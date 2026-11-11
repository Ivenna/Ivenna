const std = @import("std");
const zignal = @import("zignal");

/// One tool's model-facing result. Parts and their payloads belong to
/// the current turn; classification of one source does not remove sibling parts.
pub const Content = struct {
    parts: []const Part,

    pub const Part = union(enum) {
        text: []const u8,
        image: ImageContent,
    };

    pub fn fromText(allocator: std.mem.Allocator, text: []const u8) !Content {
        return fromParts(allocator, &.{.{ .text = text }});
    }

    pub fn fromParts(allocator: std.mem.Allocator, parts: []const Part) !Content {
        return .{ .parts = try allocator.dupe(Part, parts) };
    }
};

pub const ImageContent = union(enum) {
    data: Image,
    url: []const u8,

    pub const Description = union(enum) {
        data: struct { format: Image.Format, byte_length: u64 },
        url: struct {},
    };

    pub fn describe(self: ImageContent) Description {
        return switch (self) {
            .data => |image| .{ .data = .{ .format = image.format, .byte_length = image.bytes.len } },
            .url => .{ .url = .{} },
        };
    }
};

pub const Image = @import("image.zig").Image;

pub const image_size_limit = 32 * 1024 * 1024;
pub const reference_size_limit = 16 * 1024;

/// Explicit interpretation of a complete text source as a resource reference.
pub const Interpretation = enum { image_url };

pub const Unavailable = struct {
    byte_length: u64,
    reason: enum { unsupported_binary, image_too_large, reference_too_large },
};

pub const Classified = union(enum) {
    text: []const u8,
    image: ImageContent,
    unavailable: Unavailable,
};

/// Recognize encoded image signatures without decoding pixels.
pub fn detectFormat(bytes: []const u8) ?Image.Format {
    return switch (zignal.image.Format.detectFromBytes(bytes) orelse return null) {
        .jpeg => .jpeg,
        .png => .png,
        .gif => .gif,
        .webp => .webp,
        .bmp, .jxl => null,
    };
}

/// Classify bytes by image signature or UTF-8 text. A textual address stays text.
pub fn classify(bytes: []const u8) Classified {
    if (detectFormat(bytes)) |format| {
        if (bytes.len > image_size_limit)
            return .{ .unavailable = .{ .byte_length = bytes.len, .reason = .image_too_large } };
        return .{ .image = .{ .data = .{ .format = format, .bytes = bytes } } };
    }
    if (!isText(bytes))
        return .{ .unavailable = .{ .byte_length = bytes.len, .reason = .unsupported_binary } };
    return .{ .text = bytes };
}

/// Present a caller-declared image reference without fetching or validating it.
/// Recognized image bytes keep their data representation; empty text stays text.
pub fn interpret(bytes: []const u8, interpretation: ?Interpretation) Classified {
    const classified = classify(bytes);
    if (interpretation == .image_url and classified == .text and bytes.len > reference_size_limit)
        return .{ .unavailable = .{ .byte_length = bytes.len, .reason = .reference_too_large } };
    if (interpretation == .image_url and classified == .text and bytes.len != 0)
        return .{ .image = .{ .url = bytes } };
    return classified;
}

pub fn isText(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) == null and std.unicode.utf8ValidateSlice(bytes);
}

/// Length of the UTF-8 text prefix, excluding a still-valid incomplete tail
/// when allowed. Null means NUL or a sequence that cannot become valid text.
pub fn textPrefixLength(bytes: []const u8, allow_partial: bool) ?usize {
    var index: usize = 0;
    while (index < bytes.len) {
        const first = bytes[index];
        if (first == 0 or (first >= 0xc0 and first < 0xc2) or first > 0xf4) return null;
        const length = std.unicode.utf8ByteSequenceLength(first) catch return null;
        if (length > bytes.len - index) {
            if (!allow_partial) return null;
            const rest = bytes[index..];
            for (rest[1..]) |byte| if (byte & 0xc0 != 0x80) return null;
            if (rest.len > 1) {
                const second = rest[1];
                if ((first == 0xe0 and second < 0xa0) or
                    (first == 0xed and second >= 0xa0) or
                    (first == 0xf0 and second < 0x90) or
                    (first == 0xf4 and second >= 0x90)) return null;
            }
            return index;
        }
        _ = std.unicode.utf8Decode(bytes[index..][0..length]) catch return null;
        index += length;
    }
    return index;
}

test "image references require explicit interpretation and preserve source representation" {
    const source = "https://example.com/image.png\n";
    try std.testing.expectEqualStrings(source, classify(source).text);
    try std.testing.expectEqualStrings(source, interpret(source, .image_url).image.url);
    try std.testing.expectEqualStrings("", interpret("", .image_url).text);

    const png = "\x89PNG\r\n\x1a\n";
    const image = interpret(png, .image_url).image.data;
    try std.testing.expectEqual(Image.Format.png, image.format);
    try std.testing.expectEqualSlices(u8, png, image.bytes);

    const oversized = try std.testing.allocator.alloc(u8, reference_size_limit + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'a');
    const unavailable = interpret(oversized, .image_url).unavailable;
    try std.testing.expectEqual(.reference_too_large, unavailable.reason);
    try std.testing.expectEqual(oversized.len, unavailable.byte_length);
}

test "streaming text leaves incomplete UTF-8 for the next observation" {
    const incomplete = "hi \xf0\x9f";
    try std.testing.expectEqual(@as(?usize, 3), textPrefixLength(incomplete, true));
    try std.testing.expectEqual(null, textPrefixLength(incomplete, false));

    const complete = incomplete ++ "\x90\xbe";
    try std.testing.expectEqual(@as(?usize, complete.len), textPrefixLength(complete, false));
    try std.testing.expectEqual(null, textPrefixLength("hi \xf0A", true));
    try std.testing.expectEqual(null, textPrefixLength("hi \x00", true));
}
