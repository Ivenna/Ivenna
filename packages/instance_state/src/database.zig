const std = @import("std");
const sqlite = @import("sqlite");
const zqlite = sqlite.zqlite;
const c = zqlite.c;
const Allocator = std.mem.Allocator;

pub const filename = "state.sqlite3";
const application_id = std.mem.readInt(u32, "IVST", .big);
const schema_version = 1;
const session_snapshot_application_id = std.mem.readInt(u32, "IVS3", .big);
pub const OpenMode = enum { initialize, existing };

pub fn open(a: Allocator, path: []const u8, mode: OpenMode) !zqlite.Conn {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArguments;
    const path_z = try a.dupeSentinel(u8, path, 0);
    defer a.free(path_z);
    const flags = switch (mode) {
        .initialize => c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
        .existing => c.SQLITE_OPEN_READWRITE,
    };
    const conn = try connect(path_z, flags);
    // Closing a failed startup connection rolls back any uncommitted migration.
    errdefer conn.close();
    if (c.sqlite3_db_readonly(conn.conn, "main") == 1) {
        std.log.err("instance database '{s}' is read-only", .{path});
        return error.StateStorageFailed;
    }
    try checked(conn.busyTimeout(5000));
    try exec(conn, "PRAGMA foreign_keys=ON");
    try exec(conn, "PRAGMA synchronous=FULL");
    if (mode == .initialize) {
        try migrateSchema(conn);
        try exec(conn, "PRAGMA journal_mode=WAL");
    } else if (try integer(conn, "PRAGMA application_id", .{}) != application_id or
        try integer(conn, "PRAGMA user_version", .{}) != schema_version)
    {
        return error.IncompatibleStateSchema;
    }
    return conn;
}

/// Read the mailbox binding identity without migrating or enforcing the
/// current schema version. Startup compares it with the mailbox checkpoint
/// before `open(.initialize)` is allowed to rewrite a legacy database.
pub fn mailboxIdentity(a: Allocator, io: std.Io, path: []const u8) !?[32]u8 {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArguments;
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const path_z = try a.dupeSentinel(u8, path, 0);
    defer a.free(path_z);
    const conn = try connect(path_z, c.SQLITE_OPEN_READWRITE);
    defer conn.close();
    try checked(conn.busyTimeout(5000));
    if (try integer(conn, "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name='mailbox_binding')", .{}) == 0)
        return null;
    const s = try statement(conn, "SELECT identity FROM mailbox_binding WHERE singleton=1", .{});
    defer s.deinit();
    if (!try checked(s.step())) return error.InvalidStateDatabase;
    const id = try requiredText(s, 0);
    if (id.len != 32) return error.InvalidStateDatabase;
    return id[0..32].*;
}

fn connect(path: [:0]const u8, flags: c_int) !zqlite.Conn {
    var handle: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(path.ptr, &handle, flags, null);
    if (rc == c.SQLITE_OK) return .{ .conn = handle.? };
    // SQLite can allocate a handle even when opening the database fails.
    defer if (handle) |db| {
        _ = c.sqlite3_close(db);
    };
    return switch (rc) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.StateStoreBusy,
        c.SQLITE_FULL => error.StateStoreFull,
        c.SQLITE_NOMEM => error.OutOfMemory,
        else => blk: {
            const message = if (handle) |db| c.sqlite3_errmsg(db) else c.sqlite3_errstr(rc);
            std.log.err("opening instance database '{s}': {s}", .{ path, std.mem.span(message) });
            break :blk error.StateStorageFailed;
        },
    };
}

fn migrateSchema(conn: zqlite.Conn) !void {
    try exec(conn, "BEGIN IMMEDIATE");
    const id = try integer(conn, "PRAGMA application_id", .{});
    const recorded_version = try integer(conn, "PRAGMA user_version", .{});
    if (id != application_id and recorded_version != 0) return error.IncompatibleStateSchema;
    const installed_version = switch (id) {
        application_id => recorded_version,
        0 => installed: {
            if (try integer(conn, "SELECT EXISTS(SELECT 1 FROM sqlite_schema)", .{}) != 0)
                return error.IncompatibleStateSchema;
            try exec(conn, @embedFile("schema.sql"));
            break :installed schema_version;
        },
        std.mem.readInt(u32, "IVDB", .big),
        std.mem.readInt(u32, "IVS2", .big),
        session_snapshot_application_id,
        => installed: {
            // The session snapshot omitted the cursor on creation and kept it on upgrade.
            if (id != session_snapshot_application_id or
                try integer(conn, "SELECT EXISTS(SELECT 1 FROM pragma_table_xinfo('subscriptions') WHERE name='cursor')", .{}) != 0)
            {
                try exec(conn, "ALTER TABLE subscriptions DROP COLUMN cursor");
            }
            break :installed 1;
        },
        else => return error.IncompatibleStateSchema,
    };
    if (installed_version != schema_version) return error.IncompatibleStateSchema;
    if (id != application_id) {
        try exec(conn, std.fmt.comptimePrint("PRAGMA application_id={d}", .{application_id}));
        try exec(conn, std.fmt.comptimePrint("PRAGMA user_version={d}", .{schema_version}));
    }
    try exec(conn, "COMMIT");
}

/// Test-only connection for inspecting a legacy database without migrating it.
pub fn openRawForTest(a: Allocator, path: []const u8) !zqlite.Conn {
    if (!@import("builtin").is_test) @compileError("only tests can open an unchecked database");
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArguments;
    const path_z = try a.dupeSentinel(u8, path, 0);
    defer a.free(path_z);
    return connect(path_z, c.SQLITE_OPEN_READWRITE);
}

pub fn exec(conn: zqlite.Conn, query: [:0]const u8) !void {
    try checked(conn.execNoArgs(query.ptr));
}

pub fn rollback(conn: zqlite.Conn) void {
    if (c.sqlite3_get_autocommit(conn.conn) != 0) return;
    conn.execNoArgs("ROLLBACK") catch |err| std.log.err("state database rollback failed: {s}", .{@errorName(err)});
}

pub fn statement(conn: zqlite.Conn, query: [:0]const u8, args: anytype) !zqlite.Stmt {
    // zqlite binds text with SQLite's 32-bit length parameter.
    inline for (args) |arg| {
        if (@TypeOf(arg) == []const u8 or @TypeOf(arg) == ?[]const u8) {
            if (@as(?[]const u8, arg)) |value| if (value.len > std.math.maxInt(c_int)) return error.InvalidArguments;
        }
    }
    const s = try checked(conn.prepare(query));
    errdefer s.deinit();
    try checked(s.bind(args));
    return s;
}

pub fn integer(conn: zqlite.Conn, query: [:0]const u8, args: anytype) !i64 {
    const s = try statement(conn, query, args);
    defer s.deinit();
    if (!try checked(s.step())) return error.InvalidStateDatabase;
    return s.int(0);
}

pub fn requiredText(s: zqlite.Stmt, i: usize) ![]const u8 {
    return sqlite.text(s, i) catch |err| switch (err) {
        error.NullColumn => error.InvalidStateDatabase,
        error.OutOfMemory => error.OutOfMemory,
    };
}

pub fn copyText(a: Allocator, s: zqlite.Stmt, i: usize) ![]const u8 {
    return a.dupe(u8, try requiredText(s, i));
}

pub fn signed(n: u64) !i64 {
    return std.math.cast(i64, n) orelse error.InvalidArguments;
}

pub fn unsigned(n: i64) !u64 {
    return std.math.cast(u64, n) orelse error.InvalidStateDatabase;
}

pub fn checked(result: anytype) !@typeInfo(@TypeOf(result)).error_union.payload {
    return result catch |err| switch (err) {
        error.Busy, error.Locked => error.StateStoreBusy,
        error.Full => error.StateStoreFull,
        error.NoMem => error.OutOfMemory,
        error.TooBig => error.InvalidArguments,
        else => {
            std.log.err("state database operation failed: {s}", .{@errorName(err)});
            return error.StateStorageFailed;
        },
    };
}

test "initialization and existing open preserve an incompatible database" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, filename });
    const prior = try connect(try a.dupeSentinel(u8, path, 0), c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE);
    defer prior.close();
    try exec(prior, "CREATE TABLE notes(text TEXT)");
    try exec(prior, "INSERT INTO notes VALUES('keep me')");
    try t.expectError(error.IncompatibleStateSchema, open(a, path, .existing));
    try t.expectError(error.IncompatibleStateSchema, open(a, path, .initialize));
    try t.expectEqual(1, try integer(prior, "SELECT count(*) FROM notes WHERE text='keep me'", .{}));
    try t.expectEqual(0, try integer(prior, "PRAGMA application_id", .{}));

    // An empty database with another application's marker is already claimed.
    try exec(prior, "DROP TABLE notes");
    const other_id = std.mem.readInt(u32, "TEST", .big);
    try exec(prior, std.fmt.comptimePrint("PRAGMA application_id={d}", .{other_id}));
    try t.expectError(error.IncompatibleStateSchema, open(a, path, .existing));
    try t.expectError(error.IncompatibleStateSchema, open(a, path, .initialize));
    try t.expectEqual(other_id, try integer(prior, "PRAGMA application_id", .{}));
}

test "startup removes legacy cursors and preserves subscription state" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(t.io, ".", a);
    const cases = .{
        .{ "IVDB", true },
        .{ "IVS3", true },
        .{ "IVS3", false },
    };
    inline for (cases, 0..) |case, index| {
        const old_id, const has_cursor = case;
        const path = try std.fs.path.join(a, &.{ directory, std.fmt.comptimePrint("state-{d}.sqlite3", .{index}) });
        {
            const legacy = try connect(try a.dupeSentinel(u8, path, 0), c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE);
            defer legacy.close();
            try exec(legacy, @embedFile("schema.sql"));
            try exec(legacy, std.fmt.comptimePrint("PRAGMA application_id={d}", .{std.mem.readInt(u32, old_id, .big)}));
            try exec(legacy,
                \\UPDATE mailbox_binding SET identity='0123456789abcdef0123456789abcdef', bound=1;
                \\INSERT INTO subscriptions(id,name,focus_id,listener) VALUES(3,'news','core-1','Release feed');
                \\INSERT INTO subscription_reports(sequence,reference,focus_id,text,source_time,received)
                \\VALUES(7,'news-3','core-1','New release',120,123);
                \\INSERT INTO accepted_report_keys(subscription_id,key) VALUES(3,'report-17');
            );
            if (has_cursor) {
                try exec(legacy, "ALTER TABLE subscriptions ADD COLUMN cursor TEXT");
                try exec(legacy, "UPDATE subscriptions SET cursor='17'");
            }
        }

        (try open(a, path, .initialize)).close();
        const current = try open(a, path, .existing);
        defer current.close();
        try t.expectEqual(0, try integer(current, "SELECT count(*) FROM pragma_table_xinfo('subscriptions') WHERE name='cursor'", .{}));
        try t.expectEqual(1, try integer(current, "SELECT bound FROM mailbox_binding WHERE identity='0123456789abcdef0123456789abcdef'", .{}));
        try t.expectEqual(1, try integer(current, "SELECT count(*) FROM subscriptions WHERE reference='news-3' AND focus_id='core-1' AND listener='Release feed'", .{}));
        try t.expectEqual(1, try integer(current, "SELECT count(*) FROM subscription_reports WHERE sequence=7 AND reference='news-3' AND text='New release' AND source_time=120 AND received=123", .{}));
        try t.expectEqual(1, try integer(current, "SELECT count(*) FROM accepted_report_keys WHERE subscription_id=3 AND key='report-17'", .{}));
    }
}

test "open rejects a newer schema version without changing it" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = t.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(t.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, filename });
    const current = try open(a, path, .initialize);
    defer current.close();
    const newer = schema_version + 1;
    try exec(current, std.fmt.comptimePrint("PRAGMA user_version={d}", .{newer}));
    try t.expectError(error.IncompatibleStateSchema, open(a, path, .existing));
    try t.expectError(error.IncompatibleStateSchema, open(a, path, .initialize));
    try t.expectEqual(newer, try integer(current, "PRAGMA user_version", .{}));
}
