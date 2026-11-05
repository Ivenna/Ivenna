const std = @import("std");
const Provider = @import("provider.zig").Provider;
const Memory = @import("memory.zig").Memory;
const Host = @import("host.zig").Host;
const Content = @import("content.zig").Content;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// One model request and its complete tool batch. Kernel owns attention,
/// context lifetime, communication, and when another round starts.
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
        var messages: std.ArrayList(Value) = .empty;
        try messages.appendSlice(a, history);
        try messages.appendSlice(a, response.output);
        const reply_start = messages.items.len;
        for (response.calls) |call| {
            const content = self.invoke(a, session_id, call.name, call.arguments, runtime_tools, coordination_only) catch |err| switch (err) {
                error.InvalidToolArguments, error.UnknownTool => try Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{
                    .@"error" = .{
                        .code = if (err == error.UnknownTool) "unknown_tool" else "invalid_arguments",
                        .message = if (err == error.UnknownTool) "This tool is not available." else "The arguments do not match the tool parameters.",
                    },
                }, .{})),
                else => return err,
            };
            try messages.append(a, try Provider.toolReply(a, call.call_id, content));
        }
        try provider.limitToolReplies(a, messages.items, reply_start);
        return .{
            .output = response.output,
            .replies = messages.items[reply_start..],
            .text = response.text,
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
