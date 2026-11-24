const std = @import("std");
const contracts = @import("agent_contracts");
const ipc = @import("channel_ipc.zig");
const Channels = contracts.Channels;
const Allocator = std.mem.Allocator;
const Stream = std.Io.net.Stream;

pub const Registry = struct {
    allocator: Allocator,
    io: std.Io,
    listener: std.Io.net.Server,
    mutex: std.Io.Mutex = .init,
    channels: std.StringArrayHashMapUnmanaged(Channel) = .{},

    // Bound the connections and tasks serving local receive requests.
    const max_receive_requests = 128;
    const Channel = struct {
        focus_id: []const u8,
        waiting: std.DoublyLinkedList = .{},
    };
    const Receive = struct {
        connection: Stream,
        deadline: ?std.Io.Clock.Timestamp,
        node: std.DoublyLinkedList.Node = .{},
        linked: bool = false,

        fn expired(self: *const Receive, io: std.Io) bool {
            const end = self.deadline orelse return false;
            return end.durationFromNow(io).raw.toNanoseconds() <= 0;
        }

        fn finish(self: *Receive, waiting: *std.DoublyLinkedList) void {
            waiting.remove(&self.node);
            self.linked = false;
            ipc.wakeAfterReply(self.connection);
        }
    };

    pub fn listen(a: Allocator, io: std.Io, data_directory: []const u8) !Registry {
        return .{ .allocator = a, .io = io, .listener = try ipc.listen(io, data_directory) };
    }

    pub fn deinit(self: *Registry) void {
        self.listener.deinit(self.io);
        for (self.channels.keys(), self.channels.values()) |id, channel| self.release(id, channel);
        self.channels.deinit(self.allocator);
    }

    pub fn run(self: *Registry) !void {
        var active: std.atomic.Value(usize) = .init(0);
        var tasks: std.Io.Group = .init;
        defer tasks.cancel(self.io);
        while (true) {
            const connection = self.listener.accept(self.io) catch |err| switch (err) {
                error.ConnectionAborted => continue,
                else => return err,
            };
            ipc.requireSameUser(connection) catch {
                connection.close(self.io);
                continue;
            };
            if (active.load(.monotonic) >= max_receive_requests) {
                connection.close(self.io);
                continue;
            }
            _ = active.fetchAdd(1, .monotonic);
            tasks.concurrent(self.io, handle, .{ self, connection, &active }) catch {
                _ = active.fetchSub(1, .monotonic);
                connection.close(self.io);
            };
        }
    }

    fn handle(self: *Registry, connection: Stream, active: *std.atomic.Value(usize)) void {
        defer _ = active.fetchSub(1, .monotonic);
        defer connection.close(self.io);
        var data: [ipc.request_buffer_size]u8 = undefined;
        const request = ipc.readRequest(connection, self.io, &data) catch return;
        var receive: Receive = .{
            .connection = connection,
            .deadline = if (request.wait_ms) |ms| .fromNow(self.io, .{ .raw = .fromMilliseconds(ms), .clock = .awake }) else null,
        };
        if (!self.register(request, &receive)) return;

        const timed_out = blk: {
            ipc.waitForDisconnect(connection, self.io, receive.deadline) catch |err| break :blk err == error.Timeout;
            break :blk false;
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (receive.linked) {
            const channel = self.channels.getPtr(request.id).?;
            channel.waiting.remove(&receive.node);
            if (timed_out) ipc.reply(connection, .timeout) catch {};
        }
    }

    fn register(self: *Registry, request: ipc.Request, receive: *Receive) bool {
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);
        const channel = self.channels.getPtr(request.id) orelse {
            ipc.reply(receive.connection, .unknown_channel) catch {};
            return false;
        };
        ipc.reply(receive.connection, .waiting) catch return false;
        channel.waiting.append(&receive.node);
        receive.linked = true;
        return true;
    }

    pub fn port(self: *Registry) Channels {
        return .{ .context = self, .open = open, .close = close, .send = send, .sample = sample };
    }

    fn open(context: *anyopaque, id: []const u8, focus_id: []const u8) !void {
        const self: *Registry = @ptrCast(@alignCast(context));
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const owned_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned_id);
        const owned_focus_id = try self.allocator.dupe(u8, focus_id);
        errdefer self.allocator.free(owned_focus_id);
        try self.channels.putNoClobber(self.allocator, owned_id, .{ .focus_id = owned_focus_id });
    }

    fn close(context: *anyopaque, id: []const u8) !bool {
        const self: *Registry = @ptrCast(@alignCast(context));
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const removed = self.channels.fetchOrderedRemove(id) orelse return false;
        var channel = removed.value;
        while (channel.waiting.first) |node| {
            const receive: *Receive = @alignCast(@fieldParentPtr("node", node));
            ipc.reply(receive.connection, if (receive.expired(self.io)) .timeout else .closed) catch {};
            receive.finish(&channel.waiting);
        }
        self.release(removed.key, channel);
        return true;
    }

    fn release(self: *Registry, id: []const u8, channel: Channel) void {
        std.debug.assert(channel.waiting.first == null);
        self.allocator.free(channel.focus_id);
        self.allocator.free(id);
    }

    fn send(context: *anyopaque, id: []const u8, message: []const u8) !Channels.Outcome {
        const self: *Registry = @ptrCast(@alignCast(context));
        std.debug.assert(message.len != 0);
        if (message.len > Channels.max_bytes) return .too_long;
        try self.io.checkCancel();
        if (!self.mutex.tryLock()) return .busy;
        defer self.mutex.unlock(self.io);

        const channel = self.channels.getPtr(id) orelse return .unknown_channel;
        while (channel.waiting.first) |node| {
            const receive: *Receive = @alignCast(@fieldParentPtr("node", node));
            if (receive.expired(self.io)) {
                ipc.reply(receive.connection, .timeout) catch {};
                receive.finish(&channel.waiting);
                continue;
            }
            ipc.reply(receive.connection, .{ .message = message }) catch |err| switch (err) {
                error.PeerDisconnected => {
                    receive.finish(&channel.waiting);
                    continue;
                },
                error.WouldBlock => return .busy,
                else => return err,
            };
            receive.finish(&channel.waiting);
            return .accepted;
        }
        return .no_receiver;
    }

    fn sample(context: *anyopaque, a: Allocator, focus_id: ?[]const u8) ![]const []const u8 {
        const self: *Registry = @ptrCast(@alignCast(context));
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        var ids: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (ids.items) |id| a.free(id);
            ids.deinit(a);
        }
        for (self.channels.keys(), self.channels.values()) |id, channel| {
            if (focus_id) |focus| if (!std.mem.eql(u8, focus, channel.focus_id)) continue;
            try ids.ensureUnusedCapacity(a, 1);
            ids.appendAssumeCapacity(try a.dupe(u8, id));
        }
        return ids.toOwnedSlice(a);
    }
};
