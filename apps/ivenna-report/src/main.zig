const std = @import("std");
const subscriptions = @import("subscriptions");

const usage =
    \\Usage: ivenna-report COMMAND SUBSCRIPTION_ID
    \\
    \\Use the complete ID returned by Ivenna's subscribe tool. Host commands inherit
    \\DATA_DIR (the kernel's data directory) and IVENNA_REPORT (this executable).
    \\In another shell, set DATA_DIR to the same directory. A relative path resolves
    \\from the reporter's working directory. Set IVENNA_REPORT to run the examples.
    \\
    \\inspect      Print an object with subscription_id, focus_id, listener and cursor.
    \\             A new registration has a null cursor. An unknown or withdrawn ID
    \\             returns JSON null with exit status 0.
    \\publish      Queue a report for the subscribing focus, even with the kernel
    \\             stopped. A cursor change can be committed in the same write.
    \\checkpoint   Save a source position after processing an item that needs no report.
    \\
    \\Both writes read one JSON object from stdin. These commands use a new
    \\subscription with ID releases-1.
    \\  printf '%s\n' '{"key":"release-v2.4.0","text":"Stable release v2.4.0","cursor":{"to":"17"}}' |
    \\    "$IVENNA_REPORT" publish releases-1
    \\  "$IVENNA_REPORT" inspect releases-1
    \\  printf '%s\n' '{"from":"17","to":"18"}' | "$IVENNA_REPORT" checkpoint releases-1
    \\
    \\The required publish fields are "key" and "text". Give each update a nonempty
    \\string key within its subscription and reuse it for retries. Report text is
    \\a string of 1–2048 UTF-8 bytes.
    \\Optional source_time_unix_ms gives the source time as an integer in Unix
    \\milliseconds (-62167219200000 through 253402300799000). Omit cursor to
    \\leave the saved position unchanged.
    \\
    \\For a cursor change, "to" is the new position as a string. Set "from" to the
    \\saved cursor from inspect. Omit "from" or use null to match an unset cursor.
    \\The CLI's JSON reader limits each string to 4 MiB.
    \\
    \\A successful write prints "accepted" on stdout and exits 0. A publish with
    \\an already accepted key prints "duplicate" and exits 0. The retry queues no
    \\new report and leaves the cursor in place. Errors on stdout have nonzero exit status.
    \\  "withdrawn"          Stop reporting on this reference.
    \\  "cursor_conflict"    Inspect the saved cursor before advancing it.
    \\  "busy"               Retry after contention subsides.
    \\  "storage_full"       Free storage before retrying.
    \\  "invalid_request"    Correct the arguments or JSON input.
    \\If a write returns no complete JSON receipt, check stderr. Retry publish with
    \\the original key. For checkpoint, inspect the saved position before continuing.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    run(init) catch |err| {
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
    return 0;
}

fn run(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, usage);
        return;
    }
    if (args.len != 3) {
        try std.Io.File.stderr().writeStreamingAll(init.io, usage);
        return error.InvalidArguments;
    }
    const action = std.meta.stringToEnum(enum { inspect, publish, checkpoint }, args[1]) orelse return error.InvalidArguments;
    const directory = init.environ_map.get("DATA_DIR") orelse return error.MissingDataDirectory;
    if (directory.len == 0) return error.MissingDataDirectory;
    var store = try subscriptions.Store.openExisting(a, try std.fs.path.join(a, &.{ directory, subscriptions.filename }));
    defer store.close();
    const reference = args[2];
    if (action == .inspect) return output(init.io, try store.inspect(a, reference));

    var buf: [4096]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(init.io, &buf);
    var json = std.json.Reader.init(a, &input.interface);
    defer json.deinit();
    switch (action) {
        .publish => {
            const report = try parse(struct {
                key: Scalar([]const u8),
                text: Scalar([]const u8),
                source_time_unix_ms: ?Scalar(i64) = null,
                cursor: ?Cursor = null,
            }, a, &json);
            const received_unix_ms = std.Io.Clock.real.now(init.io).toMilliseconds();
            try output(init.io, try store.publish(reference, .{
                .key = report.key.value,
                .text = report.text.value,
                .source_time_unix_ms = if (report.source_time_unix_ms) |time| time.value else null,
                .cursor = if (report.cursor) |cursor| cursor.move() else null,
            }, received_unix_ms));
        },
        .checkpoint => {
            const cursor = try parse(Cursor, a, &json);
            try store.checkpoint(reference, cursor.move());
            try output(init.io, "accepted");
        },
        .inspect => unreachable,
    }
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

fn parse(comptime T: type, a: std.mem.Allocator, json: *std.json.Reader) !T {
    return std.json.parseFromTokenSourceLeaky(T, a, json, .{}) catch |err| switch (err) {
        error.OutOfMemory, error.ReadFailed => return err,
        else => return error.InvalidArguments,
    };
}

fn output(io: std.Io, value: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try std.json.Stringify.value(value, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}
