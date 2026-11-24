//! Canonical channel addresses within one Ivenna instance.
const std = @import("std");
const Allocator = std.mem.Allocator;
const hex = "0123456789ABCDEF";

pub const Kind = enum { correspondent, focus, feed };

pub const Address = union(Kind) {
    correspondent: []const u8,
    focus: []const u8,
    feed: []const u8,
};

pub const Error = Allocator.Error || error{InvalidAddress};

fn prefix(kind: Kind) []const u8 {
    return switch (kind) {
        .correspondent => "ivenna:/correspondent/",
        .focus => "ivenna:/focus/",
        .feed => "ivenna:/feed/",
    };
}

/// Address one opaque key. The result belongs to a.
pub fn format(a: Allocator, kind: Kind, key: []const u8) Error![]const u8 {
    if (key.len == 0 or !std.unicode.utf8ValidateSlice(key)) return error.InvalidAddress;
    const start = prefix(kind);
    var length = start.len;
    for (key) |byte| {
        if (isAsciiControl(byte)) return error.InvalidAddress;
        length += if (isUnreserved(byte)) @as(usize, 1) else 3;
    }

    const address = try a.alloc(u8, length);
    @memcpy(address[0..start.len], start);
    var index = start.len;
    for (key) |byte| {
        if (isUnreserved(byte)) {
            address[index] = byte;
            index += 1;
        } else {
            address[index..][0..3].* = .{ '%', hex[byte >> 4], hex[byte & 0x0F] };
            index += 3;
        }
    }
    return address;
}

/// Parse a canonical address for one destination. The decoded key belongs to a.
pub fn parse(a: Allocator, raw: []const u8) Error!Address {
    inline for (comptime std.meta.tags(Kind)) |kind| {
        if (std.mem.cutPrefix(u8, raw, prefix(kind))) |payload|
            return @unionInit(Address, @tagName(kind), try decode(a, payload));
    }
    return error.InvalidAddress;
}

fn decode(a: Allocator, encoded: []const u8) Error![]const u8 {
    if (encoded.len == 0) return error.InvalidAddress;
    var key = try std.ArrayList(u8).initCapacity(a, encoded.len);
    errdefer key.deinit(a);

    var index: usize = 0;
    while (index < encoded.len) {
        const byte = encoded[index];
        if (isUnreserved(byte)) {
            key.appendAssumeCapacity(byte);
            index += 1;
        } else if (byte == '%' and encoded.len - index >= 3) {
            const high = hexDigit(encoded[index + 1]) orelse return error.InvalidAddress;
            const low = hexDigit(encoded[index + 2]) orelse return error.InvalidAddress;
            const decoded = high << 4 | low;
            if (isUnreserved(decoded) or isAsciiControl(decoded)) return error.InvalidAddress;
            key.appendAssumeCapacity(decoded);
            index += 3;
        } else {
            return error.InvalidAddress;
        }
    }
    if (!std.unicode.utf8ValidateSlice(key.items)) return error.InvalidAddress;
    return key.toOwnedSlice(a);
}

fn isUnreserved(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '-', '.', '_', '~' => true,
        else => false,
    };
}

fn isAsciiControl(byte: u8) bool {
    return byte < ' ' or byte == 0x7F;
}

fn hexDigit(byte: u8) ?u8 {
    const index = std.mem.indexOfScalar(u8, hex, byte) orelse return null;
    return @intCast(index);
}

test "channel addresses preserve names as opaque UTF-8 keys" {
    const a = std.testing.allocator;
    const name = "发布 notes/$?,#%2F-17";
    const address = try format(a, .feed, name);
    defer a.free(address);
    try std.testing.expectEqualStrings("ivenna:/feed/%E5%8F%91%E5%B8%83%20notes%2F%24%3F%2C%23%252F-17", address);
    const parsed = (try parse(a, address)).feed;
    defer a.free(parsed);
    try std.testing.expectEqualStrings(name, parsed);

    const focus = (try parse(a, "ivenna:/focus/core-1")).focus;
    defer a.free(focus);
    try std.testing.expectEqualStrings("core-1", focus);
}

test "a correspondent address decodes to exactly one identifier" {
    const a = std.testing.allocator;
    const recipient = (try parse(a, "ivenna:/correspondent/Operator%2Bwork")).correspondent;
    defer a.free(recipient);
    try std.testing.expectEqualStrings("Operator+work", recipient);

    const one_key = (try parse(a, "ivenna:/correspondent/Alice%2CBob")).correspondent;
    defer a.free(one_key);
    try std.testing.expectEqualStrings("Alice,Bob", one_key);
}

test "invalid and noncanonical channel addresses are rejected" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "ivenna://focus/core-1",
        "ivenna:fetch/core-1",
        "ivenna:/focus/",
        "ivenna:/focus/a b",
        "ivenna:/focus/a/b",
        "ivenna:/focus/a#b",
        "ivenna:/focus/a?b",
        "ivenna:/focus/a,b",
        "ivenna:/feed/%6Eote-1",
        "ivenna:/feed/a%2fb",
        "ivenna:/feed/a%2",
        "ivenna:/feed/a%XY",
        "ivenna:/feed/a%00",
        "ivenna:/feed/a%1F",
        "ivenna:/feed/a%7F",
        "ivenna:/feed/%FF",
        "ivenna:/correspondent/alice,bob",
        "ivenna:/mail/alice",
        "ivenna:/output/note-1",
    }) |address| {
        try std.testing.expectError(error.InvalidAddress, parse(a, address));
    }
    try std.testing.expectError(error.InvalidAddress, format(a, .focus, ""));
    try std.testing.expectError(error.InvalidAddress, format(a, .focus, "a\n-1"));
    try std.testing.expectError(error.InvalidAddress, format(a, .focus, "\xff"));
}
