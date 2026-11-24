const std = @import("std");
const sqlite = @import("sqlite");
const zqlite = sqlite.zqlite;
const c = zqlite.c;
const Allocator = std.mem.Allocator;

pub const filename = "state.sqlite3";
const application_id = std.mem.readInt(u32, "IVDB", .big);
const OpenMode = enum { initialize, read_write };

pub fn initialize(a: Allocator, path: []const u8) !void {
    const conn = try open(a, path, .initialize);
    conn.close();
}

pub fn open(a: Allocator, path: []const u8, mode: OpenMode) !zqlite.Conn {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArguments;
    const path_z = try a.dupeSentinel(u8, path, 0);
    defer a.free(path_z);
    const flags = switch (mode) {
        .initialize => c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
        .read_write => c.SQLITE_OPEN_READWRITE,
    };
    const conn = try connect(path_z, flags);
    errdefer conn.close();
    try checked(conn.busyTimeout(5000));
    try exec(conn, "PRAGMA foreign_keys=ON");
    try exec(conn, "PRAGMA synchronous=FULL");
    if (mode == .initialize) {
        try installSchema(conn);
        try exec(conn, "PRAGMA journal_mode=WAL");
    } else if (try integer(conn, "PRAGMA application_id", .{}) != application_id) {
        return error.IncompatibleStateSchema;
    }
    return conn;
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

fn installSchema(conn: zqlite.Conn) !void {
    // Claim an empty file with the schema and format marker together.
    try exec(conn, "BEGIN IMMEDIATE");
    errdefer rollback(conn);
    const format = try integer(conn, "PRAGMA application_id", .{});
    if (format != application_id) {
        if (format != 0 or try integer(conn, "SELECT EXISTS(SELECT 1 FROM sqlite_schema)", .{}) != 0)
            return error.IncompatibleStateSchema;
        try exec(conn, @embedFile("schema.sql"));
        try exec(conn, std.fmt.comptimePrint("PRAGMA application_id={d}", .{application_id}));
    }
    try exec(conn, "COMMIT");
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
    try t.expectError(error.IncompatibleStateSchema, open(a, path, .read_write));
    try t.expectError(error.IncompatibleStateSchema, initialize(a, path));
    try t.expectEqual(1, try integer(prior, "SELECT count(*) FROM notes WHERE text='keep me'", .{}));
    try t.expectEqual(0, try integer(prior, "PRAGMA application_id", .{}));

    // An empty database with another application's marker is already claimed.
    try exec(prior, "DROP TABLE notes");
    const other_id = std.mem.readInt(u32, "TEST", .big);
    try exec(prior, std.fmt.comptimePrint("PRAGMA application_id={d}", .{other_id}));
    try t.expectError(error.IncompatibleStateSchema, open(a, path, .read_write));
    try t.expectError(error.IncompatibleStateSchema, initialize(a, path));
    try t.expectEqual(other_id, try integer(prior, "PRAGMA application_id", .{}));
}
