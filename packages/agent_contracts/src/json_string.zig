//! A JSON string. Zig byte slices alone also accept arrays of integers.
const std = @import("std");
const JsonString = @This();

bytes: []const u8,

pub fn jsonParse(a: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!JsonString {
    if (try source.peekNextTokenType() != .string) return error.UnexpectedToken;
    return .{ .bytes = try std.json.innerParse([]const u8, a, source, options) };
}

pub fn jsonParseFromValue(_: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) std.json.ParseFromValueError!JsonString {
    if (source != .string) return error.UnexpectedToken;
    return .{ .bytes = source.string };
}

pub fn jsonStringify(self: JsonString, json: *std.json.Stringify) !void {
    try json.write(self.bytes);
}
