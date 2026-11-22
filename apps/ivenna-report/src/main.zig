const std = @import("std");
const subscriptions = @import("subscriptions");

const usage =
    \\Usage: ivenna-report COMMAND SUBSCRIPTION_ID
    \\
    \\Use the ID returned by subscribe. Set DATA_DIR to the kernel's data directory.
    \\inspect      Print the registration and cursor, or null for an unknown or withdrawn ID.
    \\publish      Save an observation and any cursor change together.
    \\checkpoint   Advance the cursor after processing an item that needs no report.
    \\
    \\Both writes read one JSON object from stdin. Host commands inherit IVENNA_REPORT.
    \\In another shell, set it to the executable's path to run these examples.
    \\  printf '%s\n' '{"key":"release-v2.4.0","text":"Stable release v2.4.0","cursor":{"to":"17"}}' |
    \\    "$IVENNA_REPORT" publish releases-1
    \\  printf '%s\n' '{"from":"17","to":"18"}' | "$IVENNA_REPORT" checkpoint releases-1
    \\
    \\Use a nonempty key for each distinct update and reuse it for retries. Report
    \\text takes 1–2048 UTF-8 bytes. Other strings can hold up to 4 MiB each.
    \\Optional source_time_unix_ms gives the source event time in Unix milliseconds.
    \\
    \\A successful write prints "accepted" or, for a key already accepted by this
    \\subscription, "duplicate". These JSON errors on stdout have nonzero exit status.
    \\  "withdrawn"          Stop reporting on this reference.
    \\  "cursor_conflict"    Inspect the saved cursor before advancing it.
    \\  "busy"               Retry after contention subsides.
    \\  "storage_full"       Free storage before retrying.
    \\  "invalid_request"    Correct the arguments or JSON input.
    \\If a failure leaves no JSON receipt, check stderr for diagnostics.
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
