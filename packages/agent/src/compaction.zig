const std = @import("std");
const Provider = @import("provider.zig").Provider;
const Input = @import("input.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Build a summary request with tools disabled, using the current session and
/// runtime observations. Return validated handover text without mutating
/// history; the caller owns storage and context replacement.
pub fn summarize(provider: Provider, arena: Allocator, history: []const Value, snapshot: Input.Snapshot, max_request_bytes: u64, max_summary_bytes: usize) ![]const u8 {
    const defaults = try jsonValue(arena, .{
        .conversation = .{
            .role = snapshot.role,
            .parent_generation = snapshot.parent_generation,
            .thread_id = snapshot.thread_id,
        },
        .runtime = snapshot.runtime,
    });
    const task = try jsonValue(arena, .{
        .purpose = "context_compaction",
        .message = @embedFile("compaction.md"),
    });
    const rendered = try Input.serialize(arena, snapshot.session_id, defaults, task);
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
    var summary = std.Io.Writer.Allocating.init(arena);
    defer summary.deinit();
    for (response.output) |item| {
        const kind = try textField(item, "type");
        if (std.mem.eql(u8, kind, "reasoning")) continue;
        if (!std.mem.eql(u8, kind, "message")) return error.UnexpectedSummaryToolCall;
        if (!std.mem.eql(u8, try textField(item, "role"), "assistant")) return error.InvalidModelResponse;
        const content = try field(item, "content");
        if (content != .array) return error.InvalidModelResponse;
        for (content.array.items) |part| {
            if (!std.mem.eql(u8, try textField(part, "type"), "output_text")) return error.InvalidModelResponse;
            const text = try textField(part, "text");
            const separator: usize = if (summary.written().len == 0 or text.len == 0) 0 else 1;
            if (separator > max_summary_bytes - summary.written().len or
                text.len > max_summary_bytes - summary.written().len - separator) return error.HandoverTooLarge;
            if (separator != 0) try summary.writer.writeByte('\n');
            try summary.writer.writeAll(text);
        }
    }
    const text = std.mem.trim(u8, try summary.toOwnedSlice(), " \t\r\n");
    if (text.len == 0) return error.EmptyHandover;
    return text;
}

fn jsonValue(arena: Allocator, value: anytype) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, try std.json.Stringify.valueAlloc(arena, value, .{}), .{});
}

fn field(value: Value, name: []const u8) !Value {
    if (value != .object) return error.InvalidModelResponse;
    return value.object.get(name) orelse error.InvalidModelResponse;
}

fn textField(value: Value, name: []const u8) ![]const u8 {
    const found = try field(value, name);
    if (found != .string) return error.InvalidModelResponse;
    return found.string;
}
