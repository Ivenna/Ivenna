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
    max_output_tokens: u32 = 8192,
    tool_scope: enum { all, coordination } = .all,

    pub const FunctionCall = struct {
        call_id: []const u8,
        name: []const u8,
        arguments: []const u8,
    };

    /// Output and call fields belong to the allocator supplied to next.
    pub const Response = struct {
        output: []const Value,
        calls: []const FunctionCall,
        text: ?[]const u8,
    };

    /// Encode content parts without changing their source descriptions.
    /// limitToolReplies applies provider limits to the complete tool batch.
    /// JSON storage and encoded local images use arena; call_id, text, and
    /// remote URL strings borrow their inputs.
    pub fn toolReply(arena: Allocator, call_id: []const u8, content: Content) !Value {
        const parts = try arena.alloc(Value, content.parts.len);
        for (content.parts, parts) |part, *encoded| encoded.* = try encodeContentPart(arena, part);
        var reply: std.json.ObjectMap = .empty;
        try reply.put(arena, "type", .{ .string = "function_call_output" });
        try reply.put(arena, "call_id", .{ .string = call_id });
        try reply.put(arena, "output", .{ .array = std.array_list.Managed(Value).fromOwnedSlice(arena, parts) });
        return .{ .object = reply };
    }

    /// Limit new images in history[reply_start..], preserving all other parts
    /// and earlier history. Keep images in order up to the count limit, then
    /// remove from the end until the complete request fits the byte limit.
    pub fn limitToolReplies(self: Provider, arena: Allocator, history: []Value, reply_start: usize) !void {
        var count = imageCount(history[0..reply_start]);
        var has_image = false;
        for (history[reply_start..]) |reply| {
            for (contentParts(reply)) |*part| {
                if (imageUrl(part.*) == null) continue;
                if (count >= 600) {
                    part.* = try contentLimitPart(arena, "Image omitted: the model request would contain more than 600 images.");
                } else {
                    count += 1;
                    has_image = true;
                }
            }
        }
        if (!has_image or try self.requestBytes(arena, history) <= 48 * 1024 * 1024) return;
        var index = history.len;
        while (index > reply_start) {
            index -= 1;
            const parts = contentParts(history[index]);
            var part_index = parts.len;
            while (part_index > 0) {
                part_index -= 1;
                if (imageUrl(parts[part_index]) == null) continue;
                parts[part_index] = try contentLimitPart(arena, "Image omitted: the model request would exceed 48 MiB.");
                if (try self.requestBytes(arena, history) <= 48 * 1024 * 1024) return;
            }
        }
    }

    /// The complete serialized request, including tools and output settings.
    /// Byte budgets bound request bodies; they are not model token estimates.
    pub fn requestBytes(self: Provider, arena: Allocator, input: []const Value) !u64 {
        return payloadBytes(try self.requestPayload(arena, input));
    }

    pub fn requestBytesWithoutTools(self: Provider, arena: Allocator, input: []const Value) !u64 {
        return payloadBytes(self.withoutToolsPayload(arena, input));
    }

    fn payloadBytes(payload: Payload) !u64 {
        var buffer: [4096]u8 = undefined;
        var counter = std.Io.Writer.Discarding.init(&buffer);
        try std.json.Stringify.value(payload, .{}, &counter.writer);
        return counter.fullCount();
    }

    const Payload = struct {
        model: []const u8,
        input: []const Value,
        tools: Value,
        tool_choice: []const u8 = "auto",
        max_output_tokens: u32,
        stream: bool = false,
    };

    fn requestPayload(self: Provider, arena: Allocator, input: []const Value) !Payload {
        var declarations = try std.json.parseFromSliceLeaky(Value, arena, @embedFile("tools.json"), .{});
        if (self.tool_scope == .coordination) {
            var selected = std.array_list.Managed(Value).init(arena);
            for (declarations.array.items) |tool| {
                const name = tool.object.get("name") orelse continue;
                if (name != .string) continue;
                if (std.mem.eql(u8, name.string, "fork_session") or std.mem.eql(u8, name.string, "send_message")) {
                    try selected.append(tool);
                }
            }
            declarations = .{ .array = selected };
        }
        return .{
            .model = self.model,
            .input = input,
            .tools = declarations,
            .max_output_tokens = self.max_output_tokens,
        };
    }

    pub fn next(self: Provider, arena: Allocator, input: []const Value) !Response {
        return self.send(arena, try self.requestPayload(arena, input));
    }

    /// Request with no tool declarations and tool_choice set to none.
    /// The caller supplies the task and validates its result.
    pub fn nextWithoutTools(self: Provider, arena: Allocator, input: []const Value) !Response {
        return self.send(arena, self.withoutToolsPayload(arena, input));
    }

    fn withoutToolsPayload(self: Provider, arena: Allocator, input: []const Value) Payload {
        return .{
            .model = self.model,
            .input = input,
            .tools = .{ .array = std.array_list.Managed(Value).init(arena) },
            .tool_choice = "none",
            .max_output_tokens = self.max_output_tokens,
        };
    }

    fn send(self: Provider, arena: Allocator, request_payload: Payload) !Response {
        try self.client.io.checkCancel();

        const payload = try std.json.Stringify.valueAlloc(arena, request_payload, .{});
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
        return decodeResponse(arena, output.written());
    }

    /// Decode and validate the complete response before any tool can run.
    /// The raw output is retained for subsequent requests; execution consumes
    /// only decoded calls and text.
    fn decodeResponse(arena: Allocator, bytes: []const u8) !Response {
        const decoded = std.json.parseFromSliceLeaky(struct {
            status: []const u8,
            output: []const Value,
        }, arena, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidModelResponse,
        };
        if (!std.mem.eql(u8, decoded.status, "completed")) return error.ModelResponseNotCompleted;
        var calls: std.ArrayList(FunctionCall) = .empty;
        defer calls.deinit(arena);
        var text = std.Io.Writer.Allocating.init(arena);
        defer text.deinit();
        for (decoded.output) |item| {
            const kind = try textField(item, "type");
            if (std.mem.eql(u8, kind, "reasoning")) continue;
            if (std.mem.eql(u8, kind, "message")) {
                if (!std.mem.eql(u8, try textField(item, "role"), "assistant")) return error.InvalidModelResponse;
                const parts = try field(item, "content");
                if (parts != .array) return error.InvalidModelResponse;
                for (parts.array.items) |part| {
                    if (!std.mem.eql(u8, try textField(part, "type"), "output_text")) return error.InvalidModelResponse;
                    const value = try textField(part, "text");
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
        return .{
            .output = decoded.output,
            .calls = try calls.toOwnedSlice(arena),
            .text = if (text.written().len == 0) null else try text.toOwnedSlice(),
        };
    }
};

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

fn contentLimitPart(arena: Allocator, message: []const u8) !Value {
    const text = try std.json.Stringify.valueAlloc(arena, .{
        .@"error" = .{ .code = "content_limit", .message = message },
    }, .{});
    return encodeContentPart(arena, .{ .text = text });
}

/// Count image parts without interpreting their URLs.
fn imageCount(history: []const Value) usize {
    var count: usize = 0;
    for (history) |item| {
        for (contentParts(item)) |part| {
            if (imageUrl(part) != null) count += 1;
        }
    }
    return count;
}

fn contentParts(item: Value) []Value {
    if (item != .object) return &.{};
    const parts = item.object.get("content") orelse item.object.get("output") orelse return &.{};
    return if (parts == .array) parts.array.items else &.{};
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
