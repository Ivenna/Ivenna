const std = @import("std");
const Provider = @import("provider.zig").Provider;
const Memory = @import("memory.zig").Memory;
const Host = @import("host.zig").Host;
const Content = @import("content.zig").Content;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// One model request and its complete tool batch. Kernel owns attention,
/// context lifetime, correspondence routing, and when another round starts.
pub const Engine = struct {
    io: std.Io,
    provider: Provider,
    memory: Memory,
    host: Host,

    /// Kernel supplies attention operations without giving tool execution
    /// ownership of sessions or their retained histories.
    pub const RuntimeTools = struct {
        context: *anyopaque,
        invoke: *const fn (*anyopaque, Allocator, []const u8, []const u8) anyerror!?Content,
    };

    pub const Round = struct {
        output: []const Value,
        replies: []const Value,
        text: ?[]const u8,
    };

    /// Returned data belongs to a, including model output and tool replies.
    pub fn turn(self: *Engine, a: Allocator, session_id: u64, history: []const Value, runtime_tools: ?RuntimeTools, coordination_only: bool) !Round {
        try self.io.checkCancel();
        var provider = self.provider;
        provider.tool_scope = if (coordination_only) .coordination else .all;
        const response = try provider.next(a, history);
        const text = try responseText(a, response.output);
        var messages: std.ArrayList(Value) = .empty;
        try messages.appendSlice(a, history);
        try messages.appendSlice(a, response.output);
        const reply_start = messages.items.len;
        for (response.calls) |call| {
            const content = self.invoke(a, session_id, call.name, call.arguments, runtime_tools, coordination_only) catch |err| switch (err) {
                error.Canceled, error.OutOfMemory => return err,
                error.InvalidToolArguments, error.UnknownTool => try Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{
                    .@"error" = .{
                        .code = if (err == error.UnknownTool) "unknown_tool" else "invalid_arguments",
                        .message = if (err == error.UnknownTool) "This tool is not available." else "The arguments do not match the tool parameters.",
                    },
                }, .{})),
                else => return err,
            };
            try messages.append(a, try provider.toolReply(a, call.call_id, content, messages.items));
        }
        try provider.limitToolReplies(a, messages.items, reply_start);
        return .{
            .output = response.output,
            .replies = messages.items[reply_start..],
            .text = text,
        };
    }

    fn invoke(self: *Engine, a: Allocator, session_id: u64, name: []const u8, arguments: []const u8, runtime_tools: ?RuntimeTools, coordination_only: bool) !Content {
        if (runtime_tools) |runtime| {
            if (try runtime.invoke(runtime.context, a, name, arguments)) |result| return result;
        }
        if (coordination_only) return error.UnknownTool;
        if (try Memory.Request.parse(a, name, arguments)) |request|
            return self.memory.invoke(a, request);
        if (try Host.Request.parse(a, name, arguments)) |request|
            return self.host.invoke(a, .{ .session_id = session_id }, request);
        return error.UnknownTool;
    }
};

pub fn responseText(a: Allocator, output: []const Value) !?[]const u8 {
    var text: std.Io.Writer.Allocating = .init(a);
    defer text.deinit();
    for (output) |item| {
        if (item != .object) continue;
        const kind = item.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "message")) continue;
        const role = item.object.get("role") orelse return error.InvalidModelResponse;
        if (role != .string or !std.mem.eql(u8, role.string, "assistant")) return error.InvalidModelResponse;
        const parts = item.object.get("content") orelse continue;
        if (parts != .array) continue;
        for (parts.array.items) |part| {
            if (part != .object) continue;
            const part_type = part.object.get("type") orelse continue;
            if (part_type != .string or !std.mem.eql(u8, part_type.string, "output_text")) continue;
            const value = part.object.get("text") orelse continue;
            if (value != .string or value.string.len == 0) continue;
            if (text.written().len != 0) try text.writer.writeAll("\n\n");
            try text.writer.writeAll(value.string);
        }
    }
    return if (text.written().len == 0) null else try text.toOwnedSlice();
}
