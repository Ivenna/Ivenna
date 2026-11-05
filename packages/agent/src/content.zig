const std = @import("std");

pub const image_size_limit = 32 * 1024 * 1024;

/// Explicit interpretation of a complete text source as a resource reference.
pub const Interpretation = enum { image_url };

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

pub const Unavailable = struct {
    byte_length: u64,
    reason: enum { unsupported_binary, image_too_large },
};

pub const Classified = union(enum) {
    text: []const u8,
    image: ImageContent,
    unavailable: Unavailable,
};

/// Classify bytes by image signature or UTF-8 text. A textual address stays text.
pub fn classify(bytes: []const u8) Classified {
    if (Image.fromBytes(bytes)) |image| {
        if (bytes.len > image_size_limit)
            return .{ .unavailable = .{ .byte_length = bytes.len, .reason = .image_too_large } };
        return .{ .image = .{ .data = image } };
    }
    if (!isText(bytes))
        return .{ .unavailable = .{ .byte_length = bytes.len, .reason = .unsupported_binary } };
    return .{ .text = bytes };
}

/// Present a caller-declared image reference without fetching or validating it.
/// Recognized image bytes keep their data representation; empty text stays text.
pub fn interpret(bytes: []const u8, interpretation: ?Interpretation) Classified {
    const classified = classify(bytes);
    if (interpretation == .image_url and classified == .text and bytes.len != 0)
        return .{ .image = .{ .url = bytes } };
    return classified;
}

pub fn isText(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) == null and std.unicode.utf8ValidateSlice(bytes);
}
