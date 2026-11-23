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

fn reply(comptime status: []const u8, comptime headers: []const u8, comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint("HTTP/1.1 {s}\r\nConnection: close\r\nContent-Length: {d}\r\n{s}\r\n{s}", .{ status, body.len, headers, body });
}

const Exchange = struct {
    response: []const u8,
    target: []const u8 = "/responses",
    wait_for_close: bool = false,
};

/// Serve the scripted exchanges and report any additional request.
const Server = struct {
    io: std.Io,
    listener: std.Io.net.Server,
    exchanges: []const Exchange,
    response_flushed: std.Io.Event = .unset,
    script_finished: std.Io.Event = .unset,
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
        // Let finish collect a server error even if the script stopped early.
        defer self.script_finished.set(self.io);
        var index: usize = 0;
        while (true) : (index += 1) {
            if (index == self.exchanges.len) self.script_finished.set(self.io);
            const connection = try self.listener.accept(self.io);
            defer connection.close(self.io);
            var read_buffer: [4096]u8 = undefined;
            var write_buffer: [1024]u8 = undefined;
            var reader = connection.reader(self.io, &read_buffer);
            var writer = connection.writer(self.io, &write_buffer);
            var server = std.http.Server.init(&reader.interface, &writer.interface);
            var request = try server.receiveHead();
            if (index == self.exchanges.len) return error.UnexpectedRequest;
            const exchange = self.exchanges[index];
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
            } else if (self.payload == null) {
                self.payload = try std.testing.allocator.dupe(u8, body);
            }
            try writer.interface.writeAll(exchange.response);
            try writer.interface.flush();
            self.response_flushed.set(self.io);
            if (exchange.wait_for_close) try @import("http_test").expectPeerClosed(&reader);
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

    fn finish(self: *Fixture) !void {
        if (self.serving) |*serving| {
            try self.server.script_finished.waitTimeout(self.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
            defer self.serving = null;
            serving.cancel(self.io) catch |err| if (err != error.Canceled) return err;
        }
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

test "one inference sends the complete request and validates the response" {
    var fixture = try Fixture.init(&.{.{ .response = success }});
    defer fixture.deinit();
    var provider = try fixture.start();
    const text = try fixture.arena.allocator().alloc(u8, 48 * 1024);
    for (text, 0..) |*byte, index| byte.* = @as(u8, @intCast(index % 23)) + 'a';
    const large_input: Model.Request = .{
        .history = &.{.{ .message = .{ .role = .user, .text = text } }},
        .tools = input.tools,
        .reasoning_effort = input.reasoning_effort,
    };
    const response = (try provider.port().next(fixture.arena.allocator(), large_input)).response;
    try std.testing.expectEqual(@as(usize, 1), response.calls.len);
    try std.testing.expectEqualStrings("accepted", response.calls[0].call_id);
    try std.testing.expectEqualStrings("inspect", response.calls[0].name);
    try std.testing.expectEqualStrings("{}", response.calls[0].arguments);
    try fixture.finish();
    const sent = try std.json.parseFromSliceLeaky(struct { input: []struct { content: []const u8 } }, fixture.arena.allocator(), fixture.server.payload.?, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqualStrings(text, sent.input[0].content);
}

test "request rejections and unusable generations yield no tools" {
    for ([_]struct { response: []const u8, rejection: Model.Rejection }{
        .{ .response = reply("400 Bad Request", "", "{}"), .rejection = .request_rejected },
        .{ .response = reply("403 Forbidden", "", "{}"), .rejection = .request_rejected },
        .{ .response = reply("404 Not Found", "", "{}"), .rejection = .request_rejected },
        .{ .response = reply("503 Service Unavailable", "X-Should-Retry: false\r\n", "{}"), .rejection = .request_rejected },
        .{ .response = reply("206 Partial Content", "", completed), .rejection = .invalid_response },
        .{ .response = "HTTP/1.1 200 OK\r\nContent-Length: malformed\r\n\r\n", .rejection = .invalid_response },
        .{ .response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx!!", .rejection = .invalid_response },
        .{ .response = reply("200 OK", "", "{\"status\":\"incomplete\",\"output\":[]}"), .rejection = .incomplete_response },
        .{ .response = reply("200 OK", "", "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"partial\",\"name\":\"inspect\",\"arguments\":\"{}\"},{\"type\":\"unknown\"}]}"), .rejection = .invalid_response },
    }) |case| {
        var fixture = try Fixture.init(&.{.{ .response = case.response }});
        defer fixture.deinit();
        var provider = try fixture.start();
        const outcome = try provider.port().next(fixture.arena.allocator(), input);
        try std.testing.expectEqual(case.rejection, outcome.rejected);
        try fixture.finish();
    }
}

test "shared endpoint and account failures propagate" {
    for ([_]struct { response: []const u8, err: anyerror, wait_for_close: bool = false }{
        .{ .response = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 500\r\n\r\n", .err = error.ModelHttpFailure, .wait_for_close = true },
        .{ .response = reply("402 Payment Required", "", "{}"), .err = error.ModelQuotaExhausted },
        .{ .response = reply("405 Method Not Allowed", "", "{}"), .err = error.ModelHttpFailure },
        .{ .response = reply("307 Temporary Redirect", "Location: /elsewhere\r\n", "{}"), .err = error.ModelHttpFailure },
        .{ .response = reply("501 Not Implemented", "", "{}"), .err = error.ModelHttpFailure },
        .{ .response = reply("429 Too Many Requests", "Retry-After: 8\r\n", "{\"error\":{\"code\":\"insufficient_quota\"}}"), .err = error.ModelQuotaExhausted },
        .{ .response = reply("429 Too Many Requests", "x-should-retry: false\r\n", "{\"error\":{\"type\":\"insufficient_quota\",\"code\":null}}"), .err = error.ModelQuotaExhausted },
    }) |case| {
        var fixture = try Fixture.init(&.{.{ .response = case.response, .wait_for_close = case.wait_for_close }});
        defer fixture.deinit();
        var provider = try fixture.start();
        try std.testing.expectError(case.err, provider.port().next(fixture.arena.allocator(), input));
        try fixture.finish();
    }
}

test "transient HTTP and incomplete transfers return after one attempt" {
    const stale = "{\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"call_id\":\"discarded\",\"name\":\"inspect\",\"arguments\":\"{}\"}]}";
    for ([_]struct { response: []const u8, retry_after_ms: ?i64 = null }{
        .{ .response = "" },
        .{ .response = "HTTP/1.1 " },
        .{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 500\r\n\r\n" ++ stale },
        .{ .response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n{" },
        .{ .response = overloaded, .retry_after_ms = 0 },
        .{ .response = "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 80000\r\nRetry-After: 3\r\n\r\n", .retry_after_ms = 3000 },
        .{ .response = reply("429 Too Many Requests", "", "{\"error\":{\"message\":\"insufficient_quota\"}}") },
        .{ .response = "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 150\r\nRetry-After: 3\r\n\r\n{\"error\":{\"code\":\"insufficient_quota\"}}", .retry_after_ms = 3000 },
    }) |case| {
        var fixture = try Fixture.init(&.{.{ .response = case.response }});
        defer fixture.deinit();
        var provider = try fixture.start();
        const outcome = try provider.port().next(fixture.arena.allocator(), input);
        try std.testing.expectEqual(case.retry_after_ms, outcome.unavailable.retry_after_ms);
        try fixture.finish();
    }
}

test "model rejects response encoding without reading the body or retrying" {
    var fixture = try Fixture.init(&.{.{
        .response = "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 500\r\n\r\n",
        .wait_for_close = true,
    }});
    defer fixture.deinit();
    var provider = try fixture.start();
    const outcome = try provider.port().next(fixture.arena.allocator(), input);
    try std.testing.expectEqual(Model.Rejection.invalid_response, outcome.rejected);
    try fixture.finish();
}

const blocked_reads = [_]Exchange{
    .{ .response = "", .wait_for_close = true },
    .{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 500\r\n\r\n{", .wait_for_close = true },
};

test "a stalled response head or body meets the attempt deadline" {
    for (blocked_reads) |exchange| {
        var fixture = try Fixture.init(&.{exchange});
        defer fixture.deinit();
        var provider = try fixture.start();
        provider.request_timeout_ms = 100;
        const outcome = try provider.port().next(fixture.arena.allocator(), input);
        try std.testing.expectEqual(null, outcome.unavailable.retry_after_ms);
        try fixture.finish();
    }
}

test "rate-limit diagnostic timeout preserves the status and retry directive" {
    for ([_]bool{ false, true }) |no_retry| {
        const status = "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 500\r\nRetry-After: 3600\r\n";
        var fixture = try Fixture.init(&.{.{ .response = if (no_retry)
            status ++ "X-Should-Retry: false\r\n\r\n{"
        else
            status ++ "\r\n{", .wait_for_close = true }});
        defer fixture.deinit();
        var provider = try fixture.start();
        provider.request_timeout_ms = 100;
        const outcome = try provider.port().next(fixture.arena.allocator(), input);
        if (no_retry) {
            try std.testing.expectEqual(Model.Rejection.request_rejected, outcome.rejected);
        } else {
            try std.testing.expectEqual(@as(?i64, 3_600_000), outcome.unavailable.retry_after_ms);
        }
        try fixture.finish();
    }
}

test "model cancellation ends response reads without issuing another attempt" {
    for (blocked_reads ++ .{Exchange{ .response = "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 500\r\n\r\n{", .wait_for_close = true }}) |exchange| {
        var fixture = try Fixture.init(&.{exchange});
        defer fixture.deinit();
        var provider = try fixture.start();
        var request = try fixture.io.concurrent(Model.Port.next, .{ provider.port(), fixture.arena.allocator(), input });
        defer _ = request.cancel(fixture.io) catch {};
        try fixture.server.response_flushed.waitTimeout(fixture.io, .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } });
        try std.testing.expectError(error.Canceled, request.cancel(fixture.io));
        try fixture.finish();
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
    try fixture.finish();

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
    try fixture.finish();
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

test "file upload stops negotiating after the second rejection" {
    var fixture = try Fixture.init(&.{
        .{ .target = "/files", .response = upload_rejected },
        .{ .target = "/files", .response = upload_rejected },
    });
    defer fixture.deinit();
    var provider = try fixture.start();
    const part = try prepareFile(&provider, fixture.arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, part.text, "file_upload_failed") != null);
    try fixture.finish();
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
    try fixture.finish();
}

fn prepareFile(provider: *Provider, a: Allocator) !Content.Part {
    var history = [_]Model.Item{.{ .tool_result = .{ .call_id = "read", .content = .{ .parts = &.{.{ .file = .{ .bytes = "bytes" } }} } } }};
    const request: Model.Request = .{ .history = &history, .tools = &.{}, .reasoning_effort = .high };
    try provider.port().limitToolReplies(a, request, &history);
    return history[0].tool_result.content.parts[0];
}

test "a denied file upload leaves the other observations available for inference" {
    var fixture = try Fixture.init(&.{
        .{ .target = "/files", .response = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 500\r\n\r\n", .wait_for_close = true },
        .{ .response = success },
    });
    defer fixture.deinit();
    var provider = try fixture.start();
    var history = [_]Model.Item{.{ .tool_result = .{ .call_id = "read", .content = .{ .parts = &.{ .{ .file = .{ .bytes = "bytes" } }, .{ .text = "Sibling observation" } } } } }};
    const request: Model.Request = .{ .history = &history, .tools = &.{}, .reasoning_effort = .high };
    const a = fixture.arena.allocator();
    try provider.port().limitToolReplies(a, request, &history);
    const outcome = try provider.port().next(a, request);
    try std.testing.expectEqualStrings("accepted", outcome.response.calls[0].call_id);
    try fixture.finish();
    const payload = fixture.server.payload.?;
    try std.testing.expect(std.mem.indexOf(u8, payload, "file_upload_failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "Sibling observation") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "input_file") == null);
}

test "a refused connection never sent the file" {
    const io = std.testing.io;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    const reserved = try address.bind(io, .{ .mode = .stream, .protocol = .tcp });
    defer reserved.close(io);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();
    var provider: Provider = .{ .client = &client, .base_url = try std.fmt.allocPrint(a, "http://{f}", .{reserved.address}) };
    const part = try prepareFile(&provider, a);
    try std.testing.expect(std.mem.indexOf(u8, part.text, "file_upload_failed") != null);
}

test "file upload keeps a reference only from complete metadata" {
    const extension: [20 * 1024]u8 = @splat('x');
    for ([_]struct { response: []const u8, complete: bool }{
        .{ .response = "HTTP/1.1 200 OK\r\nContent-Length: 500\r\n\r\n{\"id\":\"file-api-test\"}", .complete = false },
        .{ .response = unavailable, .complete = false },
        .{ .response = reply("201 Created", "", "{\"extension\":\"" ++ extension ++ "\",\"id\":\"file-api-test\"}"), .complete = true },
        .{ .response = "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n{\"id\":\"file-api-test\"}", .complete = true },
    }) |case| {
        var fixture = try Fixture.init(&.{.{ .target = "/files", .response = case.response }});
        defer fixture.deinit();
        var provider = try fixture.start();
        const part = try prepareFile(&provider, fixture.arena.allocator());
        if (case.complete) {
            try std.testing.expectEqualStrings("file-api-test", part.file.reference.?);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, part.text, "file_upload_uncertain") != null);
        }
        try fixture.finish();
    }
}

test "file uploads respect cancellation and deadlines without replaying uncertain effects" {
    for ([_]bool{ false, true }) |cancel| {
        var fixture = try Fixture.init(&.{.{ .target = "/files", .response = "HTTP/1.1 200 OK\r\nContent-Length: 500\r\n\r\n{", .wait_for_close = true }});
        defer fixture.deinit();
        var provider = try fixture.start();
        provider.request_timeout_ms = if (cancel) 5000 else 100;
        if (cancel) {
            var pending = try fixture.io.concurrent(prepareFile, .{ &provider, fixture.arena.allocator() });
            defer _ = pending.cancel(fixture.io) catch {};
            try fixture.server.response_flushed.waitTimeout(fixture.io, .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } });
            try std.testing.expectError(error.Canceled, pending.cancel(fixture.io));
        } else {
            const part = try prepareFile(&provider, fixture.arena.allocator());
            try std.testing.expect(std.mem.indexOf(u8, part.text, "file_upload_uncertain") != null);
        }
        try fixture.finish();
    }
}
