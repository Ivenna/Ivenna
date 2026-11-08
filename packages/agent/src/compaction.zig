const std = @import("std");
const Model = @import("agent_contracts").Model;
const Input = @import("input.zig");
const Context = @import("context.zig").Context;
const Allocator = std.mem.Allocator;

pub const Rejection = enum {
    empty_handover,
    unexpected_tool_call,
    too_large,

    pub fn failure(self: Rejection) anyerror {
        return switch (self) {
            .empty_handover => error.EmptyHandover,
            .unexpected_tool_call => error.UnexpectedSummaryToolCall,
            .too_large => error.ContextBudgetExhausted,
        };
    }

    fn feedback(self: Rejection) []const u8 {
        return switch (self) {
            .empty_handover => "The previous attempt returned no handover text.",
            .unexpected_tool_call => "The previous attempt included tool calls.",
            .too_large => "The previous handover left the continuation request over its size limit.",
        };
    }
};

pub const Result = union(enum) {
    summary: []const u8,
    rejected: Rejection,
};

/// Make one summary inference over retained history. Kernel owns retry policy
/// and measures the resulting continuation before installing its handover.
pub fn summarize(model: Model.Port, arena: Allocator, context: *const Context, current: Input.Current, max_request_bytes: u64, previous: ?Rejection) !Result {
    const instructions = if (previous) |reason|
        try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ @embedFile("compaction.md"), reason.feedback() })
    else
        @embedFile("compaction.md");
    const messages = try context.summaryRequest(arena, current, instructions);
    const inference: Model.Request = .{ .history = messages, .tools = &.{}, .reasoning_effort = .high };
    if (try model.requestBytes(arena, inference) > max_request_bytes)
        return error.ContextBudgetExhausted;
    const response = try model.next(arena, inference);
    if (response.calls.len != 0) return .{ .rejected = .unexpected_tool_call };
    const summary = response.text orelse return .{ .rejected = .empty_handover };
    const text = std.mem.trim(u8, summary, " \t\r\n");
    if (text.len == 0) return .{ .rejected = .empty_handover };
    return .{ .summary = text };
}
