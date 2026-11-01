const std = @import("std");
const yaml = @import("yaml");
const Value = std.json.Value;

pub fn serialize(arena: std.mem.Allocator, session_id: i64, user_fields: Value, input: Value) ![]const u8 {
    var fields: std.json.ObjectMap = .empty;
    for (user_fields.object.keys(), user_fields.object.values()) |key, value| {
        try fields.put(arena, key, value);
    }
    for (input.object.keys(), input.object.values()) |key, value| {
        try fields.put(arena, key, value);
    }
    try fields.put(arena, "session_id", .{ .integer = session_id });
    if (!fields.contains("message")) try fields.put(arena, "message", .{ .string = "" });
    const bytes = try std.json.Stringify.valueAlloc(arena, Value{ .object = fields }, .{});
    const document = try yaml.parse(arena, bytes, .{});
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();
    try yaml.emit(&output.writer, document, .{});
    return output.toOwnedSlice();
}
