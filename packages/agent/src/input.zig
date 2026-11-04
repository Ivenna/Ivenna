const std = @import("std");
const yaml = @import("yaml");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const Role = enum { core, branch };

/// A current observation, rendered separately for each model request. Thread
/// identifiers borrow the live conversation until that conversation retires.
pub const Snapshot = struct {
    session_id: u64,
    role: Role,
    parent_generation: ?u64 = null,
    thread_id: []const u8,
    runtime: struct {
        active_sessions: usize,
        running_sessions: usize,
        active_conversations: usize,
        queued_turns: usize,
    },
};

/// Merge deployment fields and the particular input, then supply the trusted
/// session identity. The returned YAML belongs to arena.
pub fn serialize(arena: Allocator, session_id: u64, user_fields: Value, input: Value) ![]const u8 {
    if (user_fields != .object or input != .object) return error.InvalidInputFields;
    var fields: std.json.ObjectMap = .empty;
    for (user_fields.object.keys(), user_fields.object.values()) |key, value|
        try fields.put(arena, key, value);
    for (input.object.keys(), input.object.values()) |key, value|
        try fields.put(arena, key, value);
    try fields.put(arena, "session_id", .{ .integer = std.math.cast(i64, session_id) orelse return error.InvalidSessionId });
    if (!fields.contains("message")) try fields.put(arena, "message", .{ .string = "" });
    const bytes = try std.json.Stringify.valueAlloc(arena, Value{ .object = fields }, .{});
    const document = try yaml.parse(arena, bytes, .{});
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();
    try yaml.emit(&output.writer, document, .{});
    return output.toOwnedSlice();
}

/// Runtime observations are request-local. They do not add another task or
/// accumulate repeated counter snapshots in the working conversation history.
pub fn serializeSnapshot(arena: Allocator, snapshot: Snapshot) ![]const u8 {
    const fields = try std.json.parseFromSliceLeaky(Value, arena, try std.json.Stringify.valueAlloc(arena, .{
        .conversation = .{
            .role = snapshot.role,
            .parent_generation = snapshot.parent_generation,
            .thread_id = snapshot.thread_id,
        },
        .runtime = snapshot.runtime,
    }, .{}), .{});
    return serialize(arena, snapshot.session_id, .{ .object = .empty }, fields);
}
