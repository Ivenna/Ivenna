/// Encoded image bytes. Source adapters identify the format without decoding
/// pixels; model adapters choose their wire representation.
pub const Image = struct {
    pub const Format = enum { jpeg, png, gif, webp };

    format: Format,
    bytes: []const u8,

    pub fn mimeType(self: Image) []const u8 {
        return switch (self.format) {
            .jpeg => "image/jpeg",
            .png => "image/png",
            .gif => "image/gif",
            .webp => "image/webp",
        };
    }
};
