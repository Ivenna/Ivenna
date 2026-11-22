const std = @import("std");
pub const c = @import("sqlite");

pub fn check(rc: c_int) !void {
    switch (rc) {
        c.SQLITE_OK => {},
        c.SQLITE_BUSY, c.SQLITE_LOCKED => return error.SubscriptionStoreBusy,
        c.SQLITE_NOMEM => return error.OutOfMemory,
        c.SQLITE_FULL => return error.SubscriptionStoreFull,
        else => {
            std.log.err("subscription store: SQLite returned {d} ({s})", .{ rc, c.sqlite3_errstr(rc) });
            return error.SubscriptionStorageFailed;
        },
    }
}

pub const Statement = struct {
    ptr: *c.sqlite3_stmt,

    pub fn init(db: *c.sqlite3, sql: [:0]const u8) !Statement {
        var ptr: ?*c.sqlite3_stmt = null;
        try check(c.sqlite3_prepare_v2(db, sql.ptr, -1, &ptr, null));
        return .{ .ptr = ptr.? };
    }

    pub fn deinit(self: Statement) void {
        _ = c.sqlite3_finalize(self.ptr);
    }

    pub fn bind(self: Statement, args: anytype) !void {
        inline for (args, 1..) |arg, i| try self.value(i, arg);
    }

    fn value(self: Statement, i: c_int, arg: anytype) !void {
        switch (@typeInfo(@TypeOf(arg))) {
            .optional => if (arg) |v| try self.value(i, v) else try check(c.sqlite3_bind_null(self.ptr, i)),
            .int, .comptime_int => try check(c.sqlite3_bind_int64(self.ptr, i, std.math.cast(i64, arg) orelse return error.InvalidArguments)),
            .bool => try check(c.sqlite3_bind_int64(self.ptr, i, @intFromBool(arg))),
            .@"enum" => try self.value(i, @as([]const u8, @tagName(arg))),
            .pointer => {
                const s: []const u8 = arg;
                // SQLITE_STATIC borrows these slices for the statement's lifetime.
                try check(c.sqlite3_bind_text(self.ptr, i, s.ptr, std.math.cast(c_int, s.len) orelse return error.InvalidArguments, null));
            },
            else => @compileError("unsupported SQLite argument"),
        }
    }

    pub fn next(self: Statement) !bool {
        return switch (c.sqlite3_step(self.ptr)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => |rc| {
                try check(rc);
                unreachable;
            },
        };
    }

    pub fn number(self: Statement, i: c_int) i64 {
        return c.sqlite3_column_int64(self.ptr, i);
    }

    pub fn unsigned(self: Statement, i: c_int) !u64 {
        return std.math.cast(u64, self.number(i)) orelse error.InvalidSubscriptionDatabase;
    }

    pub fn isNull(self: Statement, i: c_int) bool {
        return c.sqlite3_column_type(self.ptr, i) == c.SQLITE_NULL;
    }

    pub fn text(self: Statement, i: c_int) ![]const u8 {
        const bytes = c.sqlite3_column_text(self.ptr, i);
        if (bytes == null) return error.InvalidSubscriptionDatabase;
        return bytes[0..@intCast(c.sqlite3_column_bytes(self.ptr, i))];
    }

    pub fn copy(self: Statement, a: std.mem.Allocator, i: c_int) ![]const u8 {
        return a.dupe(u8, try self.text(i));
    }

    pub fn optionalText(self: Statement, a: std.mem.Allocator, i: c_int) !?[]const u8 {
        return if (self.isNull(i)) null else try self.copy(a, i);
    }

    pub fn tag(self: Statement, comptime T: type, i: c_int) !T {
        return std.meta.stringToEnum(T, try self.text(i)) orelse error.InvalidSubscriptionDatabase;
    }
};
