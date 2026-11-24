const std = @import("std");
const database = @import("database.zig");
const zqlite = @import("sqlite").zqlite;
const Allocator = std.mem.Allocator;
const Reference = @import("agent_contracts").Reference;

pub const Reader = @import("feed_reader.zig").Reader;

pub const OpenFeed = struct {
    feed_id: []const u8,
    creator_focus_id: []const u8,
};

/// One writer connection per Store. Core and activity workers can share it.
/// Readers open separate connections to the same database.
pub const Store = struct {
    io: std.Io,
    db: zqlite.Conn,
    mutex: std.Io.Mutex = .init,

    pub fn open(a: Allocator, io: std.Io, path: []const u8) !Store {
        return .{ .io = io, .db = try database.open(a, path, .read_write) };
    }

    pub fn openInMemory(a: Allocator, io: std.Io) !Store {
        return .{ .io = io, .db = try database.open(a, ":memory:", .initialize) };
    }

    /// Join workers before releasing the connection.
    pub fn close(self: *Store) void {
        self.db.close();
        self.* = undefined;
    }

    /// The runtime supplies the creator's identity and a UTF-8 description.
    /// The feed ID belongs to a and is returned once it is durable.
    pub fn create(self: *Store, a: Allocator, creator_focus_id: []const u8, name: []const u8, description: []const u8) ![]const u8 {
        if (!Reference.validName(name) or description.len == 0) return error.InvalidArguments;
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try database.exec(self.db, "BEGIN IMMEDIATE");
        errdefer database.rollback(self.db);
        const s = try database.statement(self.db, "INSERT INTO feeds(creator_focus_id,name,description) VALUES(?,?,?) RETURNING reference", .{ creator_focus_id, name, description });
        defer s.deinit();
        if (!try database.checked(s.step())) return error.InvalidStateDatabase;
        const feed_id = try database.copyText(a, s, 0);
        errdefer a.free(feed_id);
        try database.checked(s.stepToCompletion());
        try database.exec(self.db, "COMMIT");
        return feed_id;
    }

    /// Copy open feed IDs with their creators in creation order. A creator
    /// restricts the sample to feeds it created. Null includes every open feed.
    pub fn openFeeds(self: *Store, a: Allocator, creator_focus_id: ?[]const u8) ![]const OpenFeed {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const s = try database.statement(
            self.db,
            "SELECT reference, creator_focus_id FROM feeds WHERE closed=0 AND (?1 IS NULL OR creator_focus_id=?1) ORDER BY id",
            .{creator_focus_id},
        );
        defer s.deinit();
        var feeds: std.ArrayList(OpenFeed) = .empty;
        errdefer {
            for (feeds.items) |feed| {
                a.free(feed.feed_id);
                a.free(feed.creator_focus_id);
            }
            feeds.deinit(a);
        }
        while (try database.checked(s.step())) {
            try feeds.ensureUnusedCapacity(a, 1);
            const feed_id = try database.copyText(a, s, 0);
            errdefer a.free(feed_id);
            feeds.appendAssumeCapacity(.{
                .feed_id = feed_id,
                .creator_focus_id = try database.copyText(a, s, 1),
            });
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

test "feed closure and sequences survive reopening" {
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
    const description = "Release notes";
    const expected = name ++ "-1";

    {
        var store = try Store.open(a, t.io, path);
        defer store.close();
        const feed_id = try store.create(a, "core-1", name, description);
        try t.expectEqualStrings(expected, feed_id);
        try t.expectError(error.UnknownFeed, store.publish("other-1", "core", "hello", 100));
        try t.expectEqual(1, try store.publish(feed_id, "activity-1", "First update", 100));
        try t.expect(try store.closeFeed(feed_id));
        try t.expectError(error.UnknownFeed, store.closeFeed("missing"));
    }

    var store = try Store.open(a, t.io, path);
    defer store.close();
    try t.expect(!try store.closeFeed(expected));
    try t.expectError(error.FeedClosed, store.publish(expected, "core", "closed after restart", 101));
    const renewed = try store.create(a, "activity-2", name, description);
    try t.expectEqualStrings(name ++ "-2", renewed);
    try t.expectEqual(2, try store.publish(renewed, "core", "second", 102));
}

test "open feed samples keep their original creators across reopening" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, database.filename });
    try database.initialize(a, path);

    const created = blk: {
        var store = try Store.open(a, t.io, path);
        defer store.close();
        const core = try store.create(a, "core-1", "core", "Core feed");
        const own = try store.create(a, "activity-2", "own", "First activity feed");
        const other = try store.create(a, "activity-21", "other", "Second activity feed");
        const closed = try store.create(a, "activity-2", "closed", "Finished feed");
        _ = try store.publish(core, "activity-2", "A shared update", 100);
        try t.expect(try store.closeFeed(closed));
        break :blk [_]OpenFeed{
            .{ .feed_id = core, .creator_focus_id = "core-1" },
            .{ .feed_id = own, .creator_focus_id = "activity-2" },
            .{ .feed_id = other, .creator_focus_id = "activity-21" },
        };
    };

    var store = try Store.open(a, t.io, path);
    defer store.close();
    try t.expectEqualDeep(@as([]const OpenFeed, &created), try store.openFeeds(a, null));
    try t.expectEqualDeep(@as([]const OpenFeed, created[1..2]), try store.openFeeds(a, "activity-2"));
    try t.expectEqualDeep(@as([]const OpenFeed, created[2..3]), try store.openFeeds(a, "activity-21"));
}
