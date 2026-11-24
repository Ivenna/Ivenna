const std = @import("std");
const database = @import("database.zig");
const zqlite = @import("sqlite").zqlite;
const Allocator = std.mem.Allocator;
const Reference = @import("agent_contracts").Reference;

pub const Reader = @import("feed_reader.zig").Reader;
pub const max_description_characters = 256;

pub const Feed = struct {
    feed_id: []const u8,
    description: []const u8,
};

/// One writer connection per Store. Core and activity workers can share it.
/// Readers open separate connections to the same catalog.
pub const Store = struct {
    io: std.Io,
    db: zqlite.Conn,
    max_open: usize,
    mutex: std.Io.Mutex = .init,

    pub fn open(a: Allocator, io: std.Io, path: []const u8, max_open: usize) !Store {
        return .{ .io = io, .db = try database.open(a, path, .read_write), .max_open = max_open };
    }

    pub fn openInMemory(a: Allocator, io: std.Io, max_open: usize) !Store {
        return .{ .io = io, .db = try database.open(a, ":memory:", .initialize), .max_open = max_open };
    }

    /// Join workers before releasing the connection.
    pub fn close(self: *Store) void {
        self.db.close();
        self.* = undefined;
    }

    /// The parsed tool request supplies UTF-8. The feed ID belongs to a and
    /// is returned once it is durable.
    pub fn create(self: *Store, a: Allocator, name: []const u8, description: []const u8) ![]const u8 {
        if (!Reference.validName(name) or !validDescription(description)) return error.InvalidArguments;
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try database.exec(self.db, "BEGIN IMMEDIATE");
        errdefer database.rollback(self.db);
        const open_count = try database.integer(self.db, "SELECT count(*) FROM feeds WHERE closed=0", .{});
        if (try database.unsigned(open_count) >= self.max_open) return error.OpenFeedCapacity;
        const s = try database.statement(self.db, "INSERT INTO feeds(name,description) VALUES(?,?) RETURNING reference", .{ name, description });
        defer s.deinit();
        if (!try database.checked(s.step())) return error.InvalidStateDatabase;
        const feed_id = try database.copyText(a, s, 0);
        errdefer a.free(feed_id);
        try database.checked(s.stepToCompletion());
        try database.exec(self.db, "COMMIT");
        return feed_id;
    }

    /// Snapshot all writable feeds in creation order. Results belong to a.
    pub fn openFeeds(self: *Store, a: Allocator) ![]const Feed {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const s = try database.statement(self.db, "SELECT reference,description FROM feeds WHERE closed=0 ORDER BY id", .{});
        defer s.deinit();
        var feeds: std.ArrayList(Feed) = .empty;
        errdefer {
            for (feeds.items) |feed| {
                a.free(feed.feed_id);
                a.free(feed.description);
            }
            feeds.deinit(a);
        }
        while (try database.checked(s.step())) {
            try feeds.ensureUnusedCapacity(a, 1);
            const feed_id = try database.copyText(a, s, 0);
            errdefer a.free(feed_id);
            const description = try database.copyText(a, s, 1);
            feeds.appendAssumeCapacity(.{ .feed_id = feed_id, .description = description });
        }
        return feeds.toOwnedSlice(a);
    }

    /// Close a known feed. Messages already published remain available.
    pub fn closeFeed(self: *Store, feed_id: []const u8) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try database.exec(self.db, "BEGIN IMMEDIATE");
        errdefer database.rollback(self.db);
        const s = try database.statement(self.db, "UPDATE feeds SET closed=1 WHERE reference=? AND closed=0", .{feed_id});
        defer s.deinit();
        try database.checked(s.stepToCompletion());
        const changed = self.db.changes() != 0;
        if (!changed) try self.requireFeed(feed_id);
        try database.exec(self.db, "COMMIT");
        return changed;
    }

    /// Store one message while the exact feed is open and return its sequence.
    /// The parsed send supplies nonempty UTF-8.
    pub fn publish(self: *Store, feed_id: []const u8, focus_id: []const u8, text: []const u8, published_at_unix_ms: i64) !u64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try database.exec(self.db, "BEGIN IMMEDIATE");
        errdefer database.rollback(self.db);
        const s = try database.statement(self.db,
            \\INSERT INTO feed_messages(feed_id,focus_id,text,published_at_unix_ms)
            \\SELECT id,?,?,? FROM feeds WHERE reference=? AND closed=0
            \\RETURNING sequence
        , .{ focus_id, text, published_at_unix_ms, feed_id });
        defer s.deinit();
        if (!try database.checked(s.step())) {
            try self.requireFeed(feed_id);
            return error.FeedClosed;
        }
        const sequence = try database.unsigned(s.int(0));
        try database.checked(s.stepToCompletion());
        try database.exec(self.db, "COMMIT");
        return sequence;
    }

    fn requireFeed(self: *Store, feed_id: []const u8) !void {
        if (try database.integer(self.db, "SELECT EXISTS(SELECT 1 FROM feeds WHERE reference=?)", .{feed_id}) == 0)
            return error.UnknownFeed;
    }
};

fn validDescription(description: []const u8) bool {
    var codepoints = std.unicode.Utf8View.initUnchecked(description).iterator();
    var count: usize = 0;
    var nonblank = false;
    while (codepoints.nextCodepoint()) |point| {
        count += 1;
        if (count > max_description_characters) return false;
        switch (point) {
            // Unicode White_Space.
            0x9...0xd, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => {},
            else => nonblank = true,
        }
    }
    return nonblank;
}

test "feed descriptions, references and message sequences persist across reopening" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, database.filename });
    try database.initialize(a, path);
    const name = "发布 notes/\"笔记\"%";
    const description = "Release notes\n更新记录\x00more";
    const expected = name ++ "-1";

    {
        var store = try Store.open(a, t.io, path, 2);
        defer store.close();
        const feed_id = try store.create(a, name, description);
        try t.expectEqualStrings(expected, feed_id);
        try t.expectError(error.UnknownFeed, store.publish("other-1", "core", "hello", 100));
        try t.expectEqual(1, try store.publish(feed_id, "activity-1", "first line\n第二行", 100));
        try t.expect(try store.closeFeed(feed_id));
        try t.expectError(error.UnknownFeed, store.closeFeed("missing"));
    }

    var store = try Store.open(a, t.io, path, 2);
    defer store.close();
    try t.expectEqual(0, (try store.openFeeds(a)).len);
    try t.expect(!try store.closeFeed(expected));
    try t.expectError(error.FeedClosed, store.publish(expected, "core", "closed after restart", 101));
    const renewed = try store.create(a, name, description);
    try t.expectEqualStrings(name ++ "-2", renewed);
    try t.expectEqual(2, try store.publish(renewed, "core", "second", 102));
}

test "feed descriptions require nonblank text within the code point limit" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store = try Store.openInMemory(a, t.io, 1);
    defer store.close();
    const character = "文";
    var characters: [max_description_characters + 1][character.len]u8 = undefined;
    @memset(&characters, character[0..character.len].*);
    const overlong = std.mem.asBytes(&characters);
    for ([_][]const u8{ " \t\n　", overlong }) |invalid| {
        try t.expectError(error.InvalidArguments, store.create(a, "release", invalid));
    }
    const description = overlong[0 .. max_description_characters * character.len];
    const feed_id = try store.create(a, "release", description);
    try t.expectEqualStrings("release-1", feed_id);
    try t.expectEqualStrings(description, (try store.openFeeds(a))[0].description);
}

test "a lowered capacity preserves all existing open feeds and blocks creation until space is available" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, database.filename });
    try database.initialize(a, path);
    const description = "Release history";

    {
        var store = try Store.open(a, t.io, path, 3);
        defer store.close();
        for (0..3) |_| _ = try store.create(a, "release", description);
        try t.expectError(error.OpenFeedCapacity, store.create(a, "release", description));
    }

    var store = try Store.open(a, t.io, path, 2);
    defer store.close();
    const open = try store.openFeeds(a);
    try t.expectEqual(3, open.len);
    try t.expectEqualStrings("release-1", open[0].feed_id);
    try t.expectEqualStrings("release-3", open[2].feed_id);
    try t.expectEqualStrings(description, open[2].description);
    try t.expectEqual(1, try store.publish(open[2].feed_id, "core", "work", 100));
    try t.expect(try store.closeFeed(open[2].feed_id));
    try t.expectError(error.OpenFeedCapacity, store.create(a, "release", description));
    try t.expect(try store.closeFeed(open[1].feed_id));
    const feed_id = try store.create(a, "release", description);
    try t.expectEqualStrings("release-4", feed_id);
    const remaining = try store.openFeeds(a);
    try t.expectEqual(2, remaining.len);
    try t.expectEqualStrings(open[0].feed_id, remaining[0].feed_id);
    try t.expectEqualStrings(feed_id, remaining[1].feed_id);
}

test "a concurrent publication and closure preserve the outcome of the write" {
    const t = std.testing;
    const io = t.io;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store = try Store.openInMemory(a, io, 1);
    defer store.close();
    const id = try store.create(a, "progress", "Current progress");
    var publishing = try io.concurrent(Store.publish, .{ &store, id, "activity-1", "work", 100 });
    defer _ = publishing.cancel(io) catch {};
    try t.expect(try store.closeFeed(id));
    const accepted: i64 = if (publishing.await(io)) |sequence| accepted: {
        try t.expectEqual(1, sequence);
        break :accepted 1;
    } else |err| rejected: {
        try t.expectEqual(error.FeedClosed, err);
        break :rejected 0;
    };
    try t.expectEqual(accepted, try database.integer(store.db, "SELECT count(*) FROM feed_messages", .{}));
}
