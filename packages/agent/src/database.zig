const std = @import("std");
const pg = @import("pg");

const Allocator = std.mem.Allocator;
const Row = []const ?[]const u8;
const Result = struct {
    columns: []const []const u8,
    rows: []const Row,
    command: []const u8,
    affected: ?i64,
};

pub const Database = struct {
    allocator: Allocator,
    io: std.Io,
    database_url: []const u8,

    /// Each call has its own connection. Transactions and connection settings
    /// belong to this SQL batch and do not survive into another tool call.
    pub fn execute(self: Database, allocator: Allocator, sql: []const u8) ![]const u8 {
        var conn = try pg.Conn.openAndAuthUri(self.io, self.allocator, try std.Uri.parse(self.database_url));
        defer conn.deinit();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        return query(&conn, arena.allocator(), allocator, sql);
    }
};

fn query(conn: *pg.Conn, arena: Allocator, output: Allocator, sql: []const u8) ![]const u8 {
    // This pg.zig version has no public query API for generic text results.
    // Encode the simple Query message here; the driver still owns
    // authentication, I/O and incoming message framing.
    var packet = std.Io.Writer.Allocating.init(arena);
    defer packet.deinit();
    try packet.writer.writeByte('Q');
    try packet.writer.writeInt(u32, @intCast(sql.len + 5), .big);
    try packet.writer.writeAll(sql);
    try packet.writer.writeByte(0);
    try conn.write(packet.written());

    var results: std.array_list.Managed(Result) = .init(arena);
    var columns: []const []const u8 = &.{};
    var rows: std.array_list.Managed(Row) = .init(arena);
    while (true) {
        const message = conn.read() catch |err| switch (err) {
            error.PG => {
                const detail = conn.err.?;
                return std.json.Stringify.valueAlloc(output, .{
                    .results = results.items,
                    .@"error" = .{
                        .code = detail.code,
                        .message = detail.message,
                        .detail = detail.detail,
                    },
                }, .{});
            },
            else => return err,
        };
        switch (message.type) {
            'T' => {
                if (message.data.len < 2) return error.InvalidDatabaseRow;
                const count = std.mem.readInt(u16, message.data[0..2], .big);
                var state = try pg.Result.State.init(arena, count);
                try state.from(count, message.data, arena);
                columns = state.names;
            },
            'D' => try rows.append(try readRow(arena, message.data, columns.len)),
            'C' => {
                const end = std.mem.indexOfScalar(u8, message.data, 0) orelse return error.InvalidDatabaseResponse;
                const command = message.data[0..end];
                try results.append(.{
                    .columns = columns,
                    .rows = rows.items,
                    .command = try arena.dupe(u8, command),
                    .affected = rowsAffected(command),
                });
                columns = &.{};
                rows = .init(arena);
            },
            'I', 'A' => {}, // Empty query or asynchronous notification.
            'Z' => return std.json.Stringify.valueAlloc(output, .{ .results = results.items }, .{}),
            else => {
                const reason = try std.fmt.allocPrint(
                    arena,
                    "PostgreSQL response '{c}' is not supported by this tool. COPY streaming is not supported.",
                    .{message.type},
                );
                return std.json.Stringify.valueAlloc(output, .{
                    .results = results.items,
                    .@"error" = .{
                        .code = "unsupported_response",
                        .message = reason,
                    },
                }, .{});
            },
        }
    }
}

fn rowsAffected(command: []const u8) ?i64 {
    const separator = std.mem.lastIndexOfScalar(u8, command, ' ') orelse return null;
    return std.fmt.parseInt(i64, command[separator + 1 ..], 10) catch null;
}

fn readRow(allocator: Allocator, data: []const u8, count: usize) !Row {
    if (data.len < 2 or std.mem.readInt(u16, data[0..2], .big) != count) return error.InvalidDatabaseRow;
    const values = try allocator.alloc(?[]const u8, count);
    var position: usize = 2;
    for (values) |*value| {
        if (data.len - position < 4) return error.InvalidDatabaseRow;
        const length = std.mem.readInt(i32, data[position..][0..4], .big);
        position += 4;
        if (length == -1) {
            value.* = null;
        } else {
            if (length < 0 or length > data.len - position) return error.InvalidDatabaseRow;
            const end = position + @as(usize, @intCast(length));
            value.* = try allocator.dupe(u8, data[position..end]);
            position = end;
        }
    }
    return values;
}
