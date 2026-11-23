const std = @import("std");
const content = @import("content");

pub const text_byte_limit = 16 * 1024;

pub const View = union(enum) {
    window: Window,
    image,

    pub fn parse(value: std.json.Value) !View {
        if (value == .string and std.mem.eql(u8, value.string, "image")) return .image;
        if (value != .object) return error.InvalidToolArguments;
        var window: Window = .{};
        var fields = value.object.iterator();
        while (fields.next()) |field| {
            const name = field.key_ptr.*;
            const input = field.value_ptr.*;
            if (input != .integer) return error.InvalidToolArguments;
            if (std.mem.eql(u8, name, "offset") and input.integer >= 0) {
                window.offset = @intCast(input.integer);
            } else if (std.mem.eql(u8, name, "limit") and input.integer > 0) {
                window.limit = std.math.cast(usize, input.integer) orelse return error.InvalidToolArguments;
            } else return error.InvalidToolArguments;
        }
        return .{ .window = window };
    }
};

pub const Window = struct {
    offset: u64 = 0,
    limit: ?usize = null,

    pub fn count(self: Window, maximum: usize) usize {
        return @min(self.limit orelse maximum, maximum);
    }
};

/// The filesystem reader probes at least four bytes (or EOF) so even a
/// one-byte request can return the complete first UTF-8 character.
pub fn textLength(bytes: []const u8, budget: usize) ?usize {
    if (bytes.len == 0) return 0;
    const first = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
    const end = @min(bytes.len, @max(budget, first));
    return content.textPrefixLength(bytes[0..end], end < bytes.len);
}

/// Return a prefix of valid UTF-8, allowing at least its first complete character.
pub fn utf8Prefix(bytes: []const u8, budget: usize) []const u8 {
    if (bytes.len <= budget) return bytes;
    var end = budget;
    while (end > 0 and bytes[end] & 0xc0 == 0x80) end -= 1;
    if (end == 0) end = std.unicode.utf8ByteSequenceLength(bytes[0]) catch unreachable;
    return bytes[0..end];
}
