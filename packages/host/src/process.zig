const std = @import("std");
const Pty = @import("pty.zig").Pty;

pub const Outcome = union(enum) {
    completed: std.process.Child.Term,
    timed_out,
    not_started: struct { reason: []const u8 },
};

pub const Signal = enum { interrupt, terminate, kill };

/// A running invocation. The caller serializes input operations and finishes
/// wait and all input operations before deinit. Output files are borrowed.
pub const Process = struct {
    child: std.process.Child,
    group_id: std.posix.pid_t,
    input: ?std.Io.File,
    terminal: ?Pty,
    stdout: std.Io.File,
    input_closed: bool,
    exited: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),

    pub const Options = struct {
        argv: []const []const u8,
        directory: []const u8,
        stdout: std.Io.File,
        stderr: std.Io.File,
        environ: *const std.process.Environ.Map,
        stdin: enum { closed, pipe } = .closed,
        terminal: bool = false,
        rows: u16 = 24,
        cols: u16 = 80,
    };

    pub fn start(io: std.Io, a: std.mem.Allocator, options: Options) !Process {
        if (options.terminal) {
            var terminal = try Pty.open(io, options.rows, options.cols);
            errdefer terminal.deinit(io);
            const argv = try a.alloc([]const u8, options.argv.len + 3);
            defer a.free(argv);
            argv[0..3].* = .{ "/usr/bin/setsid", "--ctty", "--" };
            @memcpy(argv[3..], options.argv);
            // Inheriting our group makes this PID a nonleader. setsid can
            // become the session leader and exec without forking.
            const child = try std.process.spawn(io, .{
                .argv = argv,
                .cwd = .{ .path = options.directory },
                .environ_map = options.environ,
                .stdin = .{ .file = terminal.slave },
                .stdout = .{ .file = terminal.slave },
                .stderr = .{ .file = terminal.slave },
            });
            terminal.closeSlave(io);
            return .{
                .child = child,
                .group_id = child.id.?,
                .input = null,
                .terminal = terminal,
                .stdout = options.stdout,
                .input_closed = false,
            };
        }
        var child = try std.process.spawn(io, .{
            .argv = options.argv,
            .cwd = .{ .path = options.directory },
            .environ_map = options.environ,
            .stdin = if (options.stdin == .pipe) .pipe else .ignore,
            .stdout = .{ .file = options.stdout },
            .stderr = .{ .file = options.stderr },
            .pgid = 0,
        });
        const input = child.stdin;
        child.stdin = null;
        return .{
            .child = child,
            .group_id = child.id.?,
            .input = input,
            .terminal = null,
            .stdout = options.stdout,
            .input_closed = options.stdin == .closed,
        };
    }

    /// Cancellation kills before joining the protected wait. Terminal output
    /// drains after group cleanup, bounded against escaped slave holders.
    pub fn wait(self: *Process, io: std.Io, timeout_ms: ?u32) !Outcome {
        const Result = union(enum) {
            process: anyerror!std.process.Child.Term,
            timeout: std.Io.Cancelable!void,
            terminal: anyerror!void,
            drain_timeout: std.Io.Cancelable!void,
        };
        var buffer: [4]Result = undefined;
        var select = std.Io.Select(Result).init(io, &buffer);
        var cleaned = false;
        defer {
            if (!cleaned) self.cancel(io);
            select.cancelDiscard();
            self.child.kill(io);
            self.exited.store(true, .release);
            self.finished.store(true, .release);
        }
        if (self.terminal) |terminal|
            try select.concurrent(.terminal, copyTerminal, .{ io, terminal.master, self.stdout });
        try select.concurrent(.process, waitForChild, .{ &self.child, io });
        if (timeout_ms) |milliseconds| {
            const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake });
            try select.concurrent(.timeout, waitForDeadline, .{ io, deadline });
        }

        var outcome: ?Outcome = null;
        var process_done = false;
        var terminal_done = self.terminal == null;
        var draining = false;
        while (true) {
            switch (try select.await()) {
                .process => |result| {
                    const term = try result;
                    process_done = true;
                    self.exited.store(true, .release);
                    if (outcome == null) outcome = .{ .completed = term };
                    if (!cleaned) try self.stop(io);
                    cleaned = true;
                },
                .timeout => |result| {
                    try result;
                    if (outcome == null) outcome = .timed_out;
                    if (!cleaned) try self.stop(io);
                    cleaned = true;
                },
                .terminal => |result| {
                    try result;
                    terminal_done = true;
                },
                .drain_timeout => |result| {
                    try result;
                    return error.TerminalDrainTimedOut;
                },
            }
            if (process_done and terminal_done) return outcome.?;
            if (outcome != null and !terminal_done and !draining) {
                draining = true;
                const drain_deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromSeconds(1), .clock = .awake });
                try select.concurrent(.drain_timeout, waitForDeadline, .{ io, drain_deadline });
            }
        }
    }

    pub fn writeInput(self: *Process, io: std.Io, bytes: []const u8) !void {
        if (self.exited.load(.acquire)) return error.ProcessNotFound;
        if (self.input_closed) return error.InputClosed;
        const input = if (self.terminal) |terminal| terminal.master else self.input orelse return error.InputClosed;
        try input.writeStreamingAll(io, bytes);
    }

    pub fn endInput(self: *Process, io: std.Io) !void {
        if (self.exited.load(.acquire)) return error.ProcessNotFound;
        if (self.input_closed) return;
        if (self.terminal) |terminal| {
            // A terminal has no half-close: send the terminal EOF key.
            try terminal.master.writeStreamingAll(io, "\x04");
            return;
        } else if (self.input) |input| {
            input.close(io);
            self.input = null;
        }
        self.input_closed = true;
    }

    pub fn signal(self: *Process, io: std.Io, which: Signal) !void {
        try io.checkCancel();
        if (self.exited.load(.acquire)) return error.ProcessNotFound;
        const sig: std.posix.SIG = switch (which) {
            .interrupt => .INT,
            .terminate => .TERM,
            .kill => .KILL,
        };
        if (which == .interrupt) {
            const group = if (self.terminal) |terminal| terminal.foregroundGroup() orelse self.group_id else self.group_id;
            std.posix.kill(-group, sig) catch |err| switch (err) {
                error.ProcessNotFound => try std.posix.kill(self.group_id, sig),
                else => return err,
            };
        } else {
            if (self.terminal != null) {
                if (try Pty.signalSession(io, self.group_id, sig) != 0) return;
            }
            std.posix.kill(-self.group_id, sig) catch |err| switch (err) {
                error.ProcessNotFound => try std.posix.kill(self.group_id, sig),
                else => return err,
            };
        }
    }

    pub fn resize(self: *Process, rows: u16, cols: u16) !void {
        const terminal = self.terminal orelse return error.NotATerminal;
        try terminal.resize(rows, cols);
    }

    pub fn deinit(self: *Process, io: std.Io) void {
        if (!self.finished.load(.acquire)) {
            self.cancel(io);
            self.child.kill(io);
        }
        if (self.input) |input| input.close(io);
        if (self.terminal) |*terminal| terminal.deinit(io);
        self.* = undefined;
    }

    /// Request termination while unwinding; the wait owner still reaps.
    pub fn cancel(self: *Process, io: std.Io) void {
        self.stop(io) catch {
            if (self.terminal) |terminal| {
                if (terminal.foregroundGroup()) |group| {
                    if (group != self.group_id) std.posix.kill(-group, .KILL) catch {};
                }
            }
            std.posix.kill(-self.group_id, .KILL) catch {};
            if (!self.exited.load(.acquire)) std.posix.kill(self.group_id, .KILL) catch {};
        };
    }

    fn stop(self: *Process, io: std.Io) !void {
        if (self.terminal != null) {
            const signaled = try Pty.signalSession(io, self.group_id, .KILL);
            if (signaled != 0 or self.exited.load(.acquire)) return;
        }
        std.posix.kill(-self.group_id, .KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => return err,
        };
        if (!self.exited.load(.acquire)) std.posix.kill(self.group_id, .KILL) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => return err,
        };
    }
};

fn copyTerminal(io: std.Io, source: std.Io.File, destination: std.Io.File) !void {
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const length = source.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            // Linux masters report EIO after the last slave is closed.
            error.EndOfStream, error.InputOutput => return,
            else => return err,
        };
        if (length != 0) try destination.writeStreamingAll(io, buffer[0..length]);
    }
}

fn waitForChild(child: *std.process.Child, io: std.Io) std.process.Child.WaitError!std.process.Child.Term {
    const previous_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous_protection);
    return child.wait(io);
}

fn waitForDeadline(io: std.Io, deadline: std.Io.Clock.Timestamp) std.Io.Cancelable!void {
    try deadline.wait(io);
}
