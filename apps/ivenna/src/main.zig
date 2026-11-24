const std = @import("std");
const state = @import("instance_state");
const cli = @import("cli.zig");
const serve = @import("serve.zig");
const subscription = @import("subscription.zig");

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const command = cli.parse(a, args[1..]) catch |err| return failure(init.io, err);
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
        std.log.err("set DATA_DIR to the kernel's data directory", .{});
        return error.MissingDataDirectory;
    }
    const path = try std.fs.path.join(a, &.{ directory, state.filename });
    switch (command) {
        .feed => |query| {
            var reader = try state.feeds.Reader.open(a, path);
            defer reader.close();
            try writeJson(init.io, try reader.read(a, query.channel_id, query.after, query.limit));
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

fn failure(io: std.Io, err: anyerror) !u8 {
    const reason: []const u8 = switch (err) {
        error.InvalidArguments => "invalid_request",
        error.UnknownChannel => "unknown_channel",
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
