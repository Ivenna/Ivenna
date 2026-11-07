const std = @import("std");
const Shell = @import("shell.zig").Shell;
const process = @import("process.zig");
const Content = @import("content").Content;
const Allocator = std.mem.Allocator;
const contracts = @import("agent_contracts");
const Tools = contracts.Tools;
const Model = contracts.Model;
const Callback = contracts.Callback;

/// One process registry serves short, yielded, and interactive commands.
pub const Host = struct {
    allocator: Allocator,
    shell: Shell,
    publisher: Callback.Publisher,
    max_host_commands: usize,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    tasks: std.Io.Group = .init,
    jobs: std.ArrayList(*Job) = .empty,
    active: usize = 0,
    completed_sequence: u64 = 0,
    stopping: bool = false,
    failure: ?anyerror = null,

    pub const Context = Tools.Invocation;
    pub const Action = union(enum) {
        read: struct {},
        write: struct { text: []const u8, eof: bool = false },
        signal: struct { name: process.Signal },
        resize: struct { rows: u16, cols: u16 },
    };
    pub const Continue = struct {
        command_id: u64,
        action: Action = .{ .read = .{} },
        yield_ms: u32 = 1000,
        max_output_bytes: u32 = 16384,
    };
    pub const Request = union(enum) {
        get_host_shell: struct { command_id: ?u64 = null },
        run_host_shell: Shell.Command,
        continue_host_shell: Continue,
        pub fn parse(a: Allocator, name: []const u8, arguments: []const u8) !?Request {
            const tag = std.meta.stringToEnum(std.meta.Tag(Request), name) orelse return null;
            const request: Request = switch (tag) {
                inline else => |active| @unionInit(Request, @tagName(active), std.json.parseFromSliceLeaky(@FieldType(Request, @tagName(active)), a, arguments, .{}) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return error.InvalidToolArguments,
                }),
            };
            switch (request) {
                .get_host_shell => |args| if (args.command_id == 0) return error.InvalidToolArguments,
                .run_host_shell => |args| {
                    if (!validText(args.command) or !validLimits(args.yield_ms, args.max_output_bytes) or args.timeout_ms == 0) return error.InvalidToolArguments;
                    if (args.cwd) |cwd| if (!validText(cwd)) return error.InvalidToolArguments;
                    if (args.shell) |shell| if (!validText(shell)) return error.InvalidToolArguments;
                },
                .continue_host_shell => |args| {
                    if (args.command_id == 0 or !validLimits(args.yield_ms, args.max_output_bytes)) return error.InvalidToolArguments;
                    switch (args.action) {
                        .write => |write| if (write.text.len > 16384) return error.InvalidToolArguments,
                        .resize => |size| if (size.rows == 0 or size.cols == 0) return error.InvalidToolArguments,
                        else => {},
                    }
                },
            }
            return request;
        }
    };

    const State = union(enum) { running, finished: process.Outcome, failed: anyerror };
    const Job = struct {
        arena: std.heap.ArenaAllocator,
        invocation: Shell.Invocation,
        args: Shell.Command,
        session_id: u64,
        command_id: ?u64 = null,
        refs: usize = 2, // Registry and initial invocation; tasks add their own refs.
        operations: std.Io.Mutex = .init,
        state: State,
        elapsed_ms: u64 = 0,
        completed_sequence: u64 = 0,
        cursors: [2]u64 = .{ 0, 0 }, // Protected by operations, not the registry lock.
        media_checked: bool = false,
        input_pending: bool = false,
        input_error: ?anyerror = null,
        input_open: bool,
        input_tasks: std.Io.Group = .init,

        fn destroy(self: *Job, allocator: Allocator) void {
            self.invocation.deinit();
            self.arena.deinit();
            allocator.destroy(self);
        }
    };
    const PublicState = union(enum) { running, finished: process.Outcome, unavailable: struct { reason: []const u8 } };
    const InputStatus = struct { open: bool, pending: bool, @"error": ?[]const u8 };
    const Snapshot = struct { state: PublicState, elapsed_ms: u64, stdin: InputStatus };
    const Create = union(enum) { capacity, unavailable: anyerror, job: *Job };
    const ToolError = struct { code: []const u8, message: []const u8, effects: ?[]const u8 = null };
    const Observation = struct {
        command_id: ?u64,
        snapshot: Snapshot,
        mode: Shell.Mode,
        streams: Shell.Streams,

        fn render(self: Observation, a: Allocator, failure: ?ToolError) !Content {
            const result = .{
                .command_id = self.command_id,
                .state = self.snapshot.state,
                .elapsed_ms = self.snapshot.elapsed_ms,
                .mode = self.mode,
                .stdin = self.snapshot.stdin,
                .stdout = self.streams.stdout.describe(),
                .stderr = self.streams.stderr.describe(),
                .media_omission = if (self.streams.stdout.content == .image_description) @as(?[]const u8, "asynchronous_media_unavailable") else null,
            };
            const text = if (failure) |err|
                try std.json.Stringify.valueAlloc(a, .{ .@"error" = err, .result = result }, .{ .emit_null_optional_fields = false })
            else
                try success(a, result);
            if (self.streams.stdout.content == .image)
                return Content.fromParts(a, &.{ .{ .text = text }, .{ .image = self.streams.stdout.content.image } });
            return Content.fromText(a, text);
        }
    };

    pub fn init(allocator: Allocator, io: std.Io, directory: []const u8, data_directory: []const u8, environ: *const std.process.Environ.Map, publisher: Callback.Publisher, max_host_commands: usize) Host {
        return .{ .allocator = allocator, .shell = .{ .io = io, .directory = directory, .data_directory = data_directory, .environ = environ }, .publisher = publisher, .max_host_commands = max_host_commands };
    }
    pub fn deinit(self: *Host) void {
        self.stop();
        for (self.jobs.items) |job| job.destroy(self.allocator);
        self.jobs.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn run(self: *Host) !void {
        defer self.stop();
        try self.mutex.lock(self.shell.io);
        defer self.mutex.unlock(self.shell.io);
        while (self.failure == null) try self.changed.wait(self.shell.io, &self.mutex);
        return self.failure.?;
    }
    pub fn tools(self: *Host, a: Allocator) !Tools {
        return .{ .context = self, .invoke = invokeTool, .declarations = try std.json.parseFromSliceLeaky([]const Model.Tool, a, @embedFile("tools.json"), .{}) };
    }
    fn invokeTool(context: *anyopaque, a: Allocator, invocation: Tools.Invocation, name: []const u8, arguments: []const u8) anyerror!?Content {
        const self: *Host = @ptrCast(@alignCast(context));
        return try self.invoke(a, invocation, try Request.parse(a, name, arguments) orelse return null);
    }
    pub fn invoke(self: *Host, a: Allocator, context: Context, request: Request) !Content {
        return switch (request) {
            .get_host_shell => |args| self.describe(a, args.command_id),
            .run_host_shell => |args| self.start(a, context, args),
            .continue_host_shell => |args| self.continueCommand(a, args),
        };
    }

    fn start(self: *Host, a: Allocator, context: Context, args: Shell.Command) !Content {
        const job = switch (try self.createJob(context.session_id, args)) {
            .capacity => return toolError(a, "commands_unavailable", "The live host command limit has been reached. The command was not started."),
            .unavailable => |err| return toolError(a, "host_unavailable", try std.fmt.allocPrint(a, "Could not prepare the command: {s}. The command was not started.", .{@errorName(err)})),
            .job => |job| job,
        };
        defer self.release(job);
        var detached = false;
        defer if (!detached) self.retireAndStop(job);
        try job.operations.lock(self.shell.io);
        defer job.operations.unlock(self.shell.io);
        try self.waitForUpdate(job, args.yield_ms, true);
        try self.mutex.lock(self.shell.io);
        const needs_handoff = job.state == .running;
        self.mutex.unlock(self.shell.io);
        if (needs_handoff) {
            const registrar = context.callback orelse {
                self.stopAndWait(job);
                return self.handoffFailure(a, job, "This call has no session destination for command completion.");
            };
            const id = registrar.open() catch |err| {
                if (err != error.CallbackCapacityUnavailable) return err;
                self.stopAndWait(job);
                return self.handoffFailure(a, job, "The session's callback source limit has been reached.");
            };
            try self.mutex.lock(self.shell.io);
            job.command_id = id;
            self.pruneFinishedLocked();
            self.mutex.unlock(self.shell.io);
            detached = true;
        }
        return self.observe(a, job, if (detached) .incremental else .complete, args.max_output_bytes);
    }

    fn createJob(self: *Host, session_id: u64, args: Shell.Command) !Create {
        try self.mutex.lock(self.shell.io);
        if (self.stopping) {
            self.mutex.unlock(self.shell.io);
            return error.Canceled;
        }
        if (self.active >= self.max_host_commands) {
            self.mutex.unlock(self.shell.io);
            return .capacity;
        }
        // Reserve capacity before setup, without blocking other commands on
        // filesystem or executable startup I/O under the registry mutex.
        self.active += 1;
        self.mutex.unlock(self.shell.io);
        var reservation = true;
        defer if (reservation) {
            self.mutex.lockUncancelable(self.shell.io);
            self.active -= 1;
            self.mutex.unlock(self.shell.io);
        };
        const job = try self.allocator.create(Job);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        var initialized = false;
        var transferred = false;
        defer if (!transferred) {
            if (initialized) job.invocation.deinit();
            arena.deinit();
            self.allocator.destroy(job);
        };
        const owned = arena.allocator();
        var command = args;
        command.command = try owned.dupe(u8, args.command);
        command.cwd = if (args.cwd) |cwd| try owned.dupe(u8, cwd) else null;
        command.shell = if (args.shell) |shell| try owned.dupe(u8, shell) else null;
        const invocation = switch (try self.shell.start(owned, session_id, command)) {
            .ready => |invocation| invocation,
            .unavailable => |err| return .{ .unavailable = err },
        };
        job.* = .{ .arena = arena, .invocation = invocation, .args = command, .session_id = session_id, .state = switch (invocation.backend) {
            .process => .running,
            .not_started => |reason| .{ .finished = .{ .not_started = .{ .reason = reason } } },
        }, .input_open = args.mode != .batch and invocation.backend == .process };
        initialized = true;
        try self.mutex.lock(self.shell.io);
        defer self.mutex.unlock(self.shell.io);
        if (self.stopping) return error.Canceled;
        try self.jobs.append(self.allocator, job);
        errdefer _ = self.jobs.pop();
        if (job.state == .running) {
            job.refs += 1;
            try self.tasks.concurrent(self.shell.io, supervise, .{ self, job });
        } else {
            self.active -= 1;
            job.elapsed_ms = invocation.elapsed();
        }
        reservation = false;
        transferred = true;
        return .{ .job = job };
    }

    fn continueCommand(self: *Host, a: Allocator, args: Continue) !Content {
        const job = try self.acquire(args.command_id) orelse return toolError(a, "unknown_command", "This command handle is unknown or retired. Check its completion callback or recorded log paths; handles are not restored after restart.");
        defer self.release(job);
        // Apply input or a signal promptly even when another caller is
        // waiting to collect this command's next output range.
        if (try self.act(a, job, args.action)) |failure| return failure;
        try job.operations.lock(self.shell.io);
        defer job.operations.unlock(self.shell.io);
        try self.waitForUpdate(job, args.yield_ms, false);
        const result = try self.observe(a, job, .incremental, args.max_output_bytes);
        const current = try self.snapshot(job);
        if (current.state != .running and try job.invocation.drained(job.cursors)) self.retire(job);
        return result;
    }

    fn act(self: *Host, a: Allocator, job: *Job, action: Action) !?Content {
        if (action == .read) return null;
        try self.mutex.lock(self.shell.io);
        if (job.state != .running) {
            self.mutex.unlock(self.shell.io);
            return try toolError(a, "command_finished", "The command has already finished. Omit action or use read to collect its remaining output.");
        }
        switch (action) {
            .write => |write| {
                if (!job.input_open) {
                    self.mutex.unlock(self.shell.io);
                    return try toolError(a, "stdin_closed", "This command has no writable stdin. Batch mode has no live input, and pipe stdin cannot reopen after EOF.");
                }
                if (job.input_pending) {
                    self.mutex.unlock(self.shell.io);
                    return try toolError(a, "input_busy", "The previous input is still being written. Read or wait before submitting more input.");
                }
                const bytes = self.allocator.dupe(u8, write.text) catch |err| {
                    self.mutex.unlock(self.shell.io);
                    return err;
                };
                job.input_pending = true;
                job.input_error = null;
                job.refs += 1;
                job.input_tasks.concurrent(self.shell.io, writeInput, .{ self, job, bytes, write.eof }) catch |err| {
                    job.refs -= 1;
                    job.input_pending = false;
                    self.allocator.free(bytes);
                    self.mutex.unlock(self.shell.io);
                    return err;
                };
                self.mutex.unlock(self.shell.io);
                return null;
            },
            else => self.mutex.unlock(self.shell.io),
        }
        switch (action) {
            .signal => |signal| job.invocation.backend.process.signal(self.shell.io, signal.name) catch |err| switch (err) {
                error.Canceled => return err,
                else => return try toolError(a, "control_failed", try std.fmt.allocPrint(a, "Could not signal the command: {s}.", .{@errorName(err)})),
            },
            .resize => |size| job.invocation.backend.process.resize(size.rows, size.cols) catch |err| return try toolError(a, "control_failed", try std.fmt.allocPrint(a, "Could not resize the command terminal: {s}.", .{@errorName(err)})),
            else => unreachable,
        }
        return null;
    }

    fn writeInput(self: *Host, job: *Job, bytes: []const u8, eof: bool) std.Io.Cancelable!void {
        defer self.allocator.free(bytes);
        defer self.release(job);
        const failure: ?anyerror = blk: {
            job.invocation.backend.process.writeInput(self.shell.io, bytes) catch |err| break :blk err;
            if (eof) job.invocation.backend.process.endInput(self.shell.io) catch |err| break :blk err;
            break :blk null;
        };
        self.mutex.lockUncancelable(self.shell.io);
        job.input_pending = false;
        job.input_error = failure;
        if (eof and job.args.mode == .pipe and failure == null) job.input_open = false;
        self.changed.broadcast(self.shell.io);
        self.mutex.unlock(self.shell.io);
        if (failure) |err| if (err == error.Canceled) return error.Canceled;
    }

    fn supervise(self: *Host, job: *Job) std.Io.Cancelable!void {
        defer self.release(job);
        const result: State = if (job.invocation.backend.process.wait(self.shell.io, job.args.timeout_ms)) |outcome| .{ .finished = outcome } else |err| .{ .failed = err };
        self.mutex.lockUncancelable(self.shell.io);
        job.state = result;
        job.elapsed_ms = job.invocation.elapsed();
        self.mutex.unlock(self.shell.io);
        // Prevent new input, then cancel an outstanding write even when an
        // escaped descendant still holds the read end of the pipe.
        job.input_tasks.cancel(self.shell.io);
        self.mutex.lockUncancelable(self.shell.io);
        self.active -= 1;
        self.completed_sequence += 1;
        job.completed_sequence = self.completed_sequence;
        if (result == .failed and result.failed == error.OutOfMemory) self.failLocked(error.OutOfMemory);
        self.changed.broadcast(self.shell.io);
        self.pruneFinishedLocked();
        self.mutex.unlock(self.shell.io);
        if (result == .failed and result.failed == error.Canceled) return error.Canceled;
        // The initial call holds operations through durable handoff. Read its
        // final decision only after that gate, including a fast exit while
        // callback registration was still being persisted.
        self.publishCompletion(job) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.mutex.lockUncancelable(self.shell.io);
            self.failLocked(err);
            self.mutex.unlock(self.shell.io);
        };
    }

    fn publishCompletion(self: *Host, job: *Job) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        try job.operations.lock(self.shell.io);
        var locked = true;
        defer if (locked) job.operations.unlock(self.shell.io);
        try self.mutex.lock(self.shell.io);
        const callback = if (self.stopping) null else job.command_id;
        self.mutex.unlock(self.shell.io);
        const id = callback orelse return;
        const result = try self.observe(a, job, .callback, job.args.max_output_bytes);
        job.operations.unlock(self.shell.io);
        locked = false;
        try self.publisher.send(a, .{ .id = id, .text = result.parts[0].text });
    }

    fn observe(self: *Host, a: Allocator, job: *Job, kind: Shell.Collection, budget: usize) !Content {
        const observation = self.collect(a, job, kind, budget) catch |err| return outputFailure(a, err);
        return observation.render(a, null);
    }

    fn collect(self: *Host, a: Allocator, job: *Job, kind: Shell.Collection, budget: usize) !Observation {
        const current = try self.snapshot(job);
        return .{
            .command_id = job.command_id,
            .snapshot = current,
            .mode = job.args.mode,
            .streams = try job.invocation.collect(a, &job.cursors, &job.media_checked, kind, current.state != .running, job.args.interpretation, budget),
        };
    }

    fn snapshot(self: *Host, job: *Job) !Snapshot {
        try self.mutex.lock(self.shell.io);
        defer self.mutex.unlock(self.shell.io);
        return .{ .state = switch (job.state) {
            .running => .running,
            .finished => |outcome| .{ .finished = outcome },
            .failed => |err| .{ .unavailable = .{ .reason = @errorName(err) } },
        }, .elapsed_ms = if (job.state == .running) job.invocation.elapsed() else job.elapsed_ms, .stdin = .{ .open = job.input_open and job.state == .running, .pending = job.input_pending, .@"error" = if (job.input_error) |err| @errorName(err) else null } };
    }

    fn waitForUpdate(self: *Host, job: *Job, milliseconds: u32, wait_for_exit: bool) !void {
        const deadline = std.Io.Clock.Timestamp.fromNow(self.shell.io, .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake });
        if (wait_for_exit) {
            try self.mutex.lock(self.shell.io);
            defer self.mutex.unlock(self.shell.io);
            while (job.state == .running) self.changed.waitTimeout(self.shell.io, &self.mutex, .{ .deadline = deadline }) catch |err| switch (err) {
                error.Timeout => return,
                error.Canceled => return err,
            };
            return;
        }
        while (true) {
            if (try job.invocation.readable(job.cursors)) return;
            const remaining = deadline.durationFromNow(self.shell.io).raw.toMilliseconds();
            if (remaining <= 0) return;
            try self.mutex.lock(self.shell.io);
            defer self.mutex.unlock(self.shell.io);
            if (job.state != .running) return;
            // Children write regular log files directly. Check their growth
            // periodically, while completion can wake the waiter immediately.
            self.changed.waitTimeout(self.shell.io, &self.mutex, .{ .duration = .{ .raw = .fromMilliseconds(@min(remaining, 20)), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return err,
            };
        }
    }

    fn describe(self: *Host, a: Allocator, selected_id: ?u64) !Content {
        const Entry = struct { command_id: u64, session_id: u64, command_preview: []const u8, state: PublicState, mode: Shell.Mode, stdin_open: bool, input_pending: bool };
        var entries: std.ArrayList(Entry) = .empty;
        try self.mutex.lock(self.shell.io);
        defer self.mutex.unlock(self.shell.io);
        var total: usize = 0;
        for (self.jobs.items) |job| if (job.command_id != null and (selected_id == null or job.command_id == selected_id)) {
            total += 1;
        };
        if (selected_id != null and total == 0) return toolError(a, "unknown_command", "This command handle is unknown or retired.");
        for (self.jobs.items) |job| {
            const id = job.command_id orelse continue;
            if (selected_id) |selected| if (id != selected) continue;
            var end = @min(job.args.command.len, 160);
            while (end > 0 and end < job.args.command.len and job.args.command[end] & 0xc0 == 0x80) end -= 1;
            try entries.append(a, .{ .command_id = id, .session_id = job.session_id, .command_preview = job.args.command[0..end], .state = switch (job.state) {
                .running => .running,
                .finished => |outcome| .{ .finished = outcome },
                .failed => |err| .{ .unavailable = .{ .reason = @errorName(err) } },
            }, .mode = job.args.mode, .stdin_open = job.input_open and job.state == .running, .input_pending = job.input_pending });
            if (encodedLength(.{ .result = .{ .shell = "/bin/sh", .cwd = self.shell.directory, .commands = entries.items, .commands_truncated = true, .total_commands = total } }) > 32768) {
                _ = entries.pop();
                break;
            }
        }
        return Content.fromText(a, try success(a, .{ .shell = "/bin/sh", .cwd = self.shell.directory, .commands = entries.items, .commands_truncated = entries.items.len < total, .total_commands = total }));
    }

    fn handoffFailure(self: *Host, a: Allocator, job: *Job, reason: []const u8) !Content {
        const observation = self.collect(a, job, .complete, job.args.max_output_bytes) catch |err| return outputFailure(a, err);
        return observation.render(a, .{
            .code = "handoff_unavailable",
            .message = reason,
            .effects = "The command started before handoff failed. It has now finished or been stopped and reaped; effects already produced remain.",
        });
    }
    fn acquire(self: *Host, id: u64) !?*Job {
        try self.mutex.lock(self.shell.io);
        defer self.mutex.unlock(self.shell.io);
        for (self.jobs.items) |job| if (job.command_id == id) {
            job.refs += 1;
            return job;
        };
        return null;
    }
    fn release(self: *Host, job: *Job) void {
        self.mutex.lockUncancelable(self.shell.io);
        job.refs -= 1;
        const destroy = job.refs == 0;
        self.mutex.unlock(self.shell.io);
        if (destroy) job.destroy(self.allocator);
    }
    fn retire(self: *Host, job: *Job) void {
        self.mutex.lockUncancelable(self.shell.io);
        defer self.mutex.unlock(self.shell.io);
        self.retireLocked(job);
    }
    fn retireLocked(self: *Host, job: *Job) void {
        for (self.jobs.items, 0..) |entry, index| if (entry == job) {
            _ = self.jobs.swapRemove(index);
            job.refs -= 1;
            if (job.refs == 0) job.destroy(self.allocator);
            return;
        };
    }
    fn retireAndStop(self: *Host, job: *Job) void {
        self.stopAndWait(job);
        self.retire(job);
    }
    fn stopAndWait(self: *Host, job: *Job) void {
        self.mutex.lockUncancelable(self.shell.io);
        defer self.mutex.unlock(self.shell.io);
        if (job.state == .running) {
            job.invocation.backend.process.cancel(self.shell.io);
            while (job.state == .running) self.changed.waitUncancelable(self.shell.io, &self.mutex);
        }
    }
    fn pruneFinishedLocked(self: *Host) void {
        while (true) {
            var count: usize = 0;
            var oldest: ?*Job = null;
            for (self.jobs.items) |job| if (job.command_id != null and job.state != .running) {
                count += 1;
                if (oldest == null or job.completed_sequence < oldest.?.completed_sequence) oldest = job;
            };
            if (count <= self.max_host_commands) return;
            self.retireLocked(oldest.?);
        }
    }
    fn failLocked(self: *Host, err: anyerror) void {
        if (self.failure == null) self.failure = err;
        self.changed.broadcast(self.shell.io);
    }
    fn stop(self: *Host) void {
        self.mutex.lockUncancelable(self.shell.io);
        self.stopping = true;
        self.mutex.unlock(self.shell.io);
        self.tasks.cancel(self.shell.io);
    }
};

fn success(a: Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{ .result = value }, .{ .emit_null_optional_fields = false });
}
fn toolError(a: Allocator, code: []const u8, message: []const u8) !Content {
    return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .@"error" = .{ .code = code, .message = message } }, .{}));
}
fn validText(value: []const u8) bool {
    return value.len != 0 and std.mem.indexOfScalar(u8, value, 0) == null;
}
fn validLimits(yield_ms: u32, budget: u32) bool {
    return yield_ms <= 30000 and budget >= 512 and budget <= 16384;
}

fn outputFailure(a: Allocator, err: anyerror) !Content {
    return switch (err) {
        error.Canceled, error.OutOfMemory => err,
        else => toolError(a, "host_unavailable", try std.fmt.allocPrint(a, "Could not read the command output: {s}. Command or input effects may already have occurred.", .{@errorName(err)})),
    };
}
fn encodedLength(value: anytype) usize {
    var buffer: [128]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&buffer);
    std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &discard.writer) catch unreachable;
    return @intCast(discard.fullCount());
}
