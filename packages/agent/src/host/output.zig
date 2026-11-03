const std = @import("std");

const Allocator = std.mem.Allocator;

pub const preview_limit = 16 * 1024;
const truncation_marker = "\n[... output truncated; read the full log file for more ...]\n";

pub const Preview = struct { text: []const u8, truncated: bool };

pub fn preview(a: Allocator, io: std.Io, file: std.Io.File) !Preview {
    const length = try file.length(io);
    var truncated = length > preview_limit;
    const raw = if (!truncated) blk: {
        const bytes = try a.alloc(u8, @intCast(length));
        const read = try file.readPositionalAll(io, bytes, 0);
        break :blk bytes[0..read];
    } else blk: {
        const head_length = (preview_limit - truncation_marker.len) / 2;
        const tail_length = preview_limit - truncation_marker.len - head_length;
        const head = try a.alloc(u8, head_length);
        const tail = try a.alloc(u8, tail_length);
        const head_read = try file.readPositionalAll(io, head, 0);
        const tail_read = try file.readPositionalAll(io, tail, length - tail_length);
        break :blk try std.mem.concat(a, u8, &.{ head[0..head_read], truncation_marker, tail[0..tail_read] });
    };
    const converted = try text(a, raw);
    // Replacement characters can expand invalid UTF-8, so apply the byte
    // budget again to the valid string returned to the model.
    if (converted.len <= preview_limit) return .{ .text = converted, .truncated = truncated };
    truncated = true;
    var head_end = (preview_limit - truncation_marker.len) / 2;
    while (head_end > 0 and converted[head_end] & 0xc0 == 0x80) head_end -= 1;
    var tail_start = converted.len - (preview_limit - truncation_marker.len - head_end);
    while (tail_start < converted.len and converted[tail_start] & 0xc0 == 0x80) tail_start += 1;
    return .{
        .text = try std.mem.concat(a, u8, &.{ converted[0..head_end], truncation_marker, converted[tail_start..] }),
        .truncated = truncated,
    };
}

pub fn text(a: Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var output: std.array_list.Managed(u8) = .init(a);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[offset]) catch 0;
        if (length != 0 and offset + length <= bytes.len) {
            if (std.unicode.utf8Decode(bytes[offset..][0..length])) |_| {
                try output.appendSlice(bytes[offset..][0..length]);
                offset += length;
                continue;
            } else |_| {}
        }
        try output.appendSlice("\u{fffd}");
        offset += 1;
    }
    return output.toOwnedSlice();
}
