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
        const length = try file.length(self.io);
        var header: [32]u8 = undefined;
        const header_read = try file.readPositionalAll(self.io, &header, 0);
        if (content.detectFormat(header[0..header_read]) != null) {
            if (length > content.image_size_limit)
                return .{ .unavailable = .{ .byte_length = length, .reason = .image_too_large } };
        } else if (binary_observed or content.requiresCompleteSource(header[0..header_read], header_read == length)) {
            if (length > content.file_size_limit)
                return .{ .unavailable = .{ .byte_length = length, .reason = .file_too_large } };
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
                if (image == .url and image.url.len > content.reference_size_limit)
                    break :blk .{ .unavailable = .{ .byte_length = image.url.len, .reason = .reference_too_large } };
                retained = true;
                break :blk .{ .image = image };
            },
            .file => |document| blk: {
                retained = true;
                break :blk .{ .file = document };
            },
        };
    }
};

test "a prior binary observation still applies the limit to a replacement image reference" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const reference = try a.alloc(u8, content.reference_size_limit + 1);
    @memset(reference, 'a');
    try temporary.dir.writeFile(io, .{ .sub_path = "stdout", .data = reference });
    const file = try temporary.dir.openFile(io, "stdout", .{});
    defer file.close(io);

    // The earlier binary observation selects whole-source reading, but that
    // source may now be text interpreted as a URL with its own smaller limit.
    const result = (try (Reader{ .io = io }).readMedia(a, file, .image_url, true)).?;
    try std.testing.expectEqual(.reference_too_large, result.unavailable.reason);
    try std.testing.expectEqual(reference.len, result.unavailable.byte_length);
}
