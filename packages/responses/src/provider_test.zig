const std = @import("std");
const Provider = @import("provider.zig").Provider;
const Model = @import("agent_contracts").Model;
const content = @import("content");
const Content = content.Content;
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
    target: []const u8 = "/responses",
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
    file_payloads: std.ArrayList([]u8) = .empty,
    file_content_type: ?[]u8 = null,

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
            const index = self.requests.fetchAdd(1, .monotonic);
            const exchange: Exchange = if (index < self.exchanges.len) self.exchanges[index] else .{ .response = success };
            try std.testing.expectEqualStrings(exchange.target, request.head.target);
            const is_file = std.mem.eql(u8, request.head.target, "/files");
            if (is_file) {
                if (self.file_content_type) |previous| std.testing.allocator.free(previous);
                self.file_content_type = try std.testing.allocator.dupe(u8, request.head.content_type orelse return error.MissingContentType);
            }
            const body = try request.readerExpectNone(&.{}).allocRemaining(std.testing.allocator, .limited(256 * 1024));
            defer std.testing.allocator.free(body);
            if (is_file) {
                try self.file_payloads.append(std.testing.allocator, try std.testing.allocator.dupe(u8, body));
            } else {
                if (self.payload) |previous| {
                    try std.testing.expectEqualStrings(previous, body);
                } else {
                    self.payload = try std.testing.allocator.dupe(u8, body);
                }
            }
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
        for (self.server.file_payloads.items) |payload| std.testing.allocator.free(payload);
        self.server.file_payloads.deinit(std.testing.allocator);
        if (self.server.file_content_type) |content_type| std.testing.allocator.free(content_type);
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

const uploaded = reply("200 OK", "", "{\"id\":\"file-api-test\",\"object\":\"file\"}");
const upload_rejected = reply("400 Bad Request", "", "{}");

test "classified PDF uploads intact bytes and preserves paired tool outputs before file inputs" {
    var fixture = try Fixture.init(&.{ .{ .target = "/files", .response = uploaded }, .{ .response = success } });
    defer fixture.deinit();
    var provider = try fixture.start();
    const a = fixture.arena.allocator();
    const bytes = "%PDF-1.7\n\x00\xffsource bytes";
    const classified = content.classify(bytes);
    try std.testing.expect(classified == .file);
    const parts = [_]Content.Part{
        .{ .text = "Source result" },
        .{ .file = classified.file },
        .{ .text = "Sibling observation" },
    };
    var history = [_]Model.Item{
        .{ .tool_result = .{ .call_id = "read-report", .content = .{ .parts = &parts } } },
        .{ .tool_result = .{ .call_id = "other-tool", .content = .{ .parts = &.{.{ .text = "Other result" }} } } },
    };
    const request: Model.Request = .{ .history = &history, .tools = &.{}, .reasoning_effort = .high };
    try provider.port().limitToolReplies(a, request, &history);
    try std.testing.expectEqual(null, parts[1].file.reference);
    const file = history[0].tool_result.content.parts[1].file;
    try std.testing.expectEqualStrings(bytes, file.bytes);
    try std.testing.expectEqualStrings("file-api-test", file.reference.?);
    const size = try provider.port().requestBytes(a, request);
    _ = try provider.port().next(a, request);
    try fixture.finish(2);

    const body = fixture.server.file_payloads.items[0];
    try std.testing.expect(std.mem.startsWith(u8, fixture.server.file_content_type.?, "multipart/form-data; boundary="));
    const purpose_index = std.mem.indexOf(u8, body, "name=\"purpose\"\r\n\r\nrich_layout_recognition").?;
    const file_index = std.mem.indexOf(u8, body, "name=\"file\"; filename=\"document.bin\"").?;
    try std.testing.expect(purpose_index < file_index);
    try std.testing.expect(std.mem.indexOf(u8, body, bytes) != null);
    const payload = fixture.server.payload.?;
    try std.testing.expectEqual(size, payload.len);
    try std.testing.expect(std.mem.indexOf(u8, payload, "source bytes") == null);
    const encoded = try std.json.parseFromSliceLeaky(std.json.Value, a, payload, .{});
    const items = encoded.object.get("input").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("function_call_output", items[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("function_call_output", items[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("user", items[2].object.get("role").?.string);
    const output = items[0].object.get("output").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), output.len);
    try std.testing.expectEqualStrings("Source result", output[0].object.get("text").?.string);
    try std.testing.expectEqualStrings("Sibling observation", output[2].object.get("text").?.string);
    const file_input = items[2].object.get("content").?.array.items;
    try std.testing.expect(std.mem.indexOf(u8, file_input[0].object.get("text").?.string, "read-report") != null);
    try std.testing.expectEqualStrings("input_file", file_input[1].object.get("type").?.string);
    try std.testing.expectEqualStrings("file-api-test", file_input[1].object.get("file_id").?.string);
}

test "file upload negotiates from the rejection status and reuses the accepted reference" {
    var fixture = try Fixture.init(&.{
        // The rejection body is not needed for purpose negotiation.
        .{ .target = "/files", .response = "HTTP/1.1 400 Bad Request\r\nContent-Encoding: gzip\r\nContent-Length: 100000\r\n\r\n", .wait_for_close = true },
        .{ .target = "/files", .response = uploaded },
        .{ .response = success },
    });
    defer fixture.deinit();
    var provider = try fixture.start();
    const a = fixture.arena.allocator();
    const bytes = "\x00\xffsource bytes\r\ncomplete binary\x00";
    const classified = content.classify(bytes);
    try std.testing.expect(classified == .file);
    var history = [_]Model.Item{.{ .tool_result = .{ .call_id = "read", .content = .{ .parts = &.{.{ .file = classified.file }} } } }};
    const request: Model.Request = .{ .history = &history, .tools = &.{}, .reasoning_effort = .high };
    try provider.port().limitToolReplies(a, request, &history);
    const reference = history[0].tool_result.content.parts[0].file.reference.?;
    const size = try provider.port().requestBytes(a, request);
    try provider.port().limitToolReplies(a, request, &history);
    try std.testing.expectEqualStrings(reference, history[0].tool_result.content.parts[0].file.reference.?);
    try std.testing.expectEqual(size, try provider.port().requestBytes(a, request));
    _ = try provider.port().next(a, request);
    try fixture.finish(3);
    try std.testing.expectEqual(@as(usize, 2), fixture.server.file_payloads.items.len);
    const purposes = [_][]const u8{ "rich_layout_recognition", "user_data" };
    for (fixture.server.file_payloads.items, purposes) |body, purpose| {
        const purpose_field = try std.fmt.allocPrint(a, "name=\"purpose\"\r\n\r\n{s}\r\n", .{purpose});
        const purpose_index = std.mem.indexOf(u8, body, purpose_field).?;
        const file_index = std.mem.indexOf(u8, body, "name=\"file\"; filename=\"document.bin\"").?;
        try std.testing.expect(purpose_index < file_index);
        const marker = "Content-Type: application/octet-stream\r\n\r\n";
        const start = std.mem.indexOf(u8, body, marker).? + marker.len;
        const boundary_end = std.mem.indexOf(u8, body, "\r\n").?;
        const closing = try std.fmt.allocPrint(a, "\r\n{s}--\r\n", .{body[0..boundary_end]});
        try std.testing.expect(std.mem.endsWith(u8, body, closing));
        try std.testing.expectEqualSlices(u8, bytes, body[start .. body.len - closing.len]);
    }
    try std.testing.expect(std.mem.indexOf(u8, fixture.server.payload.?, "\"type\":\"input_file\"") != null);
}

test "rejected file upload negotiation stops after its second purpose" {
    for ([_]bool{ false, true }) |server_failure| {
        const exchanges = [_]Exchange{
            .{ .target = "/files", .response = upload_rejected },
            .{ .target = "/files", .response = if (server_failure) unavailable else upload_rejected },
            .{ .response = success },
        };
        var fixture = try Fixture.init(&exchanges);
        defer fixture.deinit();
        var provider = try fixture.start();
        const a = fixture.arena.allocator();
        var history = [_]Model.Item{.{ .tool_result = .{ .call_id = "read", .content = .{ .parts = &.{ .{ .file = .{ .bytes = "\x00\xffunknown" } }, .{ .text = "Sibling observation" } } } } }};
        const request: Model.Request = .{ .history = &history, .tools = &.{}, .reasoning_effort = .high };
        if (server_failure) {
            try std.testing.expectError(error.ModelHttpFailure, provider.port().limitToolReplies(a, request, &history));
            try std.testing.expectEqual(null, history[0].tool_result.content.parts[0].file.reference);
            try fixture.finish(2);
        } else {
            try provider.port().limitToolReplies(a, request, &history);
            try std.testing.expect(std.mem.indexOf(u8, history[0].tool_result.content.parts[0].text, "file_upload_failed") != null);
            try std.testing.expectEqualStrings("Sibling observation", history[0].tool_result.content.parts[1].text);
            _ = try provider.port().next(a, request);
            try fixture.finish(3);
            try std.testing.expect(std.mem.indexOf(u8, fixture.server.payload.?, "input_file") == null);
        }
        try std.testing.expectEqual(@as(usize, 2), fixture.server.file_payloads.items.len);
    }
}

test "file count limit omits only new files before uploading" {
    var fixture = try Fixture.init(&.{});
    defer fixture.deinit();
    var provider = try fixture.start();
    const a = fixture.arena.allocator();
    const reference = "file-api-retained";
    var history: [21]Model.Item = undefined;
    for (history[0..20]) |*item| item.* = .{ .tool_result = .{ .call_id = "retained", .content = .{ .parts = &.{.{ .file = .{
        .bytes = "retained bytes",
        .reference = reference,
    } }} } } };
    history[20] = .{ .tool_result = .{ .call_id = "new", .content = .{ .parts = &.{ .{ .text = "Other observation" }, .{ .file = .{ .bytes = "new bytes" } } } } } };
    const request: Model.Request = .{ .history = &history, .tools = &.{}, .reasoning_effort = .high };
    try provider.port().limitToolReplies(a, request, history[20..]);
    try std.testing.expect(history[0].tool_result.content.parts[0] == .file);
    try std.testing.expect(std.mem.indexOf(u8, history[20].tool_result.content.parts[1].text, "20 files") != null);
    try std.testing.expectEqualStrings("Other observation", history[20].tool_result.content.parts[0].text);
    try fixture.finish(0);
}

test "file rejection preserves sibling observations and infrastructure failures are not replayed" {
    for ([_]struct { response: []const u8, err: ?anyerror }{
        .{ .response = "HTTP/1.1 415 Unsupported Media Type\r\nContent-Length: 500\r\n\r\n", .err = null },
        .{ .response = unavailable, .err = error.ModelHttpFailure },
        .{ .response = reply("200 OK", "", "{\"id\":\"\"}"), .err = error.InvalidModelResponse },
    }) |case| {
        var fixture = try Fixture.init(&.{.{ .target = "/files", .response = case.response, .wait_for_close = true }});
        defer fixture.deinit();
        var provider = try fixture.start();
        var history = [_]Model.Item{.{ .tool_result = .{ .call_id = "read", .content = .{ .parts = &.{ .{ .file = .{ .bytes = "bytes" } }, .{ .text = "Sibling observation" } } } } }};
        const request: Model.Request = .{ .history = &history, .tools = &.{}, .reasoning_effort = .high };
        if (case.err) |err| {
            try std.testing.expectError(err, provider.port().limitToolReplies(fixture.arena.allocator(), request, &history));
        } else {
            try provider.port().limitToolReplies(fixture.arena.allocator(), request, &history);
            try std.testing.expect(std.mem.indexOf(u8, history[0].tool_result.content.parts[0].text, "file_upload_failed") != null);
            try std.testing.expectEqualStrings("Sibling observation", history[0].tool_result.content.parts[1].text);
        }
        try fixture.finish(1);
    }
}

test "file upload validates the complete metadata body before retaining its reference" {
    for ([_]struct { response: []const u8, err: ?anyerror }{
        .{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 500\r\n\r\n{\"id\":\"file-api-test\"}", .err = error.EndOfStream },
        .{ .response = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n{\"id\":\"file-api-test\"}", .err = null },
    }) |case| {
        var fixture = try Fixture.init(&.{.{ .target = "/files", .response = case.response }});
        defer fixture.deinit();
        var provider = try fixture.start();
        var history = [_]Model.Item{.{ .tool_result = .{ .call_id = "read", .content = .{ .parts = &.{.{ .file = .{ .bytes = "bytes" } }} } } }};
        const request: Model.Request = .{ .history = &history, .tools = &.{}, .reasoning_effort = .high };
        if (case.err) |err| {
            try std.testing.expectError(err, provider.port().limitToolReplies(fixture.arena.allocator(), request, &history));
            try std.testing.expectEqual(null, history[0].tool_result.content.parts[0].file.reference);
        } else {
            try provider.port().limitToolReplies(fixture.arena.allocator(), request, &history);
            try std.testing.expect(history[0].tool_result.content.parts[0].file.reference != null);
        }
        try fixture.finish(1);
    }
}

test "file uploads respect cancellation and deadlines without replaying uncertain effects" {
    for ([_][]const u8{ "", "HTTP/1.1 200 OK\r\nContent-Length: 500\r\n\r\n{" }) |response| {
        for ([_]bool{ false, true }) |cancel| {
            var fixture = try Fixture.init(&.{.{ .target = "/files", .response = response, .wait_for_close = true }});
            defer fixture.deinit();
            var provider = try fixture.start();
            provider.request_timeout_ms = if (cancel) 5000 else 100;
            var history = [_]Model.Item{.{ .tool_result = .{ .call_id = "read", .content = .{ .parts = &.{.{ .file = .{ .bytes = "bytes" } }} } } }};
            const request: Model.Request = .{ .history = &history, .tools = &.{}, .reasoning_effort = .high };
            if (cancel) {
                var pending = try fixture.io.concurrent(Model.Port.limitToolReplies, .{ provider.port(), fixture.arena.allocator(), request, &history });
                defer pending.cancel(fixture.io) catch {};
                try fixture.server.received.waitTimeout(fixture.io, .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } });
                try std.testing.expectError(error.Canceled, pending.cancel(fixture.io));
            } else {
                try std.testing.expectError(error.ModelFileUploadTimedOut, provider.port().limitToolReplies(fixture.arena.allocator(), request, &history));
            }
            try fixture.finish(1);
        }
    }
}
