const zignal = @import("zignal");

/// Borrowed encoded image bytes, identified by signature without decoding pixels.
pub const Image = struct {
    pub const Format = enum { jpeg, png, gif, webp };

    format: Format,
    bytes: []const u8,

    pub fn fromBytes(bytes: []const u8) ?Image {
        return .{ .format = detectFormat(bytes) orelse return null, .bytes = bytes };
    }

    pub fn detectFormat(bytes: []const u8) ?Format {
        return switch (zignal.image.Format.detectFromBytes(bytes) orelse return null) {
            .jpeg => .jpeg,
            .png => .png,
            .gif => .gif,
            .webp => .webp,
            .bmp, .jxl => null,
        };
    }

    pub fn mimeType(self: Image) []const u8 {
        return switch (self.format) {
            .jpeg => "image/jpeg",
            .png => "image/png",
            .gif => "image/gif",
            .webp => "image/webp",
        };
    }
};
