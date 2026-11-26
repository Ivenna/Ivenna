const std = @import("std");
const contracts = @import("agent_contracts");
const Model = contracts.Model;
const Tools = contracts.Tools;
const Input = @import("input.zig");
const AgentTools = @import("tools.zig");
const Content = @import("content").Content;
const Allocator = std.mem.Allocator;

/// A focus can retain its work when reasoning cannot proceed with this input.
/// Interruption reasons have static storage so they can outlive the request.
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
        core: []const u8 = "low",
        activity: []const u8 = "max",
        compaction: []const u8 = "max",
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
        inference: Inference,
    };

    pub const Retry = enum { wait_for_service, single_attempt };

    pub fn beginRound(self: *Engine, a: Allocator, focus_id: []const u8, history: []const Model.Item, role: Input.Role) !FocusResult(Round) {
        const request = try self.modelRequest(a, history, role);
        return switch (try self.infer(focus_id, request, .wait_for_service)) {
            .ready => |inference| .{ .ready = .{ .role = role, .inference = inference } },
            .interrupted => |reason| .{ .interrupted = reason },
        };
    }

    /// Run inference. Retries reuse the original input and sampling time.
    pub fn infer(self: *Engine, focus_id: []const u8, request: Model.Request, retry: Retry) !FocusResult(Inference) {
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
                    const reason = switch (rejection) {
                        .limit => |limit| reportRequestLimit(focus_id, "model request", limit),
                        .context_window => "The request exceeded the model's context window.",
                        .request_rejected => "The model service declined the request.",
                        .invalid_response => "The runtime could not read a usable model response.",
                        .incomplete_response => "The model service did not report a completed inference.",
                    };
                    arena.deinit();
                    return .{ .interrupted = reason };
                },
                .unavailable => |outage| {
                    if (retry == .single_attempt) {
                        arena.deinit();
                        return .{ .interrupted = "The model service was unavailable for this inference." };
                    }
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

    pub fn reportRequestLimit(focus_id: []const u8, request_description: []const u8, limit: Model.Limit) []const u8 {
        const detail: struct { units: []const u8, reason: []const u8 } = switch (limit.kind) {
            .request_bytes => .{ .units = "encoded bytes", .reason = "The context was too large to continue." },
            .images => .{ .units = "images", .reason = "The context held too many images to continue." },
            .files => .{ .units = "file references", .reason = "The context held too many file attachments to continue." },
        };
        std.log.warn("{s} for {s} exceeds the adapter limit ({d} {s}, maximum {d})", .{
            request_description, focus_id, limit.actual, detail.units, limit.maximum,
        });
        return detail.reason;
    }

    /// Execute and prepare the decoded batch in order. Replies belong to a.
    pub fn executeTools(self: *Engine, a: Allocator, invocation: Tools.Invocation, round: *const Round, runtime_tools: ?RuntimeTools) ![]const Model.Item {
        const response = round.inference.response;
        const results = try a.alloc(Content, response.calls.len);
        const replies = try a.alloc(Model.Item, response.calls.len);
        for (response.calls, results) |call, *result| {
            result.* = self.invoke(a, invocation, call.name, call.arguments, runtime_tools, round.role) catch |err| switch (err) {
                error.InvalidToolArguments, error.UnknownTool => try Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{
                    .@"error" = .{
                        .code = if (err == error.UnknownTool) "unknown_tool" else "invalid_arguments",
                        .message = if (err == error.UnknownTool) "This tool is not available." else "The arguments do not match the tool parameters.",
                    },
                }, .{})),
                else => return err,
            };
        }
        for (response.calls, results, replies) |call, result, *reply| {
            reply.* = .{ .tool_result = .{ .call_id = call.call_id, .content = try self.model.prepareToolResult(a, result) } };
        }
        return replies;
    }

    fn invoke(self: *Engine, a: Allocator, invocation: Tools.Invocation, name: []const u8, arguments: []const u8, runtime_tools: ?RuntimeTools, role: Input.Role) !Content {
        if (try AgentTools.Request.parse(a, role, name, arguments)) |request| {
            const runtime = runtime_tools orelse return error.UnknownTool;
            return runtime.invoke(runtime.context, a, request) catch |err| switch (err) {
                error.InvalidReference => error.InvalidToolArguments,
                else => err,
            };
        }
        for (self.capabilities(role)) |group| {
            for (group) |tools| {
                if (try tools.invoke(tools.context, a, invocation, name, arguments)) |result| return result;
            }
        }
        return error.UnknownTool;
    }

    pub fn measure(self: *Engine, a: Allocator, history: []const Model.Item, role: Input.Role) !Model.Measurement {
        return self.model.measure(a, try self.modelRequest(a, history, role));
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
