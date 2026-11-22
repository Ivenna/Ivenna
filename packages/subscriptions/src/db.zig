const std = @import("std");
const zqlite = @import("zqlite");
const c = zqlite.c;

pub fn checked(result: anytype) !@typeInfo(@TypeOf(result)).error_union.payload {
    return result catch |err| switch (err) {
        error.Busy, error.Locked => error.SubscriptionStoreBusy,
        error.Full => error.SubscriptionStoreFull,
        error.NoMem => error.OutOfMemory,
        error.TooBig => error.InvalidArguments,
        else => {
            std.log.err("subscription store: {s}", .{@errorName(err)});
            return error.SubscriptionStorageFailed;
        },
    };
}

/// sqlite3_open_v2 can return an allocated connection even on failure.
pub fn open(path: [:0]const u8, flags: c_int) !zqlite.Conn {
    var handle: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open_v2(path.ptr, &handle, flags, null);
    if (rc == c.SQLITE_OK) return .{ .conn = handle.? };
    if (handle) |db| _ = c.sqlite3_close(db);
    return switch (rc) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.SubscriptionStoreBusy,
        c.SQLITE_FULL => error.SubscriptionStoreFull,
        c.SQLITE_NOMEM => error.OutOfMemory,
        else => error.SubscriptionStorageFailed,
    };
}

/// A null result for a required value can also mean conversion ran out of memory.
pub fn text(s: zqlite.Stmt, i: usize) ![]const u8 {
    const ptr = c.sqlite3_column_text(s.stmt, @intCast(i));
    if (ptr == null) {
        if (c.sqlite3_errcode(s.conn) == c.SQLITE_NOMEM) return error.OutOfMemory;
        return error.InvalidSubscriptionDatabase;
    }
    return ptr[0..s.columnBytes(i)];
}

pub fn copyText(a: std.mem.Allocator, s: zqlite.Stmt, i: usize) ![]const u8 {
    return a.dupe(u8, try text(s, i));
}

pub fn signed(n: u64) !i64 {
    return std.math.cast(i64, n) orelse error.InvalidArguments;
}

pub fn unsigned(n: i64) !u64 {
    return std.math.cast(u64, n) orelse error.InvalidSubscriptionDatabase;
}
