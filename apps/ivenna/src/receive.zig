const std = @import("std");
const cli = @import("cli.zig");
const ipc = @import("channel_ipc.zig");
const posix = std.posix;

pub fn run(init: std.process.Init, id: []const u8) !void {
    const directory = init.environ_map.get("DATA_DIR") orelse "";
    if (directory.len == 0) {
        std.log.err("set DATA_DIR to the instance's data directory", .{});
        return error.MissingDataDirectory;
    }
    const io = init.io;
    const data_directory = std.Io.Dir.cwd().realPathFileAlloc(io, directory, init.arena.allocator()) catch |err| switch (err) {
        error.FileNotFound => return error.ChannelServiceUnavailable,
        else => return err,
    };
    const connection = try ipc.connect(io, data_directory, id);
    defer connection.close(io);
    var buffer: [ipc.response_buffer_size]u8 = undefined;
    const deadline = std.Io.Clock.Timestamp.fromNow(io, ipc.handshake_time).raw;
    switch ((try readReply(io, connection, &buffer, deadline)) orelse return) {
        .waiting => {},
        .unknown_channel => return error.UnknownChannel,
        else => return error.InvalidChannelReply,
    }

    while (try readReply(io, connection, &buffer, null)) |response| {
        switch (response) {
            .message => |text| try cli.writeJson(io, .{ .text = text }),
            .closed => return,
            else => return error.InvalidChannelReply,
        }
        if (try outputClosed()) return;
        try ipc.requestNext(connection);
    }
}

fn readReply(
    io: std.Io,
    connection: std.Io.net.Stream,
    buffer: *[ipc.response_buffer_size]u8,
    deadline: ?std.Io.Timestamp,
) !?ipc.Response {
    var descriptors = [_]posix.pollfd{
        .{ .fd = connection.socket.handle, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = std.Io.File.stdout().handle, .events = 0, .revents = 0 },
    };
    if (!try poll(io, &descriptors, deadline)) return error.ChannelServiceUnavailable;
    if (descriptors[1].revents != 0) return null;
    return try ipc.readResponse(connection, buffer);
}

fn outputClosed() !bool {
    var descriptors = [_]posix.pollfd{.{ .fd = std.Io.File.stdout().handle, .events = 0, .revents = 0 }};
    return (try posix.poll(&descriptors, 0)) != 0;
}

fn poll(io: std.Io, descriptors: []posix.pollfd, deadline: ?std.Io.Timestamp) !bool {
    while (true) {
        const timeout: ?posix.timespec = if (deadline) |end| for_wait: {
            const remaining = std.Io.Clock.awake.now(io).durationTo(end).toNanoseconds();
            if (remaining <= 0) return false;
            break :for_wait .{
                .sec = @intCast(@divTrunc(remaining, std.time.ns_per_s)),
                .nsec = @intCast(@rem(remaining, std.time.ns_per_s)),
            };
        } else null;
        const ready = posix.ppoll(descriptors, if (timeout) |*value| value else null, null) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };
        return ready != 0;
    }
}
