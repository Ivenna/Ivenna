const std = @import("std");
const content = @import("content");
const output = @import("output.zig");
const Allocator = std.mem.Allocator;
const Interpretation = content.Interpretation;
const text_variant_overhead = "{\"text\":".len + 1;

/// Owns complete-source classification and native media.
pub const Reader = struct {
    io: std.Io,
    pub const FileContent = union(enum) {
        text: output.Preview,
        image: content.ImageContent,
        unavailable: content.Unavailable,
    };

    /// Text budget comes from the validated host request and stream split.
    pub fn readFileLimit(self: Reader, a: Allocator, file: std.Io.File, interpretation: ?Interpretation, max_bytes: usize) !FileContent {
        if (try self.readMedia(a, file, interpretation)) |media| return media;
        return self.readTextLimit(a, file, max_bytes);
    }

    /// Diagnostics never need image allocation or interpretation.
    pub fn readTextLimit(self: Reader, a: Allocator, file: std.Io.File, max_bytes: usize) !FileContent {
        return .{ .text = output.previewLimit(a, self.io, file, max_bytes - text_variant_overhead) catch |err| switch (err) {
            error.UnsupportedBinary => return .{ .unavailable = .{ .byte_length = try file.length(self.io), .reason = .unsupported_binary } },
            else => return err,
        } };
    }

    /// Null leaves a textual source to its bounded preview or byte cursor.
    /// Images and URL references are classified from their complete source.
    pub fn readMedia(self: Reader, a: Allocator, file: std.Io.File, interpretation: ?Interpretation) !?FileContent {
        const length = try file.length(self.io);
        var header: [16]u8 = undefined;
        const header_read = try file.readPositionalAll(self.io, &header, 0);
        if (content.detectFormat(header[0..header_read]) != null) {
            if (length > content.image_size_limit)
                return .{ .unavailable = .{ .byte_length = length, .reason = .image_too_large } };
        } else {
            if (interpretation == null) return null;
            if (length > content.reference_size_limit)
                return .{ .unavailable = .{ .byte_length = length, .reason = .reference_too_large } };
        }
        const bytes = try a.alloc(u8, @intCast(length));
        var retained = false;
        defer if (!retained) a.free(bytes);
        const count = try file.readPositionalAll(self.io, bytes, 0);
        return switch (content.interpret(bytes[0..count], interpretation)) {
            .text => null,
            .image => |image| blk: {
                retained = true;
                break :blk .{ .image = image };
            },
            .unavailable => |diagnostic| .{ .unavailable = diagnostic },
        };
    }
};
