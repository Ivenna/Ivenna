const std = @import("std");
const linux = std.os.linux;

/// Linux pseudoterminal handles; setsid --ctty establishes the controlling TTY.
pub const Pty = struct {
    master: std.Io.File,
    slave: std.Io.File,
    slave_open: bool = true,

    pub fn open(io: std.Io, rows: u16, cols: u16) !Pty {
        if (@import("builtin").os.tag != .linux) return error.TerminalUnsupported;
        // Verify the mechanisms needed to retire this session before launching
        // any command. An unsupported kernel or missing procfs cannot provide
        // the terminal lifetime contract.
        const probe = linux.pidfd_open(linux.getpid(), 0);
        switch (std.posix.errno(probe)) {
            .SUCCESS => {},
            .NOSYS => return error.TerminalSessionUnsupported,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => |err| return std.posix.unexpectedErrno(err),
        }
        const handle: std.Io.File = .{ .handle = @intCast(probe), .flags = .{ .nonblocking = false } };
        handle.close(io);
        var proc = try std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true });
        proc.close(io);
        const master = try std.Io.Dir.openFileAbsolute(io, "/dev/ptmx", .{ .mode = .read_write });
        errdefer master.close(io);
        var unlocked: c_int = 0;
        _ = try ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlocked));
        const flags: linux.O = .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true };
        const slave: std.Io.File = .{
            .handle = @intCast(try ioctl(master, linux.T.IOCGPTPEER, @as(u32, @bitCast(flags)))),
            .flags = .{ .nonblocking = false },
        };
        errdefer slave.close(io);
        const terminal: Pty = .{ .master = master, .slave = slave };
        try terminal.resize(rows, cols);
        return terminal;
    }

    pub fn resize(self: Pty, rows: u16, cols: u16) !void {
        var size: std.posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        _ = try ioctl(self.master, linux.T.IOCSWINSZ, @intFromPtr(&size));
    }

    pub fn foregroundGroup(self: Pty) ?std.posix.pid_t {
        const group = std.posix.tcgetpgrp(self.master.handle) catch return null;
        return if (group > 0) group else null;
    }

    pub fn closeSlave(self: *Pty, io: std.Io) void {
        if (self.slave_open) self.slave.close(io);
        self.slave_open = false;
    }

    pub fn deinit(self: *Pty, io: std.Io) void {
        self.closeSlave(io);
        self.master.close(io);
        self.* = undefined;
    }

    /// Job-control shells put background jobs in separate groups. They still
    /// belong to this terminal session, so group-only cleanup is insufficient.
    /// Bind each candidate with a pidfd before inspecting it, preventing PID
    /// reuse between the procfs read and signal from selecting another process.
    /// `session` is the terminal child PID retained by Process.start, never a
    /// model-supplied identifier or Ivenna's own session ID.
    pub fn signalSession(io: std.Io, session: std.posix.pid_t, sig: std.posix.SIG) !usize {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        var count: usize = 0;
        // SIGKILL is idempotent. A second sweep covers ordinary forks occurring
        // as the shell and its existing background jobs are being stopped.
        const passes: usize = if (sig == .KILL) 2 else 1;
        for (0..passes) |_| {
            var directory = try std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true });
            defer directory.close(io);
            var entries = directory.iterate();
            while (try entries.next(io)) |entry| {
                const pid = std.fmt.parseInt(std.posix.pid_t, entry.name, 10) catch continue;
                const candidate_session = linux.getsid(pid);
                switch (std.posix.errno(candidate_session)) {
                    .SUCCESS => if (candidate_session != session) continue,
                    .SRCH => continue,
                    else => |err| return std.posix.unexpectedErrno(err),
                }
                const descriptor = linux.pidfd_open(pid, 0);
                switch (std.posix.errno(descriptor)) {
                    .SUCCESS => {},
                    .SRCH => continue,
                    .ACCES, .PERM => return error.AccessDenied,
                    .NOSYS => return error.TerminalSessionUnsupported,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NOMEM => return error.SystemResources,
                    else => |err| return std.posix.unexpectedErrno(err),
                }
                const handle: std.Io.File = .{ .handle = @intCast(descriptor), .flags = .{ .nonblocking = false } };
                defer handle.close(io);
                var path_buffer: [64]u8 = undefined;
                const path = std.fmt.bufPrint(&path_buffer, "{s}/stat", .{entry.name}) catch continue;
                const stat = directory.openFile(io, path, .{}) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                defer stat.close(io);
                var buffer: [512]u8 = undefined;
                const length = stat.readPositional(io, &.{&buffer}, 0) catch |err| {
                    // procfs returns ESRCH when a task disappears after open;
                    // std.Io does not distinguish it in ReadPositionalError.
                    if (std.posix.errno(linux.pidfd_send_signal(handle.handle, @fromBackingInt(@intCast(0)), null, 0)) == .SRCH) continue;
                    return err;
                };
                const data = buffer[0..length];
                const close = std.mem.lastIndexOfScalar(u8, data, ')') orelse continue;
                var fields = std.mem.tokenizeScalar(u8, data[close + 1 ..], ' ');
                _ = fields.next() orelse continue; // state
                _ = fields.next() orelse continue; // parent PID
                _ = fields.next() orelse continue; // process group
                const found = std.fmt.parseInt(std.posix.pid_t, fields.next() orelse continue, 10) catch continue;
                if (found != session) continue;
                switch (std.posix.errno(linux.pidfd_send_signal(handle.handle, sig, null, 0))) {
                    .SUCCESS => count += 1,
                    .SRCH => {},
                    .PERM => return error.PermissionDenied,
                    .NOSYS => return error.TerminalSessionUnsupported,
                    else => |err| return std.posix.unexpectedErrno(err),
                }
            }
        }
        return count;
    }
};

fn ioctl(file: std.Io.File, request: u32, argument: usize) !usize {
    while (true) {
        const result = linux.ioctl(file.handle, request, argument);
        switch (std.posix.errno(result)) {
            .SUCCESS => return result,
            .INTR => continue,
            .NOTTY => return error.NotATerminal,
            .INVAL => return error.InvalidTerminalOperation,
            .ACCES, .PERM => return error.AccessDenied,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOMEM => return error.SystemResources,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}
