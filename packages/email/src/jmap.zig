const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Jmap = struct {
    pooled: std.http.Client,
    fresh: std.http.Client,
    authorization: []const u8,
    api_url: []const u8 = "",
    max_request: usize = 0,

    pub const core_capability = "urn:ietf:params:jmap:core";
    pub const mail_capability = "urn:ietf:params:jmap:mail";
    pub const submission_capability = "urn:ietf:params:jmap:submission";

    pub fn init(gpa: Allocator, runtime_io: std.Io, authorization: []const u8) Jmap {
        return .{
            .pooled = .{ .allocator = gpa, .io = runtime_io },
            // No released connection survives for a subsequent operation.
            // The HTTP client still retains its initialized TLS trust store.
            .fresh = .{ .allocator = gpa, .io = runtime_io, .connection_pool = .{ .free_size = 0 } },
            .authorization = authorization,
        };
    }

    pub fn deinit(self: *Jmap) void {
        self.fresh.deinit();
        self.pooled.deinit();
        self.* = undefined;
    }

    pub fn io(self: *Jmap) std.Io {
        return self.pooled.io;
    }

    pub fn allocator(self: *Jmap) Allocator {
        return self.pooled.allocator;
    }

    pub fn session(self: *Jmap, a: Allocator, url: []const u8) !Value {
        return self.http(a, .session, url, null);
    }

    pub fn call(self: *Jmap, a: Allocator, comptime operation: Operation, arguments: anytype) !Value {
        var output: std.Io.Writer.Allocating = .init(a);
        defer output.deinit();
        try writeRequest(operation, arguments, &output.writer);
        const payload = output.written();
        if (payload.len > self.max_request) return error.MailRequestTooLarge;
        const reply = try self.http(a, operation, self.api_url, payload);
        return methodResult(reply, operation) catch |err| return operation.failure(.method_response, err);
    }

    pub fn requestSize(comptime operation: Operation, arguments: anytype) !u64 {
        var buffer: [256]u8 = undefined;
        var output: std.Io.Writer.Discarding = .init(&buffer);
        try writeRequest(operation, arguments, &output.writer);
        return output.fullCount();
    }

    fn writeRequest(comptime operation: Operation, arguments: anytype, writer: *std.Io.Writer) !void {
        const args = if (operation == .assign_email_properties)
            .{ .accountId = arguments.accountId, .update = arguments.update }
        else
            arguments;
        try std.json.Stringify.value(.{
            .using = &[_][]const u8{ core_capability, mail_capability, submission_capability },
            .methodCalls = .{.{ operation.method(), args, "0" }},
        }, .{}, writer);
    }

    fn http(self: *Jmap, a: Allocator, operation: Operation, url: []const u8, payload: ?[]const u8) !Value {
        const deadline = std.Io.Clock.Timestamp.fromNow(self.pooled.io, .{ .raw = .fromSeconds(60), .clock = .awake });
        return self.httpBefore(a, operation, url, payload, deadline);
    }

    fn httpBefore(self: *Jmap, a: Allocator, operation: Operation, url: []const u8, payload: ?[]const u8, deadline: std.Io.Clock.Timestamp) !Value {
        const runtime_io = self.pooled.io;
        try runtime_io.checkCancel();
        var phase: Phase = .connect;
        {
            const Result = union(enum) { response: anyerror!Value, timeout: std.Io.Cancelable!void };
            var buffer: [2]Result = undefined;
            var select = std.Io.Select(Result).init(runtime_io, &buffer);
            defer select.cancelDiscard();
            try select.concurrent(.timeout, std.Io.Clock.Timestamp.wait, .{ deadline, runtime_io });
            try select.concurrent(.response, exchange, .{ self, a, operation, url, payload, &phase });
            switch (try select.await()) {
                .response => |result| return result,
                .timeout => |result| try result,
            }
        }
        // The canceled exchange is joined before inspecting its last phase.
        return operation.failure(phase, error.MailRequestTimedOut);
    }

    fn exchange(self: *Jmap, a: Allocator, operation: Operation, url: []const u8, payload: ?[]const u8, phase: *Phase) !Value {
        const uri = std.Uri.parse(url) catch |err| return operation.failure(.connect, err);
        var target: RequestTarget = .{ .uri = uri, .arena = .init(self.allocator()) };
        defer target.arena.deinit();
        const replayable = operation.effect() != .create;
        const client = if (replayable) &self.pooled else &self.fresh;
        return self.attempt(client, a, operation, &target, payload, phase) catch |err| {
            if (!connectionFailure(err) or (!replayable and phase.* != .connect))
                return operation.failure(phase.*, err);
            std.log.warn("JMAP {s} failed during {s} with {s}. Retrying on a fresh connection", .{
                operation.method(), @tagName(phase.*), @errorName(err),
            });
            return self.attempt(&self.fresh, a, operation, &target, payload, phase) catch |second| return operation.failure(phase.*, second);
        };
    }

    fn attempt(self: *Jmap, client: *std.http.Client, a: Allocator, operation: Operation, target: *RequestTarget, payload: ?[]const u8, phase: *Phase) !Value {
        while (true) {
            phase.* = .connect;
            try client.io.checkCancel();
            var request = try client.request(if (operation == .session) .GET else .POST, target.uri, .{
                .headers = .{
                    .authorization = .{ .override = self.authorization },
                    .content_type = if (payload != null) .{ .override = "application/json" } else .omit,
                    .accept_encoding = .{ .override = "identity" },
                },
                .keep_alive = client == &self.pooled,
                .redirect_behavior = .unhandled,
            });
            defer request.deinit();
            // Closing skips the unread-body drain, including on cancellation.
            errdefer if (request.connection) |connection| {
                connection.closing = true;
            };

            phase.* = .send;
            if (payload) |bytes| {
                sendBody(&request, bytes) catch |err| return transportError(&request, err);
            } else {
                request.sendBodiless() catch |err| return transportError(&request, err);
            }
            phase.* = .response_head;
            var response = request.receiveHead(&.{}) catch |err| return transportError(&request, err);
            if (operation == .session and response.head.status.class() == .redirect and response.head.status != .not_modified) {
                // Only Location is needed. Close the unread response before the next GET.
                request.connection.?.closing = true;
                try target.follow(response.head.location);
                continue;
            }
            return readResponse(a, operation, &response, phase);
        }
    }

    fn readResponse(a: Allocator, operation: Operation, response: *std.http.Client.Response, phase: *Phase) !Value {
        if (response.head.status != .ok) {
            std.log.warn("JMAP {s} returned HTTP {d}", .{ operation.method(), @backingInt(response.head.status) });
            // A rejection applies to the whole JMAP request. A gateway
            // failure or unexpected success/redirect cannot attest to a write.
            return switch (response.head.status.class()) {
                .client_error => error.MailHttpFailure,
                .server_error => error.MailServerFailure,
                else => error.UnexpectedMailStatus,
            };
        }
        phase.* = .response_body;
        if (response.head.content_encoding != .identity) return error.UnsupportedMailEncoding;
        const content_length = if (response.head.transfer_encoding == .none) response.head.content_length else null;
        const reader = response.reader(&.{});
        var output: std.Io.Writer.Allocating = .init(a);
        defer output.deinit();
        if (content_length) |length| {
            reader.streamExact64(&output.writer, length) catch |err| {
                if (err == error.WriteFailed) return error.OutOfMemory;
                return transportError(response.request, err);
            };
        } else {
            _ = reader.streamRemaining(&output.writer) catch |err| {
                if (err == error.WriteFailed) return error.OutOfMemory;
                return transportError(response.request, err);
            };
        }
        phase.* = .decode;
        return std.json.parseFromSliceLeaky(Value, a, output.written(), .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidMailReply,
        };
    }
};

const Phase = enum { connect, send, response_head, response_body, decode, method_response };

const Operation = enum {
    session,
    @"Identity/get",
    @"Mailbox/get",
    @"Mailbox/set",
    @"Email/query",
    @"Email/get",
    @"Email/set",
    @"EmailSubmission/query",
    @"EmailSubmission/set",
    /// An update-only Email/set assigning fixed properties to existing IDs.
    assign_email_properties,

    fn method(operation: Operation) []const u8 {
        return if (operation == .assign_email_properties) "Email/set" else @tagName(operation);
    }

    fn effect(operation: Operation) enum { read, assign, create } {
        return switch (operation) {
            .session, .@"Identity/get", .@"Mailbox/get", .@"Email/query", .@"Email/get", .@"EmailSubmission/query" => .read,
            .assign_email_properties => .assign,
            .@"Mailbox/set", .@"Email/set", .@"EmailSubmission/set" => .create,
        };
    }

    fn failure(operation: Operation, phase: Phase, err: anyerror) anyerror {
        if (err == error.Canceled) return err;
        std.log.warn("JMAP {s} failed during {s} with {s}", .{ operation.method(), @tagName(phase), @errorName(err) });
        if (operation.effect() == .read or phase == .connect) return err;
        return switch (err) {
            error.MailHttpFailure, error.MailMethodUnavailable, error.MailMethodFailed, error.MailObjectFailed, error.OutOfMemory => err,
            else => error.MailMutationUnconfirmed,
        };
    }
};

/// Discovery's current URL and remaining redirects survive a connection retry.
const RequestTarget = struct {
    uri: std.Uri,
    arena: std.heap.ArenaAllocator,
    redirects_left: u8 = 3,

    fn follow(self: *RequestTarget, location: ?[]const u8) !void {
        if (self.redirects_left == 0) return error.TooManyHttpRedirects;
        const target = location orelse return error.HttpRedirectLocationMissing;
        const base = self.uri;
        // resolveInPlace stores Location and, for a relative path, the merged path after it.
        const merge_capacity = base.path.percent_encoded.len + 1 + target.len;
        var space = try self.arena.allocator().alloc(u8, target.len + merge_capacity);
        @memcpy(space[0..target.len], target);
        var next = base.resolveInPlace(target.len, &space) catch return error.HttpRedirectLocationInvalid;

        if (!std.ascii.eqlIgnoreCase(base.scheme, next.scheme)) return error.CrossOriginMailRedirect;
        const protocol = std.http.Client.Protocol.fromUri(base) orelse return error.UnsupportedUriScheme;
        const default_port: u16 = if (protocol == .tls) 443 else 80;
        var base_host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        var next_host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const base_host = try std.Io.net.HostName.fromUri(base, &base_host_buffer);
        const next_host = std.Io.net.HostName.fromUri(next, &next_host_buffer) catch return error.HttpRedirectLocationInvalid;
        if (!base_host.eql(next_host) or (base.port orelse default_port) != (next.port orelse default_port))
            return error.CrossOriginMailRedirect;
        next.scheme = base.scheme;
        self.uri = next;
        self.redirects_left -= 1;
    }
};

fn methodResult(reply: Value, operation: Operation) !Value {
    if (reply != .object) return error.InvalidMailReply;
    const calls = reply.object.get("methodResponses") orelse return error.InvalidMailReply;
    if (calls != .array or calls.array.items.len != 1) return error.InvalidMailReply;
    const invocation = calls.array.items[0];
    if (invocation != .array or invocation.array.items.len != 3) return error.InvalidMailReply;
    const parts = invocation.array.items;
    if (parts[0] != .string or parts[1] != .object or parts[2] != .string or !std.mem.eql(u8, parts[2].string, "0"))
        return error.InvalidMailReply;
    const result = parts[1].object;
    if (std.mem.eql(u8, parts[0].string, "error")) {
        const kind = result.get("type") orelse return error.InvalidMailReply;
        if (kind != .string) return error.InvalidMailReply;
        if (std.mem.eql(u8, kind.string, "serverUnavailable")) return error.MailMethodUnavailable;
        // RFC 8620 §3.6.2 requires resynchronization for this method error.
        if (std.mem.eql(u8, kind.string, "serverPartialFail")) return error.MailServerPartialFailure;
        return error.MailMethodFailed;
    }
    if (!std.mem.eql(u8, parts[0].string, operation.method())) return error.InvalidMailReply;
    const failure_field = switch (operation.effect()) {
        .read => return parts[1],
        .assign => "notUpdated",
        .create => "notCreated",
    };
    if (result.get(failure_field)) |failures| switch (failures) {
        .null => {},
        .object => |objects| if (objects.count() != 0) return error.MailObjectFailed,
        else => return error.InvalidMailReply,
    };
    return parts[1];
}

fn sendBody(request: *std.http.Client.Request, bytes: []const u8) std.Io.Writer.Error!void {
    // Keep the serialized JMAP request intact even if a write is partial.
    request.transfer_encoding = .{ .content_length = bytes.len };
    var body = try request.sendBodyUnflushed(&.{});
    try body.writer.writeAll(bytes);
    try body.endUnflushed();
    try request.connection.?.flush();
}

fn transportError(request: *std.http.Client.Request, err: anyerror) anyerror {
    const connection = request.connection orelse return err;
    if (connection.stream_reader.err) |cause| if (cause == error.Canceled) return cause;
    if (connection.stream_writer.err) |cause| if (cause == error.Canceled) return cause;
    if (err == error.ReadFailed) {
        if (request.reader.body_err) |cause| return cause;
        return connection.getReadError() orelse err;
    }
    if (err == error.WriteFailed) return connection.stream_writer.err orelse err;
    return err;
}

fn connectionFailure(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionAborted,
        error.BrokenPipe,
        error.SocketUnconnected,
        error.NetworkDown,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.Timeout,
        error.ConnectionTimedOut,
        error.NameServerFailure,
        error.HttpConnectionClosing,
        error.HttpRequestTruncated,
        error.EndOfStream,
        error.HttpChunkTruncated,
        error.TlsConnectionTruncated,
        => true,
        else => false,
    };
}

const TestHttpServer = struct {
    io: std.Io,
    listener: std.Io.net.Server,
    response: []const u8,
    close_after_response: bool = false,
    response_flushed: std.Io.Event = .unset,
    requests: usize = 0,

    fn init(io: std.Io, response: []const u8) !TestHttpServer {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        return .{ .io = io, .listener = try address.listen(io, .{}), .response = response };
    }

    fn url(self: *TestHttpServer, a: Allocator) ![]const u8 {
        return std.fmt.allocPrint(a, "http://{f}/jmap", .{self.listener.socket.address});
    }

    fn serveUntilCanceled(self: *TestHttpServer) !void {
        while (true) try self.serve();
    }

    fn serve(self: *TestHttpServer) !void {
        return self.serveRequest(null);
    }

    fn serveRequest(self: *TestHttpServer, expected_session_target: ?[]const u8) !void {
        const connection = try self.listener.accept(self.io);
        defer connection.close(self.io);
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [1024]u8 = undefined;
        var reader = connection.reader(self.io, &read_buffer);
        var writer = connection.writer(self.io, &write_buffer);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        if (expected_session_target) |target| {
            try std.testing.expectEqual(.GET, request.head.method);
            try std.testing.expectEqualStrings(target, request.head.target);
            var headers = request.iterateHeaders();
            while (headers.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) {
                    try std.testing.expectEqualStrings("test", header.value);
                    break;
                }
            } else return error.MissingAuthorization;
        }
        if (request.head.method.requestHasBody()) _ = try request.readerExpectNone(&.{}).discardRemaining();
        self.requests += 1;
        try writer.interface.writeAll(self.response);
        try writer.interface.flush();
        self.response_flushed.set(self.io);
        if (self.close_after_response) return;
        try @import("http_test").expectPeerClosed(&reader);
    }
};

test "mail HTTP deadline closes connections stalled on response headers or body" {
    const io = std.testing.io;
    for ([_][]const u8{
        "",
        "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{",
    }) |response| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var server = try TestHttpServer.init(io, response);
        defer server.listener.deinit(io);
        var serving = try io.concurrent(TestHttpServer.serve, .{&server});
        defer serving.cancel(io) catch {};
        var jmap: Jmap = .init(std.testing.allocator, io, "test");
        defer jmap.deinit();
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(100), .clock = .awake });
        try std.testing.expectError(error.MailRequestTimedOut, jmap.httpBefore(a, .@"Email/query", try server.url(a), "{}", deadline));
        try server.response_flushed.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        try serving.await(io);
    }
}

test "mail HTTP cancellation closes connections stalled on response headers or body" {
    const io = std.testing.io;
    for ([_][]const u8{
        "",
        "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{",
    }) |response| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var server = try TestHttpServer.init(io, response);
        defer server.listener.deinit(io);
        var serving = try io.concurrent(TestHttpServer.serve, .{&server});
        defer serving.cancel(io) catch {};
        var jmap: Jmap = .init(std.testing.allocator, io, "test");
        defer jmap.deinit();
        var request = try io.concurrent(Jmap.http, .{ &jmap, a, .@"Email/set", try server.url(a), "{}" });
        defer _ = request.cancel(io) catch {};
        try server.response_flushed.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        try std.testing.expectError(error.Canceled, request.cancel(io));
        try serving.await(io);
    }
}

test "mail HTTP rejects encoding without reading the response body" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var server = try TestHttpServer.init(io, "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 100\r\n\r\n");
    defer server.listener.deinit(io);
    var serving = try io.concurrent(TestHttpServer.serve, .{&server});
    defer serving.cancel(io) catch {};
    var jmap: Jmap = .init(std.testing.allocator, io, "test");
    defer jmap.deinit();
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromSeconds(5), .clock = .awake });
    try std.testing.expectError(error.UnsupportedMailEncoding, jmap.httpBefore(a, .@"Email/query", try server.url(a), "{}", deadline));
    try serving.await(io);
}

test "mail HTTP rejects complete JSON in a truncated response" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var server = try TestHttpServer.init(io, "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{\"methodResponses\":[]}");
    server.close_after_response = true;
    defer server.listener.deinit(io);
    var serving = try io.concurrent(TestHttpServer.serve, .{&server});
    defer serving.cancel(io) catch {};
    var jmap: Jmap = .init(std.testing.allocator, io, "test");
    defer jmap.deinit();
    try std.testing.expectError(error.MailMutationUnconfirmed, jmap.http(a, .@"Email/set", try server.url(a), "{}"));
    try serving.await(io);
}

test "a write following an idle close starts fresh and the next read recovers" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var server = try TestHttpServer.init(io, "");
    defer server.listener.deinit(io);
    server.close_after_response = true;
    var jmap: Jmap = .init(std.testing.allocator, io, "test");
    defer jmap.deinit();
    jmap.api_url = try server.url(a);
    jmap.max_request = 4096;
    inline for (.{
        .{ Operation.@"Email/query", "{\"ids\":[\"first\"]}" },
        .{ Operation.@"Email/set", "{\"created\":{\"copy\":{\"id\":\"saved\"}}}" },
        .{ Operation.@"Email/query", "{\"ids\":[\"saved\"]}" },
    }) |case| {
        const body = comptime "{\"methodResponses\":[[\"" ++ case[0].method() ++ "\"," ++ case[1] ++ ",\"0\"]]}";
        server.response = std.fmt.comptimePrint("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
        var serving = try io.concurrent(TestHttpServer.serve, .{&server});
        defer serving.cancel(io) catch {};
        const result = try jmap.call(a, case[0], .{ .accountId = "test" });
        try std.testing.expectEqualStrings(case[1], try std.json.Stringify.valueAlloc(a, result, .{}));
        // The peer has closed its socket before the next logical operation.
        try serving.await(io);
    }
    try std.testing.expectEqual(3, server.requests);
}

test "a lost response permits one read retry and leaves a sent mutation unconfirmed" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var server = try TestHttpServer.init(io, "");
    defer server.listener.deinit(io);
    server.close_after_response = true;
    var jmap: Jmap = .init(std.testing.allocator, io, "test");
    jmap.api_url = try server.url(a);
    jmap.max_request = 4096;
    defer jmap.deinit();
    inline for (.{
        .{ Operation.@"Email/get", error.HttpConnectionClosing, 2 },
        .{ Operation.@"Email/set", error.MailMutationUnconfirmed, 1 },
    }) |case| {
        server.requests = 0;
        var serving = try io.concurrent(TestHttpServer.serveUntilCanceled, .{&server});
        defer serving.cancel(io) catch {};
        try std.testing.expectError(case[1], jmap.call(a, case[0], .{}));
        serving.cancel(io) catch |err| if (err != error.Canceled) return err;
        try std.testing.expectEqual(case[2], server.requests);
    }
}

test "session discovery closes redirect bodies and retries the final authenticated GET" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var server = try TestHttpServer.init(io, "");
    defer server.listener.deinit(io);
    const absolute = try a.print("HTTP/1.1 307 Temporary Redirect\r\nLocation: http://{f}/mail/v2/start\r\nContent-Length: 0\r\n\r\n", .{server.listener.socket.address});
    const serve = struct {
        fn chain(peer: *TestHttpServer, absolute_redirect: []const u8) !void {
            peer.response = "HTTP/1.1 302 Found\r\nLocation: discover/start\r\nContent-Length: 100\r\n\r\n";
            try peer.serveRequest("/jmap");
            peer.response = absolute_redirect;
            try peer.serveRequest("/discover/start");
            peer.response = "HTTP/1.1 303 See Other\r\nLocation: ../session\r\nContent-Length: 0\r\n\r\n";
            try peer.serveRequest("/mail/v2/start");
            // Drop the final GET once. The retry must resume at the resolved session URL.
            peer.response = "";
            peer.close_after_response = true;
            try peer.serveRequest("/mail/session");
            peer.response = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 4\r\n\r\ntrue";
            try peer.serveRequest("/mail/session");
        }
    }.chain;
    var serving = try io.concurrent(serve, .{ &server, absolute });
    defer serving.cancel(io) catch {};
    var jmap: Jmap = .init(std.testing.allocator, io, "test");
    defer jmap.deinit();
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromSeconds(5), .clock = .awake });
    try std.testing.expect((try jmap.httpBefore(a, .session, try server.url(a), null, deadline)).bool);
    try serving.await(io);
}

test "session redirects compare the scheme, decoded host name and effective port" {
    var target: RequestTarget = .{ .uri = try std.Uri.parse("https://mail.example/start"), .arena = .init(std.testing.allocator) };
    defer target.arena.deinit();
    try target.follow("HTTPS://%6dAIL.EXAMPLE:443/session");
    try std.testing.expectEqualStrings("https", target.uri.scheme);
    for ([_][]const u8{ "http://mail.example:443/", "//api.example/", "//mail.example:444/" }) |location|
        try std.testing.expectError(error.CrossOriginMailRedirect, target.follow(location));
}

test "session discovery stops after three redirects and keeps credentials at the configured origin" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var destination = try TestHttpServer.init(io, "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\n{}");
    defer destination.listener.deinit(io);
    destination.close_after_response = true;
    var watching = try io.concurrent(TestHttpServer.serveUntilCanceled, .{&destination});
    defer watching.cancel(io) catch {};
    const other_origin = try a.print("HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\n\r\n", .{try destination.url(a)});
    for ([_]struct { reply: []const u8, err: anyerror, requests: usize }{
        .{ .reply = "HTTP/1.1 301 Moved Permanently\r\nLocation: /jmap\r\nContent-Length: 0\r\n\r\n", .err = error.TooManyHttpRedirects, .requests = 4 },
        .{ .reply = other_origin, .err = error.CrossOriginMailRedirect, .requests = 1 },
    }) |case| {
        var server = try TestHttpServer.init(io, case.reply);
        defer server.listener.deinit(io);
        var serving = try io.concurrent(TestHttpServer.serveUntilCanceled, .{&server});
        defer serving.cancel(io) catch {};
        var jmap: Jmap = .init(std.testing.allocator, io, "test");
        defer jmap.deinit();
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromSeconds(5), .clock = .awake });
        try std.testing.expectError(case.err, jmap.httpBefore(a, .session, try server.url(a), null, deadline));
        try std.testing.expectError(error.Canceled, serving.cancel(io));
        try std.testing.expectEqual(case.requests, server.requests);
    }
    try std.testing.expectError(error.Canceled, watching.cancel(io));
    try std.testing.expectEqual(0, destination.requests);
}
