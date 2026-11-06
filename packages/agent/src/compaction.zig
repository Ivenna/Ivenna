const std = @import("std");
const Provider = @import("provider.zig").Provider;
const Input = @import("input.zig");
const Context = @import("context.zig").Context;
const Allocator = std.mem.Allocator;

/// Build a summary request with tools disabled and current session state.
/// Return validated handover text without mutating history; the caller owns
/// storage and context replacement.
pub fn summarize(provider: Provider, arena: Allocator, context: *const Context, request: Input.Request, max_request_bytes: u64, max_summary_bytes: usize) ![]const u8 {
    var summary_request = request;
    summary_request.state.response = .{ .summary = .{} };
    summary_request.instructions = @embedFile("compaction.md");
    const messages = try context.request(arena, summary_request);
    if (try provider.requestBytesWithoutTools(arena, messages) > max_request_bytes)
        return error.ContextBudgetExhausted;
    const response = try provider.nextWithoutTools(arena, messages);
    if (response.calls.len != 0) return error.UnexpectedSummaryToolCall;
    const summary = response.text orelse return error.EmptyHandover;
    if (summary.len > max_summary_bytes) return error.HandoverTooLarge;
    const text = std.mem.trim(u8, summary, " \t\r\n");
    if (text.len == 0) return error.EmptyHandover;
    return text;
}
