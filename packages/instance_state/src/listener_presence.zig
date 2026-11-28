const std = @import("std");
const linux = std.os.linux;

io: std.Io,
file: std.Io.File,

const Presence = @This();
const filename = "subscription-listeners.lock";

pub fn open(io: std.Io, directory: []const u8) !Presence {
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{});
    defer dir.close(io);
    const file = dir.openFile(io, filename, .{}) catch |err| switch (err) {
        error.FileNotFound => dir.createFile(io, filename, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        }) catch |create_err| switch (create_err) {
            error.PathAlreadyExists => try dir.openFile(io, filename, .{}),
            else => return create_err,
        },
        else => return err,
    };
    return .{ .io = io, .file = file };
}

pub fn close(self: Presence) void {
    self.file.close(self.io);
}

/// Each registration owns one byte. Shared locks allow independent sessions
/// and the kernel releases each lock when its file description closes.
pub fn attach(self: Presence, id: i64) !void {
    var lock = range(id, linux.F.RDLCK);
    try self.control(linux.F.OFD_SETLK, &lock);
}

pub fn connected(self: Presence, id: i64) !bool {
    var lock = range(id, linux.F.WRLCK);
    try self.control(linux.F.OFD_GETLK, &lock);
    return lock.type != linux.F.UNLCK;
}

fn range(id: i64, kind: i16) linux.Flock {
    std.debug.assert(id > 0);
    return .{
        .type = kind,
        .whence = linux.SEEK.SET,
        .start = id - 1,
        .len = 1,
        .pid = 0,
        ._unused = undefined,
    };
}

fn control(self: Presence, command: i32, lock: *linux.Flock) !void {
    while (true) switch (linux.errno(linux.fcntl(self.file.handle, command, @intFromPtr(lock)))) {
        .SUCCESS => return,
        .INTR => try self.io.checkCancel(),
        else => |err| return std.posix.unexpectedErrno(err),
    };
}
