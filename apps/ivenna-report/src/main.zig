const std = @import("std");
const subscriptions = @import("subscriptions");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !u8 {
    return run(init) catch |err| {
        const reason: []const u8 = switch (err) {
            error.SubscriptionWithdrawn => "withdrawn",
            error.CursorConflict => "cursor_conflict",
            error.SubscriptionStoreBusy => "busy",
            error.SubscriptionStoreFull => "storage_full",
            error.InvalidArguments => "invalid_request",
            else => return err,
        };
        try output(init.io, reason);
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const request = try cli.read(init) orelse return 0;
    const directory = init.environ_map.get("DATA_DIR") orelse "";
    if (directory.len == 0) {
        std.log.err("set DATA_DIR to the kernel's data directory", .{});
        return 1;
    }
    var store = try subscriptions.Store.openExisting(a, try std.fs.path.join(a, &.{ directory, subscriptions.filename }));
    defer store.close();
    switch (request.command) {
        .inspect => try output(init.io, try store.inspect(a, request.reference)),
        .publish => {
            const report = try readInput(struct {
                key: Scalar([]const u8),
                text: Scalar([]const u8),
                source_time_unix_ms: ?Scalar(i64) = null,
                cursor: ?Cursor = null,
            }, a, init.io);
            const received_unix_ms = std.Io.Clock.real.now(init.io).toMilliseconds();
            try output(init.io, try store.publish(request.reference, .{
                .key = report.key.value,
                .text = report.text.value,
                .source_time_unix_ms = if (report.source_time_unix_ms) |time| time.value else null,
                .cursor = if (report.cursor) |cursor| cursor.move() else null,
            }, received_unix_ms));
        },
        .checkpoint => {
            const cursor = try readInput(Cursor, a, init.io);
            try store.checkpoint(request.reference, cursor.move());
            try output(init.io, "accepted");
        },
    }
    return 0;
}

const Cursor = struct {
    from: ?Scalar([]const u8) = null,
    to: Scalar([]const u8),

    fn move(self: Cursor) subscriptions.Cursor {
        return .{ .from = if (self.from) |from| from.value else null, .to = self.to.value };
    }
};

// The default decoder treats [65] and "A" as the same key and accepts quoted timestamps.
fn Scalar(comptime T: type) type {
    return struct {
        value: T,

        pub fn jsonParse(a: std.mem.Allocator, json: *std.json.Reader, options: std.json.ParseOptions) !@This() {
            const expected: std.json.TokenType = if (T == []const u8) .string else .number;
            if (try json.peekNextTokenType() != expected) return error.UnexpectedToken;
            return .{ .value = try std.json.innerParse(T, a, json, options) };
        }
    };
}

fn readInput(comptime T: type, a: std.mem.Allocator, io: std.Io) !T {
    var buffer: [4096]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(io, &buffer);
    var json = std.json.Reader.init(a, &input.interface);
    defer json.deinit();
    var diagnostics: std.json.Diagnostics = .{};
    json.enableDiagnostics(&diagnostics);
    return std.json.parseFromTokenSourceLeaky(T, a, &json, .{}) catch |err| switch (err) {
        error.OutOfMemory, error.ReadFailed => return err,
        else => {
            std.log.err("cannot decode request at line {d}, column {d} of stdin ({s})", .{ diagnostics.getLine(), diagnostics.getColumn(), @errorName(err) });
            return error.InvalidArguments;
        },
    };
}

fn output(io: std.Io, value: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try std.json.Stringify.value(value, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}
