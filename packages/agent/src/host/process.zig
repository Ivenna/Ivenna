const std = @import("std");

const Allocator = std.mem.Allocator;

// Subprocess execution and cleanup for commands and environment preparation.
// Conversation-level process control belongs to Shell.
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

pub fn capture(a: Allocator, io: std.Io, argv: []const []const u8, directory: []const u8, environ: *const std.process.Environ.Map, timeout_ms: u32, output_limit: usize) !std.process.RunResult {
    const Result = union(enum) { process: anyerror!std.process.RunResult, timeout: std.Io.Cancelable!void };
    var buffer: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.process, collectProcess, .{ a, io, argv, directory, environ, output_limit });
    try select.concurrent(.timeout, waitForTimeout, .{ io, timeout_ms });
    return switch (try select.await()) {
        .process => |result| result,
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    };
}

fn collectProcess(a: Allocator, io: std.Io, argv: []const []const u8, directory: []const u8, environ: *const std.process.Environ.Map, output_limit: usize) !std.process.RunResult {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = directory },
        .environ_map = environ,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    const group_id = child.id.?;
    const Result = union(enum) { process: anyerror!std.process.Child.Term };
    var wait_buffer: [1]Result = undefined;
    var wait = std.Io.Select(Result).init(io, &wait_buffer);
    defer {
        // Stop the process group before joining the protected wait, including
        // when the output pipes have already closed.
        std.posix.kill(-group_id, .KILL) catch {};
        wait.cancelDiscard();
        child.kill(io);
    }

    var reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(a, io, reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    while (reader.fill(64, .none)) |_| {
        if (reader.reader(0).buffered().len > output_limit or reader.reader(1).buffered().len > output_limit)
            return error.OutputLimitExceeded;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try reader.checkAnyError();
    try wait.concurrent(.process, waitForChild, .{ &child, io });
    const term = switch (try wait.await()) {
        .process => |result| try result,
    };
    return .{
        .term = term,
        .stdout = try reader.toOwnedSlice(0),
        .stderr = try reader.toOwnedSlice(1),
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

fn waitForTimeout(io: std.Io, timeout_ms: u32) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(timeout_ms), .awake);
}
