//! Adopt legacy instance schemas and apply their remaining migrations with zug.

const std = @import("std");
const sql = @import("database.zig");
const zqlite = @import("sqlite").zqlite;
const zug = @import("zug");
const Allocator = std.mem.Allocator;
const Conn = zqlite.Conn;

const application_id = std.mem.readInt(u32, "IVST", .big);
const legacy_cursor_id = std.mem.readInt(u32, "IVDB", .big);
const session_cursor_id = std.mem.readInt(u32, "IVS2", .big);
const session_snapshot_id = std.mem.readInt(u32, "IVS3", .big);

// This value identifies the ledger format to earlier binaries. Only zug's
// ledger tracks schema changes once the database has this marker.
const ledger_format = 2;
const ledger_table = "zug_migrations";
const baseline_v1 = @embedFile("migrations/baseline_v1.sql");

const upgrades: []const zug.Migration = &.{
    script("0001_drop_subscription_cursor"),
};

comptime {
    for (upgrades[0 .. upgrades.len - 1], upgrades[1..]) |previous, next| {
        if (std.mem.order(u8, previous.id, next.id) != .lt)
            @compileError("Migration IDs must sort in release order");
    }
}

fn script(comptime id: []const u8) zug.Migration {
    return .{ .id = id, .statements = &.{@embedFile("migrations/" ++ id ++ ".sql")} };
}

const InstalledSchema = enum { empty, legacy_with_cursor, session_snapshot, version_one, ledger };

/// Validate the selected mailbox checkpoint before touching the database.
/// zug leaves the transaction open so the schema, ledger, and marker commit together.
pub fn initialize(a: Allocator, conn: Conn, checkpoint: ?[32]u8) !void {
    try sql.exec(conn, "BEGIN IMMEDIATE");
    errdefer sql.rollback(conn);

    const schema = try installedSchema(conn);
    if (schema == .empty) {
        if (checkpoint != null) return error.SubscriptionCatalogMismatch;
        try sql.exec(conn, baseline_v1);
    } else if (!(try sql.mailboxBinding(conn)).matches(checkpoint)) return error.SubscriptionCatalogMismatch;

    var migration_connection: MigrationConnection = .{ .conn = conn, .allocator = a };
    if (schema == .ledger) {
        try checkLedger(conn, .upgrade);
    } else {
        if (schema != .empty and try hasLedger(conn)) return error.IncompatibleStateSchema;
        const already_at_v1 = switch (schema) {
            .empty, .version_one => true,
            .legacy_with_cursor => false,
            // Fresh IVS3 databases omitted the cursor. Upgraded ones still have it.
            .session_snapshot => try sql.integer(conn, "SELECT EXISTS(SELECT 1 FROM pragma_table_xinfo('subscriptions') WHERE name='cursor')", .{}) == 0,
            .ledger => unreachable,
        };
        if (already_at_v1) try zug.sqlite.baseline(a, &migration_connection, upgrades[0..1], .{ .table_name = ledger_table });
    }

    zug.sqlite.run(a, &migration_connection, upgrades, .{ .table_name = ledger_table }) catch |err| switch (err) {
        error.ChecksumMismatch, error.DirtyMigration => return error.IncompatibleStateSchema,
        else => return err,
    };
    if (schema != .ledger) {
        try sql.exec(conn, std.fmt.comptimePrint("PRAGMA application_id={d}; PRAGMA user_version={d};", .{ application_id, ledger_format }));
    }
    try sql.exec(conn, "COMMIT");
}

/// Listeners use the installed ledger without opening a write transaction.
pub fn requireCurrent(conn: Conn) !void {
    if (try installedSchema(conn) != .ledger) return error.IncompatibleStateSchema;
    try checkLedger(conn, .listener);
}

fn hasLedger(conn: Conn) !bool {
    return try sql.integer(conn, "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name=?)", .{ledger_table}) != 0;
}

fn checkLedger(conn: Conn, use: enum { upgrade, listener }) !void {
    if (!try hasLedger(conn)) return error.IncompatibleStateSchema;
    const s = try sql.statement(conn, "SELECT id, checksum, dirty FROM " ++ ledger_table ++ " ORDER BY id", .{});
    defer s.deinit();
    var count: usize = 0;
    while (try sql.checked(s.step())) : (count += 1) {
        // An installed ledger must be a prefix of this build's plan. zug.run
        // validates known entries but can ignore unknown IDs or fill a gap.
        if (count >= upgrades.len) return error.IncompatibleStateSchema;
        const migration = upgrades[count];
        if (!std.mem.eql(u8, try sql.requiredText(s, 0), migration.id)) return error.IncompatibleStateSchema;
        if (use == .listener) {
            // A standalone listener can open while the kernel is stopped.
            // On startup, zug validates these fields itself.
            var checksum: [16]u8 = undefined;
            if (s.int(2) != 0 or !std.mem.eql(u8, try sql.requiredText(s, 1), migration.checksumHex(&checksum)))
                return error.IncompatibleStateSchema;
        }
    }
    if (count == 0 or (use == .listener and count != upgrades.len)) return error.IncompatibleStateSchema;
}

fn installedSchema(conn: Conn) !InstalledSchema {
    const id = try sql.integer(conn, "PRAGMA application_id", .{});
    const marker = try sql.integer(conn, "PRAGMA user_version", .{});
    if (id == application_id) return switch (marker) {
        1 => .version_one,
        ledger_format => .ledger,
        else => error.IncompatibleStateSchema,
    };
    if (marker != 0) return error.IncompatibleStateSchema;
    return switch (id) {
        0 => if (try sql.integer(conn, "SELECT EXISTS(SELECT 1 FROM sqlite_schema)", .{}) == 0)
            .empty
        else
            error.IncompatibleStateSchema,
        legacy_cursor_id, session_cursor_id => .legacy_with_cursor,
        session_snapshot_id => .session_snapshot,
        else => error.IncompatibleStateSchema,
    };
}

const MigrationConnection = struct {
    conn: Conn,
    allocator: Allocator,

    pub fn exec(self: *MigrationConnection, query: []const u8, args: anytype) !void {
        if (args.len != 0) return sql.checked(self.conn.exec(query, args));
        // SQLite parses complete migration scripts, including trigger bodies.
        const script_z = try self.allocator.dupeSentinel(u8, query, 0);
        defer self.allocator.free(script_z);
        try sql.exec(self.conn, script_z);
    }

    pub fn rows(self: *MigrationConnection, query: []const u8, args: anytype) !zqlite.Rows {
        return sql.checked(self.conn.rows(query, args));
    }
};

const legacy_with_cursor = @embedFile("migrations/fixtures/legacy_with_cursor.sql");
const test_catalog = "0123456789abcdef0123456789abcdef".*;

test "startup and listener schema checks preserve an incompatible database" {
    const t = std.testing;
    const conn = try sql.open(t.allocator, ":memory:", .{ .initialize = null });
    defer conn.close();
    try sql.exec(conn, "CREATE TABLE notes(text TEXT)");
    try sql.exec(conn, "INSERT INTO notes VALUES('keep me')");
    try t.expectError(error.IncompatibleStateSchema, requireCurrent(conn));
    try t.expectError(error.IncompatibleStateSchema, initialize(t.allocator, conn, null));
    try t.expectEqual(1, try sql.integer(conn, "SELECT count(*) FROM notes WHERE text='keep me'", .{}));
    try t.expectEqual(0, try sql.integer(conn, "PRAGMA application_id", .{}));

    // An empty database with another application's marker is already claimed.
    try sql.exec(conn, "DROP TABLE notes");
    const other_id = std.mem.readInt(u32, "TEST", .big);
    try sql.exec(conn, std.fmt.comptimePrint("PRAGMA application_id={d}", .{other_id}));
    try t.expectError(error.IncompatibleStateSchema, requireCurrent(conn));
    try t.expectError(error.IncompatibleStateSchema, initialize(t.allocator, conn, null));
    try t.expectEqual(other_id, try sql.integer(conn, "PRAGMA application_id", .{}));
}

test "startup removes legacy cursors and preserves subscription state" {
    const t = std.testing;
    const cases = .{
        .{ legacy_cursor_id, 0, true },
        .{ session_cursor_id, 0, true },
        .{ session_snapshot_id, 0, true },
        .{ session_snapshot_id, 0, false },
        .{ application_id, 1, false },
    };
    inline for (cases) |case| {
        const legacy_id, const old_version, const has_cursor = case;
        const conn = try sql.open(t.allocator, ":memory:", .{ .initialize = null });
        defer conn.close();
        try sql.exec(conn, if (has_cursor) legacy_with_cursor else baseline_v1);
        try sql.exec(conn, std.fmt.comptimePrint("PRAGMA application_id={d}; PRAGMA user_version={d};", .{ legacy_id, old_version }));
        try sql.exec(conn,
            \\UPDATE mailbox_binding SET identity='0123456789abcdef0123456789abcdef', bound=1;
            \\INSERT INTO subscriptions(id,name,focus_id,listener) VALUES(3,'news','core-1','Release feed');
            \\INSERT INTO subscriptions(id,name,focus_id,listener) VALUES(5,'old','core-1','Deleted feed');
            \\DELETE FROM subscriptions WHERE id=5;
            \\INSERT INTO subscription_reports(sequence,reference,focus_id,text,source_time,received)
            \\VALUES(7,'news-3','core-1','New release',120,123);
            \\INSERT INTO accepted_report_keys(subscription_id,key) VALUES(3,'report-17');
        );
        if (has_cursor) try sql.exec(conn, "UPDATE subscriptions SET cursor='17'");
        // All nonempty formats go through the same pairing check.
        if (legacy_id == legacy_cursor_id) {
            for ([_]?[32]u8{ null, @splat('0') }) |wrong| {
                try t.expectError(error.SubscriptionCatalogMismatch, initialize(t.allocator, conn, wrong));
                try t.expectEqual(legacy_id, try sql.integer(conn, "PRAGMA application_id", .{}));
                try t.expectEqual(old_version, try sql.integer(conn, "PRAGMA user_version", .{}));
                try t.expect(!try hasLedger(conn));
                try t.expectEqual(1, try sql.integer(conn, "SELECT count(*) FROM subscriptions WHERE id=3 AND cursor='17'", .{}));
            }
        }

        try initialize(t.allocator, conn, test_catalog);
        try requireCurrent(conn);
        try t.expectEqual(ledger_format, try sql.integer(conn, "PRAGMA user_version", .{}));
        try t.expectEqual(0, try sql.integer(conn, "SELECT count(*) FROM pragma_table_xinfo('subscriptions') WHERE name='cursor'", .{}));
        try t.expectEqual(1, try sql.integer(conn, "SELECT bound FROM mailbox_binding WHERE identity='0123456789abcdef0123456789abcdef'", .{}));
        try t.expectEqual(1, try sql.integer(conn, "SELECT count(*) FROM subscriptions WHERE reference='news-3' AND focus_id='core-1' AND listener='Release feed'", .{}));
        try t.expectEqual(1, try sql.integer(conn, "SELECT count(*) FROM subscription_reports WHERE sequence=7 AND reference='news-3' AND text='New release' AND source_time=120 AND received=123", .{}));
        try t.expectEqual(1, try sql.integer(conn, "SELECT count(*) FROM accepted_report_keys WHERE subscription_id=3 AND key='report-17'", .{}));
        // A deleted registration's ID stays retired across the upgrade.
        try t.expectEqual(6, try sql.integer(conn, "INSERT INTO subscriptions(name,focus_id,listener) VALUES('new','core-1','New feed') RETURNING id", .{}));
    }
}

test "startup can retry an upgrade when a reader prevents committing its changes" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.join(a, &.{ directory, sql.filename });
    const writer = try sql.open(a, path, .{ .initialize = null });
    defer writer.close();
    try sql.exec(writer, "PRAGMA journal_mode=DELETE");
    try sql.exec(writer, legacy_with_cursor);
    try sql.exec(writer, std.fmt.comptimePrint("PRAGMA application_id={d}", .{legacy_cursor_id}));
    try sql.exec(writer, "INSERT INTO subscriptions(name,focus_id,listener,cursor) VALUES('news','core-1','Release feed','17')");

    const reader = try sql.open(a, path, .existing);
    defer reader.close();
    try sql.exec(reader, "BEGIN");
    try t.expectEqual(1, try sql.integer(reader, "SELECT count(*) FROM subscriptions WHERE cursor='17'", .{}));
    // A rollback-journal reader allows BEGIN IMMEDIATE and writes, but blocks COMMIT.
    try sql.checked(writer.busyTimeout(0));
    try t.expectError(error.StateStoreBusy, initialize(a, writer, null));
    try t.expectEqual(legacy_cursor_id, try sql.integer(writer, "PRAGMA application_id", .{}));
    try t.expectEqual(0, try sql.integer(writer, "PRAGMA user_version", .{}));
    try t.expectEqual(1, try sql.integer(writer, "SELECT count(*) FROM subscriptions WHERE cursor='17'", .{}));
    try t.expect(!try hasLedger(writer));
    try sql.exec(reader, "COMMIT");

    try initialize(a, writer, null);
    try requireCurrent(reader);
    try t.expectEqual(1, try sql.integer(reader, "SELECT count(*) FROM subscriptions WHERE reference='news-1'", .{}));
}

fn normalizedSql(a: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var pending_space = false;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quote != 0) {
            // Keep quoted text verbatim: a doubled quote is an escape, not the
            // end of the literal, and spaces inside it are significant.
            try out.append(a, c);
            if (c == quote) {
                if (i + 1 < text.len and text[i + 1] == quote) {
                    try out.append(a, text[i + 1]);
                    i += 1;
                } else quote = 0;
            }
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            pending_space = out.items.len != 0;
            continue;
        }
        if (pending_space) {
            pending_space = false;
            const previous = out.items[out.items.len - 1];
            if (c != ')' and c != ',' and c != ';' and previous != '(') try out.append(a, ' ');
        }
        try out.append(a, c);
        if (c == '\'' or c == '"') quote = c;
    }
    return out.toOwnedSlice(a);
}

test "a fresh baseline and an upgraded legacy fixture end at the same schema" {
    const t = std.testing;
    const fresh = try sql.open(t.allocator, ":memory:", .{ .initialize = null });
    defer fresh.close();
    try initialize(t.allocator, fresh, null);

    const upgraded = try sql.open(t.allocator, ":memory:", .{ .initialize = null });
    defer upgraded.close();
    try sql.exec(upgraded, legacy_with_cursor);
    try sql.exec(upgraded, std.fmt.comptimePrint("PRAGMA application_id={d}", .{legacy_cursor_id}));
    try initialize(t.allocator, upgraded, null);

    // The fixture models the post-feed schema at e2879d5 (#18); it omits the
    // retired #17 feeds/feed_messages tables, which the upgrade path leaves in
    // place. The ledger itself is checked apart.
    const query = "SELECT type, name, tbl_name, sql FROM sqlite_schema " ++
        "WHERE name NOT GLOB 'sqlite_*' AND name <> '" ++ ledger_table ++ "' ORDER BY type, name";
    const left = try sql.statement(fresh, query, .{});
    defer left.deinit();
    const right = try sql.statement(upgraded, query, .{});
    defer right.deinit();
    var count: usize = 0;
    while (try sql.checked(left.step())) : (count += 1) {
        try t.expect(try sql.checked(right.step()));
        inline for (0..3) |column| {
            try t.expectEqualStrings(try sql.requiredText(left, column), try sql.requiredText(right, column));
        }
        const expected_sql = try normalizedSql(t.allocator, try sql.requiredText(left, 3));
        defer t.allocator.free(expected_sql);
        const actual_sql = try normalizedSql(t.allocator, try sql.requiredText(right, 3));
        defer t.allocator.free(actual_sql);
        try t.expectEqualStrings(expected_sql, actual_sql);
    }
    try t.expect(!try sql.checked(right.step()));
    try t.expect(count > 0);
}

test "startup and listener reject a dirty migration ledger and preserve the database" {
    const t = std.testing;
    const conn = try sql.open(t.allocator, ":memory:", .{ .initialize = null });
    defer conn.close();
    try initialize(t.allocator, conn, null);
    const dirty_id = upgrades[0].id;
    try sql.exec(conn, std.fmt.comptimePrint("UPDATE " ++ ledger_table ++ " SET dirty=1 WHERE id='{s}'", .{dirty_id}));
    try t.expectError(error.IncompatibleStateSchema, requireCurrent(conn));
    try t.expectError(error.IncompatibleStateSchema, initialize(t.allocator, conn, null));
    try t.expectEqual(ledger_format, try sql.integer(conn, "PRAGMA user_version", .{}));
    try t.expectEqual(@as(i64, upgrades.len), try sql.integer(conn, "SELECT count(*) FROM " ++ ledger_table, .{}));
    try t.expectEqual(@as(i64, 1), try sql.integer(conn, "SELECT count(*) FROM " ++ ledger_table ++ " WHERE id='" ++ dirty_id ++ "' AND dirty=1", .{}));
}

test "startup and listener reject newer migrations while retaining the ledger" {
    const t = std.testing;
    const conn = try sql.open(t.allocator, ":memory:", .{ .initialize = null });
    defer conn.close();
    try initialize(t.allocator, conn, null);
    try sql.exec(conn, "INSERT INTO " ++ ledger_table ++ " (id,name,checksum,class) VALUES('9999_future','','future','startup')");
    try t.expectError(error.IncompatibleStateSchema, requireCurrent(conn));
    try t.expectError(error.IncompatibleStateSchema, initialize(t.allocator, conn, null));
    try t.expectEqual(@as(i64, upgrades.len + 1), try sql.integer(conn, "SELECT count(*) FROM " ++ ledger_table, .{}));
    try t.expectEqual(ledger_format, try sql.integer(conn, "PRAGMA user_version", .{}));
}

test "startup and listener reject a changed migration checksum" {
    const t = std.testing;
    const conn = try sql.open(t.allocator, ":memory:", .{ .initialize = null });
    defer conn.close();
    try initialize(t.allocator, conn, null);
    try sql.exec(conn, "UPDATE " ++ ledger_table ++ " SET checksum='changed'");
    try t.expectError(error.IncompatibleStateSchema, requireCurrent(conn));
    try t.expectError(error.IncompatibleStateSchema, initialize(t.allocator, conn, null));
    try t.expectEqual(@as(i64, upgrades.len), try sql.integer(conn, "SELECT count(*) FROM " ++ ledger_table ++ " WHERE checksum='changed'", .{}));
}

test "a matching checkpoint can resume before the database has been marked bound" {
    const t = std.testing;
    const conn = try sql.open(t.allocator, ":memory:", .{ .initialize = null });
    defer conn.close();
    try t.expectError(error.SubscriptionCatalogMismatch, initialize(t.allocator, conn, test_catalog));
    try t.expectEqual(0, try sql.integer(conn, "SELECT count(*) FROM sqlite_schema", .{}));
    try initialize(t.allocator, conn, null);
    const binding = try sql.mailboxBinding(conn);
    try t.expect(!binding.bound);
    try initialize(t.allocator, conn, binding.identity);
    try t.expectEqual(binding, try sql.mailboxBinding(conn));
}
