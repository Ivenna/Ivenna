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
    switch (request.mode) {
        .once => |wait_ms| {
            const response = (try receive(io, data_directory, request.id, wait_ms, &buffer)) orelse return;
            switch (response) {
                .message => |text| try cli.writeJson(io, .{ .status = "message", .text = text }),
                .timeout, .closed => try cli.writeJson(io, .{ .status = @tagName(response) }),
                else => return error.InvalidChannelReply,
            }
        },
        .follow => try follow(io, data_directory, request.id, &buffer),
    }
}

fn follow(io: std.Io, data_directory: []const u8, id: []const u8, buffer: *[ipc.response_buffer_size]u8) !void {
    var received = false;
    while (true) {
        const response = (receive(io, data_directory, id, null, buffer) catch |err| switch (err) {
            // The channel can close between two reads of this stream.
            error.UnknownChannel => if (received) return else return err,
            else => return err,
        }) orelse return;
        switch (response) {
            .message => |text| cli.writeJson(io, .{ .status = "message", .text = text }) catch |err| switch (err) {
                error.BrokenPipe => return,
                else => return err,
            },
            .closed => return,
            else => return error.InvalidChannelReply,
        }
        received = true;
    }
}

fn receive(io: std.Io, data_directory: []const u8, id: []const u8, wait_ms: ?u32, buffer: *[ipc.response_buffer_size]u8) !?ipc.Response {
    if (try outputClosed()) return null;
    const connection = try ipc.connect(io, data_directory, id, wait_ms);
    defer connection.close(io);
    var descriptors = [_]posix.pollfd{
        .{ .fd = connection.socket.handle, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = std.Io.File.stdout().handle, .events = 0, .revents = 0 },
    };
    const deadline = std.Io.Clock.Timestamp.fromNow(io, ipc.handshake_time).raw;
    var response = (try readReply(io, connection, &descriptors, buffer, deadline)) orelse return null;
    if (response == .waiting) response = (try readReply(io, connection, &descriptors, buffer, null)) orelse return null;
    return switch (response) {
        .unknown_channel => error.UnknownChannel,
        .waiting => error.InvalidChannelReply,
        else => response,
    };
}

fn readReply(
    io: std.Io,
    connection: std.Io.net.Stream,
    descriptors: *[2]posix.pollfd,
    buffer: *[ipc.response_buffer_size]u8,
    deadline: ?std.Io.Timestamp,
) !?ipc.Response {
    if (!try poll(io, descriptors, deadline)) return error.ChannelServiceUnavailable;
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
