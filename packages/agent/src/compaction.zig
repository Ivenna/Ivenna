const std = @import("std");
const Model = @import("agent_contracts").Model;
const Engine = @import("engine.zig").Engine;
const Input = @import("input.zig");
const Context = @import("context.zig").Context;
const Allocator = std.mem.Allocator;

pub const Rejection = union(enum) {
    empty_summary,
    unexpected_tool_call,
    too_large: Model.Limit,

    fn feedback(self: Rejection) []const u8 {
        return switch (self) {
            .empty_summary => "The handover reply contained no summary.",
            .unexpected_tool_call => "The handover reply included a tool call.",
            .too_large => "Write a shorter summary.",
        };
    }

    pub fn interruption(self: Rejection, focus_id: []const u8) []const u8 {
        return switch (self) {
            .empty_summary, .unexpected_tool_call => self.feedback(),
            .too_large => |limit| Engine.reportRequestLimit(focus_id, "request with the proposed handover", limit),
        };
    }
};

pub const Result = union(enum) {
    handover: Input.Handover,
    rejected: Rejection,
    interrupted: []const u8,
};

/// Generate one summary from this history and snapshot. Kernel measures the
/// continuation and decides whether to request a replacement summary.
pub fn summarize(engine: *Engine, arena: Allocator, context: *const Context, snapshot: Input.Snapshot, scope: Context.CompactionScope, previous: ?Rejection, retry: Engine.Retry) !Result {
    const task = comptime std.mem.trimEnd(u8, @embedFile("compaction.md"), "\r\n");
    const instructions = if (previous) |reason|
        try std.fmt.allocPrint(arena, "{s} {s}", .{ task, reason.feedback() })
    else
        task;
    const history = try context.summaryRequest(arena, snapshot, instructions, scope);
    const request: Model.Request = .{
        .history = history,
        .tools = &.{},
        .reasoning_effort = engine.reasoning.compaction,
    };
    var violation = (try engine.model.measure(arena, request)).violation;
    if (violation != null and try Context.replaceSummaryMedia(arena, history)) {
        violation = (try engine.model.measure(arena, request)).violation;
    }
    if (violation) |limit|
        return .{ .interrupted = Engine.reportRequestLimit(context.focus_id, "summary request", limit) };
    var inference = switch (try engine.infer(context.focus_id, request, retry)) {
        .ready => |result| result,
        .interrupted => |reason| return .{ .interrupted = reason },
    };
    defer inference.deinit();
    const response = inference.response;
    if (response.calls.len != 0) return .{ .rejected = .unexpected_tool_call };
    const text = std.mem.trim(u8, response.text orelse "", " \t\r\n");
    if (text.len == 0) return .{ .rejected = .empty_summary };
    return .{ .handover = .{
        .focus_id = context.focus_id,
        .observed_at_unix_ms = snapshot.current.observed_at_unix_ms,
        .summary = try arena.dupe(u8, text),
        .state = snapshot.state,
    } };
}
