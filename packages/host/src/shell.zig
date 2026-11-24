const std = @import("std");
const process = @import("process.zig");
const output = @import("output.zig");
const contracts = @import("agent_contracts");
const LocalPath = contracts.LocalPath;
const Allocator = std.mem.Allocator;

/// Shell setup and retained output. Host owns command lifetimes and delivery.
pub const Shell = struct {
    io: std.Io,
    directory: []const u8,
    data_directory: []const u8,
    environ: *const std.process.Environ.Map,

    pub const default_output_bytes = 4096;
    pub const Mode = enum { batch, pipe, messages, terminal };
    pub const Command = struct {
        name: contracts.JsonString,
        command: contracts.JsonString,
        cwd: ?LocalPath.Argument = null,
        shell: ?LocalPath.Argument = null,
        login: bool = false,
        mode: Mode = .batch,
        timeout_ms: ?u32 = null,
        yield_ms: u32 = 10000,
        max_output_bytes: u32 = default_output_bytes,
    };
    pub const Range = struct { offset: u64, next_offset: u64 };
    pub const Stream = union(enum) {
        text: []const u8,
        log: struct {
            path: []const u8,
            byte_length: ?u64 = null,
            preview: ?[]const u8 = null,
            range: ?Range = null,
        },

        pub fn jsonStringify(self: Stream, json: *std.json.Stringify) !void {
            switch (self) {
                inline else => |value| try json.write(value),
            }
        }

        fn observe(path: []const u8, length: u64, range: ?Range, value: output.StreamContent) ?Stream {
            const preview = switch (value) {
                .text => |part| blk: {
                    if (!part.truncated) {
                        if (part.text.len == 0) return null;
                        if (range == null or range.?.offset == 0) return .{ .text = part.text };
                    }
                    break :blk part.text;
                },
                .binary => null,
            };
            return .{ .log = .{ .path = path, .byte_length = length, .preview = preview, .range = range } };
        }
    };
    pub const Streams = struct { stdout: ?Stream, stderr: ?Stream };
    pub const Start = union(enum) { ready: Invocation, unavailable: anyerror };
    pub const Invocation = struct {
        io: std.Io,
        backend: union(enum) { process: process.Process, not_started: []const u8 },
        started: std.Io.Clock.Timestamp,
        stdout: std.Io.File,
        stderr: std.Io.File,
        stdout_reference: []const u8,
        stderr_reference: []const u8,
        pub fn deinit(self: *Invocation) void {
            if (self.backend == .process) self.backend.process.deinit(self.io);
            self.stdout.close(self.io);
            self.stderr.close(self.io);
        }
        pub fn elapsed(self: Invocation) u64 {
            return @intCast(@max(0, self.started.untilNow(self.io).raw.toMilliseconds()));
        }
        pub fn complete(self: Invocation, a: Allocator, budget: usize) !Streams {
            const lengths = [2]u64{ try self.stdout.length(self.io), try self.stderr.length(self.io) };
            const budgets = splitBudget(budget, lengths);
            const stdout = try output.preview(a, self.io, self.stdout, lengths[0], budgets[0]);
            const stderr = try output.preview(a, self.io, self.stderr, lengths[1], budgets[1]);
            return .{
                .stdout = Stream.observe(self.stdout_reference, lengths[0], null, stdout),
                .stderr = Stream.observe(self.stderr_reference, lengths[1], null, stderr),
            };
        }
        pub fn incremental(self: Invocation, a: Allocator, cursors: *[2]u64, finished: bool, budget: usize) !Streams {
            const lengths = [2]u64{ try self.stdout.length(self.io), try self.stderr.length(self.io) };
            const remaining = [2]u64{ lengths[0] -| cursors[0], lengths[1] -| cursors[1] };
            const budgets = splitBudget(budget, remaining);
            const stdout = try output.chunk(a, self.io, self.stdout, cursors[0], lengths[0], budgets[0], finished);
            const stderr = try output.chunk(a, self.io, self.stderr, cursors[1], lengths[1], budgets[1], finished);
            cursors.* = .{ stdout.next_offset, stderr.next_offset };
            return .{ .stdout = chunkStream(self.stdout_reference, stdout), .stderr = chunkStream(self.stderr_reference, stderr) };
        }
        pub fn drained(self: Invocation, cursors: [2]u64) !bool {
            return cursors[0] >= try self.stdout.length(self.io) and cursors[1] >= try self.stderr.length(self.io);
        }

        pub fn readable(self: Invocation, cursors: [2]u64) !bool {
            return try output.readable(self.io, self.stdout, cursors[0]) or try output.readable(self.io, self.stderr, cursors[1]);
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
        const stdout_reference = try LocalPath.reference(a, stdout_path);
        const stderr_reference = try LocalPath.reference(a, stderr_path);
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
            if (std.fs.path.isAbsolute(cwd.bytes)) cwd.bytes else try std.fs.path.join(a, &.{ self.directory, cwd.bytes })
        else
            self.directory;
        const backend: @FieldType(Invocation, "backend") = if (process.Process.start(self.io, a, .{
            .argv = &.{ if (args.shell) |shell| shell.bytes else "/bin/sh", if (args.login) "-lc" else "-c", args.command.bytes },
            .directory = directory,
            .stdout = stdout,
            .stderr = stderr,
            .environ = &environment,
            .stdin = switch (args.mode) {
                .batch, .terminal => .closed,
                .pipe => .pipe,
                .messages => .messages,
            },
            .terminal = args.mode == .terminal,
        })) |child| .{ .process = child } else |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => .{ .not_started = @errorName(err) },
        };
        return .{
            .io = self.io,
            .backend = backend,
            .started = started,
            .stdout = stdout,
            .stderr = stderr,
            .stdout_reference = stdout_reference,
            .stderr_reference = stderr_reference,
        };
    }
};

fn splitBudget(total: usize, remaining: [2]u64) [2]usize {
    const smaller: usize = @intFromBool(remaining[1] < remaining[0]);
    const length = remaining[smaller];
    // An empty stream is omitted. A nonempty text byte takes at most six
    // bytes inside a JSON string, even when every character needs escaping.
    const encoded_bound = if (length == 0) 0 else length *| 6 +| 2;
    var budgets: [2]usize = undefined;
    budgets[smaller] = @intCast(@min(total / 2, encoded_bound));
    budgets[1 - smaller] = total - budgets[smaller];
    return budgets;
}
fn chunkStream(path: []const u8, chunk: output.Chunk) ?Shell.Stream {
    const range: Shell.Range = .{ .offset = chunk.offset, .next_offset = chunk.next_offset };
    return Shell.Stream.observe(path, chunk.byte_length, range, chunk.content);
}

test "partial text carries the retained path and incremental reads identify their byte range" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const bytes: [512]u8 = @splat('a');
    try tmp.dir.writeFile(t.io, .{ .sub_path = "stdout", .data = &bytes });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "stderr", .data = "" });
    var invocation: Shell.Invocation = .{
        .io = t.io,
        .backend = .{ .not_started = "test fixture" },
        .started = .now(t.io, .awake),
        .stdout = try tmp.dir.openFile(t.io, "stdout", .{}),
        .stderr = try tmp.dir.openFile(t.io, "stderr", .{}),
        .stdout_reference = "/logs/stdout",
        .stderr_reference = "/logs/stderr",
    };
    defer invocation.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const full = try invocation.complete(a, 4096);
    try t.expectEqualStrings(&bytes, full.stdout.?.text);
    try t.expectEqual(null, full.stderr);

    const limited = (try invocation.complete(a, 512)).stdout.?.log;
    try t.expectEqualStrings(invocation.stdout_reference, limited.path);
    try t.expectEqual(bytes.len, limited.byte_length);
    try t.expect(std.mem.indexOf(u8, limited.preview.?, "bytes omitted") != null);
    try t.expectEqual(null, limited.range);

    var cursors: [2]u64 = .{ 0, 0 };
    const first = (try invocation.incremental(a, &cursors, true, 512)).stdout.?.log;
    try t.expect(cursors[0] > 0 and cursors[0] < bytes.len);
    try t.expectEqualDeep(Shell.Range{ .offset = 0, .next_offset = cursors[0] }, first.range.?);
    try t.expectEqualStrings(bytes[0..@intCast(cursors[0])], first.preview.?);
    const offset = cursors[0];
    const last = (try invocation.incremental(a, &cursors, true, 512)).stdout.?.log;
    try t.expectEqualDeep(Shell.Range{ .offset = offset, .next_offset = bytes.len }, last.range.?);
    try t.expectEqualStrings(bytes[@intCast(offset)..], last.preview.?);
    try t.expectEqualStrings(invocation.stdout_reference, last.path);

    // The concrete input fits in the combined budget with either channel empty.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "stdout", .data = bytes[0..400] });
    try t.expectEqualStrings(bytes[0..400], (try invocation.complete(a, 512)).stdout.?.text);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "stderr", .data = bytes[0..400] });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "stdout", .data = "" });
    cursors = .{ 0, 0 };
    const diagnostic = try invocation.incremental(a, &cursors, true, 512);
    try t.expectEqualStrings(bytes[0..400], diagnostic.stderr.?.text);
    try t.expectEqual(null, diagnostic.stdout);

    try tmp.dir.writeFile(t.io, .{ .sub_path = "stdout", .data = "\x01" });
    const both = try invocation.complete(a, 512);
    try t.expectEqualStrings("\x01", both.stdout.?.text);
    try t.expectEqualStrings(bytes[0..400], both.stderr.?.text);
}
