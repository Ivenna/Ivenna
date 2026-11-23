const std = @import("std");
const Allocator = std.mem.Allocator;

const web = @import("web.zig");
const Outcome = web.Outcome;

const JsonString = struct {
    bytes: []const u8,

    // A Zig byte slice also accepts an array of integers. The service's text
    // fields must be JSON strings so every returned range contains UTF-8.
    pub fn jsonParse(a: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!JsonString {
        if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
        return .{ .bytes = try std.json.innerParse([]const u8, a, source, options) };
    }
};

const Error = error{
    FetchTimeout,
    FetchUnavailable,
    InvalidFetchResponse,
    PageTooLarge,
    Canceled,
    OutOfMemory,
};

const response_limit = 32 * 1024 * 1024;

pub const Client = struct {
    http: *std.http.Client,
    api_key: []const u8,
    endpoint: std.Uri = std.Uri.parse("https://api.deepseek.com/v1/tools/fetch") catch unreachable,

    pub fn reader(self: *const Client) web.Reader {
        return .{
            .context = self,
            .disclosure = "Reading a web page sends its URL to DeepSeek Fetch and may incur a charge.",
            .fetch = fetch,
        };
    }

    fn fetch(context: *const anyopaque, arena: Allocator, url: []const u8) error{ Canceled, OutOfMemory }!Outcome {
        const self: *const Client = @ptrCast(@alignCast(context));
        const characters = std.unicode.utf8CountCodepoints(url) catch return .failed(.invalid_uri, "The web URL contains invalid UTF-8.");
        if (characters > 8192) return .failed(.invalid_uri, "The web reader accepts URLs up to 8192 characters.");
        return self.fetchPage(arena, url) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => |cause| cause,
            error.PageTooLarge => .failed(.page_too_large, "The page is too large to retrieve."),
            error.FetchTimeout => .failed(.read_timeout, "The web reader timed out while retrieving this page."),
            error.InvalidFetchResponse => .failed(.web_unavailable, "The web service returned an unusable response."),
            error.FetchUnavailable => .failed(.web_unavailable, "Could not reach the web service or complete the read."),
        };
    }

    fn fetchPage(self: Client, arena: Allocator, url: []const u8) Error!Outcome {
        const io = self.http.io;
        try io.checkCancel();
        const Event = union(enum) { response: Error!Outcome, deadline: std.Io.Cancelable!void };
        var events: [2]Event = undefined;
        var select = std.Io.Select(Event).init(io, &events);
        defer select.cancelDiscard();
        select.concurrent(.response, exchange, .{ self, arena, url }) catch return error.FetchUnavailable;
        select.concurrent(.deadline, std.Io.sleep, .{ io, .fromSeconds(60), .awake }) catch return error.FetchUnavailable;
        switch (try select.await()) {
            .response => |result| return result,
            .deadline => |result| {
                try result;
                return error.FetchTimeout;
            },
        }
    }
};

fn exchange(service: Client, arena: Allocator, url: []const u8) Error!Outcome {
    const client = service.http;
    const payload = try std.json.Stringify.valueAlloc(arena, .{ .url = url }, .{});
    const authorization = try arena.print("Bearer {s}", .{service.api_key});
    var request = client.request(.POST, service.endpoint, .{
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = authorization },
            .accept_encoding = .{ .override = "identity" },
        },
        .redirect_behavior = .unhandled,
    }) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => |cause| return cause,
        else => return error.FetchUnavailable,
    };
    defer request.deinit();
    // Avoid draining an oversized, incomplete or canceled body on release.
    errdefer if (request.connection) |connection| {
        connection.closing = true;
    };
    request.sendBodyComplete(payload) catch |err| return connectionFailure(&request, err);
    var response = request.receiveHead(&.{}) catch |err| return connectionFailure(&request, err);
    if (response.head.status != .ok) {
        // We consume only the status. Closing skips the unread response body.
        request.connection.?.closing = true;
        const status = response.head.status;
        std.log.scoped(.resources).info("DeepSeek Fetch returned HTTP {d}", .{@backingInt(status)});
        return switch (status) {
            .forbidden => .failed(.not_readable, "The web service denied access to this URL."),
            .not_found => .failed(.not_readable, "The web service could not retrieve readable content at this URL."),
            .unauthorized => .failed(.web_unavailable, "The web service rejected the runtime's credentials."),
            .payment_required => .failed(.web_unavailable, "The web service account has insufficient balance."),
            .too_many_requests => .failed(.rate_limited, "The web service is rate limiting requests. Try again later."),
            .request_timeout, .gateway_timeout => .failed(.read_timeout, "The web service timed out handling this request."),
            else => .failed(.web_unavailable, try arena.print("The web service returned HTTP {d}.", .{@backingInt(status)})),
        };
    }
    if (response.head.content_encoding != .identity) return error.InvalidFetchResponse;
    const length = if (response.head.transfer_encoding == .none) response.head.content_length else null;
    if (length) |size| if (size > response_limit) return error.PageTooLarge;
    var buffer: [4096]u8 = undefined;
    const body = response.reader(&buffer).allocRemaining(arena, .limited(response_limit)) catch |err| switch (err) {
        error.StreamTooLong => return error.PageTooLarge,
        error.ReadFailed => return connectionFailure(&request, err),
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (length) |size| if (size != body.len) return error.InvalidFetchResponse;
    const parsed = std.json.parseFromSliceLeaky(struct { title: JsonString, content: JsonString }, arena, body, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidFetchResponse,
    };
    return .{ .page = .{ .title = parsed.title.bytes, .markdown = parsed.content.bytes } };
}

fn connectionFailure(request: *std.http.Client.Request, err: anyerror) Error {
    switch (err) {
        error.Canceled, error.OutOfMemory => |cause| return cause,
        else => {},
    }
    if (request.connection) |connection| {
        if (connection.stream_reader.err) |cause| if (cause == error.Canceled) return error.Canceled;
        if (connection.stream_writer.err) |cause| if (cause == error.Canceled) return error.Canceled;
    }
    return error.FetchUnavailable;
}
