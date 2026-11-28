const std = @import("std");
const receive = @import("receive.zig");
const cli = @import("cli.zig");
const serve = @import("serve.zig");
const subscription = @import("subscription.zig");

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const command = cli.parse(args[1..]) catch return 1;
    switch (command) {
        .serve => try serve.run(init),
        .help => |help| try std.Io.File.stdout().writeStreamingAll(init.io, help),
        .receive => |id| receive.run(init, id) catch |err| switch (err) {
            error.BrokenPipe => return 0,
            else => return failure(init.io, err),
        },
        .listen => |id| subscription.run(init, id) catch |err| return failure(init.io, err),
    }
    return 0;
}

fn reportBrokenPipe() void {
    std.log.err("the subscription output closed before a reply could be written. A report may already be stored. Retry any unconfirmed report with its original key", .{});
}

fn failure(io: std.Io, err: anyerror) !u8 {
    if (subscription.errorReceipt(err)) |reason| {
        cli.writeJson(io, reason) catch |write_err| switch (write_err) {
            error.BrokenPipe => {
                reportBrokenPipe();
                return 1;
            },
            else => return write_err,
        };
        return 1;
    }
    switch (err) {
        error.MissingDataDirectory, error.StateStorageFailed => return 1,
        error.BrokenPipe => {
            reportBrokenPipe();
            return 1;
        },
        error.IncompatibleStateSchema => {
            std.log.err("the listener cannot use this instance database schema. Check DATA_DIR and use the same build for the listener and kernel. After updating, start the kernel before connecting the listener", .{});
            return 1;
        },
        error.UnknownChannel => {
            std.log.err("no open channel matches CHANNEL_ID. Check the complete ID and DATA_DIR", .{});
            return 1;
        },
        error.ChannelServiceUnavailable => {
            std.log.err("the channel service is unavailable. Check that the kernel for DATA_DIR is running and uses the same Ivenna build as the receiver", .{});
            return 1;
        },
        error.InvalidChannelReply => {
            std.log.err("the channel service returned an invalid reply. Check that 'ivenna serve' and 'ivenna channel receive' use the same build", .{});
            return 1;
        },
        else => {
            std.log.err("{s}", .{@errorName(err)});
            return 1;
        },
    }
}
