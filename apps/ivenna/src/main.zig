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

/// Reads a page and, when it holds no message, keeps looking until one arrives,
/// the feed closes, or the requested wait expires. The caller owns the page.
fn readFeed(io: std.Io, a: std.mem.Allocator, reader: *state.feeds.Reader, query: cli.Feed) !state.feeds.Reader.Page {
    var page = try reader.read(a, query.feed_id, query.after, query.limit);
    var waited: u32 = 0;
    while (page.messages.len == 0 and !page.closed and waited < query.wait_ms) {
        freePage(a, page);
        const step: u32 = @min(feed_poll_ms, query.wait_ms - waited);
        try io.sleep(.fromMilliseconds(step), .awake);
        waited += step;
        page = try reader.read(a, query.feed_id, query.after, query.limit);
    }
    return page;
}

fn freePage(a: std.mem.Allocator, page: state.feeds.Reader.Page) void {
    a.free(page.feed_id);
    a.free(page.description);
    for (page.messages) |message| {
        a.free(message.focus_id);
        a.free(message.text);
    }
    a.free(page.messages);
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
