const std = @import("std");
const contracts = @import("agent_contracts");
const Model = contracts.Model;
const Tools = contracts.Tools;
const Input = @import("input.zig");
const AgentTools = @import("tools.zig");
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

    /// Kernel supplies effects tied to the calling session and round without
    /// giving tool execution ownership of sessions or their retained histories.
    pub const RuntimeTools = struct {
        context: *anyopaque,
        invoke: *const fn (*anyopaque, Allocator, AgentTools.Request) anyerror!Content,
    };

    pub const Inference = struct {
        request: Model.Request,
        response: Model.Response,
        role: Input.Role,
    };

    /// Declarations and response data belong to a. Request history borrows the
    /// caller's slice through tool execution.
    pub fn infer(self: *Engine, a: Allocator, history: []const Model.Item, role: Input.Role) !Inference {
        try self.io.checkCancel();
        const request = try self.modelRequest(a, history, role);
        return .{ .request = request, .response = try self.model.next(a, request), .role = role };
    }

    /// Execute the decoded batch in order, retaining its complete request for
    /// the provider's tool-content limits. Replies belong to a.
    pub fn executeTools(self: *Engine, a: Allocator, invocation: Tools.Invocation, inference: Inference, runtime_tools: ?RuntimeTools) ![]const Model.Item {
        var request = inference.request;
        const response = inference.response;
        var messages: std.ArrayList(Model.Item) = .empty;
        try messages.appendSlice(a, request.history);
        try messages.appendSlice(a, response.output);
        const reply_start = messages.items.len;
        for (response.calls) |call| {
            const content = self.invoke(a, invocation, call.name, call.arguments, runtime_tools, inference.role) catch |err| switch (err) {
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
        return messages.items[reply_start..];
    }

    fn invoke(self: *Engine, a: Allocator, invocation: Tools.Invocation, name: []const u8, arguments: []const u8, runtime_tools: ?RuntimeTools, role: Input.Role) !Content {
        if (try AgentTools.Request.parse(a, role, name, arguments)) |request| {
            const runtime = runtime_tools orelse return error.UnknownTool;
            return runtime.invoke(runtime.context, a, request);
        }
        for (self.capabilities(role)) |group| {
            for (group) |tools| {
                if (try tools.invoke(tools.context, a, invocation, name, arguments)) |result| return result;
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
        var selected: std.ArrayList(Model.Tool) = .empty;
        try selected.appendSlice(a, try AgentTools.declarations(a, role));
        for (self.capabilities(role)) |group| {
            for (group) |capability| try selected.appendSlice(a, capability.declarations);
        }
        return selected.toOwnedSlice(a);
    }
};
