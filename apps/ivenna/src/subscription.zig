const std = @import("std");
const subscriptions = @import("instance_state").subscriptions;
const Allocator = std.mem.Allocator;

pub fn publish(a: Allocator, io: std.Io, store: *subscriptions.Store, id: []const u8) !subscriptions.PublishResult {
    const report = try readInput(struct {
        key: Scalar([]const u8),
        text: Scalar([]const u8),
        source_time_unix_ms: ?Scalar(i64) = null,
        cursor: ?Cursor = null,
    }, a, io);
    return store.publish(id, .{
        .key = report.key.value,
        .text = report.text.value,
        .source_time_unix_ms = if (report.source_time_unix_ms) |time| time.value else null,
        .cursor = if (report.cursor) |cursor| cursor.move() else null,
    }, std.Io.Clock.real.now(io).toMilliseconds());
}

pub fn checkpoint(a: Allocator, io: std.Io, store: *subscriptions.Store, id: []const u8) !void {
    const cursor = try readInput(Cursor, a, io);
    try store.checkpoint(id, cursor.move());
}

const Cursor = struct {
    from: ?Scalar([]const u8) = null,
    to: Scalar([]const u8),

    fn move(self: Cursor) subscriptions.Cursor {
        return .{ .from = if (self.from) |from| from.value else null, .to = self.to.value };
    }
};

// Require JSON strings for text and JSON numbers for timestamps.
fn Scalar(comptime T: type) type {
    return struct {
        value: T,

        pub fn jsonParse(a: Allocator, json: *std.json.Reader, options: std.json.ParseOptions) !@This() {
            const expected: std.json.TokenType = if (T == []const u8) .string else .number;
            if (try json.peekNextTokenType() != expected) return error.UnexpectedToken;
            return .{ .value = try std.json.innerParse(T, a, json, options) };
        }
    };
}

fn readInput(comptime T: type, a: Allocator, io: std.Io) !T {
    var buffer: [4096]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(io, &buffer);
    var json = std.json.Reader.init(a, &input.interface);
    defer json.deinit();
    var diagnostics: std.json.Diagnostics = .{};
    json.enableDiagnostics(&diagnostics);
    return std.json.parseFromTokenSourceLeaky(T, a, &json, .{}) catch |err| switch (err) {
        error.OutOfMemory, error.ReadFailed => return err,
        else => {
            std.log.err("invalid JSON request on stdin at line {d}, column {d} ({s})", .{ diagnostics.getLine(), diagnostics.getColumn(), @errorName(err) });
            return error.InvalidArguments;
        },
    };
}
