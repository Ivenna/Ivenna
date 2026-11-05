const std = @import("std");
const Context = @import("context.zig").Context;
const Compaction = @import("compaction.zig");
const Engine = @import("engine.zig").Engine;
const Content = @import("content.zig").Content;
const Input = @import("input.zig");
const Sessions = @import("sessions.zig");
const WorkInput = @import("work.zig");
const Communication = @import("communication.zig");
const EmailTransport = @import("email_transport.zig").EmailTransport;
const MailState = @import("mail_state.zig").MailState;
const MailSources = @import("mail_sources.zig").MailSources;
const Allocator = std.mem.Allocator;
const Session = Sessions.Session;
const Work = Sessions.Work;

/// Coordinate sessions, model/tool rounds, email, and internal state within
/// worker scopes. Core coordination has an independent execution lane.
pub const Kernel = struct {
    allocator: Allocator,
    io: std.Io,
    engine: *Engine,
    email: *EmailTransport,
    state: *MailState,
    sources: *MailSources,
    limits: Limits,
    poll_interval_ms: u32,
    max_parallel: usize,
    sessions: Sessions.Registry,
    reception: std.atomic.Value(enum(u8) { starting, open, closed }) = .init(.starting),

    pub const Limits = struct {
        request_bytes: u64 = 65536,
        compaction_bytes: u64 = 131072,
        handover_bytes: usize = 8192,
    };

    pub fn init(allocator: Allocator, io: std.Io, engine: *Engine, email: *EmailTransport, state: *MailState, sources: *MailSources, limits: Limits, poll_interval_ms: u32, max_parallel: usize, max_contexts: usize) !Kernel {
        return .{
            .allocator = allocator,
            .io = io,
            .engine = engine,
            .email = email,
            .state = state,
            .sources = sources,
            .limits = limits,
            .poll_interval_ms = poll_interval_ms,
            .max_parallel = max_parallel,
            .sessions = try Sessions.Registry.init(allocator, io, max_contexts),
        };
    }

    pub fn deinit(self: *Kernel) void {
        self.sessions.deinit();
        self.* = undefined;
    }

    const TaskResult = union(enum) { intake: anyerror!void, work: anyerror!void };
    const Tasks = std.Io.Select(TaskResult);

    pub fn isReceiving(self: *const Kernel) bool {
        return self.reception.load(.acquire) == .open;
    }

    pub fn closeReception(self: *Kernel) void {
        self.reception.store(.closed, .release);
    }

    pub fn run(self: *Kernel) !void {
        var results: [1]TaskResult = undefined;
        var tasks = Tasks.init(self.io, &results);
        defer {
            self.closeReception();
            tasks.cancelDiscard();
        }
        try tasks.concurrent(.intake, receiveLoop, .{ self, &tasks });
        while (true) switch (try tasks.await()) {
            .intake => |result| return result,
            .work => |result| {
                try result;
                try self.dispatch(&tasks);
            },
        };
    }

    fn receiveLoop(self: *Kernel, tasks: *Tasks) !void {
        try self.recollect();
        if (self.reception.cmpxchgStrong(.starting, .open, .release, .monotonic) != null) return;
        while (true) {
            try self.io.checkCancel();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const pending = try self.state.pending(a, try self.sessions.intakeLimit());
            var waiting: std.ArrayList(WorkInput.Incoming) = .empty;
            for (pending) |candidate| {
                const received = try self.email.receive(a, candidate.receipt, @intCast(@min(4096, self.limits.request_bytes / 8)));
                try waiting.append(a, .{
                    .input = received,
                    .receipt = candidate.receipt,
                });
            }
            try self.sessions.reconcile(waiting.items);
            for (waiting.items) |incoming| _ = try self.sessions.accept(incoming);
            try self.sources.sweep(try self.sessions.receiptsInUse(a));
            try self.dispatch(tasks);
            try self.io.sleep(.fromMilliseconds(self.poll_interval_ms), .awake);
        }
    }

    fn recollect(self: *Kernel) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        if (try self.state.loadHandover(a, "core", self.limits.handover_bytes)) |record| {
            try self.sessions.appendCoreInput(try Input.serialize(a, 1, .{ .background = .{ .items = &.{.{ .handover = record }} } }));
        }
        var background: std.ArrayList(Input.Background) = .empty;
        var base = try self.sessions.snapshotCore();
        defer base.deinit();
        var provider = self.engine.provider;
        provider.tool_scope = .coordination;
        const reserve = @min(4096, self.limits.request_bytes / 4);
        var selected: ?[]const u8 = null;
        for (try self.email.recent(a, 32)) |material| {
            try background.append(a, .{ .evidence = material });
            const rendered = try Input.serialize(a, 1, .{ .background = .{ .items = background.items } });
            var candidate = try base.fork(self.allocator);
            defer candidate.deinit();
            try candidate.appendInput(rendered);
            if (try provider.requestBytes(a, candidate.history()) > self.limits.request_bytes - reserve) break;
            selected = rendered;
        }
        if (selected) |rendered| try self.sessions.appendCoreInput(rendered);
    }

    fn dispatch(self: *Kernel, tasks: *Tasks) !void {
        while (try self.sessions.nextReady(self.max_parallel)) |work| {
            tasks.concurrent(.work, execute, .{ self, work }) catch |err| {
                self.sessions.endWorker(work.session.session_id);
                return err;
            };
        }
    }

    fn execute(self: *Kernel, work: Work) !void {
        const session_id = work.session.session_id;
        defer self.sessions.endWorker(session_id);
        self.respond(work) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            std.log.err("session {d} stopped: {s}", .{ session_id, @errorName(err) });
            return err;
        };
    }

    const RuntimeRound = struct {
        kernel: *Kernel,
        work: Work,
        plan: ?Sessions.ForkPlan = null,
        committed: bool = false,

        fn deinit(self: *RuntimeRound) void {
            if (!self.committed) if (self.plan) |plan| self.kernel.sessions.abandonFork(plan);
        }

        fn invoke(context: *anyopaque, a: Allocator, name: []const u8, arguments: []const u8) anyerror!?Content {
            const self: *RuntimeRound = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, name, "send_message")) {
                const message = try parseArguments(Communication.Message, a, arguments);
                if (message.recipients.len == 0 or message.text.len == 0) return error.InvalidToolArguments;
                const submission = self.kernel.email.send(a, message) catch |err| switch (err) {
                    error.InvalidContactReference => return try runtimeError(a, "unknown_recipient", "The recipient reference is not available."),
                    else => return err,
                };
                return try runtimeResult(a, submission);
            }
            if (!std.mem.eql(u8, name, "fork_session")) return null;
            const request = try parseArguments(Sessions.ForkRequest, a, arguments);
            if (self.plan != null)
                return try runtimeError(a, "invalid_fork_batch", "Only one fork is allowed in a model round.");
            const plan = self.kernel.sessions.prepareFork(self.work, request) catch |err| switch (err) {
                error.InvalidForkArguments, error.AttentionCapacityUnavailable => return try runtimeError(a, "fork_unavailable", @errorName(err)),
                else => return err,
            };
            self.plan = plan;
            return try runtimeResult(a, .{ .session_id = plan.child.session_id });
        }
    };

    fn respond(self: *Kernel, work: Work) !void {
        const session = work.session;
        if (!work.delivery.supplied) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const observation: Input.Observation = switch (work.delivery.input) {
                .input => |input| .{ .input = input },
                .assignment => |assignment| .{ .assignment = assignment },
                .report => |report| .{ .report = report },
            };
            try self.sessions.appendInput(session, try Input.serialize(a, session.session_id, observation));
            work.delivery.supplied = true;
        }
        while (true) {
            try self.io.checkCancel();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var view = try self.requestContext(a, session);
            defer view.deinit();
            var runtime: RuntimeRound = .{ .kernel = self, .work = work };
            defer runtime.deinit();
            const round = try self.engine.turn(a, session.session_id, view.history(), .{ .context = &runtime, .invoke = RuntimeRound.invoke }, session.role == .core);
            const committed = try self.sessions.commitRound(work, round.output, round.replies, runtime.plan);
            runtime.committed = true;
            if (committed != .continuing) return;
            if (round.replies.len != 0) continue;
            return self.finishResult(work, round.text);
        }
    }

    fn finishResult(self: *Kernel, work: Work, text: ?[]const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        if (work.delivery.receipt) |receipt|
            try self.state.complete(a, receipt);
        return self.sessions.finish(work, text);
    }

    fn requestContext(self: *Kernel, a: Allocator, session: *Session) !Context {
        var provider = self.engine.provider;
        provider.tool_scope = if (session.role == .core) .coordination else .all;
        var view = try self.sessions.snapshot(session);
        errdefer view.deinit();
        const current = try Input.serializeSnapshot(a, try self.sessions.runtimeSnapshot(session));
        try view.appendInput(current);
        if (try provider.requestBytes(a, view.history()) <= self.limits.request_bytes) return view;
        const summary = try Compaction.summarize(provider, a, view.history(), try self.sessions.runtimeSnapshot(session), self.limits.compaction_bytes, self.limits.handover_bytes);
        const rendered = try Input.serialize(a, session.session_id, .{ .handover = .{ .summary = summary } });
        var candidate = try view.withHandover(self.allocator, rendered);
        errdefer candidate.deinit();
        var request = try candidate.fork(self.allocator);
        errdefer request.deinit();
        try request.appendInput(current);
        if (try provider.requestBytes(a, request.history()) > self.limits.request_bytes) return error.ContextBudgetExhausted;
        if (session.role == .core) try self.state.saveHandover(a, "core", summary);
        try self.sessions.replaceContext(session, candidate);
        view.deinit();
        return request;
    }
};

fn parseArguments(comptime T: type, a: Allocator, arguments: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, arguments, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidToolArguments,
    };
}

fn runtimeResult(a: Allocator, value: anytype) !Content {
    return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .result = value }, .{}));
}

fn runtimeError(a: Allocator, code: []const u8, message: []const u8) !Content {
    return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .@"error" = .{ .code = code, .message = message } }, .{}));
}
