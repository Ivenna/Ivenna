const std = @import("std");
const content = @import("../content.zig");

const Allocator = std.mem.Allocator;

pub const preview_limit = 16 * 1024;
const truncation_marker = "\n[... output truncated; read the full source for more ...]\n";

pub const Preview = struct { text: []const u8, truncated: bool };

/// Return a bounded text preview without replacing binary or invalid UTF-8.
pub fn preview(a: Allocator, io: std.Io, file: std.Io.File) !Preview {
    const length = try file.length(io);
    if (length <= preview_limit) {
        const bytes = try a.alloc(u8, @intCast(length));
        const read = try file.readPositionalAll(io, bytes, 0);
        const value = bytes[0..read];
        if (!content.isText(value)) return error.UnsupportedBinary;
        return .{ .text = value, .truncated = false };
    }

    const head_length = (preview_limit - truncation_marker.len) / 2;
    const tail_length = preview_limit - truncation_marker.len - head_length;
    const head = try a.alloc(u8, head_length);
    const tail = try a.alloc(u8, tail_length);
    const head_read = try file.readPositionalAll(io, head, 0);
    const tail_read = try file.readPositionalAll(io, tail, length - tail_length);
    const head_text = completePrefix(head[0..head_read]);
    const tail_text = completeSuffix(tail[0..tail_read]);
    if (!content.isText(head_text) or !content.isText(tail_text)) return error.UnsupportedBinary;
    return .{
        .text = try std.mem.concat(a, u8, &.{ head_text, truncation_marker, tail_text }),
        .truncated = true,
    };
}

fn completePrefix(bytes: []const u8) []const u8 {
    if (bytes.len == 0) return bytes;
    var start = bytes.len - 1;
    while (start > 0 and bytes[start] & 0xc0 == 0x80) start -= 1;
    const length = std.unicode.utf8ByteSequenceLength(bytes[start]) catch return bytes;
    return if (length > bytes.len - start) bytes[0..start] else bytes;
}

fn completeSuffix(bytes: []const u8) []const u8 {
    var start: usize = 0;
    while (start < @min(bytes.len, 3) and bytes[start] & 0xc0 == 0x80) start += 1;
    return bytes[start..];
}
