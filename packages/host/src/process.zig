const std = @import("std");

// Subprocess execution and process-group cleanup for shell commands.
pub const Outcome = union(enum) {
    completed: std.process.Child.Term,
    timed_out,
};

pub fn runToFiles(io: std.Io, argv: []const []const u8, directory: []const u8, stdout: std.Io.File, stderr: std.Io.File, environ: *const std.process.Environ.Map, timeout_ms: u32) !Outcome {
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake });
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = directory },
        .environ_map = environ,
        .stdin = .ignore,
        .stdout = .{ .file = stdout },
        .stderr = .{ .file = stderr },
        .pgid = 0,
    });
    const group_id = child.id.?;
    const Result = union(enum) { process: anyerror!std.process.Child.Term, timeout: std.Io.Cancelable!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &buffer);
    defer {
        // Stop the process group before joining its protected wait task. A
        // canceled stdlib wait would clear the child ID without reaping it.
        std.posix.kill(-group_id, .KILL) catch {};
        select.cancelDiscard();
        child.kill(io);
    }
    try select.concurrent(.process, waitForChild, .{ &child, io });
    try select.concurrent(.timeout, waitForDeadline, .{ io, deadline });
    return switch (try select.await()) {
        .process => |result| .{ .completed = try result },
        .timeout => |result| blk: {
            try result;
            break :blk .timed_out;
        },
    };
}

fn waitForChild(child: *std.process.Child, io: std.Io) std.process.Child.WaitError!std.process.Child.Term {
    const previous_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(previous_protection);
    return child.wait(io);
}

fn waitForDeadline(io: std.Io, deadline: std.Io.Clock.Timestamp) std.Io.Cancelable!void {
    try deadline.wait(io);
}
