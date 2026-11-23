const std = @import("std");
const process = @import("process.zig");
const Reader = @import("reader.zig").Reader;
const output = @import("output.zig");
const content = @import("content");
const FileUri = @import("agent_contracts").FileUri;
const Allocator = std.mem.Allocator;

/// Shell setup and retained output. Host owns command lifetimes and delivery.
pub const Shell = struct {
    io: std.Io,
    directory: []const u8,
    data_directory: []const u8,
    environ: *const std.process.Environ.Map,

    pub const Mode = enum { batch, pipe, terminal };
    pub const Command = struct {
        name: []const u8,
        command: []const u8,
        cwd: ?[]const u8 = null,
        shell: ?[]const u8 = null,
        login: bool = false,
        mode: Mode = .batch,
        timeout_ms: ?u32 = null,
        yield_ms: u32 = 10000,
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
            uri: []const u8,
            byte_length: u64,
            range: ?Range,
            content: union(enum) { text: output.Preview, image: content.ImageContent.Description, file: content.File.Description, unavailable: content.Unavailable },
        };
        pub fn describe(self: Stream, a: Allocator) !Description {
            const log = try logReference(a, self.path);
            return .{
                .path = log.path,
                .uri = log.uri,
                .byte_length = self.byte_length,
                .range = self.range,
                .content = switch (self.content) {
                    .text => |text| .{ .text = text },
                    .image => |image| .{ .image = image.describe() },
                    .file => |file| .{ .file = file.describe() },
                    .unavailable => |diagnostic| .{ .unavailable = diagnostic },
                },
            };
        }
    };
    pub fn logReference(a: Allocator, path: []const u8) !struct { path: []const u8, uri: []const u8 } {
        return .{ .path = path, .uri = try FileUri.fromPath(a, path, .file) };
    }
    pub const Streams = struct { stdout: Stream, stderr: Stream };
    pub const Collection = enum { complete, initial, incremental };
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

        /// Final observations deliver native media once from complete stdout,
        /// independently of text already consumed by earlier observations.
        pub fn collect(self: Invocation, a: Allocator, cursors: *[2]u64, final_media_collected: *bool, finished: bool, interpretation: ?content.Interpretation, budget: usize) !Streams {
            var streams = try self.incremental(a, cursors, finished, budget);
            if (finished and !final_media_collected.*) {
                const reader: Reader = .{ .io = self.io };
                if (try reader.readMedia(a, self.stdout, interpretation, streams.stdout.content == .unavailable)) |media| {
                    streams.stdout = .{ .path = self.stdout_path, .byte_length = try self.stdout.length(self.io), .content = media };
                    cursors[0] = streams.stdout.byte_length;
                    final_media_collected.* = true;
                }
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

test "final observation supplies the complete file after incremental output" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const bytes = "%PDF-1.7\n\x00\xffcomplete file\n";
    try temporary.dir.writeFile(io, .{ .sub_path = "stdout", .data = bytes });
    try temporary.dir.writeFile(io, .{ .sub_path = "stderr", .data = "" });
    var invocation: Shell.Invocation = .{
        .io = io,
        .backend = .{ .not_started = "test fixture" },
        .started = .now(io, .awake),
        .stdout = try temporary.dir.openFile(io, "stdout", .{ .mode = .read_write }),
        .stderr = try temporary.dir.openFile(io, "stderr", .{}),
        .stdout_path = "stdout",
        .stderr_path = "stderr",
    };
    defer invocation.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cursors: [2]u64 = .{ 0, 0 };
    var collected = false;
    const running = try invocation.collect(a, &cursors, &collected, false, null, 512);
    try std.testing.expect(running.stdout.content != .file);
    try std.testing.expectEqual(bytes.len, cursors[0]);
    const final = try invocation.collect(a, &cursors, &collected, true, null, 512);
    try std.testing.expectEqualSlices(u8, bytes, final.stdout.content.file.bytes);
    try std.testing.expectEqual(null, final.stdout.range);
    const drained = try invocation.collect(a, &cursors, &collected, true, null, 512);
    try std.testing.expect(drained.stdout.content != .file);

    try invocation.stdout.setLength(io, content.file_size_limit + 1);
    const too_large = try (Reader{ .io = io }).readMedia(a, invocation.stdout, null, false);
    try std.testing.expectEqual(.file_too_large, too_large.?.unavailable.reason);

    // A later binary chunk must still deliver the complete file after earlier
    // text observations, rather than exposing that chunk as a file fragment.
    var mixed: [2052]u8 = @splat('a');
    @memcpy(mixed[2048..], "\x00\xffend"[0..4]);
    try temporary.dir.writeFile(io, .{ .sub_path = "stdout", .data = &mixed });
    try temporary.dir.writeFile(io, .{ .sub_path = "stderr", .data = &mixed });
    cursors = .{ 0, 0 };
    collected = false;
    const prefix = try invocation.collect(a, &cursors, &collected, true, null, 512);
    try std.testing.expect(prefix.stdout.content == .text);
    try std.testing.expect(!collected);
    const complete = while (cursors[0] < mixed.len) {
        const previous = cursors[0];
        const next = try invocation.collect(a, &cursors, &collected, true, null, 512);
        if (next.stdout.content == .file) break next;
        try std.testing.expect(cursors[0] > previous);
    } else return error.ExpectedCompleteFile;
    try std.testing.expectEqualSlices(u8, &mixed, complete.stdout.content.file.bytes);
    try std.testing.expect(complete.stderr.content == .unavailable);
    try std.testing.expect(collected);
}
