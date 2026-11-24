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
        feed_id: []const u8,
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

    /// Cap how long a read waits for a writer. Zero reports contention at once.
    pub fn setBusyTimeout(self: *Reader, milliseconds: u32) !void {
        try database.checked(self.db.busyTimeout(@intCast(milliseconds)));
    }

    /// Read a page after an exclusive sequence. The caller supplies a positive
    /// limit. The page's data belongs to a.
    pub fn read(self: *Reader, a: Allocator, feed_id: []const u8, after: u63, limit: u32) !Page {
        // The join reads feed metadata and messages in one snapshot. A known feed with
        // no matching messages still has one row with a NULL message sequence.
        const s = try database.statement(self.db,
            \\SELECT feeds.description,feeds.closed,feed_messages.sequence,
            \\       feed_messages.focus_id,feed_messages.text,feed_messages.published_at_unix_ms
            \\FROM feeds LEFT JOIN feed_messages ON feed_messages.feed_id=feeds.id AND feed_messages.sequence>?
            \\WHERE feeds.reference=? ORDER BY feed_messages.sequence LIMIT ?
        , .{ @as(i64, after), feed_id, @as(i64, limit) + 1 });
        defer s.deinit();
        if (!try database.checked(s.step())) return error.UnknownFeed;
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
        const id = try a.dupe(u8, feed_id);
        errdefer a.free(id);
        return .{
            .feed_id = id,
            .description = description,
            .closed = closed,
            .messages = try messages.toOwnedSlice(a),
            .next_after = next_after,
            .has_more = has_row,
        };
    }
};
