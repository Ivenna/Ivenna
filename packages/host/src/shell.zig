const std = @import("std");
const process = @import("process.zig");
const Reader = @import("reader.zig").Reader;
const output = @import("output.zig");
const content = @import("content");
const Allocator = std.mem.Allocator;

/// Shell setup and retained output. Host owns command lifetimes and delivery.
pub const Shell = struct {
    io: std.Io,
    directory: []const u8,
    data_directory: []const u8,
    environ: *const std.process.Environ.Map,

    pub const Mode = enum { batch, pipe, terminal };
    pub const Command = struct {
        command: []const u8,
        cwd: ?[]const u8 = null,
        shell: ?[]const u8 = null,
        login: bool = false,
        mode: Mode = .batch,
        timeout_ms: ?u32 = null,
        yield_ms: u32 = 1000,
        max_output_bytes: u32 = 16384,
        interpretation: ?content.Interpretation = null,
    };
    pub const Range = struct { offset: u64, next_offset: u64 };
    pub const Stream = struct {
        path: []const u8,
        byte_length: u64,
        range: ?Range = null,
        content: Reader.FileContent,
        pub const Description = struct {
            path: []const u8,
            byte_length: u64,
            range: ?Range,
            content: union(enum) { text: output.Preview, image: content.ImageContent.Description, unavailable: content.Unavailable },
        };
        pub fn describe(self: Stream) Description {
            return .{ .path = self.path, .byte_length = self.byte_length, .range = self.range, .content = switch (self.content) {
                .text => |text| .{ .text = text },
                .image => |image| .{ .image = image.describe() },
                .image_description => |description| .{ .image = description },
                .unavailable => |diagnostic| .{ .unavailable = diagnostic },
            } };
        }
    };
    pub const Streams = struct { stdout: Stream, stderr: Stream };
    pub const Collection = enum { complete, incremental, callback };
    pub const Start = union(enum) { ready: Invocation, unavailable: anyerror };
    pub const Invocation = struct {
        io: std.Io,
        backend: union(enum) { process: process.Process, not_started: []const u8 },
        started: std.Io.Clock.Timestamp,
        stdout: std.Io.File,
        stderr: std.Io.File,
        stdout_path: []const u8,
        stderr_path: []const u8,
        pub fn deinit(self: *Invocation) void {
            if (self.backend == .process) self.backend.process.deinit(self.io);
            self.stdout.close(self.io);
            self.stderr.close(self.io);
        }
        pub fn elapsed(self: Invocation) u64 {
            return @intCast(@max(0, self.started.untilNow(self.io).raw.toMilliseconds()));
        }
        pub fn complete(self: Invocation, a: Allocator, interpretation: ?content.Interpretation, budget: usize) !Streams {
            const lengths = [2]u64{ try self.stdout.length(self.io), try self.stderr.length(self.io) };
            const budgets = splitBudget(budget, lengths);
            const reader: Reader = .{ .io = self.io };
            const stdout = try reader.readFileLimit(a, self.stdout, interpretation, budgets[0]);
            const stderr = try reader.readTextLimit(a, self.stderr, budgets[1]);
            return .{ .stdout = .{ .path = self.stdout_path, .byte_length = lengths[0], .content = stdout }, .stderr = .{ .path = self.stderr_path, .byte_length = lengths[1], .content = stderr } };
        }
        pub fn incremental(self: Invocation, a: Allocator, cursors: *[2]u64, finished: bool, budget: usize) !Streams {
            const lengths = [2]u64{ try self.stdout.length(self.io), try self.stderr.length(self.io) };
            const remaining = [2]u64{ lengths[0] -| cursors[0], lengths[1] -| cursors[1] };
            const budgets = splitBudget(budget, remaining);
            const stdout = try output.chunk(a, self.io, self.stdout, cursors[0], budgets[0], finished);
            const stderr = try output.chunk(a, self.io, self.stderr, cursors[1], budgets[1], finished);
            cursors.* = .{ stdout.next_offset, stderr.next_offset };
            return .{ .stdout = chunkStream(self.stdout_path, stdout), .stderr = chunkStream(self.stderr_path, stderr) };
        }
        pub fn drained(self: Invocation, cursors: [2]u64) !bool {
            return cursors[0] >= try self.stdout.length(self.io) and cursors[1] >= try self.stderr.length(self.io);
        }

        pub fn readable(self: Invocation, cursors: [2]u64) !bool {
            return try output.readable(self.io, self.stdout, cursors[0]) or try output.readable(self.io, self.stderr, cursors[1]);
        }

        /// One source policy serves direct results, subsequent reads and text
        /// callbacks. A callback description does not consume native delivery.
        pub fn collect(self: Invocation, a: Allocator, cursors: *[2]u64, media_collected: *bool, kind: Collection, finished: bool, interpretation: ?content.Interpretation, budget: usize) !Streams {
            if (kind == .complete) return self.complete(a, interpretation, budget);
            var streams = try self.incremental(a, cursors, finished, budget);
            if (finished and !media_collected.*) {
                const reader: Reader = .{ .io = self.io };
                const delivery: Reader.Delivery = if (kind == .callback) .description else .native;
                if (try reader.readMedia(a, self.stdout, interpretation, delivery)) |media| {
                    streams.stdout = .{ .path = self.stdout_path, .byte_length = try self.stdout.length(self.io), .content = media };
                    cursors[0] = streams.stdout.byte_length;
                }
                if (kind != .callback) media_collected.* = true;
            }
            return streams;
        }
    };

    pub fn start(self: Shell, a: Allocator, session_id: u64, args: Command) !Start {
        return .{ .ready = self.prepare(a, session_id, args) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => return .{ .unavailable = err },
        } };
    }

    fn prepare(self: Shell, a: Allocator, session_id: u64, args: Command) !Invocation {
        const started = std.Io.Clock.Timestamp.now(self.io, .awake);
        const session = try std.fmt.allocPrint(a, "{d}", .{session_id});
        const log_directory = try std.fs.path.join(a, &.{ self.data_directory, "host", session });
        _ = try std.Io.Dir.cwd().createDirPathStatus(self.io, log_directory, .fromMode(0o700));
        var random: [16]u8 = undefined;
        self.io.random(&random);
        const id = std.fmt.bytesToHex(random, .lower);
        const stdout_path = try std.fmt.allocPrint(a, "{s}/{s}.stdout.log", .{ log_directory, id });
        const stderr_path = try std.fmt.allocPrint(a, "{s}/{s}.stderr.log", .{ log_directory, id });
        const stdout = try std.Io.Dir.createFileAbsolute(self.io, stdout_path, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) });
        errdefer stdout.close(self.io);
        const stderr = try std.Io.Dir.createFileAbsolute(self.io, stderr_path, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) });
        errdefer stderr.close(self.io);
        var environment = try self.environ.clone(a);
        defer environment.deinit();
        try environment.put("NO_COLOR", "1");
        try environment.put("TERM", if (args.mode == .terminal) "xterm-256color" else "dumb");
        for ([_][]const u8{ "PAGER", "GIT_PAGER", "GH_PAGER" }) |name| try environment.put(name, "cat");
        const directory = if (args.cwd) |cwd|
            if (std.fs.path.isAbsolute(cwd)) cwd else try std.fs.path.join(a, &.{ self.directory, cwd })
        else
            self.directory;
        const child = process.Process.start(self.io, a, .{
            .argv = &.{ args.shell orelse "/bin/sh", if (args.login) "-lc" else "-c", args.command },
            .directory = directory,
            .stdout = stdout,
            .stderr = stderr,
            .environ = &environment,
            .stdin = if (args.mode == .batch) .closed else .pipe,
            .terminal = args.mode == .terminal,
        }) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => return .{ .io = self.io, .backend = .{ .not_started = @errorName(err) }, .started = started, .stdout = stdout, .stderr = stderr, .stdout_path = stdout_path, .stderr_path = stderr_path },
        };
        return .{ .io = self.io, .backend = .{ .process = child }, .started = started, .stdout = stdout, .stderr = stderr, .stdout_path = stdout_path, .stderr_path = stderr_path };
    }
};

fn splitBudget(total: usize, remaining: [2]u64) [2]usize {
    const minimum = output.minimum_budget;
    if (remaining[0] == 0) return .{ minimum, total - minimum };
    if (remaining[1] == 0) return .{ total - minimum, minimum };
    return .{ total / 2, total - total / 2 };
}
fn chunkStream(path: []const u8, chunk: output.Chunk) Shell.Stream {
    return .{ .path = path, .byte_length = chunk.byte_length, .range = .{ .offset = chunk.offset, .next_offset = chunk.next_offset }, .content = switch (chunk.content) {
        .text => |text| .{ .text = text },
        .unavailable => |diagnostic| .{ .unavailable = .{ .byte_length = diagnostic.byte_length, .reason = .unsupported_binary } },
    } };
}
