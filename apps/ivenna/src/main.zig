const std = @import("std");
const state = @import("instance_state");
const cli = @import("cli.zig");
const serve = @import("serve.zig");
const subscription = @import("subscription.zig");

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const command = cli.parse(args[1..]) catch |err| return failure(init.io, err);
    switch (command) {
        .serve => try serve.run(init),
        .help => |help| try std.Io.File.stdout().writeStreamingAll(init.io, help),
        else => localCommand(init, command) catch |err| return failure(init.io, err),
    }
    return 0;
}

fn localCommand(init: std.process.Init, command: cli.Command) !void {
    const a = init.arena.allocator();
    const directory = init.environ_map.get("DATA_DIR") orelse "";
    if (directory.len == 0) {
        std.log.err("set DATA_DIR to the instance's data directory", .{});
        return error.MissingDataDirectory;
    }
    const path = try std.fs.path.join(a, &.{ directory, state.filename });
    switch (command) {
        .feed => |query| {
            var reader = try state.feeds.Reader.open(a, path);
            defer reader.close();
            try writeJson(init.io, try readFeed(init.io, a, &reader, query));
        },
        .subscription => |request| {
            var store = try state.subscriptions.Store.open(a, path);
            defer store.close();
            switch (request.action) {
                .inspect => try writeJson(init.io, try store.inspect(a, request.id)),
                .publish => try writeJson(init.io, try subscription.publish(a, init.io, &store, request.id)),
                .checkpoint => {
                    try subscription.checkpoint(a, init.io, &store, request.id);
                    try writeJson(init.io, "accepted");
                },
            }
        },
        .serve, .help => unreachable,
    }
}

/// How long a waiting read sleeps between looks at the database.
const feed_poll_ms: u32 = 25;
/// The longest single look waits for a writer while the read is waiting.
const feed_busy_cap_ms: u32 = 100;

/// Reads a page and, when it holds no message, keeps looking until one arrives,
/// the feed closes, or the requested wait expires. Time spent in the database
/// counts against the wait, so the deadline is absolute rather than a total of
/// sleeps. The caller owns the page.
fn readFeed(io: std.Io, a: std.mem.Allocator, reader: *state.feeds.Reader, query: cli.Feed) !state.feeds.Reader.Page {
    if (query.wait_ms == 0) return reader.read(a, query.feed_id, query.after, query.limit);
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .fromMilliseconds(query.wait_ms),
        .clock = .awake,
    });
    // Every look reuses one scratch arena that is reset between looks, so a
    // long wait does not accumulate the metadata of each empty page. Only the
    // page that ends the wait is allocated from the caller's allocator.
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    while (true) {
        const left = remainingMilliseconds(io, deadline);
        try reader.setBusyTimeout(@min(left, feed_busy_cap_ms));
        const look = reader.read(scratch.allocator(), query.feed_id, query.after, query.limit) catch |err| {
            // A writer holding the lock must not stretch the wait past its
            // deadline, and a wait should survive one that comes and goes.
            if (err != error.StateStoreBusy or left == 0) return err;
            _ = scratch.reset(.retain_capacity);
            try io.sleep(.fromMilliseconds(@min(feed_poll_ms, left)), .awake);
            continue;
        };
        const settled = look.messages.len != 0 or look.closed or left == 0;
        _ = scratch.reset(.retain_capacity);
        if (settled) return reader.read(a, query.feed_id, query.after, query.limit);
        try io.sleep(.fromMilliseconds(@max(1, @min(feed_poll_ms, left))), .awake);
    }
}

/// Whole milliseconds left before the deadline, never negative.
fn remainingMilliseconds(io: std.Io, deadline: std.Io.Clock.Timestamp) u32 {
    const left = std.Io.Clock.awake.now(io).durationTo(deadline.raw).nanoseconds;
    if (left <= 0) return 0;
    const milliseconds = @divTrunc(left, std.time.ns_per_ms);
    return if (milliseconds > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(milliseconds);
}

fn failure(io: std.Io, err: anyerror) !u8 {
    const reason: []const u8 = switch (err) {
        error.InvalidArguments => "invalid_request",
        error.UnknownFeed => "unknown_feed",
        error.SubscriptionWithdrawn => "withdrawn",
        error.CursorConflict => "cursor_conflict",
        error.StateStoreBusy => "busy",
        error.StateStoreFull => "storage_full",
        error.MissingDataDirectory, error.StateStorageFailed => return 1,
        else => {
            std.log.err("{s}", .{@errorName(err)});
            return 1;
        },
    };
    try writeJson(io, reason);
    return 1;
}

fn writeJson(io: std.Io, value: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try std.json.Stringify.value(value, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}
