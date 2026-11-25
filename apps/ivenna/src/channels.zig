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
    channels: std.StringHashMapUnmanaged(Channel) = .empty,

    // Bound the sockets and tasks serving local receivers.
    const max_connections = 128;
    /// Reserved entries accept readers and sends only after activation.
    const Channel = struct {
        receivers: std.DoublyLinkedList = .{},
        active: bool = false,
    };
    const Receiver = struct {
        connection: Stream,
        deadline: ?std.Io.Clock.Timestamp,
        node: std.DoublyLinkedList.Node = .{},
        state: enum { waiting, between_reads, finished } = .finished,

        fn expired(self: *const Receiver, io: std.Io) bool {
            const end = self.deadline orelse return false;
            return end.durationFromNow(io).raw.toNanoseconds() <= 0;
        }

        fn park(self: *Receiver, receivers: *std.DoublyLinkedList) void {
            receivers.append(&self.node);
            self.state = .waiting;
        }

        fn finish(self: *Receiver, receivers: *std.DoublyLinkedList) void {
            receivers.remove(&self.node);
            self.state = .finished;
            ipc.endRequests(self.connection);
        }
    };

    pub fn listen(a: Allocator, io: std.Io, data_directory: []const u8) !Registry {
        return .{ .allocator = a, .io = io, .listener = try ipc.listen(io, data_directory) };
    }

    pub fn deinit(self: *Registry) void {
        self.listener.deinit(self.io);
        var entries = self.channels.iterator();
        while (entries.next()) |entry| {
            std.debug.assert(entry.value_ptr.receivers.first == null);
            self.allocator.free(entry.key_ptr.*);
        }
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
        var receiver: Receiver = .{
            .connection = connection,
            .deadline = if (request.timeout_ms) |ms| .fromNow(self.io, .{ .raw = .fromMilliseconds(ms), .clock = .awake }) else null,
        };
        if (!self.startReceive(request.id, &receiver)) return;
        while (self.waitForNext(request.id, &receiver)) {}
    }

    fn waitForNext(self: *Registry, id: []const u8, receiver: *Receiver) bool {
        const result = ipc.waitForNext(receiver.connection, self.io, receiver.deadline);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (receiver.state == .finished) return false;
        const channel = self.channels.getPtr(id).?;
        if (receiver.state == .between_reads and result == .next) {
            // Rejoin at the back so older pending reads get first chance.
            channel.receivers.remove(&receiver.node);
            receiver.park(&channel.receivers);
            return true;
        }
        if (result == .timeout) ipc.reply(receiver.connection, .timeout) catch {};
        receiver.finish(&channel.receivers);
        return false;
    }

    fn startReceive(self: *Registry, id: []const u8, receiver: *Receiver) bool {
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);
        const channel = self.channels.getPtr(id) orelse {
            ipc.reply(receiver.connection, .unknown_channel) catch {};
            return false;
        };
        if (!channel.active) {
            ipc.reply(receiver.connection, .unknown_channel) catch {};
            return false;
        }
        ipc.reply(receiver.connection, .waiting) catch return false;
        receiver.park(&channel.receivers);
        return true;
    }

    pub fn port(self: *Registry) Channels {
        return .{ .context = self, .vtable = &.{
            .open = open,
            .activate = activate,
            .close = close,
            .trySend = trySend,
        } };
    }

    fn open(context: *anyopaque, id: []const u8) !void {
        const self: *Registry = @ptrCast(@alignCast(context));
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const owned_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned_id);
        try self.channels.putNoClobber(self.allocator, owned_id, .{});
    }

    fn activate(context: *anyopaque, id: []const u8) !void {
        const self: *Registry = @ptrCast(@alignCast(context));
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const channel = self.channels.getPtr(id) orelse return error.UnknownChannel;
        channel.active = true;
    }

    fn close(context: *anyopaque, id: []const u8) bool {
        const self: *Registry = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const removed = self.channels.fetchRemove(id) orelse return false;
        var channel = removed.value;
        while (channel.receivers.first) |node| {
            const receiver: *Receiver = @alignCast(@fieldParentPtr("node", node));
            ipc.reply(receiver.connection, if (receiver.expired(self.io)) .timeout else .closed) catch {};
            receiver.finish(&channel.receivers);
        }
        self.allocator.free(removed.key);
        return true;
    }

    fn trySend(context: *anyopaque, id: []const u8, message: []const u8) !Channels.SendOutcome {
        const self: *Registry = @ptrCast(@alignCast(context));
        std.debug.assert(message.len != 0);
        if (message.len > Channels.max_message_bytes) return .too_long;
        try self.io.checkCancel();
        if (!self.mutex.tryLock()) return .would_block;
        defer self.mutex.unlock(self.io);

        const channel = self.channels.getPtr(id) orelse return .unknown_channel;
        if (!channel.active) return .unknown_channel;
        var candidate = channel.receivers.first;
        while (candidate) |node| {
            candidate = node.next;
            const receiver: *Receiver = @alignCast(@fieldParentPtr("node", node));
            if (receiver.state != .waiting) continue;
            if (receiver.expired(self.io)) {
                ipc.reply(receiver.connection, .timeout) catch {};
                receiver.finish(&channel.receivers);
                continue;
            }
            ipc.reply(receiver.connection, .{ .message = message }) catch |err| switch (err) {
                error.PeerDisconnected => {
                    receiver.finish(&channel.receivers);
                    continue;
                },
                error.WouldBlock => continue,
                else => return err,
            };
            if (receiver.deadline == null) {
                receiver.state = .between_reads;
            } else {
                receiver.finish(&channel.receivers);
            }
            return .accepted;
        }
        return .would_block;
    }
};
