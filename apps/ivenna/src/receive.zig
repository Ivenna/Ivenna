const std = @import("std");
const cli = @import("cli.zig");
const ipc = @import("channel_ipc.zig");
const posix = std.posix;

pub fn run(init: std.process.Init, request: cli.Receive) !void {
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
    var buffer: [ipc.response_buffer_size]u8 = undefined;
    const timeout_ms = if (request.mode == .once) request.mode.once else null;
    const connection = (try start(io, data_directory, request.id, timeout_ms, &buffer)) orelse return;
    switch (request.mode) {
        .once => {
            const reply = readReply(io, connection, &buffer, null);
            connection.close(io);
            const response = (try reply) orelse return;
            switch (response) {
                .message => |text| try cli.writeJson(io, .{ .status = "message", .text = text }),
                .timeout, .closed => try cli.writeJson(io, .{ .status = @tagName(response) }),
                else => return error.InvalidChannelReply,
            }
        },
        .follow => {
            defer connection.close(io);
            try follow(io, connection, &buffer);
        },
    }
}

fn follow(io: std.Io, connection: std.Io.net.Stream, buffer: *[ipc.response_buffer_size]u8) !void {
    while (try readReply(io, connection, buffer, null)) |response| {
        switch (response) {
            .message => |text| try cli.writeJson(io, .{ .status = "message", .text = text }),
            .closed => return,
            else => return error.InvalidChannelReply,
        }
        if (try outputClosed()) return;
        try ipc.requestNext(connection);
    }
}

fn start(io: std.Io, data_directory: []const u8, id: []const u8, timeout_ms: ?u32, buffer: *[ipc.response_buffer_size]u8) !?std.Io.net.Stream {
    const connection = try ipc.connect(io, data_directory, id, timeout_ms);
    errdefer connection.close(io);
    const deadline = std.Io.Clock.Timestamp.fromNow(io, ipc.handshake_time).raw;
    const response = (try readReply(io, connection, buffer, deadline)) orelse {
        connection.close(io);
        return null;
    };
    return switch (response) {
        .waiting => connection,
        .unknown_channel => error.UnknownChannel,
        else => error.InvalidChannelReply,
    };
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
