const std = @import("std");
const process = @import("process.zig");
const Reader = @import("reader.zig").Reader;
const output = @import("output.zig");
const Interpretation = @import("../content.zig").Interpretation;
const Image = @import("../content.zig").Image;

const Allocator = std.mem.Allocator;

/// Owns host shell command execution. Process sessions and terminal control
/// are planned capabilities.
pub const Shell = struct {
    io: std.Io,
    directory: []const u8,
    data_directory: []const u8,
    environ: *const std.process.Environ.Map,

    const default_timeout_ms = 600_000;

    /// Engine supplies the session identity used to group command logs.
    pub const Context = struct { session_id: u64 };

    pub const Command = struct {
        command: []const u8,
        cwd: ?[]const u8 = null,
        timeout_ms: ?u32 = null,
        interpretation: ?Interpretation = null,
    };

    pub const Stream = struct {
        path: []const u8,
        content: Reader.FileContent,

        pub const Description = struct {
            path: []const u8,
            content: union(enum) {
                text: @FieldType(Reader.FileContent, "text"),
                image: union(enum) {
                    data: struct {
                        format: Image.Format,
                        byte_length: u64,
                    },
                    url: struct {},
                },
                unavailable: @FieldType(Reader.FileContent, "unavailable"),
            },
        };

        pub fn describe(self: Stream) Stream.Description {
            return .{
                .path = self.path,
                .content = switch (self.content) {
                    .text => |preview| .{ .text = preview },
                    .image => |source| .{ .image = switch (source) {
                        .data => |image| .{ .data = .{
                            .format = image.format,
                            .byte_length = image.bytes.len,
                        } },
                        .url => .{ .url = .{} },
                    } },
                    .unavailable => |unavailable| .{ .unavailable = unavailable },
                },
            };
        }
    };

    pub const DiagnosticsStream = struct {
        path: []const u8,
        content: union(enum) {
            text: output.Preview,
            unavailable: struct {
                byte_length: u64,
                reason: enum { unsupported_binary },
            },
        },
    };

    pub const Result = struct {
        outcome: process.Outcome,
        stdout: Stream,
        stderr: DiagnosticsStream,

        pub const Description = struct {
            outcome: process.Outcome,
            stdout: Stream.Description,
            stderr: DiagnosticsStream,
        };

        pub fn describe(self: Result) Result.Description {
            return .{
                .outcome = self.outcome,
                .stdout = self.stdout.describe(),
                .stderr = self.stderr,
            };
        }
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

    // TODO(process_sessions): design process state that outlives model-turn
    // arenas, including how process handles relate to conversation identity.
    // TODO(stdin, pty, process_control): design incremental output, input/EOF,
    // terminal transport, interruption, and cleanup for that runtime.
    // TODO(background_jobs): design completion delivery through Engine scheduling.

    pub fn run(self: Shell, a: Allocator, context: Context, args: Command) !Result {
        const deadline = std.Io.Clock.Timestamp.fromNow(self.io, .{ .raw = .fromMilliseconds(args.timeout_ms orelse default_timeout_ms), .clock = .awake });
        const conversation = try std.fmt.allocPrint(a, "{d}", .{context.session_id});
        const log_directory = try std.fs.path.join(a, &.{ self.data_directory, "host", conversation });
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
        const reader: Reader = .{ .io = self.io };
        const diagnostics: DiagnosticsStream = .{
            .path = stderr_path,
            .content = blk: {
                const preview = output.preview(a, self.io, stderr) catch |err| switch (err) {
                    error.UnsupportedBinary => break :blk .{ .unavailable = .{
                        .byte_length = try stderr.length(self.io),
                        .reason = .unsupported_binary,
                    } },
                    else => return err,
                };
                break :blk .{ .text = preview };
            },
        };
        return .{
            .outcome = outcome,
            .stdout = .{
                .path = stdout_path,
                .content = try reader.readFile(a, stdout, args.interpretation),
            },
            .stderr = diagnostics,
        };
    }

    fn execute(self: Shell, a: Allocator, args: Command, stdout: std.Io.File, stderr: std.Io.File, deadline: std.Io.Clock.Timestamp) !process.Outcome {
        var environment = try self.environ.clone(a);
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
