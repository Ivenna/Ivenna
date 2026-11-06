const std = @import("std");
const contracts = @import("agent_contracts");
const Model = contracts.Model;
const Tools = contracts.Tools;
const Content = @import("content").Content;
const Allocator = std.mem.Allocator;

/// One model request and its complete tool batch. Kernel owns attention,
/// context lifetime, communication, and when another round starts.
pub const Engine = struct {
    io: std.Io,
    model: Model.Port,
    tools: []const Tools,

    pub const Scope = enum { all, coordination };

    /// Kernel supplies attention operations without giving tool execution
    /// ownership of sessions or their retained histories.
    pub const RuntimeTools = struct {
        context: *anyopaque,
        invoke: *const fn (*anyopaque, Allocator, []const u8, []const u8) anyerror!?Content,
    };

    pub const Round = struct {
        output: []const Model.Item,
        replies: []const Model.Item,
        text: ?[]const u8,
    };

    /// Returned data belongs to a, including model output and tool replies.
    pub fn turn(self: *Engine, a: Allocator, session_id: u64, history: []const Model.Item, runtime_tools: ?RuntimeTools, coordination_only: bool) !Round {
        try self.io.checkCancel();
        const declarations = try self.toolDeclarations(a, if (coordination_only) .coordination else .all);
        const response = try self.model.next(a, .{ .history = history, .tools = declarations });
        var messages: std.ArrayList(Model.Item) = .empty;
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
            try messages.append(a, .{ .tool_result = .{ .call_id = call.call_id, .content = content } });
        }
        try self.model.limitToolReplies(a, .{ .history = messages.items, .tools = declarations }, messages.items[reply_start..]);
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
        for (self.tools) |tools| {
            if (try tools.invoke(tools.context, a, session_id, name, arguments)) |result| return result;
        }
        return error.UnknownTool;
    }

    pub fn requestBytes(self: *Engine, a: Allocator, history: []const Model.Item, scope: Scope) !u64 {
        return self.model.requestBytes(a, .{ .history = history, .tools = try self.toolDeclarations(a, scope) });
    }

    /// The agent owns coordination policy; each registered body capability
    /// supplies its declarations together with its invocation entry point.
    fn toolDeclarations(self: *Engine, a: Allocator, scope: Scope) ![]const Model.Tool {
        const coordination = try std.json.parseFromSliceLeaky([]const Model.Tool, a, @embedFile("tools.json"), .{});
        if (scope == .coordination) return coordination;
        var selected: std.ArrayList(Model.Tool) = .empty;
        try selected.appendSlice(a, coordination);
        for (self.tools) |capability| try selected.appendSlice(a, capability.declarations);
        return selected.toOwnedSlice(a);
    }
};
