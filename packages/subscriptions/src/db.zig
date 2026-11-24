const std = @import("std");
const sqlite = @import("sqlite");
const zqlite = sqlite.zqlite;

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

pub fn open(path: [:0]const u8, flags: c_int) !zqlite.Conn {
    return checked(sqlite.open(path, flags));
}

pub fn text(s: zqlite.Stmt, i: usize) ![]const u8 {
    return sqlite.text(s, i) catch |err| switch (err) {
        error.NullColumn => error.InvalidSubscriptionDatabase,
        error.OutOfMemory => error.OutOfMemory,
    };
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
