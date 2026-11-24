const std = @import("std");
const database = @import("database.zig");
const zqlite = @import("sqlite").zqlite;
const Allocator = std.mem.Allocator;
const contracts = @import("agent_contracts");
const ChannelAddress = contracts.ChannelAddress;
const Reference = contracts.Reference;

pub const Reader = @import("feed_reader.zig").Reader;
pub const max_description_characters = 256;

pub const Feed = struct {
    channel_id: []const u8,
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

    /// The parsed tool request supplies UTF-8. The address belongs to a and
    /// is returned once it is durable.
    pub fn create(self: *Store, a: Allocator, name: []const u8, description: []const u8) ![]const u8 {
        if (!Reference.validName(name) or !validDescription(description)) return error.InvalidArguments;
        const stem = try ChannelAddress.format(a, .feed, name);
        defer a.free(stem);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try database.exec(self.db, "BEGIN IMMEDIATE");
        errdefer database.rollback(self.db);
        const open_count = try database.integer(self.db, "SELECT count(*) FROM feeds WHERE closed=0", .{});
        if (try database.unsigned(open_count) >= self.max_open) return error.OpenChannelCapacity;
        const s = try database.statement(self.db, "INSERT INTO feeds(stem,description) VALUES(?,?) RETURNING reference", .{ stem, description });
        defer s.deinit();
        if (!try database.checked(s.step())) return error.InvalidStateDatabase;
        const address = try a.dupe(u8, try database.requiredText(s, 0));
        errdefer a.free(address);
        try database.checked(s.stepToCompletion());
        try database.exec(self.db, "COMMIT");
        return address;
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
                a.free(feed.channel_id);
                a.free(feed.description);
            }
            feeds.deinit(a);
        }
        while (try database.checked(s.step())) {
            try feeds.ensureUnusedCapacity(a, 1);
            const channel_id = try a.dupe(u8, try database.requiredText(s, 0));
            errdefer a.free(channel_id);
            const description = try a.dupe(u8, try database.requiredText(s, 1));
            feeds.appendAssumeCapacity(.{ .channel_id = channel_id, .description = description });
        }
        return feeds.toOwnedSlice(a);
    }

    /// Close a known channel. Rows already published remain available.
    pub fn closeChannel(self: *Store, address: []const u8) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try database.exec(self.db, "BEGIN IMMEDIATE");
        errdefer database.rollback(self.db);
        const s = try database.statement(self.db, "UPDATE feeds SET closed=1 WHERE reference=? AND closed=0", .{address});
        defer s.deinit();
        try database.checked(s.stepToCompletion());
        const changed = self.db.changes() != 0;
        if (!changed) try self.requireChannel(address);
        try database.exec(self.db, "COMMIT");
        return changed;
    }

    /// Store one message while the exact channel is open and return its sequence.
    /// The parsed send supplies nonempty UTF-8.
    pub fn publish(self: *Store, address: []const u8, focus_id: []const u8, text: []const u8, published_at_unix_ms: i64) !u64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try database.exec(self.db, "BEGIN IMMEDIATE");
        errdefer database.rollback(self.db);
        const s = try database.statement(self.db,
            \\INSERT INTO feed_messages(channel,focus_id,text,published_at_unix_ms)
            \\SELECT id,?,?,? FROM feeds WHERE reference=? AND closed=0
            \\RETURNING sequence
        , .{ focus_id, text, published_at_unix_ms, address });
        defer s.deinit();
        if (!try database.checked(s.step())) {
            try self.requireChannel(address);
            return error.ChannelClosed;
        }
        const sequence = try database.unsigned(s.int(0));
        try database.checked(s.stepToCompletion());
        try database.exec(self.db, "COMMIT");
        return sequence;
    }

    fn requireChannel(self: *Store, address: []const u8) !void {
        if (try database.integer(self.db, "SELECT EXISTS(SELECT 1 FROM feeds WHERE reference=?)", .{address}) == 0)
            return error.UnknownChannel;
    }
};

fn validDescription(description: []const u8) bool {
    if (description.len > max_description_characters * 4) return false;
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
    const name = "发布-\"笔记\"";
    const description = "Release notes\n更新记录\x00more";
    const expected: []const u8 = "ivenna:/feed/%E5%8F%91%E5%B8%83-%22%E7%AC%94%E8%AE%B0%22-1";

    {
        var store = try Store.open(a, t.io, path, 2);
        defer store.close();
        const address = try store.create(a, name, description);
        try t.expectEqualStrings(expected, address);
        const open = try store.openFeeds(a);
        try t.expectEqual(1, open.len);
        try t.expectEqualStrings(expected, open[0].channel_id);
        try t.expectEqualStrings(description, open[0].description);
        try t.expectError(error.UnknownChannel, store.publish("ivenna:/feed/other-1", "core", "hello", 100));
        try t.expectEqual(1, try store.publish(address, "activity-1", "first line\n第二行", 100));
        try t.expect(try store.closeChannel(address));
        try t.expect(!try store.closeChannel(address));
        try t.expectError(error.UnknownChannel, store.closeChannel("ivenna:/feed/other-1"));
        try t.expectError(error.ChannelClosed, store.publish(address, "core", "closed", 101));
    }

    var store = try Store.open(a, t.io, path, 2);
    defer store.close();
    try t.expectEqual(0, (try store.openFeeds(a)).len);
    try t.expectError(error.ChannelClosed, store.publish(expected, "core", "closed after restart", 101));
    const renewed = try store.create(a, name, description);
    try t.expectEqualStrings("ivenna:/feed/%E5%8F%91%E5%B8%83-%22%E7%AC%94%E8%AE%B0%22-2", renewed);
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
    const address = try store.create(a, "release", description);
    try t.expectEqualStrings("ivenna:/feed/release-1", address);
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
        try t.expectError(error.OpenChannelCapacity, store.create(a, "release", description));
    }

    var store = try Store.open(a, t.io, path, 2);
    defer store.close();
    const open = try store.openFeeds(a);
    try t.expectEqual(3, open.len);
    try t.expectEqualStrings("ivenna:/feed/release-1", open[0].channel_id);
    try t.expectEqualStrings("ivenna:/feed/release-3", open[2].channel_id);
    try t.expectEqualStrings(description, open[2].description);
    try t.expectEqual(1, try store.publish(open[2].channel_id, "core", "work", 100));
    try t.expect(try store.closeChannel(open[2].channel_id));
    try t.expectError(error.OpenChannelCapacity, store.create(a, "release", description));
    try t.expect(try store.closeChannel(open[1].channel_id));
    const address = try store.create(a, "release", description);
    try t.expectEqualStrings("ivenna:/feed/release-4", address);
    const remaining = try store.openFeeds(a);
    try t.expectEqual(2, remaining.len);
    try t.expectEqualStrings(open[0].channel_id, remaining[0].channel_id);
    try t.expectEqualStrings(address, remaining[1].channel_id);
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
    try t.expect(try store.closeChannel(id));
    const accepted: i64 = if (publishing.await(io)) |sequence| accepted: {
        try t.expectEqual(1, sequence);
        break :accepted 1;
    } else |err| rejected: {
        try t.expectEqual(error.ChannelClosed, err);
        break :rejected 0;
    };
    try t.expectEqual(accepted, try database.integer(store.db, "SELECT count(*) FROM feed_messages", .{}));
}
