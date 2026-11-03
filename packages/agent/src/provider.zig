const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Content = @import("content.zig").Content;

/// Every request uses the worker's Io, so canceling it also cancels its HTTP I/O.
pub const Provider = struct {
    pub const default_base_url = "https://api.deepseek.com";
    pub const default_model = "deepseek-flash";

    client: *std.http.Client,
    base_url: []const u8 = default_base_url,
    api_key: []const u8 = "",
    model: []const u8 = default_model,

    pub const FunctionCall = struct {
        call_id: []const u8,
        name: []const u8,
        arguments: []const u8,
    };

    /// Output and call fields belong to the allocator supplied to next.
    pub const Response = struct {
        output: []const Value,
        calls: []const FunctionCall,
    };

    /// Encode tool content and reject locally detectable limit violations.
    /// JSON storage and encoded local images use arena; call_id, text, and
    /// remote URL strings borrow their inputs.
    pub fn toolReply(self: Provider, arena: Allocator, call_id: []const u8, content: []const Content, history: []const Value) !Value {
        var has_image = false;
        for (content) |part| {
            if (part == .image) has_image = true;
        }
        if (!has_image) return encodeToolReply(arena, call_id, content);
        if (imageLimit(content, history)) |message|
            return contentLimitReply(arena, call_id, content, message);

        const reply = try encodeToolReply(arena, call_id, content);
        const input = try arena.alloc(Value, history.len + 1);
        @memcpy(input[0..history.len], history);
        input[history.len] = reply;
        if (try self.requestSize(arena, input) > 48 * 1024 * 1024)
            return contentLimitReply(arena, call_id, content, "Images omitted: the next model request would exceed 48 MiB.");
        return reply;
    }

    /// Remove image parts in history[reply_start..], newest first, until the
    /// request fits or no new images remain.
    pub fn limitToolReplies(self: Provider, arena: Allocator, history: []Value, reply_start: usize) !void {
        var has_image = false;
        for (history[reply_start..]) |reply| {
            if (hasImage(reply)) {
                has_image = true;
                break;
            }
        }
        if (!has_image or try self.requestSize(arena, history) <= 48 * 1024 * 1024) return;
        var index = history.len;
        while (index > reply_start) {
            index -= 1;
            if (!hasImage(history[index])) continue;
            const rejection = try contentLimitReply(arena, try textField(history[index], "call_id"), &.{}, "Images omitted: the completed tool results would make the next model request exceed 48 MiB.");
            var parts: std.array_list.Managed(Value) = .init(arena);
            for (contentParts(history[index])) |part| {
                if (imageUrl(part) == null) try parts.append(part);
            }
            try parts.appendSlice(contentParts(rejection));
            try history[index].object.put(arena, "output", .{ .array = parts });
            if (try self.requestSize(arena, history) <= 48 * 1024 * 1024) return;
        }
    }

    fn requestSize(self: Provider, arena: Allocator, input: []const Value) !u64 {
        var buffer: [4096]u8 = undefined;
        var counter = std.Io.Writer.Discarding.init(&buffer);
        try std.json.Stringify.value(try self.requestPayload(arena, input), .{}, &counter.writer);
        return counter.fullCount();
    }

    const Payload = struct {
        model: []const u8,
        input: []const Value,
        tools: Value,
        stream: bool = false,
    };

    fn requestPayload(self: Provider, arena: Allocator, input: []const Value) !Payload {
        return .{
            .model = self.model,
            .input = input,
            .tools = try std.json.parseFromSliceLeaky(Value, arena, @embedFile("tools.json"), .{}),
        };
    }

    pub fn next(self: Provider, arena: Allocator, input: []const Value) !Response {
        try self.client.io.checkCancel();

        const payload = try std.json.Stringify.valueAlloc(arena, try self.requestPayload(arena, input), .{});
        const url = try std.fmt.allocPrint(arena, "{s}/responses", .{std.mem.trimEnd(u8, self.base_url, "/")});
        const authorization = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.api_key});
        var output = std.Io.Writer.Allocating.init(arena);
        defer output.deinit();
        var request = try self.client.request(.POST, try std.Uri.parse(url), .{
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .authorization = .{ .override = authorization },
                .accept_encoding = .{ .override = "identity" },
            },
            .redirect_behavior = .unhandled,
        });
        defer request.deinit();
        request.sendBodyComplete(payload) catch |err| return transportError(&request, err);
        var response = request.receiveHead(&.{}) catch |err| return transportError(&request, err);
        if (response.head.status != .ok) {
            std.log.err("model endpoint returned HTTP {d}", .{@backingInt(response.head.status)});
            _ = response.reader(&.{}).streamRemaining(&output.writer) catch |err| return transportError(&request, err);
            const failure = std.json.parseFromSliceLeaky(struct {
                @"error": struct { message: []const u8 },
            }, arena, output.written(), .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.ModelHttpFailure,
            };
            const detail = failure.@"error".message;
            const message = if (self.api_key.len == 0) detail else try std.mem.replaceOwned(u8, arena, detail, self.api_key, "[redacted]");
            std.log.err("model endpoint: {s}", .{message});
            return error.ModelHttpFailure;
        }
        if (response.head.content_encoding != .identity) return error.UnsupportedModelEncoding;
        const reader = response.reader(&.{});
        _ = reader.streamRemaining(&output.writer) catch |err| return transportError(&request, err);
        const decoded = std.json.parseFromSliceLeaky(struct {
            status: []const u8,
            output: []const Value,
        }, arena, output.written(), .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidModelResponse,
        };
        if (!std.mem.eql(u8, decoded.status, "completed")) return error.ModelResponseNotCompleted;
        var calls: std.ArrayList(FunctionCall) = .empty;
        defer calls.deinit(arena);
        // Validate the complete batch before Engine can execute any tool.
        for (decoded.output) |item| {
            if (!std.mem.eql(u8, try textField(item, "type"), "function_call")) continue;
            try calls.append(arena, .{
                .call_id = try textField(item, "call_id"),
                .name = try textField(item, "name"),
                .arguments = try textField(item, "arguments"),
            });
        }
        return .{ .output = decoded.output, .calls = try calls.toOwnedSlice(arena) };
    }
};

fn encodeToolReply(arena: Allocator, call_id: []const u8, content: []const Content) !Value {
    var parts: std.array_list.Managed(Value) = .init(arena);
    for (content) |part| {
        var encoded: std.json.ObjectMap = .empty;
        switch (part) {
            .text => |value| {
                try encoded.put(arena, "type", .{ .string = "input_text" });
                try encoded.put(arena, "text", .{ .string = value });
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
        try parts.append(.{ .object = encoded });
    }
    var reply: std.json.ObjectMap = .empty;
    try reply.put(arena, "type", .{ .string = "function_call_output" });
    try reply.put(arena, "call_id", .{ .string = call_id });
    try reply.put(arena, "output", .{ .array = parts });
    return .{ .object = reply };
}

fn contentLimitReply(arena: Allocator, call_id: []const u8, content: []const Content, message: []const u8) !Value {
    const text = try std.json.Stringify.valueAlloc(arena, .{
        .@"error" = .{ .code = "content_limit", .message = message },
    }, .{});
    var parts: std.array_list.Managed(Content) = .init(arena);
    for (content) |part| {
        if (part == .text) try parts.append(part);
    }
    try parts.append(.{ .text = text });
    return encodeToolReply(arena, call_id, parts.items);
}

/// Count image parts without interpreting their URLs.
fn imageLimit(content: []const Content, history: []const Value) ?[]const u8 {
    var count: usize = 0;
    for (content) |part| {
        if (part == .image) count += 1;
    }
    for (history) |item| {
        for (contentParts(item)) |part| {
            if (imageUrl(part) != null) count += 1;
        }
    }
    if (count > 600) return "Images omitted: this result would exceed 600 images in one model request.";
    return null;
}

fn contentParts(item: Value) []const Value {
    if (item != .object) return &.{};
    const parts = item.object.get("content") orelse item.object.get("output") orelse return &.{};
    return if (parts == .array) parts.array.items else &.{};
}

fn hasImage(item: Value) bool {
    for (contentParts(item)) |part| {
        if (imageUrl(part) != null) return true;
    }
    return false;
}

fn imageUrl(part: Value) ?[]const u8 {
    if (part != .object) return null;
    const kind = part.object.get("type") orelse return null;
    if (kind != .string or !std.mem.eql(u8, kind.string, "input_image")) return null;
    const url = part.object.get("image_url") orelse return null;
    return if (url == .string) url.string else null;
}

fn transportError(request: *std.http.Client.Request, err: anyerror) anyerror {
    // std.http reader/writer adapters erase Canceled to ReadFailed/WriteFailed.
    // Cancellation is delivered once, so checkCancel cannot recover it later.
    if (request.connection) |connection| {
        if (connection.stream_reader.err) |cause| if (cause == error.Canceled) return cause;
        if (connection.stream_writer.err) |cause| if (cause == error.Canceled) return cause;
    }
    return err;
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
