const std = @import("std");
const content = @import("content");

const Allocator = std.mem.Allocator;

pub const preview_line_limit = 2000;
const marker_format = "\n[... {d} bytes omitted ...]\n";
const marker_reserve = std.fmt.count(marker_format, .{std.math.maxInt(u64)});

pub const Preview = struct { text: []const u8, truncated: bool };

pub const StreamContent = union(enum) {
    text: Preview,
    binary,
};

pub const Chunk = struct {
    offset: u64,
    next_offset: u64,
    byte_length: u64,
    content: StreamContent,
};

fn mediaHeader(prefix: []const u8) bool {
    return content.detectFormat(prefix) != null or content.hasPdfHeader(prefix);
}

/// Read a consecutive range and classify its bytes as text or binary.
/// `max_bytes` bounds the JSON-encoded text.
/// A running stream's incomplete final character remains at the next cursor.
pub fn chunk(a: Allocator, io: std.Io, file: std.Io.File, offset: u64, length: u64, max_bytes: usize, finished: bool) !Chunk {
    const budget = max_bytes;
    if (offset > length) return error.InvalidOutputOffset;
    if (offset == length) return .{
        .offset = offset,
        .next_offset = offset,
        .byte_length = length,
        .content = .{ .text = .{ .text = "", .truncated = false } },
    };
    var header: [32]u8 = undefined;
    const count = try file.readPositionalAll(io, header[0..@intCast(@min(header.len, length))], 0);
    if (mediaHeader(header[0..count])) return .{
        .offset = offset,
        .next_offset = length,
        .byte_length = length,
        .content = .binary,
    };
    const capacity: usize = @intCast(@min(length - offset, budget));
    const bytes = try a.alloc(u8, capacity);
    errdefer a.free(bytes);
    const read = try file.readPositionalAll(io, bytes, offset);
    const window = linePrefix(bytes[0..read]);
    const allow_partial = !finished or offset + window.len < length;
    const prefix = content.textPrefixLength(window, allow_partial) orelse {
        a.free(bytes);
        return .{
            .offset = offset,
            .next_offset = offset + window.len,
            .byte_length = length,
            .content = .binary,
        };
    };
    var end = prefix;
    while (true) {
        const next = offset + end;
        const text = bytes[0..end];
        const encoded = encodedLength(text);
        if (encoded <= budget) return .{
            .offset = offset,
            .next_offset = next,
            .byte_length = length,
            .content = .{ .text = .{ .text = text, .truncated = next < length } },
        };
        // The prefix is valid UTF-8. Shrink only at complete characters and
        // leave all omitted bytes available at the returned cursor.
        const target = @min(end - 1, end * budget / encoded);
        end = completePrefix(bytes[0..target]).len;
    }
}

/// Return a beginning/end preview whose encoded text fits the budget.
pub fn preview(a: Allocator, io: std.Io, file: std.Io.File, length: u64, budget: usize) !StreamContent {
    if (length == 0) return .{ .text = .{ .text = "", .truncated = false } };
    if (length <= budget) {
        const bytes = try a.alloc(u8, @intCast(length));
        const read = try file.readPositionalAll(io, bytes, 0);
        const value = bytes[0..read];
        if (mediaHeader(value) or !content.isText(value)) return .binary;
        const lines = std.mem.count(u8, value, "\n") + @intFromBool(value.len != 0 and value[value.len - 1] != '\n');
        if (lines <= preview_line_limit and encodedLength(value) <= budget) return .{ .text = .{ .text = value, .truncated = false } };
        return truncatedPreview(a, value, value, length, budget);
    }

    const head_length = (budget - marker_reserve) / 2;
    const tail_length = budget - marker_reserve - head_length;
    const head = try a.alloc(u8, head_length);
    const head_read = try file.readPositionalAll(io, head, 0);
    if (mediaHeader(head[0..head_read])) return .binary;
    const tail = try a.alloc(u8, tail_length);
    const tail_read = try file.readPositionalAll(io, tail, length - tail_length);
    return truncatedPreview(a, head[0..head_read], tail[0..tail_read], length, budget);
}

/// Whether a running source can advance its cursor. Use the same text prefix
/// decision as chunk so malformed bytes are ready and partial characters wait.
pub fn readable(io: std.Io, file: std.Io.File, offset: u64) !bool {
    const length = try file.length(io);
    if (length <= offset) return false;
    if (length - offset >= 4) return true;
    var bytes: [4]u8 = undefined;
    const count = try file.readPositionalAll(io, bytes[0..@intCast(length - offset)], offset);
    return if (content.textPrefixLength(bytes[0..count], true)) |prefix| prefix != 0 else true;
}

fn truncatedPreview(a: Allocator, head: []const u8, tail: []const u8, length: u64, budget: usize) !StreamContent {
    var capacity: usize = @intCast(@min(budget - marker_reserve, length));
    while (true) {
        const head_capacity = capacity / 2;
        const tail_capacity = capacity - head_capacity;
        const head_text = headLines(completePrefix(head[0..@min(head.len, head_capacity)]));
        const tail_text = tailLines(completeSuffix(tail[tail.len - @min(tail.len, tail_capacity) ..]));
        if (!content.isText(head_text) or !content.isText(tail_text)) return .binary;
        const selected = head_text.len + tail_text.len;
        var marker_buffer: [marker_reserve]u8 = undefined;
        const marker = std.fmt.bufPrint(&marker_buffer, marker_format, .{length - selected}) catch unreachable;
        const text = try std.mem.concat(a, u8, &.{ head_text, marker, tail_text });
        const encoded = encodedLength(text);
        if (encoded <= budget) return .{ .text = .{ .text = text, .truncated = true } };
        a.free(text);
        capacity = @min(capacity - 1, selected * budget / encoded);
    }
}

fn encodedLength(value: anytype) usize {
    var buffer: [64]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&buffer);
    std.json.Stringify.value(value, .{}, &discard.writer) catch unreachable;
    return @intCast(discard.fullCount());
}

fn linePrefix(bytes: []const u8) []const u8 {
    var lines: usize = 0;
    for (bytes, 0..) |byte, index| {
        if (byte != '\n') continue;
        lines += 1;
        if (lines == preview_line_limit) return bytes[0 .. index + 1];
    }
    return bytes;
}

fn headLines(bytes: []const u8) []const u8 {
    var lines: usize = 0;
    var last_newline: ?usize = null;
    for (bytes, 0..) |byte, index| {
        if (byte != '\n') continue;
        last_newline = index;
        lines += 1;
        if (lines == preview_line_limit / 2) return bytes[0 .. index + 1];
    }
    // Keep a partial line only when no complete line fits the byte limit.
    return if (last_newline) |index| bytes[0 .. index + 1] else bytes;
}

fn tailLines(bytes: []const u8) []const u8 {
    var lines: usize = 0;
    var index = bytes.len;
    if (index != 0 and bytes[index - 1] == '\n') index -= 1;
    while (index != 0) {
        index -= 1;
        if (bytes[index] != '\n') continue;
        lines += 1;
        if (lines == preview_line_limit / 2) return bytes[index + 1 ..];
    }
    return if (std.mem.indexOfScalar(u8, bytes, '\n')) |newline|
        if (newline + 1 < bytes.len) bytes[newline + 1 ..] else bytes
    else
        bytes;
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

test "incremental reads recover text following a binary range" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const tail = "conversion complete\n";
    const budget = 128;
    var bytes: [budget + tail.len]u8 = @splat(0);
    @memcpy(bytes[budget..], tail);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "mixed", .data = &bytes });
    const file = try tmp.dir.openFile(t.io, "mixed", .{});
    defer file.close(t.io);
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const first = try chunk(arena.allocator(), t.io, file, 0, bytes.len, budget, true);
    try t.expect(first.content == .binary);
    try t.expectEqual(budget, first.next_offset);
    const rest = try chunk(arena.allocator(), t.io, file, first.next_offset, bytes.len, budget, true);
    try t.expectEqualStrings(tail, rest.content.text.text);
}
