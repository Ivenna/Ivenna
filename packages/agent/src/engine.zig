const std = @import("std");
const contracts = @import("agent_contracts");
const Model = contracts.Model;
const Tools = contracts.Tools;
const Input = @import("input.zig");
const AgentTools = @import("tools.zig");
const Content = @import("content").Content;
const Allocator = std.mem.Allocator;

/// A focus can retain its work when reasoning cannot proceed with this input.
/// Shared-service and runtime errors propagate through the error union.
pub fn FocusResult(comptime T: type) type {
    return union(enum) { ready: T, interrupted: []const u8 };
}

/// One model request and its complete tool batch. Kernel owns attention,
/// context lifetime, communication, and when another round starts.
pub const Engine = struct {
    allocator: Allocator,
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
        arena: std.heap.ArenaAllocator,
        response: Model.Response,

        pub fn deinit(self: *Inference) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };

    pub const Round = struct {
        role: Input.Role,
        request: Model.Request,
        inference: Inference,
    };

    pub fn beginRound(self: *Engine, a: Allocator, focus_id: []const u8, history: []const Model.Item, role: Input.Role) !FocusResult(Round) {
        const request = try self.modelRequest(a, history, role);
        return switch (try self.infer(focus_id, request)) {
            .ready => |inference| .{ .ready = .{ .role = role, .request = request, .inference = inference } },
            .interrupted => |reason| .{ .interrupted = reason },
        };
    }

    /// Retry only inference, with its original input and sampling time.
    pub fn infer(self: *Engine, focus_id: []const u8, request: Model.Request) !FocusResult(Inference) {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const initial_ms = 500;
        var backoff_ms: i64 = initial_ms;
        const random: std.Random.IoSource = .{ .io = self.io };
        while (true) {
            try self.io.checkCancel();
            switch (try self.model.next(arena.allocator(), request)) {
                .response => |response| {
                    if (backoff_ms != initial_ms) std.log.info("model inference resumed for {s}", .{focus_id});
                    return .{ .ready = .{ .arena = arena, .response = response } };
                },
                .rejected => |rejection| {
                    arena.deinit();
                    return .{ .interrupted = switch (rejection) {
                        .request_rejected => "The model service rejected the inference request.",
                        .invalid_response => "The runtime could not read the model response.",
                        .incomplete_response => "The model service did not report a completed response.",
                    } };
                },
                .unavailable => |outage| {
                    _ = arena.reset(.free_all);
                    const local_delay = random.interface().intRangeAtMostBiased(i64, @divExact(backoff_ms, 2), backoff_ms);
                    const delay_ms = @max(local_delay, outage.retry_after_ms orelse 0);
                    std.log.warn("model unavailable for {s}; retrying inference in {d} ms", .{ focus_id, delay_ms });
                    try self.io.sleep(.fromMilliseconds(delay_ms), .awake);
                    backoff_ms = @min(backoff_ms * 2, 300_000);
                },
            }
        }
    }

    /// Execute the decoded batch in order, retaining its complete request for
    /// the provider's tool-content limits. Replies belong to a.
    pub fn executeTools(self: *Engine, a: Allocator, invocation: Tools.Invocation, round: *const Round, runtime_tools: ?RuntimeTools) ![]const Model.Item {
        var request = round.request;
        const response = round.inference.response;
        var messages: std.ArrayList(Model.Item) = .empty;
        try messages.appendSlice(a, request.history);
        try messages.appendSlice(a, response.output);
        const reply_start = messages.items.len;
        for (response.calls) |call| {
            const content = self.invoke(a, invocation, call.name, call.arguments, runtime_tools, round.role) catch |err| switch (err) {
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

fn hasDeclaration(declarations: []const Model.Tool, name: []const u8) bool {
    for (declarations) |declaration| if (std.mem.eql(u8, declaration.name, name)) return true;
    return false;
}

test "shared tools are declared for both roles and activity tools only for activities" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Probes = struct {
        fn invoke(_: *anyopaque, _: Allocator, _: Tools.Invocation, _: []const u8, _: []const u8) anyerror!?Content {
            return null;
        }

        const shared = [_]Model.Tool{.{ .name = "shared_probe", .description = "probe", .parameters = .{ .null = {} } }};
        const activity = [_]Model.Tool{.{ .name = "activity_probe", .description = "probe", .parameters = .{ .null = {} } }};
    };
    var shared_tools = [_]Tools{.{ .context = undefined, .invoke = Probes.invoke, .declarations = &Probes.shared }};
    var activity_tools = [_]Tools{.{ .context = undefined, .invoke = Probes.invoke, .declarations = &Probes.activity }};
    var engine: Engine = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .model = undefined,
        .shared_tools = &shared_tools,
        .activity_tools = &activity_tools,
        .reasoning = .{},
    };

    const core = try engine.toolDeclarations(a, .core);
    const activity = try engine.toolDeclarations(a, .activity);
    try std.testing.expect(hasDeclaration(core, "shared_probe"));
    try std.testing.expect(!hasDeclaration(core, "activity_probe"));
    try std.testing.expect(hasDeclaration(activity, "shared_probe"));
    try std.testing.expect(hasDeclaration(activity, "activity_probe"));
}
