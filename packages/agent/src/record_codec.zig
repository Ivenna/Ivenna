//! Compact ZON encoding and content keys shared by history and activity reports.
//! Their storage owners retain schemas, chain selection, and retention policy.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Key = @import("agent_contracts").HistoryStore.Key;

pub fn encode(a: Allocator, value: anytype) ![]const u8 {
    // ZON inspects the complete nested history schema at compile time.
    @setEvalBranchQuota(10_000);
    var writer: std.Io.Writer.Allocating = .init(a);
    defer writer.deinit();
    try std.zon.stringify.serialize(value, .{ .whitespace = false }, &writer.writer);
    return writer.toOwnedSlice();
}

pub fn decode(comptime T: type, a: Allocator, data: []const u8, options: struct { ignore_unknown_fields: bool = false }) !T {
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(T, .{
        .gpa = a,
        .arena = a,
        .source = try a.dupeSentinel(u8, data, 0),
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = options.ignore_unknown_fields,
    }) catch |err| switch (err) {
        error.ParseZon => error.InvalidHistory,
        else => err,
    };
}

pub fn digest(data: []const u8) Key {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

pub fn validKey(key: Key) bool {
    for (key) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}
