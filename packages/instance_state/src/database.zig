const std = @import("std");
const sqlite = @import("sqlite");
const zqlite = sqlite.zqlite;
const c = zqlite.c;
const Allocator = std.mem.Allocator;

pub const filename = "state.sqlite3";
pub const OpenMode = union(enum) { initialize: ?[32]u8, existing };

pub fn open(a: Allocator, path: []const u8, mode: OpenMode) !zqlite.Conn {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidArguments;
    const path_z = try a.dupeSentinel(u8, path, 0);
    defer a.free(path_z);
    const has_checkpoint = mode == .initialize and mode.initialize != null;
    const flags: c_int = c.SQLITE_OPEN_READWRITE | (if (mode == .initialize and !has_checkpoint) c.SQLITE_OPEN_CREATE else 0);
    const conn = try connect(path_z, flags, has_checkpoint);
    errdefer conn.close();
    if (c.sqlite3_db_readonly(conn.conn, "main") == 1) {
        std.log.err("instance database '{s}' is read-only", .{path});
        return error.StateStorageFailed;
    }
    try checked(conn.busyTimeout(5000));
    try exec(conn, "PRAGMA foreign_keys=ON");
    try exec(conn, "PRAGMA synchronous=FULL");
    return conn;
}

const MailboxBinding = struct {
    identity: [32]u8,
    bound: bool,

    pub fn matches(self: MailboxBinding, checkpoint: ?[32]u8) bool {
        return if (checkpoint) |catalog| std.mem.eql(u8, &self.identity, &catalog) else !self.bound;
    }
};

pub fn mailboxBinding(conn: zqlite.Conn) !MailboxBinding {
    const s = try statement(conn, "SELECT identity,bound FROM mailbox_binding WHERE singleton=1", .{});
    defer s.deinit();
    if (!try checked(s.step())) return error.InvalidStateDatabase;
    const id = try requiredText(s, 0);
    if (id.len != 32) return error.InvalidStateDatabase;
    return .{ .identity = id[0..32].*, .bound = s.int(1) != 0 };
}

fn connect(path: [:0]const u8, flags: c_int, has_checkpoint: bool) !zqlite.Conn {
    var handle: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(path.ptr, &handle, flags, null);
    if (rc == c.SQLITE_OK) return .{ .conn = handle.? };
    // SQLite can allocate a handle even when opening the database fails.
    defer if (handle) |db| {
        _ = c.sqlite3_close(db);
    };
    if (has_checkpoint and rc == c.SQLITE_CANTOPEN and c.sqlite3_system_errno(handle) == @backingInt(std.posix.E.NOENT))
        return error.SubscriptionCatalogMismatch;
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
