const std = @import("std");
const sql = @import("database.zig");
const migrations = @import("migrations.zig");
const ListenerPresence = @import("listener_presence.zig");
const zqlite = @import("sqlite").zqlite;
const Allocator = std.mem.Allocator;
const Reference = @import("agent_contracts").Reference;

pub const Created = struct {
    subscription_id: []const u8,
};

pub const ActiveRegistration = struct {
    subscription_id: []const u8,
    listener: []const u8,
};

pub const Report = struct {
    sequence: u64,
    reference: []const u8,
    text: []const u8,
    source_time_unix_ms: ?i64,
    observed_at_unix_ms: i64,
};

pub const NewReport = struct {
    key: []const u8,
    text: []const u8,
    source_time_unix_ms: ?i64 = null,
};

/// Owns one subscription connection, including its live presence. All
/// requests use the registration selected when this listener connected.
pub const Listener = struct {
    store: Store,
    registration_id: i64,

    pub fn open(a: Allocator, io: std.Io, path: []const u8, reference: []const u8) !Listener {
        var store = try Store.openFile(a, io, path, .existing);
        errdefer store.close();
        const id = try store.registrationId(reference);
        try store.listener_presence.?.attach(id);
        return .{ .store = store, .registration_id = id };
    }

    pub fn close(self: *Listener) void {
        self.store.close();
        self.* = undefined;
    }

    pub fn publish(self: *Listener, report: NewReport, received_unix_ms: i64) !void {
        try self.store.publish(self.registration_id, report, received_unix_ms);
    }
};

/// Each Store owns one SQLite connection. Serialize calls on a shared Store
/// and supply an arena for query results. The kernel and independent listeners
/// open separate connections to the instance database.
pub const Store = struct {
    db: zqlite.Conn,
    listener_presence: ?ListenerPresence,

    /// Open the database paired with the selected mailbox checkpoint and
    /// install or migrate its schema. A checkpoint requires an existing file.
    pub fn initialize(a: Allocator, io: std.Io, path: []const u8, checkpoint_catalog: ?[32]u8) !Store {
        return openFile(a, io, path, .{ .initialize = checkpoint_catalog });
    }

    fn openFile(a: Allocator, io: std.Io, path: []const u8, mode: sql.OpenMode) !Store {
        const db = try openDatabase(a, path, mode);
        errdefer db.close();
        return .{
            .db = db,
            .listener_presence = try ListenerPresence.open(io, std.fs.path.dirname(path) orelse "."),
        };
    }

    pub fn openInMemory(a: Allocator) !Store {
        return .{ .db = try openDatabase(a, ":memory:", .{ .initialize = null }), .listener_presence = null };
    }

    pub fn close(self: *Store) void {
        if (self.listener_presence) |presence| presence.close();
        self.db.close();
        self.* = undefined;
    }

    fn change(self: *Store, query: [:0]const u8, args: anytype) !bool {
        const s = try sql.statement(self.db, query, args);
        defer s.deinit();
        try sql.checked(s.stepToCompletion());
        return self.db.changes() != 0;
    }

    pub fn identity(self: *Store) ![32]u8 {
        return (try sql.mailboxBinding(self.db)).identity;
    }

    pub fn markBound(self: *Store) !void {
        _ = try self.change("UPDATE mailbox_binding SET bound=1 WHERE singleton=1", .{});
    }

    /// The parsed subscription request supplies a UTF-8 listener description.
    pub fn create(self: *Store, a: Allocator, focus_id: []const u8, name: []const u8, listener: []const u8) !Created {
        if (!Reference.validName(name) or listener.len == 0) return error.InvalidArguments;
        try sql.exec(self.db, "BEGIN IMMEDIATE");
        errdefer sql.rollback(self.db);
        const s = try sql.statement(
            self.db,
            "INSERT INTO subscriptions(focus_id,name,listener) VALUES(?,?,?) RETURNING reference",
            .{ focus_id, name, listener },
        );
        defer s.deinit();
        if (!try sql.checked(s.step())) return error.InvalidStateDatabase;
        const reference = try sql.copyText(a, s, 0);
        try sql.checked(s.stepToCompletion());
        try sql.exec(self.db, "COMMIT");
        return .{ .subscription_id = reference };
    }

    pub fn hasActive(self: *Store, focus_id: []const u8) !bool {
        return try sql.integer(self.db, "SELECT EXISTS(SELECT 1 FROM subscriptions WHERE focus_id=?)", .{focus_id}) != 0;
    }

    pub fn activeRegistrations(self: *Store, a: Allocator, focus_id: []const u8) ![]const ActiveRegistration {
        const s = try sql.statement(self.db, "SELECT reference,listener FROM subscriptions WHERE focus_id=? ORDER BY id", .{focus_id});
        defer s.deinit();
        var registrations: std.ArrayList(ActiveRegistration) = .empty;
        while (try sql.checked(s.step())) try registrations.append(a, .{
            .subscription_id = try sql.copyText(a, s, 0),
            .listener = try sql.copyText(a, s, 1),
        });
        return registrations.toOwnedSlice(a);
    }

    fn registrationId(self: *Store, reference: []const u8) !i64 {
        const s = try sql.statement(self.db, "SELECT id FROM subscriptions WHERE reference=?", .{reference});
        defer s.deinit();
        if (!try sql.checked(s.step())) return error.SubscriptionWithdrawn;
        return s.int(0);
    }

    pub fn subscriptionsWithoutListeners(self: *Store, a: Allocator, focus_id: []const u8, limit: usize) ![]const []const u8 {
        const s = try sql.statement(self.db, "SELECT id,reference FROM subscriptions WHERE focus_id=? ORDER BY id DESC", .{focus_id});
        defer s.deinit();
        var references: std.ArrayList([]const u8) = .empty;
        while (references.items.len < limit and try sql.checked(s.step())) {
            const reference = try sql.requiredText(s, 1);
            if (self.listener_presence) |presence| {
                const connected = presence.connected(s.int(0)) catch |err| switch (err) {
                    error.Canceled => return err,
                    error.Unexpected => {
                        std.log.warn("subscription listener probe failed for '{s}': {s}", .{ reference, @errorName(err) });
                        continue;
                    },
                };
                if (connected) continue;
            }
            try references.append(a, try a.dupe(u8, reference));
        }
        return references.toOwnedSlice(a);
    }

    pub fn withdraw(self: *Store, reference: []const u8) !bool {
        return self.change("DELETE FROM subscriptions WHERE reference=?", .{reference});
    }

    /// Save the report and its retry key in one transaction. The listener
    /// boundary supplies UTF-8 report fields.
    fn publish(self: *Store, id: i64, report: NewReport, received_unix_ms: i64) !void {
        if (report.text.len == 0 or report.text.len > 2048 or report.key.len == 0)
            return error.InvalidArguments;
        // The model renders source timestamps as four-digit UTC years. zdt
        // accepts milliseconds through the start of the final second.
        if (report.source_time_unix_ms) |ms| if (ms < -62_167_219_200_000 or ms > 253_402_300_799_000)
            return error.InvalidArguments;
        try sql.exec(self.db, "BEGIN IMMEDIATE");
        errdefer sql.rollback(self.db);
        const inserted = try self.change(
            \\INSERT INTO accepted_report_keys(subscription_id,key) SELECT id,? FROM subscriptions WHERE id=?
            \\ON CONFLICT(subscription_id,key) DO NOTHING
        , .{ report.key, id });
        if (inserted) {
            _ = try self.change(
                \\INSERT INTO subscription_reports(reference,focus_id,text,source_time,received)
                \\SELECT reference,focus_id,?,?,? FROM subscriptions WHERE id=?
            , .{ report.text, report.source_time_unix_ms, received_unix_ms, id });
        } else if (try sql.integer(self.db, "SELECT EXISTS(SELECT 1 FROM subscriptions WHERE id=?)", .{id}) == 0) {
            return error.SubscriptionWithdrawn;
        }
        try sql.exec(self.db, "COMMIT");
    }

    pub fn publishInMemory(self: *Store, reference: []const u8, report: NewReport, received_unix_ms: i64) !void {
        if (!@import("builtin").is_test) @compileError("only tests can publish to an in-memory store");
        std.debug.assert(self.listener_presence == null);
        try self.publish(try self.registrationId(reference), report, received_unix_ms);
    }

    pub fn pending(self: *Store, a: Allocator, focus_id: []const u8, after: u64, through: u64, limit: usize) ![]const Report {
        const s = try sql.statement(self.db,
            \\SELECT sequence,reference,text,source_time,received
            \\FROM subscription_reports WHERE focus_id=? AND sequence>? AND sequence<=? ORDER BY sequence LIMIT ?
        , .{ focus_id, try sql.signed(after), try sql.signed(through), try sql.signed(limit) });
        defer s.deinit();
        var rows: std.ArrayList(Report) = .empty;
        while (try sql.checked(s.step())) try rows.append(a, .{
            .sequence = try sql.unsigned(s.int(0)),
            .reference = try sql.copyText(a, s, 1),
            .text = try sql.copyText(a, s, 2),
            .source_time_unix_ms = s.nullableInt(3),
            .observed_at_unix_ms = s.int(4),
        });
        return rows.toOwnedSlice(a);
    }

    pub fn latestSequence(self: *Store, focus_id: []const u8) !u64 {
        return sql.unsigned(try sql.integer(self.db, "SELECT coalesce(max(sequence),0) FROM subscription_reports WHERE focus_id=?", .{focus_id}));
    }

    pub fn acknowledge(self: *Store, focus_id: []const u8, through: u64) !void {
        _ = try self.change("DELETE FROM subscription_reports WHERE focus_id=? AND sequence<=?", .{ focus_id, try sql.signed(through) });
    }
};

fn openDatabase(a: Allocator, path: []const u8, mode: sql.OpenMode) !zqlite.Conn {
    const db = try sql.open(a, path, mode);
    errdefer db.close();
    switch (mode) {
        .initialize => |checkpoint| {
            try migrations.initialize(a, db, checkpoint);
            try sql.exec(db, "PRAGMA journal_mode=WAL");
        },
        .existing => try migrations.requireCurrent(db),
    }
    return db;
}

test "a reconnected listener can retry an accepted report after the focus received it" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(t.io, ".", a);
    const filename = sql.filename;
    const path = try std.fs.path.join(a, &.{ dir, filename });
    var kernel = try Store.initialize(a, t.io, path, null);
    defer kernel.close();
    const activity = "read-2";
    const ref = (try kernel.create(a, activity, "feed", "watch changes")).subscription_id;
    if (@hasDecl(std.Io.File.Permissions, "toMode")) {
        for ([_][]const u8{ filename, filename ++ "-wal", filename ++ "-shm" }) |file| {
            const stat = try temporary.dir.statFile(t.io, file, .{});
            try t.expectEqual(0, stat.permissions.toMode() & 0o077);
        }
    }
    const first = NewReport{ .key = "post-1", .text = "First", .source_time_unix_ms = -62_167_219_200_000 };
    {
        var producer = try Listener.open(a, t.io, path, ref);
        defer producer.close();
        try producer.publish(first, 10);
    }
    const other = (try kernel.create(a, "core-1", "feed", "read a second feed")).subscription_id;
    {
        var other_listener = try Listener.open(a, t.io, path, other);
        defer other_listener.close();
        try other_listener.publish(.{ .key = first.key, .text = "For the core" }, 11);
    }
    // Acknowledging a later sequence for another focus leaves this delivery pending.
    try kernel.acknowledge("core-1", try kernel.latestSequence("core-1"));
    const admitted = (try kernel.pending(a, activity, 0, try kernel.latestSequence(activity), 1))[0];
    try t.expectEqualStrings("First", admitted.text);
    try kernel.acknowledge(activity, admitted.sequence);
    var producer = try Listener.open(a, t.io, path, ref);
    defer producer.close();
    try producer.publish(first, 15);
    try t.expectEqual(0, try kernel.latestSequence(activity));

    var next = NewReport{ .key = "post-2", .text = "Second", .source_time_unix_ms = std.math.maxInt(i64) };
    try t.expectError(error.InvalidArguments, producer.publish(next, 20));
    next.source_time_unix_ms = null;
    try producer.publish(next, 20);

    try t.expect(try kernel.withdraw(ref));
    const renewed = (try kernel.create(a, activity, "feed", "watch changes")).subscription_id;
    try t.expectError(error.SubscriptionWithdrawn, producer.publish(next, 25));
    const through = try kernel.latestSequence(activity);
    var replacement = try Listener.open(a, t.io, path, renewed);
    defer replacement.close();
    try replacement.publish(first, 30);
    const sampled = try kernel.pending(a, activity, admitted.sequence, through, 8);
    try t.expectEqual(1, sampled.len);
    try t.expectEqualStrings(ref, sampled[0].reference);
    try t.expectEqualStrings("Second", sampled[0].text);
    const later = try kernel.pending(a, activity, through, try kernel.latestSequence(activity), 8);
    try t.expectEqual(1, later.len);
    try t.expectEqualStrings(renewed, later[0].reference);
}

test "withdrawing the highest subscription does not let a replacement inherit its listener" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, sql.filename });
    var kernel = try Store.initialize(a, t.io, path, null);
    defer kernel.close();

    const latest = (try kernel.create(a, "core-1", "feed", "watch updates")).subscription_id;
    var listener = try Listener.open(a, t.io, path, latest);
    defer listener.close();
    try t.expect(try kernel.withdraw(latest));

    const replacement = (try kernel.create(a, "core-1", "feed", "watch updates")).subscription_id;
    // The withdrawn listener still holds the old id. Without AUTOINCREMENT,
    // SQLite would reuse that id and the replacement would look connected.
    try t.expectEqualDeep(@as([]const []const u8, &.{replacement}), try kernel.subscriptionsWithoutListeners(a, "core-1", 8));
    try t.expectError(error.SubscriptionWithdrawn, Listener.open(a, t.io, path, latest));
}

test "a mailbox checkpoint does not create a missing database" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(t.io, ".", a);
    const missing = try std.fs.path.join(a, &.{ dir, "missing.sqlite3" });
    try t.expectError(error.SubscriptionCatalogMismatch, Store.initialize(a, t.io, missing, @splat('0')));
    try t.expectError(error.FileNotFound, std.Io.Dir.cwd().access(t.io, missing, .{}));
}

test "a listener can publish to a legacy database after startup upgrades it" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, sql.filename });
    const checkpoint = checkpoint: {
        const legacy = try sql.open(a, path, .{ .initialize = null });
        defer legacy.close();
        const legacy_id = std.mem.readInt(u32, "IVDB", .big);
        try sql.exec(legacy, @embedFile("migrations/fixtures/legacy_with_cursor.sql"));
        try sql.exec(legacy, std.fmt.comptimePrint("PRAGMA application_id={d}", .{legacy_id}));
        try sql.exec(legacy, "INSERT INTO subscriptions(name,focus_id,listener,cursor) VALUES('news','core-1','Release feed','17')");
        try t.expectError(error.IncompatibleStateSchema, Listener.open(a, t.io, path, "news-1"));
        try t.expectEqual(1, try sql.integer(legacy, "SELECT count(*) FROM subscriptions WHERE cursor='17'", .{}));
        break :checkpoint (try sql.mailboxBinding(legacy)).identity;
    };
    var kernel = try Store.initialize(a, t.io, path, checkpoint);
    defer kernel.close();
    var listener = try Listener.open(a, t.io, path, "news-1");
    defer listener.close();
    try listener.publish(.{ .key = "post-1", .text = "New release" }, 123);
    try t.expectEqual(1, try kernel.latestSequence("core-1"));
}

test "listener presence follows independent sessions and active registrations" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, sql.filename });
    var kernel = try Store.initialize(a, t.io, path, null);
    defer kernel.close();
    const ref = (try kernel.create(a, "core-1", "feed", "watch changes")).subscription_id;
    const other = (try kernel.create(a, "read-2", "feed", "watch another source")).subscription_id;
    try t.expectEqualDeep(@as([]const []const u8, &.{ref}), try kernel.subscriptionsWithoutListeners(a, "core-1", 8));

    {
        var first = try Listener.open(a, t.io, path, ref);
        defer first.close();
        {
            var second = try Listener.open(a, t.io, path, ref);
            defer second.close();
            var reopened = try Store.initialize(a, t.io, path, null);
            defer reopened.close();
            try t.expectEqual(0, (try reopened.subscriptionsWithoutListeners(a, "core-1", 8)).len);
            try t.expectEqualDeep(@as([]const []const u8, &.{other}), try reopened.subscriptionsWithoutListeners(a, "read-2", 8));
        }
        try t.expectEqual(0, (try kernel.subscriptionsWithoutListeners(a, "core-1", 8)).len);
    }
    try t.expectEqualDeep(@as([]const []const u8, &.{ref}), try kernel.subscriptionsWithoutListeners(a, "core-1", 8));
}
