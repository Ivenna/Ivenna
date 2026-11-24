const std = @import("std");
const database = @import("database.zig");
const zqlite = @import("sqlite").zqlite;
const Allocator = std.mem.Allocator;

/// A reader owns a read-only connection to an initialized instance database.
pub const Reader = struct {
    db: zqlite.Conn,

    pub const Message = struct {
        sequence: u63,
        focus_id: []const u8,
        text: []const u8,
        published_at_unix_ms: i64,
    };

    pub const Page = struct {
        channel_id: []const u8,
        description: []const u8,
        closed: bool,
        messages: []const Message,
        next_after: u63,
        has_more: bool,
    };

    pub fn open(a: Allocator, path: []const u8) !Reader {
        return .{ .db = try database.open(a, path, .read_only) };
    }

    pub fn close(self: *Reader) void {
        self.db.close();
        self.* = undefined;
    }

    /// Read a page after an exclusive sequence. The caller supplies a positive
    /// limit. The page's data belongs to a.
    pub fn read(self: *Reader, a: Allocator, channel_id: []const u8, after: u63, limit: u32) !Page {
        // The join reads feed metadata and messages in one snapshot. A known feed with
        // no matching messages still has one row with a NULL message sequence.
        const s = try database.statement(self.db,
            \\SELECT feeds.description,feeds.closed,feed_messages.sequence,
            \\       feed_messages.focus_id,feed_messages.text,feed_messages.published_at_unix_ms
            \\FROM feeds LEFT JOIN feed_messages ON feed_messages.channel=feeds.id AND feed_messages.sequence>?
            \\WHERE feeds.reference=? ORDER BY feed_messages.sequence LIMIT ?
        , .{ @as(i64, after), channel_id, @as(i64, limit) + 1 });
        defer s.deinit();
        if (!try database.checked(s.step())) return error.UnknownChannel;
        const description = try database.copyText(a, s, 0);
        errdefer a.free(description);
        const closed = s.int(1) != 0;

        var messages: std.ArrayList(Message) = .empty;
        errdefer {
            for (messages.items) |message| {
                a.free(message.focus_id);
                a.free(message.text);
            }
            messages.deinit(a);
        }
        var next_after = after;
        var has_row = s.columnType(2) != .null;
        while (has_row and messages.items.len < limit) : (has_row = try database.checked(s.step())) {
            try messages.ensureUnusedCapacity(a, 1);
            const focus_id = try database.copyText(a, s, 3);
            errdefer a.free(focus_id);
            const message = try database.copyText(a, s, 4);
            next_after = @intCast(s.int(2));
            messages.appendAssumeCapacity(.{
                .sequence = next_after,
                .focus_id = focus_id,
                .text = message,
                .published_at_unix_ms = s.int(5),
            });
        }
        const id = try a.dupe(u8, channel_id);
        errdefer a.free(id);
        return .{
            .channel_id = id,
            .description = description,
            .closed = closed,
            .messages = try messages.toOwnedSlice(a),
            .next_after = next_after,
            .has_more = has_row,
        };
    }
};

test "feed readers resume across sequence gaps and can catch up after closure" {
    const feeds = @import("feeds.zig");
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(t.io, ".", a);
    const database_path = try std.fs.path.join(a, &.{ directory, database.filename });
    try database.initialize(a, database_path);
    var reader = try Reader.open(a, database_path);
    defer reader.close();

    const channel_id = live: {
        var writer = try feeds.Store.open(a, t.io, database_path, 2);
        defer writer.close();
        const primary = try writer.create(a, "releases", "Release notes\n更新记录");
        const other = try writer.create(a, "progress", "Progress reports");

        const empty = try reader.read(a, primary, 0, 1);
        try t.expect(!empty.closed and !empty.has_more);
        try t.expectEqual(0, empty.next_after);
        try t.expectEqual(0, empty.messages.len);
        try t.expectError(error.UnknownChannel, reader.read(a, "ivenna:/feed/missing-9", 0, 1));

        try t.expectEqual(1, try writer.publish(primary, "activity-1", "First line\n第二行", 100));
        try t.expectEqual(2, try writer.publish(other, "core-1", "Other feed", 101));
        try t.expectEqual(3, try writer.publish(primary, "core-1", "Latest version", 102));
        try t.expect(try writer.closeChannel(primary));
        break :live primary;
    };

    const first = try reader.read(a, channel_id, 0, 1);
    try t.expect(first.closed and first.has_more);
    try t.expectEqual(1, first.next_after);
    try t.expectEqual(1, first.messages.len);
    try t.expectEqual(1, first.messages[0].sequence);
    try t.expectEqualStrings("First line\n第二行", first.messages[0].text);
    try t.expectEqualStrings("activity-1", first.messages[0].focus_id);
    try t.expectEqual(100, first.messages[0].published_at_unix_ms);

    const second = try reader.read(a, channel_id, first.next_after, 1);
    try t.expect(second.closed and !second.has_more);
    try t.expectEqual(3, second.next_after);
    try t.expectEqual(1, second.messages.len);
    try t.expectEqual(3, second.messages[0].sequence);

    const caught_up = try reader.read(a, channel_id, second.next_after, 1);
    try t.expect(caught_up.closed and !caught_up.has_more);
    try t.expectEqualStrings("Release notes\n更新记录", caught_up.description);
    try t.expectEqual(second.next_after, caught_up.next_after);
    try t.expectEqual(0, caught_up.messages.len);
}
