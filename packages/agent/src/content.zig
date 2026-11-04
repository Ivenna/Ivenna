const std = @import("std");

pub const image_size_limit = 32 * 1024 * 1024;

/// Content hint for a complete memory entry or stdout capture.
pub const Expected = union(enum) {
    auto: struct {},
    text: struct {},
    image: struct {
        representation: enum { data, url } = .data,
    },

    pub fn isUrlReference(self: Expected) bool {
        return switch (self) {
            .image => |image| image.representation == .url,
            .auto, .text => false,
        };
    }
};

/// One tool's model-facing result. Payload slices are borrowed for the current turn.
pub const Content = union(enum) {
    text: []const u8,
    image: ImageContent,
};

pub const ImageContent = union(enum) {
    data: Image,
    url: []const u8,
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

/// Classify bytes by image signature or UTF-8 text, without requiring a match
/// to a text or image-data expectation. URL expectations interpret nonempty text
/// as a reference without fetching, changing, or validating the address.
pub fn classify(bytes: []const u8, expected: Expected) Classified {
    if (Image.fromBytes(bytes)) |image| {
        if (bytes.len > image_size_limit)
            return .{ .unavailable = .{ .byte_length = bytes.len, .reason = .image_too_large } };
        return .{ .image = .{ .data = image } };
    }
    if (!isText(bytes))
        return .{ .unavailable = .{ .byte_length = bytes.len, .reason = .unsupported_binary } };
    if (expected.isUrlReference() and bytes.len != 0) return .{ .image = .{ .url = bytes } };
    return .{ .text = bytes };
}

pub fn isText(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) == null and std.unicode.utf8ValidateSlice(bytes);
}
