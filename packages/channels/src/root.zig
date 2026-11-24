const std = @import("std");
const sqlite = @import("sqlite");
const zqlite = sqlite.zqlite;
const c = zqlite.c;
const Allocator = std.mem.Allocator;
const contracts = @import("agent_contracts");
const ChannelAddress = contracts.ChannelAddress;
const Reference = contracts.Reference;

pub const filename = "channels.sqlite3";
pub const max_description_characters = 256;
const catalog_format = std.mem.readInt(u32, "IVC3", .big);

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
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArguments;
        const path_z = try a.dupeSentinel(u8, path, 0);
        defer a.free(path_z);
        var self: Store = .{
            .io = io,
            .db = try checked(sqlite.open(path_z, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE)),
            .max_open = max_open,
        };
        errdefer self.close();
        try checked(self.db.busyTimeout(5000));
        try self.exec("PRAGMA foreign_keys=ON");
        try self.exec("PRAGMA synchronous=FULL");
        // Claim an empty file with the schema and format marker together.
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.rollback();
        const format = try self.scalar("PRAGMA application_id", .{});
        if (format != catalog_format) {
            if (format != 0 or try self.scalar("SELECT EXISTS(SELECT 1 FROM sqlite_schema)", .{}) != 0)
                return error.IncompatibleChannelSchema;
            try self.exec(@embedFile("schema.sql"));
            try self.exec(std.fmt.comptimePrint("PRAGMA application_id={d}", .{catalog_format}));
        }
        try self.exec("COMMIT");
        try self.exec("PRAGMA journal_mode=WAL");
        return self;
    }

    /// Join workers before releasing the connection.
    pub fn close(self: *Store) void {
        self.db.close();
        self.* = undefined;
    }

    /// The address belongs to a and is returned only once it is durable.
    pub fn create(self: *Store, a: Allocator, name: []const u8, description: []const u8) ![]const u8 {
        if (!Reference.validName(name) or !validDescription(description)) return error.InvalidArguments;
        const stem = try ChannelAddress.format(a, .feed, name);
        defer a.free(stem);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.rollback();
        const open_count = try self.scalar("SELECT count(*) FROM channels WHERE closed=0", .{}) orelse return error.InvalidChannelDatabase;
        if (@as(u64, @intCast(open_count)) >= self.max_open) return error.OpenChannelCapacity;
        const s = try self.statement("INSERT INTO channels(stem,description) VALUES(?,?) RETURNING reference", .{ stem, description });
        defer s.deinit();
        if (!try checked(s.step())) return error.InvalidChannelDatabase;
        const address = try a.dupe(u8, try requiredText(s, 0));
        errdefer a.free(address);
        try checked(s.stepToCompletion());
        try self.exec("COMMIT");
        return address;
    }

    /// Snapshot all writable feeds in creation order. Results belong to a.
    pub fn openFeeds(self: *Store, a: Allocator) ![]const Feed {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const s = try self.statement("SELECT reference,description FROM channels WHERE closed=0 ORDER BY id", .{});
        defer s.deinit();
        var feeds: std.ArrayList(Feed) = .empty;
        errdefer {
            for (feeds.items) |feed| {
                a.free(feed.channel_id);
                a.free(feed.description);
            }
            feeds.deinit(a);
        }
        while (try checked(s.step())) {
            try feeds.ensureUnusedCapacity(a, 1);
            const channel_id = try a.dupe(u8, try requiredText(s, 0));
            errdefer a.free(channel_id);
            const description = try a.dupe(u8, try requiredText(s, 1));
            feeds.appendAssumeCapacity(.{ .channel_id = channel_id, .description = description });
        }
        return feeds.toOwnedSlice(a);
    }

    /// Close a known channel. Rows already published remain available.
    pub fn closeChannel(self: *Store, address: []const u8) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.rollback();
        const s = try self.statement("UPDATE channels SET closed=1 WHERE reference=? AND closed=0", .{address});
        defer s.deinit();
        try checked(s.stepToCompletion());
        const changed = self.db.changes() != 0;
        if (!changed) try self.requireChannel(address);
        try self.exec("COMMIT");
        return changed;
    }

    /// Store one message while the exact channel is open and return its sequence.
    /// The parsed send supplies nonempty UTF-8. Feed readers require text without NUL bytes.
    pub fn publish(self: *Store, address: []const u8, focus_id: []const u8, text: []const u8, published_at_unix_ms: i64) !u64 {
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidArguments;
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.rollback();
        const s = try self.statement(
            \\INSERT INTO messages(channel,focus_id,text,published_at_unix_ms)
            \\SELECT id,?,?,? FROM channels WHERE reference=? AND closed=0
            \\RETURNING sequence
        , .{ focus_id, text, published_at_unix_ms, address });
        defer s.deinit();
        if (!try checked(s.step())) {
            try self.requireChannel(address);
            return error.ChannelClosed;
        }
        const sequence: u64 = @intCast(s.int(0));
        try checked(s.stepToCompletion());
        try self.exec("COMMIT");
        return sequence;
    }

    fn requireChannel(self: *Store, address: []const u8) !void {
        _ = try self.scalar("SELECT id FROM channels WHERE reference=?", .{address}) orelse return error.UnknownChannel;
    }

    fn exec(self: *Store, query: [:0]const u8) !void {
        try checked(self.db.execNoArgs(query.ptr));
    }

    fn rollback(self: *Store) void {
        if (c.sqlite3_get_autocommit(self.db.conn) != 0) return;
        self.exec("ROLLBACK") catch |err| std.log.err("feed storage rollback failed: {s}", .{@errorName(err)});
    }

    fn statement(self: *Store, query: [:0]const u8, args: anytype) !zqlite.Stmt {
        // zqlite binds text with SQLite's 32-bit length parameter.
        inline for (args) |arg| {
            if (@TypeOf(arg) == []const u8 and arg.len > std.math.maxInt(c_int)) return error.InvalidArguments;
        }
        const s = try checked(self.db.prepare(query));
        errdefer s.deinit();
        try checked(s.bind(args));
        return s;
    }

    fn scalar(self: *Store, query: [:0]const u8, args: anytype) !?i64 {
        const s = try self.statement(query, args);
        defer s.deinit();
        return if (try checked(s.step())) s.int(0) else null;
    }
};

fn validDescription(description: []const u8) bool {
    if (description.len > max_description_characters * 4) return false;
    var codepoints = (std.unicode.Utf8View.init(description) catch return false).iterator();
    var count: usize = 0;
    var nonblank = false;
    while (codepoints.nextCodepoint()) |point| {
        count += 1;
        if (count > max_description_characters) return false;
        switch (point) {
            0 => return false,
            // Unicode White_Space.
            0x9...0xd, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => {},
            else => nonblank = true,
        }
    }
    return nonblank;
}

fn requiredText(s: zqlite.Stmt, i: usize) ![]const u8 {
    return sqlite.text(s, i) catch |err| switch (err) {
        error.NullColumn => error.InvalidChannelDatabase,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn checked(result: anytype) !@typeInfo(@TypeOf(result)).error_union.payload {
    return result catch |err| switch (err) {
        error.Busy, error.Locked => error.ChannelStoreBusy,
        error.Full => error.ChannelStoreFull,
        error.NoMem => error.OutOfMemory,
        error.TooBig => error.InvalidArguments,
        else => {
            std.log.err("feed storage operation failed: {s}", .{@errorName(err)});
            return error.ChannelStorageFailed;
        },
    };
}

test "feed descriptions, messages and closure persist and are visible to independent readers" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, filename });
    const path_z = try a.dupeSentinel(u8, path, 0);
    const name = "发布-\"笔记\"";
    const description = "Release notes\n更新记录";
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
        const reader = try sqlite.open(path_z, c.SQLITE_OPEN_READONLY);
        defer reader.close();
        try t.expectError(error.UnknownChannel, store.publish("ivenna:/feed/other-1", "core", "hello", 100));
        try t.expectError(error.InvalidArguments, store.publish(address, "core", "part\x00part", 100));
        try t.expectEqual(1, try store.publish(address, "activity-1", "first line\n第二行", 100));
        try t.expect(try store.closeChannel(address));
        try t.expect(!try store.closeChannel(address));
        try t.expectError(error.UnknownChannel, store.closeChannel("ivenna:/feed/other-1"));
        try t.expectError(error.ChannelClosed, store.publish(address, "core", "closed", 101));
        const row = (try reader.row(
            "SELECT focus_id,text,published_at_unix_ms FROM feed_messages WHERE channel_id=? AND sequence>?",
            .{ address, @as(i64, 0) },
        )).?;
        defer row.deinit();
        try t.expectEqualStrings("activity-1", row.text(0));
        try t.expectEqualStrings("first line\n第二行", row.text(1));
        try t.expectEqual(100, row.int(2));
    }

    var store = try Store.open(a, t.io, path, 2);
    defer store.close();
    try t.expectEqual(0, (try store.openFeeds(a)).len);
    {
        const record = (try store.db.row("SELECT description,closed FROM feeds WHERE channel_id=?", .{expected})).?;
        defer record.deinit();
        try t.expectEqualStrings(description, record.text(0));
        try t.expectEqual(1, record.int(1));
    }
    try t.expectEqual(1, try store.scalar("SELECT count(*) FROM feed_messages", .{}));
    const renewed = try store.create(a, name, description);
    try t.expectEqualStrings("ivenna:/feed/%E5%8F%91%E5%B8%83-%22%E7%AC%94%E8%AE%B0%22-2", renewed);
    try t.expectEqual(2, try store.publish(renewed, "core", "second", 102));
}

test "feed descriptions require nonblank UTF-8 text within the code point limit" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store = try Store.open(a, t.io, ":memory:", 1);
    defer store.close();
    const character = "文";
    var characters: [max_description_characters + 1][character.len]u8 = undefined;
    @memset(&characters, character[0..character.len].*);
    const overlong = std.mem.asBytes(&characters);
    for ([_][]const u8{ "", " \t\n　", "\xff", "NUL\x00inside", overlong }) |invalid| {
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
    const path = try std.fs.path.join(a, &.{ dir, filename });
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
    var store = try Store.open(a, io, ":memory:", 1);
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
    try t.expectEqual(accepted, try store.scalar("SELECT count(*) FROM feed_messages", .{}));
}
