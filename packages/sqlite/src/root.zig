const std = @import("std");
pub const zqlite = @import("zqlite");
const c = zqlite.c;

/// SQLite can allocate a connection even when opening a database fails.
pub fn open(path: [:0]const u8, flags: c_int) zqlite.Error!zqlite.Conn {
    var handle: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(path.ptr, &handle, flags, null);
    if (rc == c.SQLITE_OK) return .{ .conn = handle.? };
    defer if (handle) |db| {
        _ = c.sqlite3_close(db);
    };
    const message = if (handle) |db| c.sqlite3_errmsg(db) else c.sqlite3_errstr(rc);
    std.log.err("opening SQLite database '{s}': {s}", .{ path, std.mem.span(message) });
    return switch (rc) {
        c.SQLITE_BUSY => error.Busy,
        c.SQLITE_LOCKED => error.Locked,
        c.SQLITE_FULL => error.Full,
        c.SQLITE_NOMEM => error.NoMem,
        else => error.CantOpen,
    };
}

/// A null result for a required value can also mean conversion ran out of memory.
pub fn text(s: zqlite.Stmt, i: usize) ![]const u8 {
    const ptr = c.sqlite3_column_text(s.stmt, @intCast(i));
    if (ptr == null) {
        if (c.sqlite3_errcode(s.conn) == c.SQLITE_NOMEM) return error.OutOfMemory;
        return error.NullColumn;
    }
    return ptr[0..s.columnBytes(i)];
}
