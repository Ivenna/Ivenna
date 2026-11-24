pub const zqlite = @import("zqlite");
const c = zqlite.c;

/// A null result for a required value can also mean conversion ran out of memory.
pub fn text(s: zqlite.Stmt, i: usize) ![]const u8 {
    const ptr = c.sqlite3_column_text(s.stmt, @intCast(i));
    if (ptr == null) {
        if (c.sqlite3_errcode(s.conn) == c.SQLITE_NOMEM) return error.OutOfMemory;
        return error.NullColumn;
    }
    return ptr[0..s.columnBytes(i)];
}
