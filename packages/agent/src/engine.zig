const std = @import("std");
const contracts = @import("agent_contracts");
const Model = contracts.Model;
const Tools = contracts.Tools;
const Input = @import("input.zig");
const Content = @import("content").Content;
const Allocator = std.mem.Allocator;

/// One model request and its complete tool batch. Kernel owns attention,
/// context lifetime, communication, and when another round starts.
pub const Engine = struct {
    io: std.Io,
    model: Model.Port,
    shared_tools: []const Tools,
    activity_tools: []const Tools,
    reasoning: Reasoning = .{},

    pub const Reasoning = struct {
        core: Model.ReasoningEffort = .low,
        activity: Model.ReasoningEffort = .high,
    };

    /// Kernel supplies attention operations without giving tool execution
    /// ownership of sessions or their retained histories.
    pub const RuntimeTools = struct {
        context: *anyopaque,
        invoke: *const fn (*anyopaque, Allocator, []const u8, []const u8) anyerror!?Content,
        register_callback: *const fn (*anyopaque) anyerror!u64,
    };

    pub const Round = struct {
        output: []const Model.Item,
        replies: []const Model.Item,
        text: ?[]const u8,
    };

    /// Returned data belongs to a, including model output and tool replies.
    pub fn turn(self: *Engine, a: Allocator, session_id: u64, history: []const Model.Item, runtime_tools: ?RuntimeTools, role: Input.Role) !Round {
        try self.io.checkCancel();
        var request = try self.modelRequest(a, history, role);
        const response = try self.model.next(a, request);
        var messages: std.ArrayList(Model.Item) = .empty;
        try messages.appendSlice(a, history);
        try messages.appendSlice(a, response.output);
        const reply_start = messages.items.len;
        for (response.calls) |call| {
            const content = self.invoke(a, session_id, call.name, call.arguments, runtime_tools, role) catch |err| switch (err) {
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
        request.history = messages.items;
        try self.model.limitToolReplies(a, request, messages.items[reply_start..]);
        return .{
            .output = response.output,
            .replies = messages.items[reply_start..],
            .text = response.text,
        };
    }

    fn invoke(self: *Engine, a: Allocator, session_id: u64, name: []const u8, arguments: []const u8, runtime_tools: ?RuntimeTools, role: Input.Role) !Content {
        if (!coordinationAvailable(role, name)) return error.UnknownTool;
        if (runtime_tools) |runtime| {
            if (try runtime.invoke(runtime.context, a, name, arguments)) |result| return result;
        }
        for (self.capabilities(role)) |group| {
            for (group) |tools| {
                if (try tools.invoke(tools.context, a, .{
                    .session_id = session_id,
                    .callback = if (runtime_tools) |runtime| .{ .context = runtime.context, .register = runtime.register_callback } else null,
                }, name, arguments)) |result| return result;
            }
        }
        return error.UnknownTool;
    }

    pub fn requestBytes(self: *Engine, a: Allocator, history: []const Model.Item, role: Input.Role) !u64 {
        return self.model.requestBytes(a, try self.modelRequest(a, history, role));
    }

    fn modelRequest(self: *Engine, a: Allocator, history: []const Model.Item, role: Input.Role) !Model.Request {
        return .{
            .history = history,
            .tools = try self.toolDeclarations(a, role),
            .reasoning_effort = switch (role) {
                .core => self.reasoning.core,
                .activity => self.reasoning.activity,
            },
        };
    }

    fn capabilities(self: *const Engine, role: Input.Role) [2][]const Tools {
        return .{ self.shared_tools, if (role == .activity) self.activity_tools else &.{} };
    }

    /// The agent owns coordination policy; each registered body capability
    /// supplies its declarations together with its invocation entry point.
    fn toolDeclarations(self: *Engine, a: Allocator, role: Input.Role) ![]const Model.Tool {
        const coordination = try std.json.parseFromSliceLeaky([]const Model.Tool, a, @embedFile("tools.json"), .{});
        var selected: std.ArrayList(Model.Tool) = .empty;
        for (coordination) |tool| {
            if (coordinationAvailable(role, tool.name)) try selected.append(a, tool);
        }
        for (self.capabilities(role)) |group| {
            for (group) |capability| try selected.appendSlice(a, capability.declarations);
        }
        return selected.toOwnedSlice(a);
    }
};

fn coordinationAvailable(role: Input.Role, name: []const u8) bool {
    return role == .core or
        (!std.mem.eql(u8, name, "fork_session") and !std.mem.eql(u8, name, "send_session_message"));
}
