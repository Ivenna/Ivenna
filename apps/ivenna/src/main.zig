const std = @import("std");
const state = @import("instance_state");
const receive = @import("receive.zig");
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
        .receive => |options| receive.run(init, options) catch |err| return failure(init.io, err),
        .subscription => |request| runSubscription(init, request) catch |err| return failure(init.io, err),
    }
    return 0;
}

fn runSubscription(init: std.process.Init, request: @FieldType(cli.Command, "subscription")) !void {
    const a = init.arena.allocator();
    const directory = init.environ_map.get("DATA_DIR") orelse "";
    if (directory.len == 0) {
        std.log.err("set DATA_DIR to the instance's data directory", .{});
        return error.MissingDataDirectory;
    }
    const path = try std.fs.path.join(a, &.{ directory, state.filename });
    var store = try state.subscriptions.Store.open(a, path);
    defer store.close();
    switch (request.action) {
        .inspect => try cli.writeJson(init.io, try store.inspect(a, request.id)),
        .publish => try cli.writeJson(init.io, try subscription.publish(a, init.io, &store, request.id)),
        .checkpoint => {
            try subscription.checkpoint(a, init.io, &store, request.id);
            try cli.writeJson(init.io, "accepted");
        },
    }
}

fn failure(io: std.Io, err: anyerror) !u8 {
    const reason: []const u8 = switch (err) {
        error.InvalidArguments => "invalid_request",
        error.SubscriptionWithdrawn => "withdrawn",
        error.CursorConflict => "cursor_conflict",
        error.StateStoreBusy => "busy",
        error.StateStoreFull => "storage_full",
        error.InvalidReceiveArguments, error.MissingDataDirectory, error.StateStorageFailed => return 1,
        error.UnknownChannel => {
            std.log.err("no open channel matches CHANNEL_ID in this instance", .{});
            return 1;
        },
        error.ChannelServiceUnavailable => {
            std.log.err("the channel service is unavailable. Check DATA_DIR and the running instance before retrying", .{});
            return 1;
        },
        error.InvalidMessage => {
            std.log.err("the channel message contains invalid UTF-8", .{});
            return 1;
        },
        else => {
            std.log.err("{s}", .{@errorName(err)});
            return 1;
        },
    };
    try cli.writeJson(io, reason);
    return 1;
}
