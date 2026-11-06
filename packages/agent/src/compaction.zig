const std = @import("std");
const Model = @import("model.zig");
const Input = @import("input.zig");
const Context = @import("context.zig").Context;
const Allocator = std.mem.Allocator;

/// Build a summary request with tools disabled and current session state.
/// Return validated handover text without mutating history; the caller owns
/// storage and context replacement.
pub fn summarize(model: Model.Port, arena: Allocator, context: *const Context, request: Input.Request, max_request_bytes: u64, max_summary_bytes: usize) ![]const u8 {
    var summary_request = request;
    summary_request.state.response = .{ .summary = .{} };
    summary_request.instructions = @embedFile("compaction.md");
    const messages = try context.request(arena, summary_request);
    const inference: Model.Request = .{ .history = messages, .tools = &.{} };
    if (try model.requestBytes(arena, inference) > max_request_bytes)
        return error.ContextBudgetExhausted;
    const response = try model.next(arena, inference);
    if (response.calls.len != 0) return error.UnexpectedSummaryToolCall;
    const summary = response.text orelse return error.EmptyHandover;
    if (summary.len > max_summary_bytes) return error.HandoverTooLarge;
    const text = std.mem.trim(u8, summary, " \t\r\n");
    if (text.len == 0) return error.EmptyHandover;
    return text;
}
