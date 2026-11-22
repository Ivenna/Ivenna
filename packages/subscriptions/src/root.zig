const std = @import("std");
const sql = @import("db.zig");
const c = sql.c;
const Statement = sql.Statement;
const Allocator = std.mem.Allocator;
const Reference = @import("agent_contracts").Reference;

pub const Reminder = enum { immediate, next_input };
pub const Retrieval = enum { unavailable, current, version };
pub const filename = "subscriptions.sqlite3";
pub const Subscription = struct {
    subscription_id: []const u8,
    focus_id: []const u8,
    reminder: Reminder,
    listener: []const u8,
    active: bool,
    external: bool,
    status: ?[]const u8,
    progress: ?[]const u8,
    pending: u64,
};

/// The references and reminder policies a focus needs to recognize its
/// registrations. Inactive entries still have an outstanding external follow.
pub const Registration = struct {
    subscription_id: []const u8,
    focus_id: []const u8,
    reminder: Reminder,
    active: bool,

    fn read(a: Allocator, s: Statement) !Registration {
        return .{
            .subscription_id = try s.copy(a, 0),
            .focus_id = try s.copy(a, 1),
            .reminder = try s.tag(Reminder, 2),
            .active = s.number(3) != 0,
        };
    }
};

pub const Report = struct {
    sequence: u64,
    reference: []const u8,
    text: []const u8,
    handle: ?[]const u8,
    retrieval: Retrieval,
    version: ?[]const u8,
    truncated: bool,
    source_time_unix_ms: ?i64,
    observed_at_unix_ms: i64,
};

pub const NewReport = struct {
    key: []const u8,
    text: []const u8,
    progress: ?[]const u8 = null,
    expected_progress: ?[]const u8 = null,
    handle: ?[]const u8 = null,
    retrieval: Retrieval = .unavailable,
    version: ?[]const u8 = null,
    truncated: bool = false,
    source_time_unix_ms: ?i64 = null,
};
pub const PublishResult = enum { accepted, duplicate };
pub const Checkpoint = struct {
    progress: ?[]const u8 = null,
    expected_progress: ?[]const u8 = null,
    status: ?[]const u8 = null,
    external: ?bool = null,
};

/// One connection per process or serialized client. Independent connections
/// share SQLite's commit order, including producers running with the kernel down.
/// Callers supply an arena for query results and serialize calls on each Store.
pub const Store = struct {
    db: *c.sqlite3,

    pub fn open(a: Allocator, path: []const u8) !Store {
        var self = try connect(a, path, true);
        errdefer self.close();
        try self.exec("PRAGMA journal_mode=WAL");
        try self.exec(@embedFile("schema.sql"));
        return self;
    }

    /// A producer opens a provisioned store. A mistyped DATA_DIR must not
    /// create a new stream of identifiers.
    pub fn openExisting(a: Allocator, path: []const u8) !Store {
        return connect(a, path, false);
    }

    fn connect(a: Allocator, path: []const u8, initialize: bool) !Store {
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArguments;
        const path_z = try a.dupeSentinel(u8, path, 0);
        defer a.free(path_z);
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path_z.ptr, &db, c.SQLITE_OPEN_READWRITE | @as(c_int, if (initialize) c.SQLITE_OPEN_CREATE else 0), null);
        errdefer if (db) |ptr| {
            _ = c.sqlite3_close(ptr);
        };
        try sql.check(rc);
        var self = Store{ .db = db.? };
        try sql.check(c.sqlite3_busy_timeout(self.db, 5000));
        try self.exec("PRAGMA foreign_keys=ON");
        try self.exec("PRAGMA synchronous=FULL");
        return self;
    }

    pub fn close(self: *Store) void {
        std.debug.assert(c.sqlite3_close(self.db) == c.SQLITE_OK);
        self.* = undefined;
    }

    fn exec(self: *Store, query: [:0]const u8) !void {
        try sql.check(c.sqlite3_exec(self.db, query.ptr, null, null, null));
    }

    fn rollback(self: *Store) void {
        if (c.sqlite3_get_autocommit(self.db) != 0) return;
        self.exec("ROLLBACK") catch |err| std.log.err("subscription rollback failed: {s}", .{@errorName(err)});
    }

    fn statement(self: *Store, query: [:0]const u8, args: anytype) !Statement {
        const s = try Statement.init(self.db, query);
        errdefer s.deinit();
        try s.bind(args);
        return s;
    }

    fn change(self: *Store, query: [:0]const u8, args: anytype) !bool {
        const s = try self.statement(query, args);
        defer s.deinit();
        if (try s.next()) return error.InvalidSubscriptionDatabase;
        return c.sqlite3_changes(self.db) != 0;
    }

    fn integer(self: *Store, query: [:0]const u8, args: anytype) !u64 {
        const s = try self.statement(query, args);
        defer s.deinit();
        if (!try s.next()) return error.InvalidSubscriptionDatabase;
        return s.unsigned(0);
    }

    pub fn identity(self: *Store) ![32]u8 {
        const s = try self.statement("SELECT identity FROM metadata WHERE singleton=1", .{});
        defer s.deinit();
        if (!try s.next()) return error.InvalidSubscriptionDatabase;
        const id = try s.text(0);
        if (id.len != 32) return error.InvalidSubscriptionDatabase;
        return id[0..32].*;
    }

    pub fn isBound(self: *Store) !bool {
        return try self.integer("SELECT bound FROM metadata WHERE singleton=1", .{}) != 0;
    }

    pub fn markBound(self: *Store) !void {
        _ = try self.change("UPDATE metadata SET bound=1 WHERE singleton=1", .{});
    }

    pub fn create(self: *Store, a: Allocator, owner: u64, focus_id: []const u8, name: []const u8, reminder: Reminder, listener: []const u8) !Registration {
        if (!Reference.validName(name) or !validText(listener, null)) return error.InvalidArguments;
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.rollback();
        const s = try self.statement(
            \\INSERT INTO subscriptions(name,session_id,focus_id,reminder,listener) VALUES(?,?,?,?,?)
            \\RETURNING reference,focus_id,reminder,active
        , .{ name, owner, focus_id, reminder, listener });
        defer s.deinit();
        if (!try s.next()) return error.InvalidSubscriptionDatabase;
        const row = try Registration.read(a, s);
        if (try s.next()) return error.InvalidSubscriptionDatabase;
        try self.exec("COMMIT");
        return row;
    }

    pub fn registrations(self: *Store, a: Allocator, owner: ?u64) ![]const Registration {
        const query = "SELECT reference,focus_id,reminder,active FROM subscriptions";
        const s = if (owner) |id|
            try self.statement(query ++ " WHERE session_id=? ORDER BY id", .{id})
        else
            try self.statement(query ++ " ORDER BY id", .{});
        defer s.deinit();
        var rows: std.ArrayList(Registration) = .empty;
        while (try s.next()) try rows.append(a, try Registration.read(a, s));
        return rows.toOwnedSlice(a);
    }

    pub fn inspect(self: *Store, a: Allocator, reference: []const u8) !?Subscription {
        const s = try self.statement(
            \\SELECT reference, focus_id, reminder, listener, active, external, status, progress,
            \\       (SELECT count(*) FROM reports WHERE reports.reference=subscriptions.reference)
            \\FROM subscriptions WHERE reference=?
        , .{reference});
        defer s.deinit();
        if (!try s.next()) return null;
        return .{
            .subscription_id = try s.copy(a, 0),
            .focus_id = try s.copy(a, 1),
            .reminder = try s.tag(Reminder, 2),
            .listener = try s.copy(a, 3),
            .active = s.number(4) != 0,
            .external = s.number(5) != 0,
            .status = try s.optionalText(a, 6),
            .progress = try s.optionalText(a, 7),
            .pending = try s.unsigned(8),
        };
    }

    pub fn withdraw(self: *Store, owner: ?u64, reference: []const u8) !bool {
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.rollback();
        const found = try self.change("UPDATE subscriptions SET active=0 WHERE reference=?1 AND active AND (?2 IS NULL OR session_id=?2)", .{ reference, owner });
        if (found) {
            _ = try self.change("DELETE FROM producer_keys WHERE subscription_id=(SELECT id FROM subscriptions WHERE reference=?)", .{reference});
            _ = try self.change("DELETE FROM subscriptions WHERE reference=? AND NOT external", .{reference});
        }
        try self.exec("COMMIT");
        return found;
    }

    /// Accept a report for an active registration and advance its source cursor
    /// in one transaction. Retrying its key preserves the committed cursor.
    pub fn publish(self: *Store, reference: []const u8, report: NewReport, received_unix_ms: i64) !PublishResult {
        if (!validText(report.key, 256) or !validText(report.text, 2048) or
            !validOptional(report.handle, 512) or !validOptional(report.version, 512) or
            (report.handle == null) != (report.retrieval == .unavailable) or
            !validInstant(report.source_time_unix_ms) or !validInstant(received_unix_ms))
            return error.InvalidArguments;
        try validateProgress(report.expected_progress, report.progress);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.rollback();
        const s = try self.statement("SELECT id,progress FROM subscriptions WHERE reference=? AND active", .{reference});
        defer s.deinit();
        if (!try s.next()) return error.SubscriptionWithdrawn;
        const id = try s.unsigned(0);
        const registered = try self.change(
            \\INSERT INTO producer_keys(subscription_id,key) VALUES(?,?)
            \\ON CONFLICT(subscription_id,key) DO NOTHING
        , .{ id, report.key });
        if (!registered) {
            try self.exec("COMMIT");
            return .duplicate;
        }
        if (report.progress != null and !try progressMatches(s, 1, report.expected_progress)) return error.ProgressConflict;
        _ = try self.change(
            \\INSERT INTO reports(reference,session_id,reminder,text,handle,retrieval,version,truncated,source_time,received)
            \\SELECT reference,session_id,reminder,?2,?3,?4,?5,?6,?7,?8 FROM subscriptions WHERE id=?1
        , .{ id, report.text, report.handle, report.retrieval, report.version, report.truncated, report.source_time_unix_ms, received_unix_ms });
        if (report.progress) |next| _ = try self.change("UPDATE subscriptions SET progress=? WHERE id=?", .{ next, id });
        try self.exec("COMMIT");
        return .accepted;
    }

    /// A listener may advance through filtered events or record upstream state
    /// without waking its owner. After local withdrawal only closure/status
    /// for an outstanding external relationship is accepted.
    pub fn checkpoint(self: *Store, reference: []const u8, value: Checkpoint) !void {
        if ((value.progress == null and value.status == null and value.external == null) or
            !validOptional(value.status, 512)) return error.InvalidArguments;
        try validateProgress(value.expected_progress, value.progress);
        try self.exec("BEGIN IMMEDIATE");
        errdefer self.rollback();
        const s = try self.statement("SELECT id,active,progress FROM subscriptions WHERE reference=?", .{reference});
        defer s.deinit();
        if (!try s.next()) return error.SubscriptionWithdrawn;
        if (s.number(1) == 0 and (value.progress != null or value.external == true)) return error.SubscriptionWithdrawn;
        if (value.progress != null and !try progressMatches(s, 2, value.expected_progress)) return error.ProgressConflict;
        const id = try s.unsigned(0);
        _ = try self.change(
            \\UPDATE subscriptions SET progress=coalesce(?,progress),status=coalesce(?,status),
            \\external=coalesce(?,external) WHERE id=?
        , .{ value.progress, value.status, value.external, id });
        _ = try self.change("DELETE FROM subscriptions WHERE id=? AND NOT active AND NOT external", .{id});
        try self.exec("COMMIT");
    }

    pub fn pending(self: *Store, a: Allocator, owner: u64, after: u64, limit: usize) ![]const Report {
        const s = try self.statement(
            \\SELECT sequence,reference,text,handle,retrieval,version,truncated,source_time,received
            \\FROM reports WHERE session_id=? AND sequence>? ORDER BY sequence LIMIT ?
        , .{ owner, after, limit });
        defer s.deinit();
        var rows: std.ArrayList(Report) = .empty;
        while (try s.next()) try rows.append(a, .{
            .sequence = try s.unsigned(0),
            .reference = try s.copy(a, 1),
            .text = try s.copy(a, 2),
            .handle = try s.optionalText(a, 3),
            .retrieval = try s.tag(Retrieval, 4),
            .version = try s.optionalText(a, 5),
            .truncated = s.number(6) != 0,
            .source_time_unix_ms = if (s.isNull(7)) null else s.number(7),
            .observed_at_unix_ms = s.number(8),
        });
        return rows.toOwnedSlice(a);
    }

    pub fn hasActive(self: *Store, owner: u64) !bool {
        return try self.integer("SELECT EXISTS(SELECT 1 FROM subscriptions WHERE session_id=? AND active)", .{owner}) != 0;
    }

    pub fn latestImmediate(self: *Store, owner: u64) !u64 {
        return self.integer("SELECT coalesce(max(sequence),0) FROM reports WHERE session_id=? AND reminder='immediate'", .{owner});
    }

    pub fn hasImmediate(self: *Store, owner: u64, after: u64) !bool {
        return try self.latestImmediate(owner) > after;
    }

    pub fn hasPending(self: *Store, owner: u64, after: u64) !bool {
        return try self.integer("SELECT EXISTS(SELECT 1 FROM reports WHERE session_id=? AND sequence>?)", .{ owner, after }) != 0;
    }

    pub fn acknowledge(self: *Store, owner: u64, through: u64) !void {
        _ = try self.change("DELETE FROM reports WHERE session_id=? AND sequence<=?", .{ owner, through });
    }
};

fn validText(s: []const u8, max: ?usize) bool {
    if (max) |limit| if (s.len > limit) return false;
    return s.len != 0 and std.unicode.utf8ValidateSlice(s);
}

fn validOptional(value: ?[]const u8, max: ?usize) bool {
    return if (value) |s| validText(s, max) else true;
}

fn validInstant(time: ?i64) bool {
    // The renderer uses a four-digit UTC year. zdt accepts millisecond instants
    // up to the start of the final representable second.
    return if (time) |ms| ms >= -62_167_219_200_000 and ms <= 253_402_300_799_000 else true;
}

fn validateProgress(expected: ?[]const u8, next: ?[]const u8) !void {
    if (!validOptional(expected, null) or !validOptional(next, null) or (expected != null and next == null))
        return error.InvalidArguments;
}

fn progressMatches(s: Statement, column: c_int, expected: ?[]const u8) !bool {
    if (s.isNull(column)) return expected == null;
    return if (expected) |value| std.mem.eql(u8, try s.text(column), value) else false;
}

test "independent connections preserve progress, retry receipts and accepted reports" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, filename });
    var kernel = try Store.open(a, path);
    defer kernel.close();
    if (@hasDecl(std.Io.File.Permissions, "toMode")) {
        for ([_][]const u8{ filename, filename ++ "-wal", filename ++ "-shm" }) |file| {
            const stat = try temporary.dir.statFile(t.io, file, .{});
            try t.expectEqual(0, stat.permissions.toMode() & 0o077);
        }
    }
    var producer = try Store.openExisting(a, path);
    defer producer.close();
    const row = try kernel.create(a, 2, "work-2", "feed", .next_input, "watch changes");
    const ref = row.subscription_id;
    const token: [800]u8 = @splat('x');
    const first = NewReport{ .key = "post-1", .text = "First", .progress = &token, .source_time_unix_ms = -62_167_219_200_000 };
    try t.expectEqual(.accepted, try producer.publish(ref, first, 10));
    try t.expect(!try kernel.hasImmediate(2, 0));
    const admitted = (try kernel.pending(a, 2, 0, 1))[0];
    try kernel.acknowledge(2, admitted.sequence);
    try t.expectEqual(.duplicate, try producer.publish(ref, first, 10));
    try t.expect(!try kernel.hasPending(2, 0));

    var next = NewReport{ .key = "post-2", .text = "Second", .progress = "tail", .source_time_unix_ms = std.math.maxInt(i64) };
    try t.expectError(error.InvalidArguments, producer.publish(ref, next, 20));
    next.source_time_unix_ms = null;
    try t.expectError(error.ProgressConflict, producer.publish(ref, next, 20));
    next.expected_progress = (try producer.inspect(a, ref)).?.progress;
    try t.expectEqualStrings(&token, next.expected_progress.?);
    try t.expectEqual(.accepted, try producer.publish(ref, next, 20));
    try t.expect(try kernel.withdraw(2, ref));
    const pending_reports = try kernel.pending(a, 2, admitted.sequence, 8);
    try t.expectEqual(1, pending_reports.len);
    try t.expectEqualStrings("Second", pending_reports[0].text);
    try t.expect(!try kernel.hasImmediate(2, admitted.sequence));
}

test "an outstanding external cancellation keeps only its actionable state" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store = try Store.open(a, ":memory:");
    defer store.close();
    const ref = (try store.create(a, 2, "check-2", "follow", .immediate, "external feed")).subscription_id;
    try store.checkpoint(ref, .{ .external = true, .status = "pending approval" });
    try t.expect(!try store.hasImmediate(2, 0));
    _ = try store.publish(ref, .{ .key = "status-event", .text = "pending" }, 10);
    try t.expect(try store.withdraw(2, ref));
    try t.expect(!try store.withdraw(2, ref));
    try t.expectEqual(0, try store.integer("SELECT count(*) FROM producer_keys", .{}));
    try store.acknowledge(2, try store.latestImmediate(2));
    const closing = (try store.inspect(a, ref)).?;
    try t.expect(closing.external and !closing.active);
    const newer = try store.create(a, 1, "core-1", "follow", .next_input, "follow again");
    try store.checkpoint(newer.subscription_id, .{ .external = true, .status = "awaiting confirmation" });
    const all = try store.registrations(a, null);
    try t.expectEqual(@as(usize, 2), all.len);
    try t.expectEqualStrings(ref, all[0].subscription_id);
    try t.expect(!all[0].active);
    try t.expectEqualStrings(newer.subscription_id, all[1].subscription_id);
    try t.expect(all[1].active);
    const own = try store.registrations(a, 2);
    try t.expectEqual(@as(usize, 1), own.len);
    try t.expectEqualStrings(ref, own[0].subscription_id);
    try t.expectEqualStrings("check-2", own[0].focus_id);
    try t.expectEqual(Reminder.immediate, own[0].reminder);

    try t.expectError(error.SubscriptionWithdrawn, store.publish(ref, .{ .key = "late", .text = "late" }, 20));
    try t.expectError(error.SubscriptionWithdrawn, store.checkpoint(ref, .{ .progress = "unexpected" }));
    try store.checkpoint(ref, .{ .external = false, .status = "withdrawal confirmed" });
    try t.expect(try store.inspect(a, ref) == null);
    try t.expectEqual(@as(usize, 0), (try store.registrations(a, 2)).len);
    const current = (try store.inspect(a, newer.subscription_id)).?;
    try t.expect(current.active and current.external);
    try t.expectEqualStrings("awaiting confirmation", current.status.?);
}
