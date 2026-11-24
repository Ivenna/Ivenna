const std = @import("std");
const sql = @import("database.zig");
const zqlite = @import("sqlite").zqlite;
const Allocator = std.mem.Allocator;
const Reference = @import("agent_contracts").Reference;

pub const Created = struct {
    subscription_id: []const u8,
};

pub const Subscription = struct {
    subscription_id: []const u8,
    focus_id: []const u8,
    listener: []const u8,
    cursor: ?[]const u8,
};

pub const Report = struct {
    sequence: u64,
    reference: []const u8,
    text: []const u8,
    source_time_unix_ms: ?i64,
    observed_at_unix_ms: i64,
};

/// Source positions are UTF-8 strings supplied by the listener.
pub const Cursor = struct {
    from: ?[]const u8 = null,
    to: []const u8,
};

pub const NewReport = struct {
    key: []const u8,
    text: []const u8,
    source_time_unix_ms: ?i64 = null,
    cursor: ?Cursor = null,
};
pub const PublishResult = enum { accepted, duplicate };

/// Each Store owns one SQLite connection. Serialize calls on a shared Store
/// and supply an arena for query results. The kernel and independent listeners
/// open separate connections to the instance database.
pub const Store = struct {
    db: zqlite.Conn,

    pub fn open(a: Allocator, path: []const u8) !Store {
        return .{ .db = try sql.open(a, path, .read_write) };
    }

    pub fn openInMemory(a: Allocator) !Store {
        return .{ .db = try sql.open(a, ":memory:", .initialize) };
    }

    pub fn close(self: *Store) void {
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
        const s = try sql.statement(self.db, "SELECT identity FROM mailbox_binding WHERE singleton=1", .{});
        defer s.deinit();
        if (!try sql.checked(s.step())) return error.InvalidStateDatabase;
        const id = try sql.requiredText(s, 0);
        if (id.len != 32) return error.InvalidStateDatabase;
        return id[0..32].*;
    }

    pub fn isBound(self: *Store) !bool {
        return try sql.integer(self.db, "SELECT bound FROM mailbox_binding WHERE singleton=1", .{}) != 0;
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

    pub fn activeReferences(self: *Store, a: Allocator, focus_id: []const u8) ![]const []const u8 {
        const s = try sql.statement(self.db, "SELECT reference FROM subscriptions WHERE focus_id=? ORDER BY id", .{focus_id});
        defer s.deinit();
        var references: std.ArrayList([]const u8) = .empty;
        while (try sql.checked(s.step())) try references.append(a, try sql.copyText(a, s, 0));
        return references.toOwnedSlice(a);
    }

    pub fn inspect(self: *Store, a: Allocator, reference: []const u8) !?Subscription {
        const s = try sql.statement(self.db, "SELECT reference,focus_id,listener,cursor FROM subscriptions WHERE reference=?", .{reference});
        defer s.deinit();
        if (!try sql.checked(s.step())) return null;
        return .{
            .subscription_id = try sql.copyText(a, s, 0),
            .focus_id = try sql.copyText(a, s, 1),
            .listener = try sql.copyText(a, s, 2),
            .cursor = if (s.columnType(3) == .null) null else try sql.copyText(a, s, 3),
        };
    }

    pub fn withdraw(self: *Store, reference: []const u8) !bool {
        return self.change("DELETE FROM subscriptions WHERE reference=?", .{reference});
    }

    /// Save the report, its retry key, and any cursor advance together. The
    /// listener boundary supplies UTF-8 report fields and source positions.
    pub fn publish(self: *Store, reference: []const u8, report: NewReport, received_unix_ms: i64) !PublishResult {
        if (report.text.len == 0 or report.text.len > 2048 or report.key.len == 0)
            return error.InvalidArguments;
        // The model renders source timestamps as four-digit UTC years. zdt
        // accepts milliseconds through the start of the final second.
        if (report.source_time_unix_ms) |ms| if (ms < -62_167_219_200_000 or ms > 253_402_300_799_000)
            return error.InvalidArguments;
        try sql.exec(self.db, "BEGIN IMMEDIATE");
        errdefer sql.rollback(self.db);
        const registered = try self.change(
            \\INSERT INTO accepted_report_keys(subscription_id,key) SELECT id,? FROM subscriptions WHERE reference=?
            \\ON CONFLICT(subscription_id,key) DO NOTHING
        , .{ report.key, reference });
        if (!registered) {
            try self.requireRegistration(reference);
            try sql.exec(self.db, "COMMIT");
            return .duplicate;
        }
        if (report.cursor) |cursor| try self.advanceCursor(reference, cursor);
        _ = try self.change(
            \\INSERT INTO subscription_reports(reference,focus_id,text,source_time,received)
            \\SELECT reference,focus_id,?,?,? FROM subscriptions WHERE reference=?
        , .{ report.text, report.source_time_unix_ms, received_unix_ms, reference });
        try sql.exec(self.db, "COMMIT");
        return .accepted;
    }

    pub fn checkpoint(self: *Store, reference: []const u8, cursor: Cursor) !void {
        try self.advanceCursor(reference, cursor);
    }

    fn advanceCursor(self: *Store, reference: []const u8, cursor: Cursor) !void {
        if (try self.change("UPDATE subscriptions SET cursor=? WHERE reference=? AND cursor IS ?", .{ cursor.to, reference, cursor.from })) return;
        try self.requireRegistration(reference);
        return error.CursorConflict;
    }

    fn requireRegistration(self: *Store, reference: []const u8) !void {
        if (try sql.integer(self.db, "SELECT EXISTS(SELECT 1 FROM subscriptions WHERE reference=?)", .{reference}) == 0)
            return error.SubscriptionWithdrawn;
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

test "independent connections preserve cursors, retries and the destination of accepted reports" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(t.io, ".", a);
    const filename = sql.filename;
    const path = try std.fs.path.join(a, &.{ dir, filename });
    try sql.initialize(a, path);
    var kernel = try Store.open(a, path);
    defer kernel.close();
    var producer = try Store.open(a, path);
    defer producer.close();
    const activity = "read-2";
    const ref = (try kernel.create(a, activity, "feed", "watch changes")).subscription_id;
    if (@hasDecl(std.Io.File.Permissions, "toMode")) {
        for ([_][]const u8{ filename, filename ++ "-wal", filename ++ "-shm" }) |file| {
            const stat = try temporary.dir.statFile(t.io, file, .{});
            try t.expectEqual(0, stat.permissions.toMode() & 0o077);
        }
    }
    const first = NewReport{ .key = "post-1", .text = "First", .cursor = .{ .to = "" }, .source_time_unix_ms = -62_167_219_200_000 };
    try t.expectEqual(.accepted, try producer.publish(ref, first, 10));
    const other = (try kernel.create(a, "core-1", "feed", "read a second feed")).subscription_id;
    try t.expectEqual(.accepted, try producer.publish(other, .{ .key = first.key, .text = "For the core" }, 11));
    // Acknowledging a later sequence for another focus leaves this delivery pending.
    try kernel.acknowledge("core-1", try kernel.latestSequence("core-1"));
    const admitted = (try kernel.pending(a, activity, 0, try kernel.latestSequence(activity), 1))[0];
    try t.expectEqualStrings("First", admitted.text);
    try kernel.acknowledge(activity, admitted.sequence);
    const retry = NewReport{ .key = first.key, .text = "Edited retry", .cursor = .{ .from = "", .to = "retry cursor" } };
    try t.expectEqual(.duplicate, try producer.publish(ref, retry, 15));
    try t.expectEqual(0, try kernel.latestSequence(activity));

    var next = NewReport{ .key = "post-2", .text = "Second", .cursor = .{ .to = "tail" }, .source_time_unix_ms = std.math.maxInt(i64) };
    try t.expectError(error.InvalidArguments, producer.publish(ref, next, 20));
    next.source_time_unix_ms = null;
    try t.expectError(error.CursorConflict, producer.publish(ref, next, 20));
    next.cursor.?.from = (try producer.inspect(a, ref)).?.cursor;
    try t.expectEqualStrings("", next.cursor.?.from.?);
    try t.expectEqual(.accepted, try producer.publish(ref, next, 20));
    try t.expectEqualStrings("tail", (try producer.inspect(a, ref)).?.cursor.?);

    try t.expect(try kernel.withdraw(ref));
    const renewed = (try kernel.create(a, activity, "feed", "watch changes")).subscription_id;
    try t.expectError(error.SubscriptionWithdrawn, producer.publish(ref, next, 25));
    const through = try kernel.latestSequence(activity);
    try t.expectEqual(.accepted, try producer.publish(renewed, first, 30));
    const sampled = try kernel.pending(a, activity, admitted.sequence, through, 8);
    try t.expectEqual(1, sampled.len);
    try t.expectEqualStrings(ref, sampled[0].reference);
    try t.expectEqualStrings("Second", sampled[0].text);
    const later = try kernel.pending(a, activity, through, try kernel.latestSequence(activity), 8);
    try t.expectEqual(1, later.len);
    try t.expectEqualStrings(renewed, later[0].reference);
}
