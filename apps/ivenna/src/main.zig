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
            else => return channelFailure(err),
        },
        .listen => |id| return subscription.run(init, id),
    }
    return 0;
}

fn channelFailure(err: anyerror) u8 {
    switch (err) {
        error.MissingDataDirectory => {},
        error.UnknownChannel => std.log.err("no open channel matches CHANNEL_ID. Check the complete channel ID and DATA_DIR", .{}),
        error.ChannelServiceUnavailable => std.log.err("the channel connection failed or ended without a closing reply. Check that the kernel for DATA_DIR is running and uses the same build as the receiver", .{}),
        error.InvalidChannelReply => std.log.err("invalid reply from the channel service. Check that 'ivenna serve' and 'ivenna channel receive' use the same build", .{}),
        else => std.log.err("{s}", .{@errorName(err)}),
    }
    return 1;
}
