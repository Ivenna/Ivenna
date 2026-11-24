const std = @import("std");
const builtin = @import("builtin");
const Channels = @import("agent_contracts").Channels;
const linux = std.os.linux;

const Pipe = struct { reader: std.Io.File, writer: std.Io.File };

pub fn open(io: std.Io) !Pipe {
    if (builtin.os.tag != .linux) return error.CommandMessagesUnsupported;

    var descriptors: [2]std.posix.fd_t = undefined;
    switch (linux.errno(linux.pipe2(&descriptors, .{ .DIRECT = true, .NONBLOCK = true, .CLOEXEC = true }))) {
        .SUCCESS => {},
        .INVAL, .NOSYS => return error.CommandMessagesUnsupported,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => |err| return std.posix.unexpectedErrno(err),
    }
    const pipe: Pipe = .{
        .reader = .{ .handle = descriptors[0], .flags = .{ .nonblocking = true } },
        .writer = .{ .handle = descriptors[1], .flags = .{ .nonblocking = true } },
    };
    errdefer {
        pipe.reader.close(io);
        pipe.writer.close(io);
    }

    // A packet occupies one complete pipe buffer, even when it is short.
    // Keep exactly one page so the second write cannot enter the pipe.
    const page_size = std.heap.pageSize();
    const capacity = linux.fcntl(pipe.writer.handle, linux.F.SETPIPE_SZ, page_size);
    switch (linux.errno(capacity)) {
        .SUCCESS => if (capacity != page_size) return error.CommandMessagesUnsupported,
        .PERM => return error.PermissionDenied,
        else => |err| return std.posix.unexpectedErrno(err),
    }
    return pipe;
}

pub fn send(writer: std.Io.File, io: std.Io, text: []const u8) !Channels.Outcome {
    std.debug.assert(text.len != 0);
    if (text.len > Channels.max_bytes) return .too_long;
    // The message limit fits Linux PIPE_BUF, so a write cannot be partial.
    const count = writer.writeStreaming(io, &.{}, &.{text}, 1) catch |err| switch (err) {
        error.WouldBlock => return .full,
        error.BrokenPipe => return .closed,
        else => return err,
    };
    std.debug.assert(count == text.len);
    return .accepted;
}

test "a command pipe accepts the maximum packet size" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    const pipe = try open(io);
    defer pipe.reader.close(io);
    defer pipe.writer.close(io);

    var buffer: [Channels.max_bytes]u8 = undefined;
    const oversize: [Channels.max_bytes + 1]u8 = @splat('x');
    try std.testing.expectEqual(.too_long, try send(pipe.writer, io, &oversize));
    const packet = oversize[0..Channels.max_bytes];
    try std.testing.expectEqual(.accepted, try send(pipe.writer, io, packet));
    const count = try pipe.reader.readStreaming(io, &.{&buffer});
    try std.testing.expectEqualStrings(packet, buffer[0..count]);
}

test "a closed command reader is a send outcome" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    const pipe = try open(io);
    defer pipe.writer.close(io);
    pipe.reader.close(io);
    try std.testing.expectEqual(.closed, try send(pipe.writer, io, "message"));
}
