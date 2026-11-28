const std = @import("std");
const Shell = @import("shell.zig").Shell;
const process = @import("process.zig");
const Content = @import("content").Content;
const Allocator = std.mem.Allocator;
const contracts = @import("agent_contracts");
const Callback = contracts.Callback;
const Tools = contracts.Tools;
const Model = contracts.Model;
const Reference = contracts.Reference;
const finished_command_cache = 8;
const max_input_characters = 4096;

/// One process registry serves completed calls and background commands.
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
        write: struct { text: contracts.JsonString, eof: bool = false },
        signal: struct { name: process.Signal },
        resize: struct { rows: u16, cols: u16 },
    };
    pub const Continue = struct {
        command_id: contracts.JsonString,
        action: Action = .{ .read = .{} },
        yield_ms: u32 = 1000,
        max_output_bytes: u32 = Shell.default_output_bytes,
    };
    pub const Inspect = struct { command_id: ?contracts.JsonString = null, offset: usize = 0 };
    pub const Request = union(enum) {
        inspect_host_shell: Inspect,
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
                .inspect_host_shell => |args| if (args.command_id) |id| {
                    if (!validText(id.bytes)) return error.InvalidToolArguments;
                },
                .run_host_shell => |args| {
                    if (!Reference.validName(args.name.bytes) or !validText(args.command.bytes) or !validBudget(args.max_output_bytes) or args.timeout_ms == 0) return error.InvalidToolArguments;
                },
                .continue_host_shell => |args| {
                    if (!validText(args.command_id.bytes) or !validBudget(args.max_output_bytes)) return error.InvalidToolArguments;
                    switch (args.action) {
                        .write => |write| {
                            const length = std.unicode.utf8CountCodepoints(write.text.bytes) catch return error.InvalidToolArguments;
                            if (length > max_input_characters) return error.InvalidToolArguments;
                        },
                        .resize => |size| if (size.rows == 0 or size.cols == 0) return error.InvalidToolArguments,
                        else => {},
                    }
                },
            }
            return request;
        }
    };

    const State = union(enum) { running, finished: process.Outcome, unavailable: struct { reason: []const u8 } };
    const Job = struct {
        arena: std.heap.ArenaAllocator,
        invocation: Shell.Invocation,
        mode: Shell.Mode,
        timeout_ms: ?u32 = null,
        max_output_bytes: u32,
        focus_id: []const u8,
        command_id: []const u8,
        retained: bool,
        callback_id: ?u64 = null,
        // Publish only after the initial call finishes its handoff decision.
        handoff_pending: bool = true,
        settled: bool = false,
        refs: usize = 2, // Registry and initial invocation; tasks add their own refs.
        operations: std.Io.Mutex = .init,
        state: State,
        elapsed_ms: u64 = 0,
        completed_sequence: u64 = 0,
        cursors: [2]u64 = .{ 0, 0 }, // Protected by operations, not the registry lock.
        input_pending: bool = false,
        input_error: ?[]const u8 = null,
        input_open: bool,
        input_tasks: std.Io.Group = .init,

        fn destroy(self: *Job, allocator: Allocator) void {
            self.invocation.deinit();
            self.arena.deinit();
            allocator.destroy(self);
        }
    };
    const InputStatus = struct { open: bool, pending: bool, @"error": ?[]const u8 };
    const Snapshot = struct { state: State, elapsed_ms: u64, stdin: InputStatus };
    const Create = union(enum) { capacity, unavailable, job: *Job };
    const Collection = union(enum) { complete, initial, incremental: u32 };
    const ToolError = struct { code: []const u8, message: []const u8, effects: []const u8 };
    const unreadable_output: ToolError = .{
        .code = "host_unavailable",
        .message = "Could not read the command output.",
        .effects = "The result includes the observed command state and log paths. Check uncertain effects before repeating the command.",
    };
    const Observation = struct {
        command_id: ?[]const u8,
        callback_id: ?[]const u8 = null,
        snapshot: Snapshot,
        mode: Shell.Mode,
        streams: Shell.Streams,
        output_error: ?[]const u8 = null,

        fn render(self: Observation, a: Allocator) !Content {
            return Content.fromText(a, try self.renderText(a, null));
        }

        fn renderText(self: Observation, a: Allocator, failure: ?ToolError) ![]const u8 {
            return std.json.Stringify.valueAlloc(a, .{
                .@"error" = failure,
                .result = .{
                    .command_id = self.command_id,
                    .callback_id = self.callback_id,
                    .state = self.snapshot.state,
                    .elapsed_ms = self.snapshot.elapsed_ms,
                    .mode = self.mode,
                    .stdin = self.snapshot.stdin,
                    .stdout = self.streams.stdout,
                    .stderr = self.streams.stderr,
                    .output_error = self.output_error,
                },
            }, .{ .emit_null_optional_fields = false });
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
            .inspect_host_shell => |args| self.describe(a, args),
            .run_host_shell => |args| self.execute(a, context, args),
            .continue_host_shell => |args| self.continueCommand(a, args),
        };
    }

    fn execute(self: *Host, a: Allocator, context: Context, args: Shell.Command) !Content {
        const registrar = context.callback orelse return error.MissingCallbackRegistrar;
        const issuer = context.command_reference orelse return error.MissingCommandReferenceIssuer;
        const job = switch (try self.createJob(context.session_id, context.focus_id, issuer, args)) {
            .capacity => return toolError(a, "commands_unavailable", "The live host command limit has been reached. The command was not started."),
            .unavailable => return toolError(a, "host_unavailable", "Could not prepare the command logs. The command was not started."),
            .job => |job| job,
        };
        defer self.release(job);
        defer self.finishHandoff(job);
        var retained = false;
        defer if (!retained) self.retireAndStop(job);
        // Waiting for execution does not own the observation cursor. Other
        // activities may inspect or control this command while its caller waits.
        try self.waitForCompletion(job, args.yield_ms);
        try self.mutex.lock(self.shell.io);
        const needs_handoff = !job.settled;
        self.mutex.unlock(self.shell.io);
        if (needs_handoff) {
            const registration = try registrar.open(a, args.name.bytes, job.command_id);
            try self.mutex.lock(self.shell.io);
            job.callback_id = registration.id;
            job.retained = true;
            retained = true;
            self.pruneFinishedLocked();
            self.mutex.unlock(self.shell.io);
            errdefer self.retireAndStop(job);
            var observation = self.collect(a, job, .initial, args.max_output_bytes) catch |err|
                return Content.fromText(a, try self.outputFailureText(a, job, job.command_id, registration.reference, err, .{
                    .code = "host_unavailable",
                    .message = "Could not read the command's initial background output.",
                    .effects = "The command was handed off successfully, and a completion observation was registered for this focus. Command or input effects may already have occurred.",
                }));
            observation.callback_id = registration.reference;
            return observation.render(a);
        }
        const observation = self.collect(a, job, .complete, args.max_output_bytes) catch |err|
            return Content.fromText(a, try self.outputFailureText(a, job, null, null, err, unreadable_output));
        return observation.render(a);
    }

    fn createJob(self: *Host, session_id: u64, focus: []const u8, issuer: Reference.Issuer, args: Shell.Command) !Create {
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
        const reference = try issuer.create(owned, args.name.bytes);
        const focus_id = try owned.dupe(u8, focus);
        const invocation = switch (try self.shell.start(owned, session_id, args)) {
            .ready => |invocation| invocation,
            .unavailable => return .unavailable,
        };
        job.* = .{
            .arena = arena,
            .invocation = invocation,
            .mode = args.mode,
            .timeout_ms = args.timeout_ms,
            .max_output_bytes = args.max_output_bytes,
            .focus_id = focus_id,
            .command_id = reference,
            .retained = false,
            .state = switch (invocation.backend) {
                .process => .running,
                .not_started => |reason| .{ .finished = .{ .not_started = .{ .reason = reason } } },
            },
            .settled = invocation.backend == .not_started,
            .input_open = args.mode != .batch and invocation.backend == .process,
        };
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
        const job = try self.acquire(args.command_id.bytes) orelse return toolError(a, "unknown_command", "This command handle is unknown or retired. Use inspect_host_shell to list current commands.");
        defer self.release(job);
        // Apply input or a signal promptly even when another caller is
        // waiting to collect this command's next output range.
        if (try self.act(a, job, args.action)) |failure| return failure;
        try job.operations.lock(self.shell.io);
        defer job.operations.unlock(self.shell.io);
        const observation = self.collect(a, job, .{ .incremental = args.yield_ms }, args.max_output_bytes) catch |err|
            return Content.fromText(a, try self.outputFailureText(a, job, job.command_id, null, err, unreadable_output));
        const result = try observation.render(a);
        // Retirement must follow the state returned to this caller. Completion
        // racing with a running snapshot still needs one terminal observation.
        if (observation.snapshot.state != .running and try job.invocation.drained(job.cursors)) {
            try self.mutex.lock(self.shell.io);
            defer self.mutex.unlock(self.shell.io);
            if (job.retained) self.retireLocked(job);
        }
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
                const bytes = self.allocator.dupe(u8, write.text.bytes) catch |err| {
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
            .signal => |signal| job.invocation.backend.process.signal(self.shell.io, signal.name) catch |err| {
                if (err == error.Canceled) return err;
                std.log.debug("could not send {s} to host command {s}: {s}", .{ @tagName(signal.name), job.command_id, @errorName(err) });
                const message = switch (err) {
                    error.ProcessNotFound => "The process is no longer available. Read the command state and remaining output.",
                    error.AccessDenied, error.PermissionDenied => "The host lacks permission to signal one or more processes.",
                    else => "Could not confirm that the signal reached the command. Read its state before trying again.",
                };
                return try toolError(a, "control_failed", message);
            },
            .resize => |size| job.invocation.backend.process.resize(size.rows, size.cols) catch |err| {
                std.log.debug("could not resize terminal for host command {s}: {s}", .{ job.command_id, @errorName(err) });
                return try toolError(a, "control_failed", switch (err) {
                    error.NotATerminal => "This command has no resizable terminal.",
                    error.AccessDenied => "The host lacks permission to resize the command terminal.",
                    else => "Could not resize the command terminal.",
                });
            },
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
        job.input_error = if (failure) |err| switch (err) {
            error.InputClosed, error.BrokenPipe => "The input stream closed during the write.",
            error.ProcessNotFound => "The command exited before the input operation completed.",
            error.Canceled => "Writing input was interrupted.",
            else => "Could not complete the input write.",
        } else null;
        if (eof and job.mode == .pipe and failure == null) job.input_open = false;
        self.changed.broadcast(self.shell.io);
        self.mutex.unlock(self.shell.io);
        if (failure) |err| {
            if (err == error.Canceled) return error.Canceled;
            std.log.debug("could not write input to host command {s}: {s}", .{ job.command_id, @errorName(err) });
        }
    }

    fn supervise(self: *Host, job: *Job) std.Io.Cancelable!void {
        defer self.release(job);
        const result = job.invocation.backend.process.wait(self.shell.io, job.timeout_ms);
        const failure: ?anyerror = if (result) |_| null else |err| err;
        self.mutex.lockUncancelable(self.shell.io);
        job.state = if (result) |outcome| .{ .finished = outcome } else |err| .{ .unavailable = .{
            .reason = switch (err) {
                error.TerminalDrainTimedOut => "The command started but collection of its terminal output timed out. Check its output and effects before repeating the command.",
                else => "The command started but its final outcome is unavailable. Check its output and effects before repeating the command.",
            },
        } };
        job.elapsed_ms = job.invocation.elapsed();
        self.mutex.unlock(self.shell.io);
        // Prevent new input, then cancel an outstanding write even when an
        // escaped descendant still holds the read end of the pipe.
        job.input_tasks.cancel(self.shell.io);
        self.mutex.lockUncancelable(self.shell.io);
        self.active -= 1;
        job.settled = true;
        self.completed_sequence += 1;
        job.completed_sequence = self.completed_sequence;
        if (failure) |err| if (err == error.OutOfMemory) self.failLocked(err);
        self.changed.broadcast(self.shell.io);
        self.pruneFinishedLocked();
        self.mutex.unlock(self.shell.io);
        if (failure) |err| {
            if (err == error.Canceled) return error.Canceled;
            std.log.debug("could not observe final outcome for host command {s}: {s}", .{ job.command_id, @errorName(err) });
        }
        self.publishCompletion(job) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.mutex.lockUncancelable(self.shell.io);
            self.failLocked(err);
            self.mutex.unlock(self.shell.io);
        };
    }

    fn finishHandoff(self: *Host, job: *Job) void {
        self.mutex.lockUncancelable(self.shell.io);
        defer self.mutex.unlock(self.shell.io);
        job.handoff_pending = false;
        self.changed.broadcast(self.shell.io);
    }

    fn publishCompletion(self: *Host, job: *Job) !void {
        const id = blk: {
            try self.mutex.lock(self.shell.io);
            defer self.mutex.unlock(self.shell.io);
            while (job.handoff_pending and !self.stopping) try self.changed.wait(self.shell.io, &self.mutex);
            if (self.stopping) return;
            break :blk job.callback_id orelse return;
        };
        // The supervision reference retains logs even after another activity
        // drains or the registry reclaims the command's control handle.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const observation = self.collect(a, job, .complete, job.max_output_bytes) catch |err| {
            const failure = try self.outputFailureText(a, job, null, null, err, unreadable_output);
            return self.publisher.send(a, .{ .id = id, .text = failure });
        };
        try self.publisher.send(a, .{ .id = id, .text = try observation.renderText(a, null) });
    }

    fn collect(self: *Host, a: Allocator, job: *Job, kind: Collection, budget: usize) !Observation {
        if (kind == .incremental) try self.waitForUpdate(job, kind.incremental);
        const current = try self.snapshot(job);
        return .{
            .command_id = if (kind == .complete) null else job.command_id,
            .snapshot = current,
            .mode = job.mode,
            .streams = switch (kind) {
                .complete => try job.invocation.complete(a, budget),
                .initial => blk: {
                    // The starting call observes its own prefix without waiting
                    // behind another activity or consuming its shared cursor.
                    var cursors: [2]u64 = .{ 0, 0 };
                    break :blk try job.invocation.incremental(a, &cursors, current.state != .running, budget);
                },
                .incremental => try job.invocation.incremental(a, &job.cursors, current.state != .running, budget),
            },
        };
    }

    fn snapshot(self: *Host, job: *Job) !Snapshot {
        try self.mutex.lock(self.shell.io);
        defer self.mutex.unlock(self.shell.io);
        return .{
            .state = job.state,
            .elapsed_ms = if (job.state == .running) job.invocation.elapsed() else job.elapsed_ms,
            .stdin = .{
                .open = job.input_open and job.state == .running,
                .pending = job.input_pending,
                .@"error" = job.input_error,
            },
        };
    }

    fn waitForCompletion(self: *Host, job: *Job, milliseconds: u32) !void {
        try self.mutex.lock(self.shell.io);
        defer self.mutex.unlock(self.shell.io);
        const deadline = std.Io.Clock.Timestamp.fromNow(self.shell.io, .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake });
        while (!job.settled) self.changed.waitTimeout(self.shell.io, &self.mutex, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => return,
            error.Canceled => return err,
        };
    }

    fn waitForUpdate(self: *Host, job: *Job, milliseconds: u32) !void {
        const deadline = std.Io.Clock.Timestamp.fromNow(self.shell.io, .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake });
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

    fn describe(self: *Host, a: Allocator, args: Inspect) !Content {
        const Entry = struct { command_id: []const u8, focus_id: []const u8, state: State, mode: Shell.Mode, stdin_open: bool, input_pending: bool };
        const Page = struct {
            shell: ?[]const u8 = null,
            cwd: ?[]const u8 = null,
            commands: []const Entry = &.{},
            offset: usize,
            next_offset: std.json.Value = .null,
            total_commands: usize = 0,

            fn setEntries(page: *@This(), entries: []const Entry) void {
                page.commands = entries;
                const end = page.offset + entries.len;
                page.next_offset = if (end < page.total_commands) .{ .integer = @intCast(end) } else .null;
            }
        };
        const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
        var page: Page = .{ .offset = args.offset };
        if (args.command_id == null and args.offset == 0) {
            page.shell = "/bin/sh";
            page.cwd = try contracts.LocalPath.reference(a, self.shell.directory);
        }
        var entries: std.ArrayList(Entry) = .empty;
        try self.mutex.lock(self.shell.io);
        defer self.mutex.unlock(self.shell.io);
        for (self.jobs.items) |job| if (args.command_id == null or std.mem.eql(u8, job.command_id, args.command_id.?.bytes)) {
            page.total_commands += 1;
        };
        if (args.command_id != null and page.total_commands == 0) return toolError(a, "unknown_command", "This command handle is unknown or retired. Omit command_id to find current commands.");
        var position: usize = 0;
        for (self.jobs.items) |job| {
            const id = job.command_id;
            if (args.command_id) |selected| if (!std.mem.eql(u8, id, selected.bytes)) continue;
            if (position < args.offset) {
                position += 1;
                continue;
            }
            try entries.append(a, .{
                .command_id = id,
                .focus_id = job.focus_id,
                .state = job.state,
                .mode = job.mode,
                .stdin_open = job.input_open and job.state == .running,
                .input_pending = job.input_pending,
            });
            page.setEntries(entries.items);
            if (std.fmt.count("{f}", .{std.json.fmt(.{ .result = page }, options)}) > 32768) {
                _ = entries.pop();
                page.setEntries(entries.items);
                break;
            }
        }
        return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .result = page }, options));
    }

    fn outputFailureText(self: *Host, a: Allocator, job: *Job, command_id: ?[]const u8, callback_id: ?[]const u8, err: anyerror, failure: ToolError) ![]const u8 {
        switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => {},
        }
        std.log.debug("could not collect output for host command {s}: {s}", .{ job.command_id, @errorName(err) });
        const observation: Observation = .{
            .command_id = command_id,
            .callback_id = callback_id,
            .snapshot = try self.snapshot(job),
            .mode = job.mode,
            .streams = .{
                .stdout = .{ .log = .{ .path = job.invocation.stdout_reference } },
                .stderr = .{ .log = .{ .path = job.invocation.stderr_reference } },
            },
            .output_error = "Could not read the retained command output.",
        };
        return observation.renderText(a, failure);
    }

    fn acquire(self: *Host, id: []const u8) !?*Job {
        try self.mutex.lock(self.shell.io);
        defer self.mutex.unlock(self.shell.io);
        for (self.jobs.items) |job| if (std.mem.eql(u8, job.command_id, id)) {
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
    fn retireLocked(self: *Host, job: *Job) void {
        for (self.jobs.items, 0..) |entry, index| if (entry == job) {
            _ = self.jobs.swapRemove(index);
            job.refs -= 1;
            if (job.refs == 0) job.destroy(self.allocator);
            return;
        };
    }
    fn retireAndStop(self: *Host, job: *Job) void {
        self.mutex.lockUncancelable(self.shell.io);
        defer self.mutex.unlock(self.shell.io);
        if (job.state == .running) {
            job.invocation.backend.process.cancel(self.shell.io);
        }
        while (!job.settled) self.changed.waitUncancelable(self.shell.io, &self.mutex);
        self.retireLocked(job);
    }
    fn pruneFinishedLocked(self: *Host) void {
        while (true) {
            var count: usize = 0;
            var oldest: ?*Job = null;
            for (self.jobs.items) |job| if (job.retained and job.state != .running) {
                count += 1;
                if (oldest == null or job.completed_sequence < oldest.?.completed_sequence) oldest = job;
            };
            if (count <= finished_command_cache) return;
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
        self.changed.broadcast(self.shell.io);
        self.mutex.unlock(self.shell.io);
        self.tasks.cancel(self.shell.io);
    }
};

fn toolError(a: Allocator, code: []const u8, message: []const u8) !Content {
    return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .@"error" = .{ .code = code, .message = message } }, .{}));
}
fn validText(value: []const u8) bool {
    return value.len != 0 and std.mem.indexOfScalar(u8, value, 0) == null;
}
fn validBudget(budget: u32) bool {
    return budget >= 512 and budget <= 16384;
}

test "shell defaults appear only on the first unfiltered inspection" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = std.process.Environ.Map.init(a);
    var host = Host.init(a, t.io, "/workspace", "/data", &env, undefined, 1);
    var job: Host.Job = .{
        .arena = undefined,
        .invocation = undefined,
        .mode = .batch,
        .max_output_bytes = 4096,
        .command_id = "build-1",
        .focus_id = "activity-1",
        .retained = true,
        .state = .running,
        .input_open = false,
    };
    try host.jobs.append(a, &job);
    for ([_]Host.Inspect{ .{}, .{ .command_id = .{ .bytes = job.command_id } }, .{ .offset = 1 } }, 0..) |args, i| {
        const result = try host.describe(a, args);
        const value = try std.json.parseFromSliceLeaky(std.json.Value, a, result.parts[0].text, .{});
        const fields = value.object.get("result").?.object;
        try t.expectEqual(i == 0, fields.contains("shell"));
        try t.expectEqual(i == 0, fields.contains("cwd"));
        const commands = fields.get("commands").?.array.items;
        try t.expectEqual(@as(usize, 1) - args.offset, commands.len);
        if (i == 0) {
            try t.expectEqualStrings(job.command_id, commands[0].object.get("command_id").?.string);
            try t.expect(!commands[0].object.contains("command_preview"));
        }
        try t.expect(fields.get("next_offset").? == .null);
    }
}

test "binary output exposes its log path and a printed data URL stays inline" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = "%PDF-1.7\nplain ASCII PDF content";
    const line = "data:image/png;base64,aGk=";
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buffer);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    const shell: Shell = .{
        .io = io,
        .environ = &env,
        .directory = buffer[0..n],
        .data_directory = try std.fs.path.join(a, &.{ buffer[0..n], "a b%20#?\xff" }),
    };
    var invocation = (try shell.start(a, 1, .{
        .name = .{ .bytes = "render" },
        .command = .{ .bytes = "printf '%s' '" ++ bytes ++ "'; printf '%s\\n' '" ++ line ++ "' >&2; exit 1" },
    })).ready;
    defer invocation.deinit();
    const outcome = try invocation.backend.process.wait(io, null);

    const complete: Host.Observation = .{
        .command_id = null,
        .snapshot = .{ .state = .{ .finished = outcome }, .elapsed_ms = 1, .stdin = .{ .open = false, .pending = false, .@"error" = null } },
        .mode = .batch,
        .streams = try invocation.complete(a, 512),
    };
    const result = try complete.render(a);
    try t.expectEqual(1, result.parts.len);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, result.parts[0].text, .{});
    const description = value.object.get("result").?.object;
    const stdout = description.get("stdout").?.object;
    const reference = stdout.get("path").?.string;
    const path = try contracts.LocalPath.fromReference(a, reference);
    try t.expectEqualStrings(bytes, try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(bytes.len + 1)));
    try t.expectEqual(@as(i64, bytes.len), stdout.get("byte_length").?.integer);
    try t.expect(!stdout.contains("uri") and !stdout.contains("preview"));
    try t.expectEqualStrings(line ++ "\n", description.get("stderr").?.string);

    var cursors: [2]u64 = .{ 0, 0 };
    const next = try invocation.incremental(a, &cursors, true, 512);
    try t.expectEqual(bytes.len, next.stdout.?.log.range.?.next_offset);
    try t.expectEqualStrings(line ++ "\n", next.stderr.?.text);
    try t.expect(try invocation.drained(cursors));
    const empty = try invocation.incremental(a, &cursors, true, 512);
    const encoded = try std.json.Stringify.valueAlloc(a, empty, .{ .emit_null_optional_fields = false });
    try t.expectEqualStrings("{}", encoded);
}

test "the shell accepts only text for a path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidToolArguments, Host.Request.parse(a, "run_host_shell",
        \\{"name":"job","command":"pwd","cwd":[47,255]}
    ));
}
