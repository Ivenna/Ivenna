const std = @import("std");
const Context = @import("context.zig").Context;
const Compaction = @import("compaction.zig");
const Engine = @import("engine.zig").Engine;
const Content = @import("content").Content;
const Input = @import("input.zig");
const Sessions = @import("sessions.zig");
const contracts = @import("agent_contracts");
const Communication = contracts.Communication;
const Model = contracts.Model;
const Allocator = std.mem.Allocator;
const Session = Sessions.Session;
const Work = Sessions.Work;

/// Coordinate sessions, model/tool rounds, communication, and retained history within
/// worker scopes. Core coordination has an independent execution lane.
pub const Kernel = struct {
    allocator: Allocator,
    io: std.Io,
    engine: *Engine,
    inbox: contracts.Inbox,
    sender: Communication.Sender,
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

    pub const Dependencies = struct {
        engine: *Engine,
        inbox: contracts.Inbox,
        sender: Communication.Sender,
        history: contracts.HistoryStore,
    };

    pub const Config = struct {
        limits: Limits,
        poll_interval_ms: u32,
        max_parallel: usize,
        max_contexts: usize,
    };

    pub fn init(allocator: Allocator, io: std.Io, dependencies: Dependencies, config: Config) !Kernel {
        return .{
            .allocator = allocator,
            .io = io,
            .engine = dependencies.engine,
            .inbox = dependencies.inbox,
            .sender = dependencies.sender,
            .limits = config.limits,
            .poll_interval_ms = config.poll_interval_ms,
            .max_parallel = config.max_parallel,
            .sessions = try Sessions.Registry.init(allocator, io, config.max_contexts, dependencies.history),
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
        try self.sessions.maintain();
        if (self.reception.cmpxchgStrong(.starting, .open, .release, .monotonic) != null) return;
        try self.dispatch(tasks);
        var maintained_at = std.Io.Clock.awake.now(self.io).toMilliseconds();
        while (true) {
            try self.io.checkCancel();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const waiting = try self.inbox.poll(a, try self.sessions.intakeLimit());
            try self.sessions.reconcile(waiting);
            for (waiting) |incoming| _ = try self.sessions.accept(incoming);
            try self.dispatch(tasks);
            const now = std.Io.Clock.awake.now(self.io).toMilliseconds();
            if (now - maintained_at >= 60_000) {
                try self.sessions.maintain();
                maintained_at = std.Io.Clock.awake.now(self.io).toMilliseconds();
            }
            try self.io.sleep(.fromMilliseconds(self.poll_interval_ms), .awake);
        }
    }

    fn dispatch(self: *Kernel, tasks: *Tasks) !void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const ready = try self.sessions.takeReadyBatch(arena.allocator(), self.max_parallel);
        var started: usize = 0;
        defer for (ready[started..]) |work| self.sessions.endWorker(work.session.session_id);
        for (ready) |work| {
            try tasks.concurrent(.work, execute, .{ self, work });
            started += 1;
        }
    }

    fn execute(self: *Kernel, work: Work) !void {
        const session_id = work.session.session_id;
        const result = self.respond(work);
        self.sessions.endWorker(session_id);
        try self.sessions.save();
        result catch |err| {
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
                const submission = self.kernel.sender.send(a, message) catch |err| switch (err) {
                    error.InvalidRecipientId => return try runtimeError(a, "invalid_recipient", "The recipient ID is invalid."),
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
        try self.beginActivation(work);
        while (true) {
            try self.io.checkCancel();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var view = try self.requestContext(a, session);
            defer view.deinit();
            var runtime: RuntimeRound = .{ .kernel = self, .work = work };
            defer runtime.deinit();
            const round = try self.engine.turn(a, session.session_id, view.input, .{ .context = &runtime, .invoke = RuntimeRound.invoke }, session.role == .core);
            const committed = try self.sessions.commitRound(work, round.output, round.replies, runtime.plan);
            runtime.committed = true;
            try self.sessions.save();
            if (committed != .continuing) return;
            if (round.replies.len != 0) continue;
            return self.sessions.finish(work, round.text);
        }
    }

    const Selection = struct { count: usize, context: Context };

    /// Choose from the queue snapshot owned by this activation. Later arrivals
    /// stay queued; excluded deliveries return ahead of them when selected
    /// history is installed.
    fn selectActivation(self: *Kernel, a: Allocator, work: Work, history: *const Context, request: Input.Request) !?Selection {
        const scope: Engine.Scope = if (work.session.role == .core) .coordination else .all;
        var count: usize = 0;
        const deliveries = work.activation.deliveries.items;
        const events = try a.alloc(Input.Event, deliveries.len);
        for (deliveries, events) |delivery, *event| event.* = delivery.event;
        var trial_arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer trial_arena.deinit();
        for (1..events.len + 1) |end| {
            const trial = trial_arena.allocator();
            var current = request;
            current.state.runtime.queued_inputs += events.len - end;
            const input = try history.requestWithRecord(trial, .{ .session_id = work.session.session_id, .events = events[0..end] }, current);
            const bytes = try self.engine.requestBytes(trial, input, scope);
            _ = trial_arena.reset(.retain_capacity);
            if (bytes > self.limits.request_bytes) break;
            count = end;
        }
        if (count == 0) return null;
        var selected = try history.fork(self.allocator);
        errdefer selected.deinit();
        try selected.appendRecord(.{ .session_id = work.session.session_id, .events = events[0..count] });
        return .{ .count = count, .context = selected };
    }

    fn beginActivation(self: *Kernel, work: Work) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var history = try self.sessions.snapshot(work.session);
        defer history.deinit();
        const snapshot = try self.sessions.runtimeSnapshot(work.session);
        var request: Input.Request = .{ .session_id = snapshot.session_id, .state = snapshot.state };
        var selection = try self.selectActivation(a, work, &history, request);
        if (selection == null and history.history().len > 1) {
            const summary = try Compaction.summarize(self.engine.model, a, &history, request, self.limits.compaction_bytes, self.limits.handover_bytes);
            var compacted = try history.withHandover(self.allocator, work.session.session_id, .{ .summary = summary });
            defer compacted.deinit();
            request.state = (try self.sessions.runtimeSnapshot(work.session)).state;
            selection = try self.selectActivation(a, work, &compacted, request);
        }
        var selected = selection orelse return error.ContextBudgetExhausted;
        var installed = false;
        errdefer if (!installed) selected.context.deinit();
        try self.sessions.beginActivation(work, selected.count, selected.context);
        installed = true;
        try self.sessions.save();
        for (work.activation.deliveries.items) |delivery| {
            const receipt = delivery.receipt orelse continue;
            try self.inbox.acknowledge(a, receipt);
            try self.sessions.acknowledged(receipt);
            delivery.receipt = null;
        }
    }

    /// Owns the history snapshot borrowed by the request-arena input view.
    const RequestView = struct {
        context: Context,
        input: []const Model.Item,

        fn deinit(self: *RequestView) void {
            self.context.deinit();
            self.* = undefined;
        }
    };

    fn requestContext(self: *Kernel, a: Allocator, session: *Session) !RequestView {
        const scope: Engine.Scope = if (session.role == .core) .coordination else .all;
        var view = try self.sessions.snapshot(session);
        errdefer view.deinit();
        const snapshot = try self.sessions.runtimeSnapshot(session);
        const request: Input.Request = .{ .session_id = snapshot.session_id, .state = snapshot.state };
        const input = try view.request(a, request);
        if (try self.engine.requestBytes(a, input, scope) <= self.limits.request_bytes) return .{ .context = view, .input = input };
        const summary = try Compaction.summarize(self.engine.model, a, &view, request, self.limits.compaction_bytes, self.limits.handover_bytes);
        var candidate = try view.withHandover(self.allocator, session.session_id, .{ .summary = summary });
        var installed = false;
        errdefer if (!installed) candidate.deinit();
        var replacement = try candidate.fork(self.allocator);
        errdefer replacement.deinit();
        var replacement_request = request;
        replacement_request.state = (try self.sessions.runtimeSnapshot(session)).state;
        const replacement_input = try replacement.request(a, replacement_request);
        if (try self.engine.requestBytes(a, replacement_input, scope) > self.limits.request_bytes) return error.ContextBudgetExhausted;
        try self.sessions.replaceContext(session, candidate);
        installed = true;
        try self.sessions.save();
        view.deinit();
        return .{ .context = replacement, .input = replacement_input };
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
