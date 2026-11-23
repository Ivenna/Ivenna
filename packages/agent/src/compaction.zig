const std = @import("std");
const Model = @import("agent_contracts").Model;
const Engine = @import("engine.zig").Engine;
const Input = @import("input.zig");
const Context = @import("context.zig").Context;
const Allocator = std.mem.Allocator;

/// Summary requests carry no tools: measure them exactly that way.
const SummaryMeasurer = struct {
    engine: *Engine,

    pub fn measure(self: *const SummaryMeasurer, a: Allocator, items: []const Model.Item) !u64 {
        return self.engine.model.requestBytes(a, .{ .history = items, .tools = &.{}, .reasoning_effort = .high });
    }
};

pub const Rejection = enum {
    empty_summary,
    unexpected_tool_call,
    too_large,

    pub fn description(self: Rejection) []const u8 {
        return switch (self) {
            .empty_summary => "The compaction response contained no summary text.",
            .unexpected_tool_call => "The compaction response contained tool calls.",
            .too_large => "The proposed handover left the next request over its context budget.",
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
pub fn summarize(engine: *Engine, arena: Allocator, context: *const Context, snapshot: Input.Snapshot, max_request_bytes: u64, previous: ?Rejection) !Result {
    const instructions = if (previous) |reason|
        try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ @embedFile("compaction.md"), reason.description() })
    else
        @embedFile("compaction.md");
    const messages = switch (try context.summaryRequestFitted(arena, snapshot, instructions, max_request_bytes, &SummaryMeasurer{ .engine = engine })) {
        .fitted => |fitted| fitted.items,
        .over_budget => |omissions| return .{ .interrupted = try std.fmt.allocPrint(arena, "The summary request of {d} bytes exceeds the {d}-byte compaction budget even after omitting retained content.", .{ omissions.measured_after, max_request_bytes }) },
    };
    const request: Model.Request = .{ .history = messages, .tools = &.{}, .reasoning_effort = .high };
    var inference = switch (try engine.infer(context.focus_id, request)) {
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
