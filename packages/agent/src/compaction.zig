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

    fn retryInstruction(self: Rejection) []const u8 {
        return switch (self) {
            .empty_summary => "The previous summary was empty. Include what this focus needs to continue.",
            .unexpected_tool_call => "The previous reply tried to call a tool. Return the handover as plain text.",
            .too_large => "The proposed handover left too little room to continue. Write a shorter summary.",
        };
    }

    pub fn interruption(self: Rejection, focus_id: []const u8) []const u8 {
        return switch (self) {
            .empty_summary => "The handover summary was empty.",
            .unexpected_tool_call => "The handover response tried to call a tool.",
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
    const instructions = if (previous) |reason|
        try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ @embedFile("compaction.md"), reason.retryInstruction() })
    else
        @embedFile("compaction.md");
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
    const summary = response.text orelse return .{ .rejected = .empty_summary };
    const text = std.mem.trim(u8, summary, " \t\r\n");
    if (text.len == 0) return .{ .rejected = .empty_summary };
    return .{ .handover = .{
        .focus_id = context.focus_id,
        .observed_at_unix_ms = snapshot.current.observed_at_unix_ms,
        .summary = try arena.dupe(u8, text),
        .state = snapshot.state,
    } };
}
