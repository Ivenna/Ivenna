const std = @import("std");
const content = @import("content");
const output = @import("output.zig");
const Allocator = std.mem.Allocator;
const Interpretation = content.Interpretation;
const text_variant_overhead = "{\"text\":".len + 1;

/// Combines host output previews with complete file content.
pub const Reader = struct {
    io: std.Io,
    pub const FileContent = union(enum) {
        text: output.Preview,
        image: content.ImageContent,
        file: content.File,
        unavailable: content.Unavailable,
    };

    /// Text budget comes from the validated host request and stream split.
    pub fn readFileLimit(self: Reader, a: Allocator, file: std.Io.File, interpretation: ?Interpretation, max_bytes: usize) !FileContent {
        if (try self.readMedia(a, file, interpretation, false)) |media| return media;
        const preview = try self.readTextLimit(a, file, max_bytes);
        if (preview == .unavailable) {
            if (try self.readMedia(a, file, interpretation, true)) |media| return media;
        }
        return preview;
    }

    /// Read a bounded text preview, reporting binary content as unavailable.
    pub fn readTextLimit(self: Reader, a: Allocator, file: std.Io.File, max_bytes: usize) !FileContent {
        return .{ .text = output.previewLimit(a, self.io, file, max_bytes - text_variant_overhead) catch |err| switch (err) {
            error.UnsupportedBinary => return .{ .unavailable = .{ .byte_length = try file.length(self.io), .reason = .unsupported_binary } },
            else => return err,
        } };
    }

    /// Null leaves a textual source to its bounded preview or byte cursor.
    /// Images, files, and URL references use their complete source.
    pub fn readMedia(self: Reader, a: Allocator, file: std.Io.File, interpretation: ?Interpretation, binary_observed: bool) !?FileContent {
        const media = try content.readFileMedia(self.io, a, file, try file.length(self.io), .{
            .detect = .{ .interpretation = interpretation, .binary_observed = binary_observed },
        }) orelse return null;
        return switch (media) {
            inline else => |value, tag| @unionInit(FileContent, @tagName(tag), value),
        };
    }
};
