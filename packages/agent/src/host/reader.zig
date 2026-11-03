const std = @import("std");
const content = @import("../content.zig");
const output = @import("output.zig");

const Allocator = std.mem.Allocator;
const Expected = content.Expected;
const Image = content.Image;

/// Reads command stdout as text or native image content.
pub const Reader = struct {
    io: std.Io,

    pub const FileContent = union(enum) {
        text: output.Preview,
        image: content.ImageContent,
        unavailable: content.Unavailable,
    };

    /// Returned content uses the current turn's allocator.
    pub fn readFile(self: Reader, a: Allocator, file: std.Io.File, expected: Expected) !FileContent {
        const length = try file.length(self.io);
        var header: [16]u8 = undefined;
        const header_read = try file.readPositionalAll(self.io, &header, 0);
        const is_image = Image.detectFormat(header[0..header_read]) != null;
        if (is_image and length > content.image_size_limit)
            return .{ .unavailable = .{ .byte_length = length, .reason = .image_too_large } };

        if (is_image or expected.isUrlReference()) {
            const bytes = try a.alloc(u8, @intCast(length));
            const byte_count = try file.readPositionalAll(self.io, bytes, 0);
            return switch (content.classify(bytes[0..byte_count], expected)) {
                .text => .{ .text = try output.preview(a, self.io, file) },
                .image => |image| .{ .image = image },
                .unavailable => |unavailable| .{ .unavailable = unavailable },
            };
        }

        // TODO(streaming): classify omitted bytes incrementally when adding
        // streaming reads. Large text sources currently use head/tail samples.
        return .{ .text = output.preview(a, self.io, file) catch |err| switch (err) {
            error.UnsupportedBinary => return .{ .unavailable = .{ .byte_length = length, .reason = .unsupported_binary } },
            else => return err,
        } };
    }
};
