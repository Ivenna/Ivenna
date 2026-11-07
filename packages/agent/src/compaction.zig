const std = @import("std");
const Model = @import("agent_contracts").Model;
const Input = @import("input.zig");
const Context = @import("context.zig").Context;
const Allocator = std.mem.Allocator;

/// Build a summary request with tools disabled and current session state.
/// Return validated handover text without mutating history; the caller owns
/// storage and context replacement.
pub fn summarize(model: Model.Port, arena: Allocator, context: *const Context, snapshot: Input.Snapshot, max_request_bytes: u64, max_summary_bytes: usize) ![]const u8 {
    const summary_request: Input.Request = .{
        .session_id = snapshot.session_id,
        .state = snapshot.state,
        .operation = .{ .summarize = .{ .instructions = @embedFile("compaction.md") } },
    };
    const messages = try context.request(arena, summary_request);
    const inference: Model.Request = .{ .history = messages, .tools = &.{}, .reasoning_effort = .high };
    if (try model.requestBytes(arena, inference) > max_request_bytes)
        return error.ContextBudgetExhausted;
    const response = try model.next(arena, inference);
    if (response.calls.len != 0) return error.UnexpectedSummaryToolCall;
    const summary = response.text orelse return error.EmptyHandover;
    const text = std.mem.trim(u8, summary, " \t\r\n");
    if (text.len == 0) return error.EmptyHandover;
    if (text.len > max_summary_bytes) return error.HandoverTooLarge;
    return text;
}
