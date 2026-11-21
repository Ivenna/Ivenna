const std = @import("std");
const Mailbox = @import("mail.zig").Mailbox;
const Jmap = @import("jmap.zig").Jmap;
const Addressing = @import("addressing.zig").Addressing;

/// Match a scalar or list of IDs at a path in the parsed request arguments.
pub const Property = struct {
    path: []const []const u8,
    json: []const u8,

    fn matches(self: Property, a: std.mem.Allocator, arguments: std.json.Value) !bool {
        var item = arguments;
        for (self.path) |key| {
            if (item != .object) return false;
            item = item.object.get(key) orelse return false;
        }
        return std.mem.eql(u8, self.json, try std.json.Stringify.valueAlloc(a, item, .{}));
    }
};

const Exchange = struct {
    method: []const u8,
    properties: []const Property = &.{},
    /// Close after receiving the request when no response was specified.
    result: ?[]const u8,
    method_error: bool = false,
};

pub const Fixture = struct {
    exchanges: []const Exchange,
    listener: std.Io.net.Server,
    serving: ?std.Io.Future(anyerror!void) = null,
    jmap: Jmap,
    arena: std.heap.ArenaAllocator = .init(std.testing.allocator),
    received: usize = 0,
    matched: bool = true,

    pub fn init(exchanges: []const Exchange) !Fixture {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        return .{
            .exchanges = exchanges,
            .listener = try address.listen(std.testing.io, .{}),
            .jmap = .init(std.testing.allocator, std.testing.io, "test"),
        };
    }

    pub fn start(self: *Fixture) !Mailbox {
        self.jmap.max_request = 1024 * 1024;
        self.jmap.api_url = try std.fmt.allocPrint(self.arena.allocator(), "http://{f}/jmap", .{self.listener.socket.address});
        self.serving = try std.testing.io.concurrent(serve, .{self});
        return .{
            .jmap = &self.jmap,
            .session_url = self.jmap.api_url,
            .address = "ivenna@example.com",
            .addressing = try Addressing.init("ivenna@example.com"),
            .account_id = "account",
            .identity_id = "identity",
            .drafts_id = "drafts",
            .callback_id = "callbacks",
            .history_id = "history",
            .trash_id = "trash",
        };
    }

    fn serve(self: *Fixture) anyerror!void {
        const io = std.testing.io;
        while (true) {
            const connection = try self.listener.accept(io);
            defer connection.close(io);
            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [1024]u8 = undefined;
            var reader = connection.reader(io, &read_buffer);
            var writer = connection.writer(io, &write_buffer);
            var http = std.http.Server.init(&reader.interface, &writer.interface);
            var request = try http.receiveHead();
            var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer scratch.deinit();
            const a = scratch.allocator();
            const payload = try request.readerExpectNone(&.{}).allocRemaining(a, .limited(1024 * 1024));
            const index = self.received;
            self.received += 1;
            if (index >= self.exchanges.len) {
                try request.respond("", .{ .status = .bad_request, .keep_alive = false });
                continue;
            }
            const step = self.exchanges[index];
            const sent = try std.json.parseFromSliceLeaky(struct {
                methodCalls: []const struct { []const u8, std.json.Value, []const u8 },
            }, a, payload, .{ .ignore_unknown_fields = true });
            self.matched = self.matched and sent.methodCalls.len == 1 and
                std.mem.eql(u8, sent.methodCalls[0][0], step.method);
            for (step.properties) |property| {
                self.matched = self.matched and try property.matches(a, sent.methodCalls[0][1]);
            }
            if (step.result) |result| {
                const body = try std.fmt.allocPrint(a, "{{\"methodResponses\":[[\"{s}\",{s},\"0\"]]}}", .{
                    if (step.method_error) "error" else step.method, result,
                });
                try request.respond(body, .{ .keep_alive = false });
            }
        }
    }

    pub fn finish(self: *Fixture) !void {
        if (self.serving) |*serving| {
            defer self.serving = null;
            serving.cancel(std.testing.io) catch |err| if (err != error.Canceled) return err;
        }
        try std.testing.expectEqual(self.exchanges.len, self.received);
        try std.testing.expect(self.matched);
    }

    pub fn deinit(self: *Fixture) void {
        if (self.serving) |*serving| serving.cancel(std.testing.io) catch {};
        self.jmap.deinit();
        self.listener.deinit(std.testing.io);
        self.arena.deinit();
    }
};
