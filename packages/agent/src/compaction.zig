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

    pub fn description(self: Rejection, a: Allocator) ![]const u8 {
        return switch (self) {
            .empty_summary => "The model returned an empty handover summary.",
            .unexpected_tool_call => "The model returned tool calls for the handover summary.",
            .too_large => |limit| a.print("The next request still exceeds its limit with this handover. {s}", .{try limit.description(a)}),
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
        try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ @embedFile("compaction.md"), try reason.description(arena) })
    else
        @embedFile("compaction.md");
    const history = try context.summaryRequest(arena, snapshot, instructions, scope);
    const request: Model.Request = .{
        .history = history,
        .tools = &.{},
        .reasoning_effort = .high,
    };
    if ((try engine.model.measure(arena, request)).violation) |original_limit| {
        const remaining_limit: ?Model.Limit = if (try Context.replaceSummaryMedia(arena, history))
            (try engine.model.measure(arena, request)).violation
        else
            original_limit;
        if (remaining_limit) |limit|
            return .{ .interrupted = try std.fmt.allocPrint(arena, "The summary request could not be sent. {s}", .{try limit.description(arena)}) };
    }
    var inference = switch (try engine.infer(arena, context.focus_id, request, retry)) {
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
