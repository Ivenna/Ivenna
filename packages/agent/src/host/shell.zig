const std = @import("std");
const process = @import("process.zig");
const output = @import("output.zig");
const mise = @import("mise.zig");

const Allocator = std.mem.Allocator;

/// Owns host shell execution and control. Command execution is implemented;
/// process sessions and terminal control will extend this runtime.
pub const Shell = struct {
    io: std.Io,
    directory: []const u8,
    environ: *const std.process.Environ.Map,

    const default_timeout_ms = 600_000;

    /// Engine supplies this identity. Future process handles must be looked up
    /// within the same conversation.
    pub const Context = struct { session_id: i64 };

    pub const Command = struct {
        command: []const u8,
        cwd: ?[]const u8 = null,
        timeout_ms: ?u32 = null,
    };

    pub const Stream = struct {
        text: []const u8,
        truncated: bool,
        path: []const u8,
    };

    pub const Result = struct {
        outcome: process.Outcome,
        stdout: Stream,
        stderr: Stream,
    };

    pub const CapabilityStatus = enum { available, planned };

    pub const Capabilities = struct {
        command_execution: CapabilityStatus = .available,
        process_sessions: CapabilityStatus = .planned,
        stdin: CapabilityStatus = .planned,
        pty: CapabilityStatus = .planned,
        process_control: CapabilityStatus = .planned,
        background_jobs: CapabilityStatus = .planned,
    };

    pub const Description = struct {
        shell: []const u8 = "/bin/sh",
        cwd: []const u8,
        capabilities: Capabilities = .{},
    };

    pub fn describe(self: Shell) Description {
        return .{ .cwd = self.directory };
    }

    // TODO(process_sessions): add a service-owned runtime registry whose handles
    // are bound to Context.session_id and outlive individual model-turn arenas.
    // TODO(stdin, pty, process_control): extend that runtime with incremental
    // output, input/EOF, terminal transport, interruption, and explicit cleanup.
    // TODO(background_jobs): connect runtime completion to Engine scheduling;
    // returning a process handle alone does not notify a paused conversation.

    pub fn run(self: Shell, a: Allocator, context: Context, args: Command) !Result {
        const deadline = std.Io.Clock.Timestamp.fromNow(self.io, .{ .raw = .fromMilliseconds(args.timeout_ms orelse default_timeout_ms), .clock = .awake });
        const conversation = try std.fmt.allocPrint(a, "{d}", .{context.session_id});
        const log_directory = try std.fs.path.join(a, &.{ self.directory, ".ivenna", "host", conversation });
        _ = try std.Io.Dir.cwd().createDirPathStatus(self.io, log_directory, .fromMode(0o700));
        var random: [16]u8 = undefined;
        self.io.random(&random);
        const id = std.fmt.bytesToHex(random, .lower);
        const stdout_path = try std.fmt.allocPrint(a, "{s}/{s}.stdout.log", .{ log_directory, id });
        const stderr_path = try std.fmt.allocPrint(a, "{s}/{s}.stderr.log", .{ log_directory, id });
        const stdout = try std.Io.Dir.createFileAbsolute(self.io, stdout_path, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        defer stdout.close(self.io);
        const stderr = try std.Io.Dir.createFileAbsolute(self.io, stderr_path, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        defer stderr.close(self.io);

        const outcome = try self.execute(a, args, stdout, stderr, deadline);
        const stdout_preview = try output.preview(a, self.io, stdout);
        const stderr_preview = try output.preview(a, self.io, stderr);
        return .{
            .outcome = outcome,
            .stdout = .{
                .text = stdout_preview.text,
                .truncated = stdout_preview.truncated,
                .path = stdout_path,
            },
            .stderr = .{
                .text = stderr_preview.text,
                .truncated = stderr_preview.truncated,
                .path = stderr_path,
            },
        };
    }

    fn execute(self: Shell, a: Allocator, args: Command, stdout: std.Io.File, stderr: std.Io.File, deadline: std.Io.Clock.Timestamp) !process.Outcome {
        var environment = mise.prepareEnvironment(a, self.io, self.directory, self.environ, deadline) catch |err| switch (err) {
            error.Timeout => return .timed_out,
            else => return err,
        };
        defer environment.deinit();
        try environment.put("NO_COLOR", "1");
        try environment.put("TERM", "dumb");
        try environment.put("PAGER", "cat");
        try environment.put("GIT_PAGER", "cat");
        try environment.put("GH_PAGER", "cat");

        const remaining_ms = deadline.durationFromNow(self.io).raw.toMilliseconds();
        if (remaining_ms <= 0) return .timed_out;
        return process.runToFiles(self.io, &.{
            "/bin/sh", "-c", "cd -- \"$1\" && exec /bin/sh -c \"$2\"", "ivenna-host", args.cwd orelse ".", args.command,
        }, self.directory, stdout, stderr, &environment, @intCast(remaining_ms));
    }
};
