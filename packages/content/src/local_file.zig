const std = @import("std");
const LocalFile = @This();

file: std.Io.File,
size: u64,

pub fn open(io: std.Io, path: []const u8) !LocalFile {
    const file: std.Io.File = if (@import("builtin").os.tag == .linux) .{
        // Opening a FIFO must return control even when it has no writer.
        .handle = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOCTTY = true, .CLOEXEC = true }, 0),
        .flags = .{ .nonblocking = true },
    } else blk: {
        const dir = std.Io.Dir.cwd();
        if ((try dir.statFile(io, path, .{})).kind != .file) return error.NotRegularFile;
        break :blk try dir.openFile(io, path, .{ .allow_directory = false });
    };
    errdefer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotRegularFile;
    return .{ .file = file, .size = stat.size };
}

pub fn readAll(self: LocalFile, io: std.Io, a: std.mem.Allocator, limit: usize) ![]const u8 {
    // Read to EOF. Virtual files can report zero size and still return bytes.
    var reader = self.file.reader(io, &.{});
    reader.mode = .positional_simple;
    return reader.interface.allocRemaining(a, .limited(limit)) catch |err| switch (err) {
        error.ReadFailed => return reader.err orelse error.ReadFailed,
        else => |cause| return cause,
    };
}
