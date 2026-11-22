const std = @import("std");
const subscriptions = @import("subscriptions");

const usage =
    \\Usage: ivenna-report inspect|publish|checkpoint SUBSCRIPTION_ID
    \\
    \\Use the ID returned by subscribe and set DATA_DIR to that instance's directory.
    \\inspect      Print the registration and its progress, or null if none exists.
    \\publish      Save an observation for the owning focus. Prints "accepted" or "duplicate".
    \\checkpoint   Update progress or follow status without waking the focus. Prints "accepted".
    \\
    \\publish and checkpoint read one JSON object (up to 64 KiB) from stdin.
    \\For an existing subscription with ID releases-1, a listener can publish from sh:
    \\  printf '%s\n' '{"key":"release-17","text":"Release 17 is available","progress":"17"}' |
    \\    "$IVENNA_REPORT" publish releases-1
    \\
    \\Use a distinct key for each observation. Key and text limits are 256 and 2048 UTF-8 bytes.
    \\Retry the same report with its original key. To advance the saved cursor:
    \\  printf '%s\n' '{"expected_progress":"17","progress":"18"}' | "$IVENNA_REPORT" checkpoint releases-1
    \\
    \\Reports can include source_time_unix_ms, version, truncated, and a handle with
    \\retrieval set to "current" or "version". Set external to true in a checkpoint before
    \\requesting an external follow, then to false once the publisher confirms closure.
    \\
    \\Read the JSON result on stdout. Rejections exit nonzero.
    \\  "withdrawn"          Stop reporting on this reference.
    \\  "progress_conflict"  Inspect the saved cursor before advancing it.
    \\  "busy"               Retry after contention subsides.
    \\  "storage_full"       Free storage before retrying.
    \\  "invalid_request"    Correct the arguments or JSON input.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    run(init) catch |err| {
        const reason: []const u8 = switch (err) {
            error.SubscriptionWithdrawn => "withdrawn",
            error.ProgressConflict => "progress_conflict",
            error.SubscriptionStoreBusy => "busy",
            error.SubscriptionStoreFull => "storage_full",
            error.InvalidArguments, error.StreamTooLong => "invalid_request",
            else => return err,
        };
        try output(init.io, init.arena.allocator(), reason);
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
    if (action == .inspect) return output(init.io, a, try store.inspect(a, reference));

    // Bound the single submission, including escaped UTF-8 and JSON syntax.
    var buf: [4096]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(init.io, &buf);
    const json = try input.interface.allocRemaining(a, .limited(64 * 1024));
    switch (action) {
        .publish => {
            const report = try parse(subscriptions.NewReport, a, json);
            const received_unix_ms = std.Io.Clock.real.now(init.io).toMilliseconds();
            try output(init.io, a, try store.publish(reference, report, received_unix_ms));
        },
        .checkpoint => {
            const state = try parse(subscriptions.Checkpoint, a, json);
            try store.checkpoint(reference, state);
            try output(init.io, a, "accepted");
        },
        .inspect => unreachable,
    }
}

fn parse(comptime T: type, a: std.mem.Allocator, json: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidArguments,
    };
}

fn output(io: std.Io, a: std.mem.Allocator, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(a, value, .{});
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}
