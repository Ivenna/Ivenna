const std = @import("std");
const Model = @import("agent_contracts").Model;
const Content = @import("content").Content;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Responses wire encoding and HTTP transport. Tool selection and execution
/// belong to the agent; every operation uses the caller's cancelable Io.
pub const Provider = struct {
    pub const default_base_url = "https://api.deepseek.com";
    pub const default_model = "deepseek-flash";

    client: *std.http.Client,
    base_url: []const u8 = default_base_url,
    api_key: []const u8 = "",
    model: []const u8 = default_model,
    max_output_tokens: u32 = 8192,

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
        };
    }

    fn send(self: Provider, arena: Allocator, request_payload: Payload) !Model.Response {
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

    /// Validate the complete response before publishing any calls. Each output
    /// item is retained as adapter-private continuation bytes, including fields
    /// the execution core does not interpret.
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
        const output = try arena.alloc(Model.Item, decoded.output.len);
        for (decoded.output, output) |item, *retained|
            retained.* = .{ .continuation = try std.json.Stringify.valueAlloc(arena, item, .{}) };
        return .{
            .output = output,
            .calls = try calls.toOwnedSlice(arena),
            .text = if (text.written().len == 0) null else try text.toOwnedSlice(),
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
