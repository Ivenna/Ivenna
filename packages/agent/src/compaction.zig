const std = @import("std");
const Provider = @import("provider.zig").Provider;
const Input = @import("input.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Build a summary request with tools disabled, using the current session and
/// runtime observations. Return validated handover text without mutating
/// history; the caller owns storage and context replacement.
pub fn summarize(provider: Provider, arena: Allocator, history: []const Value, snapshot: Input.Snapshot, max_request_bytes: u64, max_summary_bytes: usize) ![]const u8 {
    var state = snapshot.state;
    state.response = .{ .summary = .{} };
    const rendered = try Input.serialize(arena, snapshot.session_id, .{ .context_compaction = .{
        .instructions = @embedFile("compaction.md"),
        .state = state,
    } });
    var user_message: std.json.ObjectMap = .empty;
    try user_message.put(arena, "role", .{ .string = "user" });
    try user_message.put(arena, "content", .{ .string = rendered });
    const messages = try arena.alloc(Value, history.len + 1);
    @memcpy(messages[0..history.len], history);
    messages[history.len] = .{ .object = user_message };
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
