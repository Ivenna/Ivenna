const std = @import("std");
const zignal = @import("zignal");

/// One tool's model-facing result. Parts and their payloads belong to
/// the current turn; classification of one source does not remove sibling parts.
pub const Content = struct {
    parts: []const Part,

    pub const Part = union(enum) {
        text: []const u8,
        image: ImageContent,
        file: File,
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
};

pub const Image = @import("image.zig").Image;
pub const LocalFile = @import("local_file.zig");

/// Complete opaque file bytes. The model service owns format recognition.
pub const File = struct {
    bytes: []const u8,
    reference: ?[]const u8 = null,
};

pub const image_size_limit = 32 * 1024 * 1024;
pub const file_size_limit = 32 * 1024 * 1024;
pub const reference_size_limit = 16 * 1024;

pub fn withoutLineEnding(bytes: []const u8) []const u8 {
    return std.mem.cutSuffix(u8, bytes, "\r\n") orelse std.mem.cutSuffix(u8, bytes, "\n") orelse bytes;
}

/// Explicit interpretation of a complete text source as a resource reference.
pub const Interpretation = enum { image_url };

pub const Unavailable = struct {
    byte_length: u64,
    reason: enum { image_too_large, file_too_large, reference_too_large },
};

pub const Classified = union(enum) {
    text: []const u8,
    image: ImageContent,
    file: File,
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

/// A partial UTF-8 character at the end of a prefix is still possible text.
/// ASCII PDF headers need complete-file delivery even when all bytes are text.
pub fn requiresCompleteSource(prefix: []const u8, complete: bool) bool {
    return detectFormat(prefix) != null or hasPdfHeader(prefix) or textPrefixLength(prefix, !complete) == null;
}

pub fn hasPdfHeader(bytes: []const u8) bool {
    return bytes.len >= 8 and std.mem.startsWith(u8, bytes, "%PDF-") and
        std.ascii.isDigit(bytes[5]) and bytes[6] == '.' and std.ascii.isDigit(bytes[7]);
}

/// Preserve ordinary text and images; pass other complete sources as files.
pub fn classify(bytes: []const u8) Classified {
    if (detectFormat(bytes)) |format|
        return .{ .image = .{ .data = .{ .format = format, .bytes = bytes } } };
    if (hasPdfHeader(bytes) or !isText(bytes))
        return .{ .file = .{ .bytes = bytes } };
    return .{ .text = bytes };
}

/// Present a caller-declared image reference without fetching or validating it.
/// Recognized media keep their data representation; empty text stays text.
pub fn interpret(bytes: []const u8, interpretation: ?Interpretation) Classified {
    const classified = classify(bytes);
    if (interpretation == .image_url and classified == .text) {
        const url = withoutLineEnding(bytes);
        if (url.len > 0) return .{ .image = .{ .url = url } };
    }
    return classified;
}

pub fn isText(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) == null and std.unicode.utf8ValidateSlice(bytes);
}

/// Length of the UTF-8 text prefix, excluding a still-valid incomplete tail
/// when allowed. Null means NUL or a sequence that cannot become valid text.
pub fn textPrefixLength(bytes: []const u8, allow_partial: bool) ?usize {
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return null;
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes.len;
    if (!allow_partial) return null;

    // An incomplete codepoint has at most three bytes. Walking backward also
    // establishes that every byte after its leading byte is a continuation.
    var start = bytes.len - 1;
    while (bytes[start] & 0xc0 == 0x80) {
        if (start == 0 or bytes.len - start == 3) return null;
        start -= 1;
    }
    const tail = bytes[start..];
    const first = tail[0];
    if (first < 0xc2 or first > 0xf4) return null;
    const length = std.unicode.utf8ByteSequenceLength(first) catch return null;
    if (length <= tail.len) return null;
    if (tail.len > 1) {
        const second = tail[1];
        if ((first == 0xe0 and second < 0xa0) or
            (first == 0xed and second >= 0xa0) or
            (first == 0xf0 and second < 0x90) or
            (first == 0xf4 and second >= 0x90)) return null;
    }
    return if (std.unicode.utf8ValidateSlice(bytes[0..start])) start else null;
}

test "explicit image references accept a trailing line ending" {
    const source = "https://example.com/image.png\n";
    try std.testing.expectEqualStrings(source, classify(source).text);
    try std.testing.expectEqualStrings("https://example.com/image.png", interpret(source, .image_url).image.url);
    try std.testing.expectEqualStrings("", interpret("", .image_url).text);

    const png = "\x89PNG\r\n\x1a\n";
    const image = interpret(png, .image_url).image.data;
    try std.testing.expectEqual(Image.Format.png, image.format);
    try std.testing.expectEqualSlices(u8, png, image.bytes);
}

test "complete binary files pass through without local format recognition" {
    for ([_][]const u8{ "%PDF-1.7\nall ASCII", "\x00\xff\x01", "PK\x03\x04\x00unknown package" }) |bytes| {
        const file = classify(bytes).file;
        try std.testing.expectEqualSlices(u8, bytes, file.bytes);
        try std.testing.expectEqual(null, file.reference);
        try std.testing.expectEqualSlices(u8, bytes, interpret(bytes, .image_url).file.bytes);
    }
    try std.testing.expectEqualStrings("ordinary text", classify("ordinary text").text);
    try std.testing.expect(!requiresCompleteSource("UTF-8 \xf0\x9f", false));
    try std.testing.expect(requiresCompleteSource("UTF-8 \xf0\x9f", true));
    try std.testing.expect(requiresCompleteSource("binary \x00", false));
}

test "streaming text preserves valid codepoint prefixes at encoding boundaries" {
    const prefix = "context ";
    for ([_]u21{ 0x80, 0x800, 0xd7ff, 0x10000, 0x10ffff }) |codepoint| {
        var bytes: [prefix.len + 4]u8 = undefined;
        @memcpy(bytes[0..prefix.len], prefix);
        const length = try std.unicode.utf8Encode(codepoint, bytes[prefix.len..]);
        for (1..@as(usize, length)) |selected| {
            const source = bytes[0 .. prefix.len + selected];
            try std.testing.expectEqual(@as(?usize, prefix.len), textPrefixLength(source, true));
            try std.testing.expectEqual(null, textPrefixLength(source, false));
        }
    }
    try std.testing.expectEqual(@as(?usize, 0), textPrefixLength("", true));
    const complete = "hi \xf0\x9f\x90\xbe";
    try std.testing.expectEqual(@as(?usize, complete.len), textPrefixLength(complete, false));
}

test "streaming text rejects malformed bytes rather than retaining them as an incomplete tail" {
    for ([_][]const u8{
        "text\x00tail", "\x80", "\xc0",      "\xe0\x80",     "\xed\xa0",         "\xf0\x80",
        "\xf4\x90",     "\xf5", "\xe2\x82A", "\xff\xe2\x82", "\xe2\x82\xac\x80",
    }) |bytes| {
        try std.testing.expectEqual(null, textPrefixLength(bytes, true));
        try std.testing.expectEqual(null, textPrefixLength(bytes, false));
    }
}
