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

    // Bound the sockets and tasks serving local receivers.
    const max_connections = 128;
    const Channel = struct {
        opening_focus_id: []const u8,
        description: ?[]const u8,
        waiting: std.DoublyLinkedList = .{},
    };
    const ReceiveRequest = struct {
        connection: Stream,
        deadline: ?std.Io.Clock.Timestamp,
        node: std.DoublyLinkedList.Node = .{},
        linked: bool = false,

        fn expired(self: *const ReceiveRequest, io: std.Io) bool {
            const end = self.deadline orelse return false;
            return end.durationFromNow(io).raw.toNanoseconds() <= 0;
        }

        fn park(self: *ReceiveRequest, waiting: *std.DoublyLinkedList) void {
            waiting.append(&self.node);
            self.linked = true;
        }

        fn remove(self: *ReceiveRequest, waiting: *std.DoublyLinkedList) void {
            waiting.remove(&self.node);
            self.linked = false;
        }

        fn finish(self: *ReceiveRequest, waiting: *std.DoublyLinkedList) void {
            self.remove(waiting);
            ipc.endRequests(self.connection);
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
            if (active.load(.monotonic) >= max_connections) {
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
        var receive: ReceiveRequest = .{
            .connection = connection,
            .deadline = if (request.timeout_ms) |ms| .fromNow(self.io, .{ .raw = .fromMilliseconds(ms), .clock = .awake }) else null,
        };
        if (!self.startReceive(request.id, &receive)) return;
        while (self.waitForNext(request.id, &receive)) {}
    }

    fn waitForNext(self: *Registry, id: []const u8, receive: *ReceiveRequest) bool {
        const result = ipc.waitForNext(receive.connection, self.io, receive.deadline);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (receive.linked) {
            const channel = self.channels.getPtr(id).?;
            receive.remove(&channel.waiting);
            if (result == .timeout) ipc.reply(receive.connection, .timeout) catch {};
            return false;
        }
        if (result != .next or receive.deadline != null) return false;
        const channel = self.channels.getPtr(id) orelse {
            ipc.reply(receive.connection, .closed) catch {};
            return false;
        };
        receive.park(&channel.waiting);
        return true;
    }

    fn startReceive(self: *Registry, id: []const u8, receive: *ReceiveRequest) bool {
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);
        const channel = self.channels.getPtr(id) orelse {
            ipc.reply(receive.connection, .unknown_channel) catch {};
            return false;
        };
        ipc.reply(receive.connection, .waiting) catch return false;
        receive.park(&channel.waiting);
        return true;
    }

    pub fn port(self: *Registry) Channels {
        return .{ .context = self, .vtable = &.{
            .open = open,
            .close = close,
            .trySend = trySend,
            .sample = sample,
        } };
    }

    fn open(context: *anyopaque, id: []const u8, opening_focus_id: []const u8, description: ?[]const u8) !void {
        const self: *Registry = @ptrCast(@alignCast(context));
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const owned_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned_id);
        const owned_focus = try self.allocator.dupe(u8, opening_focus_id);
        errdefer self.allocator.free(owned_focus);
        const owned_description = if (description) |text| try self.allocator.dupe(u8, text) else null;
        errdefer if (owned_description) |text| self.allocator.free(text);
        try self.channels.putNoClobber(self.allocator, owned_id, .{ .opening_focus_id = owned_focus, .description = owned_description });
    }

    fn close(context: *anyopaque, id: []const u8) !bool {
        const self: *Registry = @ptrCast(@alignCast(context));
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const removed = self.channels.fetchOrderedRemove(id) orelse return false;
        var channel = removed.value;
        while (channel.waiting.first) |node| {
            const receive: *ReceiveRequest = @alignCast(@fieldParentPtr("node", node));
            ipc.reply(receive.connection, if (receive.expired(self.io)) .timeout else .closed) catch {};
            receive.finish(&channel.waiting);
        }
        self.release(removed.key, channel);
        return true;
    }

    fn release(self: *Registry, id: []const u8, channel: Channel) void {
        std.debug.assert(channel.waiting.first == null);
        self.allocator.free(channel.opening_focus_id);
        if (channel.description) |text| self.allocator.free(text);
        self.allocator.free(id);
    }

    fn trySend(context: *anyopaque, id: []const u8, message: []const u8) !Channels.SendOutcome {
        const self: *Registry = @ptrCast(@alignCast(context));
        std.debug.assert(message.len != 0);
        if (message.len > Channels.max_message_bytes) return .too_long;
        try self.io.checkCancel();
        if (!self.mutex.tryLock()) return .would_block;
        defer self.mutex.unlock(self.io);

        const channel = self.channels.getPtr(id) orelse return .unknown_channel;
        var candidate = channel.waiting.first;
        while (candidate) |node| {
            candidate = node.next;
            const receive: *ReceiveRequest = @alignCast(@fieldParentPtr("node", node));
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
                error.WouldBlock => continue,
                else => return err,
            };
            if (receive.deadline == null) {
                receive.remove(&channel.waiting);
            } else {
                receive.finish(&channel.waiting);
            }
            return .accepted;
        }
        return .would_block;
    }

    fn sample(context: *anyopaque, arena: Allocator, opening_focus_id: ?[]const u8) ![]const Channels.Registration {
        const self: *Registry = @ptrCast(@alignCast(context));
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        var registrations: std.ArrayList(Channels.Registration) = .empty;
        for (self.channels.keys(), self.channels.values()) |id, channel| {
            if (opening_focus_id) |focus| if (!std.mem.eql(u8, focus, channel.opening_focus_id)) continue;
            try registrations.append(arena, .{
                .channel_id = try arena.dupe(u8, id),
                .description = if (channel.description) |text| try arena.dupe(u8, text) else null,
            });
        }
        return registrations.items;
    }
};
