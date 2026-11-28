const std = @import("std");
const Model = @import("agent_contracts").Model;
const Engine = @import("engine.zig").Engine;
const Input = @import("input.zig");
const Context = @import("context.zig").Context;
const Allocator = std.mem.Allocator;

pub const Rejection = union(enum) {
    empty_reflection,
    unexpected_tool_call,
    too_large: Model.Limit,

    fn feedback(self: Rejection) []const u8 {
        return switch (self) {
            .empty_reflection => "Leave a brief reflection in your own words.",
            .unexpected_tool_call => "Write your reflection directly.",
            .too_large => "Make the reflection shorter. Keep what you most need to recognize yourself and find your bearings.",
        };
    }

    pub fn interruption(self: Rejection, focus_id: []const u8) []const u8 {
        return switch (self) {
            .empty_reflection => "The quiet reflection returned no text.",
            .unexpected_tool_call => "The quiet reflection returned a tool call.",
            .too_large => |limit| Engine.reportRequestLimit(focus_id, "request with the proposed continuity record", limit),
        };
    }
};

pub const Result = union(enum) {
    continuity: Input.Continuity,
    rejected: Rejection,
    interrupted: []const u8,
};

/// Ask the focus to reflect on the selected history. Kernel measures the
/// continuation and decides whether to request a revised account.
pub fn reflect(engine: *Engine, arena: Allocator, context: *const Context, snapshot: Input.Snapshot, scope: Context.CompactionScope, previous: ?Rejection, retry: Engine.Retry) !Result {
    const task = comptime std.mem.trimEnd(u8, @embedFile("quiet_reflection.md"), "\r\n");
    const instructions = if (previous) |reason|
        try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ task, reason.feedback() })
    else
        task;
    const history = try context.reflectionRequest(arena, snapshot, instructions, scope);
    const request: Model.Request = .{
        .history = history,
        .tools = &.{},
        .reasoning_effort = engine.reasoning.compaction,
    };
    var violation = (try engine.model.measure(arena, request)).violation;
    if (violation != null and try Context.replaceReflectionMedia(arena, history)) {
        violation = (try engine.model.measure(arena, request)).violation;
    }
    if (violation) |limit|
        return .{ .interrupted = Engine.reportRequestLimit(context.focus_id, "quiet reflection request", limit) };
    var inference = switch (try engine.infer(context.focus_id, request, retry)) {
        .ready => |result| result,
        .interrupted => |reason| return .{ .interrupted = reason },
    };
    defer inference.deinit();
    const response = inference.response;
    if (response.calls.len != 0) return .{ .rejected = .unexpected_tool_call };
    const text = response.text orelse "";
    if (std.mem.trim(u8, text, &std.ascii.whitespace).len == 0) return .{ .rejected = .empty_reflection };
    return .{ .continuity = .{
        .focus_id = context.focus_id,
        .observed_at_unix_ms = snapshot.current.observed_at_unix_ms,
        .text = try arena.dupe(u8, text),
        .state = snapshot.state,
    } };
}
