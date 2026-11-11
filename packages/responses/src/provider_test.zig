const std = @import("std");
const Provider = @import("provider.zig").Provider;
const Model = @import("agent_contracts").Model;
const Allocator = std.mem.Allocator;

const input: Model.Request = .{
    .history = &.{.{ .message = .{ .role = .user, .text = "Continue the work." } }},
    .tools = &.{},
    .reasoning_effort = .medium,
};
const completed = "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"accepted\",\"name\":\"inspect\",\"arguments\":\"{}\"}]}";
const success = reply("200 OK", "", completed);
const unavailable = reply("503 Service Unavailable", "Retry-After: 0\r\n", "{}");
const overloaded = reply("529 Service Overloaded", "Retry-After: 0\r\n", "{}");
const rate_limited = reply("429 Too Many Requests", "Retry-After: 0\r\n", "{}");
const long_backoff = reply("429 Too Many Requests", "Retry-After: 3600\r\n", "{}");

fn reply(comptime status: []const u8, comptime headers: []const u8, comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint("HTTP/1.1 {s}\r\nContent-Length: {d}\r\n{s}\r\n{s}", .{ status, body.len, headers, body });
}

const Exchange = struct {
    response: []const u8,
    wait_for_close: bool = false,
    signal_after_close: bool = false,
};

/// A real HTTP peer captures requests and can stop before the head or body is
/// complete. An unexpected retry gets a valid reply, so it fails the assertion
/// instead of hanging the test.
const Server = struct {
    io: std.Io,
    listener: std.Io.net.Server,
    exchanges: []const Exchange,
    received: std.Io.Event = .unset,
    requests: std.atomic.Value(usize) = .init(0),
    payload: ?[]u8 = null,

    fn init(io: std.Io, exchanges: []const Exchange) !Server {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        return .{ .io = io, .listener = try address.listen(io, .{}), .exchanges = exchanges };
    }

    fn url(self: *Server, a: Allocator) ![]const u8 {
        return std.fmt.allocPrint(a, "http://{f}", .{self.listener.socket.address});
    }

    fn serve(self: *Server) anyerror!void {
        while (true) {
            const connection = try self.listener.accept(self.io);
            defer connection.close(self.io);
            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [1024]u8 = undefined;
            var reader = connection.reader(self.io, &read_buffer);
            var writer = connection.writer(self.io, &write_buffer);
            var server = std.http.Server.init(&reader.interface, &writer.interface);
            var request = try server.receiveHead();
            try std.testing.expectEqualStrings("/responses", request.head.target);
            const body = try request.readerExpectNone(&.{}).allocRemaining(std.testing.allocator, .limited(256 * 1024));
            defer std.testing.allocator.free(body);
            if (self.payload) |previous| {
                try std.testing.expectEqualStrings(previous, body);
            } else {
                self.payload = try std.testing.allocator.dupe(u8, body);
            }
            const index = self.requests.fetchAdd(1, .monotonic);
            const exchange: Exchange = if (index < self.exchanges.len) self.exchanges[index] else .{ .response = success };
            try writer.interface.writeAll(exchange.response);
            try writer.interface.flush();
            if (!exchange.signal_after_close) self.received.set(self.io);
            if (exchange.wait_for_close) {
                var buffer: [1]u8 = undefined;
                var buffers = [_][]u8{&buffer};
                if (try connection.read(self.io, &buffers) != 0) return error.UnexpectedRequestReplay;
            }
            if (exchange.signal_after_close) self.received.set(self.io);
        }
    }
};

const Fixture = struct {
    io: std.Io = std.testing.io,
    arena: std.heap.ArenaAllocator = .init(std.testing.allocator),
    server: Server,
    client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io },
    serving: ?std.Io.Future(anyerror!void) = null,

    fn init(exchanges: []const Exchange) !Fixture {
        return .{ .server = try Server.init(std.testing.io, exchanges) };
    }

    fn start(self: *Fixture) !Provider {
        self.serving = try self.io.concurrent(Server.serve, .{&self.server});
        return .{ .client = &self.client, .base_url = try self.server.url(self.arena.allocator()), .request_timeout_ms = 5000 };
    }

    fn finish(self: *Fixture, expected_requests: usize) !void {
        if (self.serving) |*serving| {
            serving.cancel(self.io) catch |err| if (err != error.Canceled) return err;
            self.serving = null;
        }
        try std.testing.expectEqual(expected_requests, self.server.requests.load(.monotonic));
    }

    fn deinit(self: *Fixture) void {
        if (self.serving) |*serving| serving.cancel(self.io) catch {};
        self.client.deinit();
        self.server.listener.deinit(self.io);
        if (self.server.payload) |payload| std.testing.allocator.free(payload);
        self.arena.deinit();
    }
};

test "model retries server errors and rate limits with the identical request" {
    var fixture = try Fixture.init(&.{ .{ .response = overloaded }, .{ .response = rate_limited }, .{ .response = success } });
    defer fixture.deinit();
    var provider = try fixture.start();
    const text = try fixture.arena.allocator().alloc(u8, 48 * 1024);
    for (text, 0..) |*byte, index| byte.* = @as(u8, @intCast(index % 23)) + 'a';
    const large_input: Model.Request = .{
        .history = &.{.{ .message = .{ .role = .user, .text = text } }},
        .tools = input.tools,
        .reasoning_effort = input.reasoning_effort,
    };
    const response = try provider.port().next(fixture.arena.allocator(), large_input);
    try std.testing.expectEqual(@as(usize, 1), response.calls.len);
    try std.testing.expectEqualStrings("accepted", response.calls[0].call_id);
    try std.testing.expectEqualStrings("inspect", response.calls[0].name);
    try std.testing.expectEqualStrings("{}", response.calls[0].arguments);
    try fixture.finish(3);
    const sent = try std.json.parseFromSliceLeaky(struct { input: []struct { content: []const u8 } }, fixture.arena.allocator(), fixture.server.payload.?, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings(text, sent.input[0].content);
}

test "model fails on non-retryable HTTP errors and invalid complete responses" {
    for ([_]struct { response: []const u8, err: anyerror, wait_for_close: bool = false }{
        .{ .response = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 500\r\n\r\n", .err = error.ModelHttpFailure, .wait_for_close = true },
        .{ .response = reply("400 Bad Request", "", "{}"), .err = error.ModelHttpFailure },
        .{ .response = reply("409 Conflict", "", "{}"), .err = error.ModelHttpFailure },
        .{ .response = reply("200 OK", "", "{"), .err = error.InvalidModelResponse },
        .{ .response = reply("200 OK", "", "{\"status\":\"incomplete\",\"output\":[]}"), .err = error.ModelResponseNotCompleted },
        .{ .response = reply("200 OK", "", "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"partial\",\"name\":\"inspect\",\"arguments\":\"{}\"},{\"type\":\"unknown\"}]}"), .err = error.InvalidModelResponse },
    }) |case| {
        var fixture = try Fixture.init(&.{.{ .response = case.response, .wait_for_close = case.wait_for_close }});
        defer fixture.deinit();
        var provider = try fixture.start();
        try std.testing.expectError(case.err, provider.port().next(fixture.arena.allocator(), input));
        try fixture.finish(1);
    }
}

test "model retries premature head and body EOF without exposing calls from the failed attempt" {
    const stale = "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"discarded\",\"name\":\"inspect\",\"arguments\":\"{}\"}]}";
    for ([_][]const u8{
        "HTTP/1.1 ",
        "HTTP/1.1 200 OK\r\nContent-Length: 500\r\n\r\n" ++ stale,
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n{",
    }) |broken| {
        var fixture = try Fixture.init(&.{ .{ .response = broken }, .{ .response = success } });
        defer fixture.deinit();
        var provider = try fixture.start();
        const response = try provider.port().next(fixture.arena.allocator(), input);
        try std.testing.expectEqual(@as(usize, 1), response.calls.len);
        try std.testing.expectEqualStrings("accepted", response.calls[0].call_id);
        try fixture.finish(2);
    }
}

test "model stops at its total attempt limit" {
    var fixture = try Fixture.init(&.{ .{ .response = unavailable }, .{ .response = unavailable } });
    defer fixture.deinit();
    var provider = try fixture.start();
    provider.max_attempts = 2;
    try std.testing.expectError(error.ModelHttpFailure, provider.port().next(fixture.arena.allocator(), input));
    try fixture.finish(2);
}

test "model rejects response encoding without reading the body or retrying" {
    var fixture = try Fixture.init(&.{.{
        .response = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 500\r\n\r\n",
        .wait_for_close = true,
    }});
    defer fixture.deinit();
    var provider = try fixture.start();
    try std.testing.expectError(error.UnsupportedModelEncoding, provider.port().next(fixture.arena.allocator(), input));
    try fixture.finish(1);
}

const waiting_exchanges = [_]Exchange{
    .{ .response = "", .wait_for_close = true },
    .{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 500\r\n\r\n{", .wait_for_close = true },
    .{ .response = long_backoff, .wait_for_close = true, .signal_after_close = true },
};

test "model deadline covers response headers, response body, and retry waits" {
    for (waiting_exchanges) |exchange| {
        var fixture = try Fixture.init(&.{exchange});
        defer fixture.deinit();
        var provider = try fixture.start();
        provider.request_timeout_ms = 100;
        try std.testing.expectError(error.ModelRequestTimedOut, provider.port().next(fixture.arena.allocator(), input));
        try fixture.finish(1);
    }
}

test "model cancellation ends response reads and retry waits without another attempt" {
    for (waiting_exchanges) |exchange| {
        var fixture = try Fixture.init(&.{exchange});
        defer fixture.deinit();
        var provider = try fixture.start();
        var request = try fixture.io.concurrent(Model.Port.next, .{ provider.port(), fixture.arena.allocator(), input });
        defer _ = request.cancel(fixture.io) catch {};
        try fixture.server.received.waitTimeout(fixture.io, .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } });
        try std.testing.expectError(error.Canceled, request.cancel(fixture.io));
        try fixture.finish(1);
    }
}
