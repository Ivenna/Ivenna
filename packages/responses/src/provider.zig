const std = @import("std");
const zdt = @import("zdt");
const Model = @import("agent_contracts").Model;
const Content = @import("content").Content;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Responses wire encoding and HTTP transport. Tool selection and execution
/// belong to the agent; HTTP exchanges use the client's cancelable Io.
pub const Provider = struct {
    pub const default_base_url = "https://api.deepseek.com";
    pub const default_model = "deepseek-flash";
    pub const default_max_output_tokens: u32 = 65536;
    pub const default_max_attempts: u32 = 3;
    pub const default_request_timeout_ms: u32 = 600000;

    client: *std.http.Client,
    base_url: []const u8 = default_base_url,
    api_key: []const u8 = "",
    model: []const u8 = default_model,
    max_output_tokens: u32 = default_max_output_tokens,
    /// Maximum HTTP attempts per inference, including the initial request.
    max_attempts: u32 = default_max_attempts,
    /// Milliseconds available for all HTTP attempts and retry waits.
    request_timeout_ms: u32 = default_request_timeout_ms,

    pub fn port(self: *Provider) Model.Port {
        return .{ .context = self, .vtable = &.{
            .next = next,
            .requestBytes = requestBytes,
            .limitToolReplies = limitToolReplies,
        } };
    }

    fn next(context: *anyopaque, arena: Allocator, request: Model.Request) anyerror!Model.Response {
        const self: *Provider = @ptrCast(@alignCast(context));
        return self.send(arena, try self.requestPayload(arena, request));
    }

    /// Measure exactly the same payload that next serializes and sends.
    fn requestBytes(context: *anyopaque, arena: Allocator, request: Model.Request) anyerror!u64 {
        const self: *Provider = @ptrCast(@alignCast(context));
        const payload = try self.requestPayload(arena, request);
        var buffer: [4096]u8 = undefined;
        var counter = std.Io.Writer.Discarding.init(&buffer);
        try std.json.Stringify.value(payload, .{}, &counter.writer);
        return counter.fullCount();
    }

    /// Preserve prior history and all non-image parts. Only the new reply
    /// parts are copied and changed, keeping the caller's other observations.
    fn limitToolReplies(context: *anyopaque, arena: Allocator, request: Model.Request, replies: []Model.Item) anyerror!void {
        const earlier = request.history[0 .. request.history.len - replies.len];
        var count = imageCount(earlier);
        var has_image = false;
        for (replies) |*reply| {
            if (reply.* != .tool_result) continue;
            const parts = try arena.dupe(Content.Part, reply.tool_result.content.parts);
            reply.tool_result.content.parts = parts;
            for (parts) |*part| {
                if (part.* != .image) continue;
                if (part.image == .url) {
                    const url = part.image.url;
                    if ((std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://")) and
                        try std.unicode.utf8CountCodepoints(url) > 8192)
                    {
                        part.* = try contentLimitPart(arena, "Image omitted: the HTTP(S) image URL exceeds 8192 Unicode code points.");
                        continue;
                    }
                }
                if (count >= 600) {
                    part.* = try contentLimitPart(arena, "Image omitted: the model request would contain more than 600 images.");
                } else {
                    count += 1;
                    has_image = true;
                }
            }
        }
        if (!has_image or try requestBytes(context, arena, request) <= 48 * 1024 * 1024) return;
        var index = replies.len;
        while (index > 0) {
            index -= 1;
            if (replies[index] != .tool_result) continue;
            // All tool result parts were copied above and belong to arena.
            const parts = @constCast(replies[index].tool_result.content.parts);
            var part_index = parts.len;
            while (part_index > 0) {
                part_index -= 1;
                if (parts[part_index] != .image) continue;
                parts[part_index] = try contentLimitPart(arena, "Image omitted: the model request would exceed 48 MiB.");
                if (try requestBytes(context, arena, request) <= 48 * 1024 * 1024) return;
            }
        }
    }

    const WireTool = struct {
        type: []const u8 = "function",
        name: []const u8,
        description: []const u8,
        parameters: Value,
    };

    const Payload = struct {
        model: []const u8,
        input: []const Value,
        tools: []const WireTool,
        tool_choice: []const u8,
        max_output_tokens: u32,
        reasoning: struct { effort: Model.ReasoningEffort },
        stream: bool = false,
    };

    fn requestPayload(self: Provider, arena: Allocator, request: Model.Request) !Payload {
        const input = try arena.alloc(Value, request.history.len);
        for (request.history, input) |item, *encoded| encoded.* = try encodeItem(arena, item);
        const tools = try arena.alloc(WireTool, request.tools.len);
        for (request.tools, tools) |tool, *encoded| encoded.* = .{
            .name = tool.name,
            .description = tool.description,
            .parameters = tool.parameters,
        };
        return .{
            .model = self.model,
            .input = input,
            .tools = tools,
            .tool_choice = if (tools.len == 0) "none" else "auto",
            .max_output_tokens = self.max_output_tokens,
            .reasoning = .{ .effort = request.reasoning_effort },
        };
    }

    fn send(self: Provider, arena: Allocator, request_payload: Payload) !Model.Response {
        const io = self.client.io;
        try io.checkCancel();
        const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
            .raw = .fromMilliseconds(self.request_timeout_ms),
            .clock = .awake,
        });
        const payload = try std.json.Stringify.valueAlloc(arena, request_payload, .{});
        const url = try std.fmt.allocPrint(arena, "{s}/responses", .{std.mem.trimEnd(u8, self.base_url, "/")});
        const authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.api_key});

        const Result = union(enum) { response: anyerror!Model.Response, timeout: std.Io.Cancelable!void };
        var buffer: [2]Result = undefined;
        var select = std.Io.Select(Result).init(io, &buffer);
        // Join the exchange before the caller can release its request arena.
        defer select.cancelDiscard();
        try select.concurrent(.response, sendWithRetries, .{ self, arena, payload, url, authorization });
        try select.concurrent(.timeout, waitForDeadline, .{ io, deadline });
        return switch (try select.await()) {
            .response => |result| try result,
            .timeout => |result| blk: {
                try result;
                break :blk error.ModelRequestTimedOut;
            },
        };
    }

    const Attempt = union(enum) {
        response: Model.Response,
        retry: struct { status: std.http.Status, after_ms: ?i64 },
    };

    fn sendWithRetries(self: Provider, arena: Allocator, payload: []const u8, url: []const u8, authorization: []const u8) !Model.Response {
        const io = self.client.io;
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            try io.checkCancel();
            var after_ms: ?i64 = null;
            if (self.sendAttempt(arena, payload, url, authorization)) |result| {
                switch (result) {
                    .response => |response| return response,
                    .retry => |retry| {
                        if (attempt >= self.max_attempts) {
                            std.log.warn("model endpoint returned HTTP {d}; exhausted {d} attempts", .{ @backingInt(retry.status), attempt });
                            return error.ModelHttpFailure;
                        }
                        after_ms = retry.after_ms;
                        std.log.warn("model endpoint returned HTTP {d}; retrying after attempt {d}/{d}", .{ @backingInt(retry.status), attempt, self.max_attempts });
                    },
                }
            } else |err| {
                if (!retryableTransport(err) or attempt >= self.max_attempts) return err;
                std.log.warn("model transport failed ({s}); retrying after attempt {d}/{d}", .{ @errorName(err), attempt, self.max_attempts });
            }
            var random: [2]u8 = undefined;
            io.random(&random);
            const delay_ms = after_ms orelse retryDelay(attempt, std.mem.readInt(u16, &random, .little));
            try io.sleep(.fromMilliseconds(delay_ms), .awake);
        }
    }

    fn sendAttempt(self: Provider, arena: Allocator, payload: []const u8, url: []const u8, authorization: []const u8) !Attempt {
        // Response bytes are temporary; decoded output belongs to the caller.
        var scratch = std.heap.ArenaAllocator.init(self.client.allocator);
        defer scratch.deinit();
        const temporary = scratch.allocator();
        var request = try self.client.request(.POST, try std.Uri.parse(url), .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = authorization },
                .accept_encoding = .{ .override = "identity" },
            },
            .redirect_behavior = .unhandled,
        });
        defer request.deinit();
        // Closing skips Request.deinit's unread-body drain, which could block
        // again after cancellation has already been delivered.
        errdefer if (request.connection) |connection| {
            connection.closing = true;
        };
        sendPayload(&request, payload) catch |err| return transportError(&request, err);
        var response = request.receiveHead(&.{}) catch |err| return transportError(&request, err);
        if (retryableStatus(response.head.status)) {
            const after_ms = retryAfter(response.head, self.client.io);
            request.connection.?.closing = true;
            return .{ .retry = .{ .status = response.head.status, .after_ms = after_ms } };
        }
        if (response.head.status != .ok) {
            std.log.warn("model endpoint returned HTTP {d}", .{@backingInt(response.head.status)});
            return error.ModelHttpFailure;
        }
        if (response.head.content_encoding != .identity) return error.UnsupportedModelEncoding;
        const content_length = if (response.head.transfer_encoding == .none) response.head.content_length else null;
        const reader = response.reader(&.{});
        var output = std.Io.Writer.Allocating.init(temporary);
        defer output.deinit();
        if (content_length) |length| {
            reader.streamExact64(&output.writer, length) catch |err| {
                if (err == error.WriteFailed) return error.OutOfMemory;
                return transportError(&request, err);
            };
        } else {
            _ = reader.streamRemaining(&output.writer) catch |err| {
                if (err == error.WriteFailed) return error.OutOfMemory;
                return transportError(&request, err);
            };
        }
        return .{ .response = try decodeResponse(arena, output.written()) };
    }

    /// Decode every output item before returning calls for execution. Check
    /// fields needed for text and call extraction; retain each complete item
    /// as adapter-private continuation, including uninterpreted fields.
    fn decodeResponse(arena: Allocator, bytes: []const u8) !Model.Response {
        const decoded = std.json.parseFromSliceLeaky(struct {
            status: []const u8,
            output: []const Value,
        }, arena, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidModelResponse,
        };
        if (!std.mem.eql(u8, decoded.status, "completed")) return error.ModelResponseNotCompleted;
        var calls: std.ArrayList(Model.Call) = .empty;
        defer calls.deinit(arena);
        var text = std.Io.Writer.Allocating.init(arena);
        defer text.deinit();
        var has_text = false;
        for (decoded.output) |item| {
            const kind = try textField(item, "type");
            if (std.mem.eql(u8, kind, "reasoning")) continue;
            if (std.mem.eql(u8, kind, "message")) {
                const parts = try field(item, "content");
                if (parts != .array) return error.InvalidModelResponse;
                for (parts.array.items) |part| {
                    if (!std.mem.eql(u8, try textField(part, "type"), "output_text")) return error.InvalidModelResponse;
                    const value = try textField(part, "text");
                    has_text = true;
                    if (value.len == 0) continue;
                    if (text.written().len != 0) try text.writer.writeAll("\n\n");
                    try text.writer.writeAll(value);
                }
                continue;
            }
            if (!std.mem.eql(u8, kind, "function_call")) return error.InvalidModelResponse;
            const call_id = try textField(item, "call_id");
            if (call_id.len == 0) return error.InvalidModelResponse;
            for (calls.items) |previous| {
                if (std.mem.eql(u8, previous.call_id, call_id)) return error.InvalidModelResponse;
            }
            try calls.append(arena, .{
                .call_id = call_id,
                .name = try textField(item, "name"),
                .arguments = try textField(item, "arguments"),
            });
        }
        const output = try arena.alloc(Model.Item, decoded.output.len);
        for (decoded.output, output) |item, *retained|
            retained.* = .{ .continuation = try std.json.Stringify.valueAlloc(arena, item, .{}) };
        return .{
            .output = output,
            .calls = try calls.toOwnedSlice(arena),
            .text = if (has_text) try text.toOwnedSlice() else null,
        };
    }
};

fn encodeItem(arena: Allocator, item: Model.Item) !Value {
    switch (item) {
        .continuation => |bytes| return std.json.parseFromSliceLeaky(Value, arena, bytes, .{}),
        .message => |message| {
            var fields: std.json.ObjectMap = .empty;
            try fields.put(arena, "role", .{ .string = @tagName(message.role) });
            try fields.put(arena, "content", .{ .string = message.text });
            return .{ .object = fields };
        },
        .tool_result => |result| {
            const parts = try arena.alloc(Value, result.content.parts.len);
            for (result.content.parts, parts) |part, *encoded| encoded.* = try encodeContentPart(arena, part);
            var fields: std.json.ObjectMap = .empty;
            try fields.put(arena, "type", .{ .string = "function_call_output" });
            try fields.put(arena, "call_id", .{ .string = result.call_id });
            try fields.put(arena, "output", .{ .array = std.array_list.Managed(Value).fromOwnedSlice(arena, parts) });
            return .{ .object = fields };
        },
    }
}

fn encodeContentPart(arena: Allocator, part: Content.Part) !Value {
    var encoded: std.json.ObjectMap = .empty;
    switch (part) {
        .text => |text| {
            try encoded.put(arena, "type", .{ .string = "input_text" });
            try encoded.put(arena, "text", .{ .string = text });
        },
        .image => |source| {
            const url = switch (source) {
                .url => |url| url,
                .data => |image| blk: {
                    const encoder = std.base64.standard.Encoder;
                    const mime = image.mimeType();
                    const prefix_length = "data:".len + mime.len + ";base64,".len;
                    const url = try arena.alloc(u8, prefix_length + encoder.calcSize(image.bytes.len));
                    _ = try std.fmt.bufPrint(url[0..prefix_length], "data:{s};base64,", .{mime});
                    _ = encoder.encode(url[prefix_length..], image.bytes);
                    break :blk url;
                },
            };
            try encoded.put(arena, "type", .{ .string = "input_image" });
            try encoded.put(arena, "image_url", .{ .string = url });
        },
    }
    return .{ .object = encoded };
}

fn contentLimitPart(arena: Allocator, message: []const u8) !Content.Part {
    return .{ .text = try std.json.Stringify.valueAlloc(arena, .{
        .@"error" = .{ .code = "content_limit", .message = message },
    }, .{}) };
}

fn imageCount(history: []const Model.Item) usize {
    var count: usize = 0;
    for (history) |item| {
        if (item != .tool_result) continue;
        for (item.tool_result.content.parts) |part| {
            if (part == .image) count += 1;
        }
    }
    return count;
}

fn transportError(request: *std.http.Client.Request, err: anyerror) anyerror {
    // std.http reader/writer adapters erase Canceled to ReadFailed/WriteFailed.
    // Cancellation is delivered once, so checkCancel cannot recover it later.
    if (request.connection) |connection| {
        if (connection.stream_reader.err) |cause| if (cause == error.Canceled) return cause;
        if (connection.stream_writer.err) |cause| if (cause == error.Canceled) return cause;
        if (err == error.ReadFailed) {
            if (request.reader.body_err) |cause| return cause;
            return connection.getReadError() orelse err;
        }
        if (err == error.WriteFailed) {
            if (connection.stream_writer.err) |cause| return cause;
        }
    }
    return err;
}

fn sendPayload(request: *std.http.Client.Request, payload: []const u8) std.Io.Writer.Error!void {
    // sendBodyComplete uses its input as a mutable buffer and can shift it
    // after partial writes. Keep the serialized payload intact for retries.
    request.transfer_encoding = .{ .content_length = payload.len };
    var body = try request.sendBodyUnflushed(&.{});
    try body.writer.writeAll(payload);
    try body.end();
}

fn waitForDeadline(io: std.Io, deadline: std.Io.Clock.Timestamp) std.Io.Cancelable!void {
    try deadline.wait(io);
}

fn retryableStatus(status: std.http.Status) bool {
    return status.class() == .server_error or status == .request_timeout or status == .too_many_requests;
}

fn retryableTransport(err: anyerror) bool {
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

fn retryDelay(attempt: u32, random: u16) i64 {
    const base: i64 = @as(i64, 500) << @intCast(@min(attempt - 1, 4));
    // Equal jitter spreads concurrent sessions over half to all of the delay.
    return @divTrunc(base, 2) + @divTrunc(@divTrunc(base, 2) * random, std.math.maxInt(u16));
}

fn retryAfter(head: std.http.Client.Response.Head, io: std.Io) ?i64 {
    var headers = head.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after"))
            return retryAfterMilliseconds(header.value, std.Io.Clock.real.now(io).toMilliseconds());
    }
    return null;
}

fn retryAfterMilliseconds(raw: []const u8, now_ms: i64) ?i64 {
    const value = std.mem.trim(u8, raw, " \t");
    if (value.len == 0) return null;
    if (for (value) |byte| {
        if (!std.ascii.isDigit(byte)) break false;
    } else true) {
        const seconds = std.fmt.parseInt(i64, value, 10) catch return std.math.maxInt(i64);
        return seconds *| 1000;
    }

    // IMF-fixdate uses English names and UTC.
    if (value.len != 29 or !std.mem.eql(u8, value[3..5], ", ") or value[7] != ' ' or
        value[11] != ' ' or value[16] != ' ' or value[19] != ':' or value[22] != ':' or
        !std.mem.eql(u8, value[25..], " GMT")) return null;
    _ = zdt.Datetime.Weekday.nameShortToInt(value[0..3]) catch return null;
    const date = zdt.Datetime.fromFields(.{
        .year = std.fmt.parseUnsigned(i16, value[12..16], 10) catch return null,
        .month = zdt.Datetime.Month.nameShortToInt(value[8..11]) catch return null,
        .day = std.fmt.parseUnsigned(u8, value[5..7], 10) catch return null,
        .hour = std.fmt.parseUnsigned(u8, value[17..19], 10) catch return null,
        .minute = std.fmt.parseUnsigned(u8, value[20..22], 10) catch return null,
        .second = std.fmt.parseUnsigned(u8, value[23..25], 10) catch return null,
        .tz_options = .{ .tz = &zdt.Timezone.UTC },
    }) catch return null;
    const timestamp_ms: i64 = @intCast(date.toUnix(.millisecond));
    return @max(0, timestamp_ms -| now_ms);
}

test "Retry-After preserves server timing and ignores invalid dates" {
    const testing = std.testing;
    try testing.expectEqual(@as(?i64, 2000), retryAfterMilliseconds(" 2 ", 0));
    try testing.expectEqual(@as(?i64, 0), retryAfterMilliseconds("0", 0));
    try testing.expectEqual(@as(?i64, 1500), retryAfterMilliseconds("Thu, 01 Jan 1970 00:00:02 GMT", 500));
    try testing.expectEqual(@as(?i64, 0), retryAfterMilliseconds("Thu, 01 Jan 1970 00:00:02 GMT", 3000));
    try testing.expectEqual(@as(?i64, 500), retryAfterMilliseconds("Wed, 21 Oct 2015 07:28:00 GMT", 1445412479500));
    try testing.expectEqual(null, retryAfterMilliseconds("-1", 0));
    try testing.expectEqual(null, retryAfterMilliseconds("tomorrow", 0));
    try testing.expectEqual(null, retryAfterMilliseconds("Fri, 30 Feb 2024 00:00:00 GMT", 0));
}

fn field(value: Value, name: []const u8) error{InvalidModelResponse}!Value {
    if (value != .object) return error.InvalidModelResponse;
    return value.object.get(name) orelse error.InvalidModelResponse;
}

fn textField(value: Value, name: []const u8) error{InvalidModelResponse}![]const u8 {
    const found = try field(value, name);
    if (found != .string) return error.InvalidModelResponse;
    return found.string;
}
