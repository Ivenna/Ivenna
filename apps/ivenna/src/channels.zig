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

        fn hasReceiver(self: *const Channel) !bool {
            var candidate = self.receivers.first;
            while (candidate) |node| : (candidate = node.next) {
                const receiver: *const Receiver = @alignCast(@fieldParentPtr("node", node));
                // A hangup can be visible before the reader task unlinks itself.
                var descriptors = [_]std.posix.pollfd{.{
                    .fd = receiver.connection.socket.handle,
                    .events = 0,
                    .revents = 0,
                }};
                if (try std.posix.poll(&descriptors, 0) == 0) return true;
            }
            return false;
        }
    };
    const Receiver = struct {
        const State = enum { waiting, between_reads, closed, finished };

        connection: Stream,
        node: std.DoublyLinkedList.Node = .{},
        state: State = .finished,

        fn park(self: *Receiver, receivers: *std.DoublyLinkedList) void {
            receivers.append(&self.node);
            self.state = .waiting;
        }

        fn detach(self: *Receiver, receivers: *std.DoublyLinkedList, state: State) void {
            std.debug.assert(state == .closed or state == .finished);
            receivers.remove(&self.node);
            self.state = state;
        }

        fn interrupt(self: *Receiver, receivers: *std.DoublyLinkedList, state: State) void {
            self.detach(receivers, state);
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
        const id = ipc.readChannelId(connection, self.io, &data) catch return;
        var receiver: Receiver = .{ .connection = connection };
        if (!self.startReceive(id, &receiver)) return;
        while (self.waitForNext(id, &receiver)) {}
        if (receiver.state == .closed) ipc.replyClosed(connection, self.io) catch |err| switch (err) {
            error.Canceled, error.PeerDisconnected => {},
            else => std.log.warn("channel '{s}' close reply failed: {s}", .{ id, @errorName(err) }),
        };
    }

    fn waitForNext(self: *Registry, id: []const u8, receiver: *Receiver) bool {
        const requested_next = ipc.waitForNext(receiver.connection, self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (receiver.state == .finished or receiver.state == .closed) return false;
        const channel = self.channels.getPtr(id).?;
        if (receiver.state == .between_reads and requested_next) {
            // Rejoin at the back so older pending reads get first chance.
            channel.receivers.remove(&receiver.node);
            receiver.park(&channel.receivers);
            return true;
        }
        receiver.detach(&channel.receivers, .finished);
        return false;
    }

    // Access under the registry mutex. Reserved channels are still private.
    fn activeChannel(self: *Registry, id: []const u8) ?*Channel {
        const channel = self.channels.getPtr(id) orelse return null;
        return if (channel.active) channel else null;
    }

    fn startReceive(self: *Registry, id: []const u8, receiver: *Receiver) bool {
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);
        const channel = self.activeChannel(id) orelse {
            ipc.reply(receiver.connection, .unknown_channel) catch {};
            return false;
        };
        ipc.reply(receiver.connection, .waiting) catch return false;
        receiver.park(&channel.receivers);
        return true;
    }

    pub fn port(self: *Registry) Channels {
        return .{ .context = self, .vtable = &.{
            .reserve = reserve,
            .activate = activate,
            .close = close,
            .trySend = trySend,
            .hasReceiver = hasReceiver,
        } };
    }

    fn hasReceiver(context: *anyopaque, id: []const u8) std.Io.Cancelable!?bool {
        const self: *Registry = @ptrCast(@alignCast(context));
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const channel = self.activeChannel(id).?;
        return channel.hasReceiver() catch |err| {
            std.log.warn("channel receiver probe failed for '{s}': {s}", .{ id, @errorName(err) });
            return null;
        };
    }

    fn reserve(context: *anyopaque, id: []const u8) !void {
        const self: *Registry = @ptrCast(@alignCast(context));
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const owned_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned_id);
        try self.channels.putNoClobber(self.allocator, owned_id, .{});
    }

    fn activate(context: *anyopaque, id: []const u8) void {
        const self: *Registry = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const channel = self.channels.getPtr(id).?;
        std.debug.assert(!channel.active);
        channel.active = true;
    }

    fn close(context: *anyopaque, id: []const u8) void {
        const self: *Registry = @ptrCast(@alignCast(context));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const removed = self.channels.fetchRemove(id).?;
        var channel = removed.value;
        while (channel.receivers.first) |node| {
            const receiver: *Receiver = @alignCast(@fieldParentPtr("node", node));
            receiver.interrupt(&channel.receivers, .closed);
        }
        self.allocator.free(removed.key);
    }

    fn trySend(context: *anyopaque, id: []const u8, message: []const u8) !Channels.SendOutcome {
        const self: *Registry = @ptrCast(@alignCast(context));
        std.debug.assert(message.len != 0);
        if (message.len > Channels.max_message_bytes) return .too_long;
        try self.io.checkCancel();
        if (!self.mutex.tryLock()) return .would_block;
        defer self.mutex.unlock(self.io);

        const channel = self.activeChannel(id) orelse return .unknown_channel;
        var candidate = channel.receivers.first;
        while (candidate) |node| {
            candidate = node.next;
            const receiver: *Receiver = @alignCast(@fieldParentPtr("node", node));
            if (receiver.state != .waiting) continue;
            ipc.reply(receiver.connection, .{ .message = message }) catch |err| switch (err) {
                error.PeerDisconnected => {
                    receiver.interrupt(&channel.receivers, .finished);
                    continue;
                },
                error.WouldBlock => continue,
                else => return err,
            };
            receiver.state = .between_reads;
            return .accepted;
        }
        return if (try channel.hasReceiver()) .would_block else .no_receiver;
    }
};

test "channel close reports retirement after a matched message fills the socket" {
    const testing = std.testing;
    const io = testing.io;
    const linux = std.os.linux;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(directory);
    var registry = try Registry.listen(testing.allocator, io, directory);
    defer registry.deinit();
    var task = try io.concurrent(Registry.run, .{&registry});
    defer task.cancel(io) catch {};

    const id = "events-1";
    const channels = registry.port();
    try channels.reserve(id);
    channels.activate(id);
    const receiver = try ipc.connect(io, directory, id);
    defer receiver.close(io);
    var response: [ipc.response_buffer_size]u8 = undefined;
    try testing.expectEqualDeep(@as(ipc.Response, .waiting), try readTestResponse(receiver, &response));

    const server = server: {
        try registry.mutex.lock(io);
        defer registry.mutex.unlock(io);
        const channel = registry.channels.getPtr(id).?;
        const attached: *Registry.Receiver = @alignCast(@fieldParentPtr("node", channel.receivers.first.?));
        break :server attached.connection;
    };
    const buffer_size: c_int = 4096;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.setsockopt(
        server.socket.handle,
        linux.SOL.SOCKET,
        linux.SO.SNDBUF,
        std.mem.asBytes(&buffer_size),
        @sizeOf(c_int),
    )));
    const message: [Channels.max_message_bytes]u8 = @splat('x');
    try testing.expectEqual(.accepted, try channels.trySend(id, &message));
    try testing.expectError(error.WouldBlock, ipc.reply(server, .closed));

    channels.close(id);
    var hangup = [_]std.posix.pollfd{.{ .fd = receiver.socket.handle, .events = 0, .revents = 0 }};
    try testing.expectEqual(0, try std.posix.poll(&hangup, 50));
    try testing.expectEqualDeep(ipc.Response{ .message = &message }, try readTestResponse(receiver, &response));
    try testing.expectEqualDeep(@as(ipc.Response, .closed), try readTestResponse(receiver, &response));
}

fn readTestResponse(receiver: Stream, buffer: *[ipc.response_buffer_size]u8) !ipc.Response {
    var descriptors = [_]std.posix.pollfd{.{ .fd = receiver.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expect(try std.posix.poll(&descriptors, 5000) != 0);
    return ipc.readResponse(receiver, buffer);
}
