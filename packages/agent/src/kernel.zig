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
    callbacks: contracts.Callback.Publisher,
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
        callbacks: contracts.Callback.Publisher,
        history: contracts.HistoryStore,
    };

    pub const Config = struct {
        limits: Limits,
        poll_interval_ms: u32,
        max_parallel: usize,
        max_sessions: usize,
        max_pending_events: usize,
        max_pending_callbacks: usize,
    };

    pub fn init(allocator: Allocator, io: std.Io, dependencies: Dependencies, config: Config) !Kernel {
        return .{
            .allocator = allocator,
            .io = io,
            .engine = dependencies.engine,
            .inbox = dependencies.inbox,
            .sender = dependencies.sender,
            .callbacks = dependencies.callbacks,
            .limits = config.limits,
            .poll_interval_ms = config.poll_interval_ms,
            .max_parallel = config.max_parallel,
            .sessions = try Sessions.Registry.init(allocator, io, config.max_sessions, config.max_pending_events, config.max_pending_callbacks, dependencies.history),
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
        {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            for (try self.sessions.interruptedHostCallbacks(a)) |id| {
                try self.callbacks.send(a, .{ .id = id, .text = "The previous runtime ended before this host activity's result was admitted. The result is unknown; effects may already have occurred. Inspect the host before deciding how to continue. The command was not replayed." });
            }
        }
        if (self.reception.cmpxchgStrong(.starting, .open, .release, .monotonic) != null) return;
        try self.dispatch(tasks);
        var maintained_at = std.Io.Clock.awake.now(self.io).toMilliseconds();
        while (true) {
            try self.io.checkCancel();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            for (try self.sessions.dueWakeups(a)) |source| {
                try self.callbacks.send(a, .{ .id = source.id, .text = source.text });
                try self.sessions.wakeupSent(source.id);
            }
            const waiting = try self.inbox.poll(a, try self.sessions.pollRequest());
            try self.sessions.reconcile(waiting);
            for (waiting) |incoming| switch (try self.sessions.accept(incoming)) {
                .accepted, .deferred => {},
                .duplicate => if (incoming.receipt) |receipt| try self.inbox.acknowledge(a, receipt),
            };
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
        defer self.sessions.endWorker(session_id);
        result catch |err| {
            if (err == error.Canceled) return error.Canceled;
            std.log.err("session {d} stopped: {s}", .{ session_id, @errorName(err) });
            return err;
        };
        try self.sessions.save();
    }

    const RuntimeRound = struct {
        kernel: *Kernel,
        work: Work,
        forks: std.ArrayList(Sessions.ForkPlan) = .empty,

        fn deinit(self: *RuntimeRound) void {
            for (self.forks.items) |plan| self.kernel.sessions.abandonFork(plan);
            self.forks.deinit(self.kernel.allocator);
        }

        fn registerCallback(context: *anyopaque) anyerror!u64 {
            const self: *RuntimeRound = @ptrCast(@alignCast(context));
            return self.kernel.sessions.registerHostCallback(self.work);
        }

        fn invoke(context: *anyopaque, a: Allocator, name: []const u8, arguments: []const u8) anyerror!?Content {
            const self: *RuntimeRound = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, name, "send_message")) {
                const message = try parseArguments(Communication.Message, a, arguments);
                if (message.recipients.len == 0 or message.text.len == 0) return error.InvalidToolArguments;
                return switch (try self.kernel.sender.send(a, message)) {
                    .submitted => |submission| try runtimeResult(a, submission),
                    .invalid_recipient => try runtimeError(a, "invalid_recipient", "The recipient ID is invalid."),
                };
            }
            if (std.mem.eql(u8, name, "send_session_message")) {
                const message = try parseArguments(struct { session_id: u64, text: []const u8 }, a, arguments);
                if (message.session_id == 0 or message.text.len == 0) return error.InvalidToolArguments;
                self.kernel.sessions.sendSessionMessage(self.work, message.session_id, message.text) catch |err| return try toolFailure(a, err);
                return try runtimeResult(a, .{ .session_id = message.session_id });
            }
            if (std.mem.eql(u8, name, "wakeup")) {
                const request = try parseArguments(struct { at_unix_ms: i64, text: []const u8 }, a, arguments);
                if (request.text.len == 0) return error.InvalidToolArguments;
                const id = self.kernel.sessions.scheduleWakeup(self.work, request.at_unix_ms, request.text) catch |err| return try toolFailure(a, err);
                return try runtimeResult(a, .{ .callback_id = id });
            }
            if (!std.mem.eql(u8, name, "fork_session")) return null;
            const request = try parseArguments(Sessions.ForkRequest, a, arguments);
            if (request.task.len == 0) return error.InvalidToolArguments;
            try self.forks.ensureUnusedCapacity(self.kernel.allocator, 1);
            const plan = self.kernel.sessions.prepareFork(self.work, request) catch |err| switch (err) {
                error.SessionCapacityUnavailable => return try runtimeError(a, "fork_unavailable", "The session limit has been reached. Existing sessions remain addressable."),
                error.SessionQueueFull => return try runtimeError(a, "fork_unavailable", "No queue capacity is available for the activity's report."),
                else => return err,
            };
            self.forks.appendAssumeCapacity(plan);
            return try runtimeResult(a, .{ .session_id = plan.session.session_id });
        }
    };

    fn respond(self: *Kernel, work: Work) !void {
        const session = work.session;
        var delivery: Context.Delivery = .none;
        if (work.activation.deliveries.items.len != 0 or try self.sessions.collectPending(work)) {
            try self.admitEvents(work);
            delivery = .latest;
        }
        while (true) {
            try self.io.checkCancel();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var view = try self.requestContext(a, session, delivery);
            defer view.deinit();
            var runtime: RuntimeRound = .{ .kernel = self, .work = work };
            defer runtime.deinit();
            try self.sessions.observeAttention(work, view.attention_revision);
            const round = try self.engine.turn(a, session.session_id, view.input, .{ .context = &runtime, .invoke = RuntimeRound.invoke, .register_callback = RuntimeRound.registerCallback }, session.role);
            delivery = .none;
            try self.sessions.commitRound(work, round.output, round.replies, runtime.forks.items);
            runtime.forks.clearRetainingCapacity();
            try self.sessions.save();
            if (round.replies.len == 0 and try self.sessions.finish(work, round.text)) return;
            if (try self.sessions.collectPending(work)) {
                try self.admitEvents(work);
                delivery = .latest;
            }
        }
    }

    const Selection = struct { count: usize, context: Context };

    /// Admit a FIFO prefix at a decision boundary. Later arrivals remain queued
    /// for the next boundary; each admitted group is retained independently.
    fn selectEvents(self: *Kernel, a: Allocator, work: Work, history: *const Context, snapshot: Sessions.Snapshot) !?Selection {
        var count: usize = 0;
        const deliveries = work.activation.deliveries.items;
        const events = try a.alloc(Input.Event, deliveries.len);
        for (deliveries, events) |delivery, *event| event.* = delivery.event;
        var trial_arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer trial_arena.deinit();
        for (1..events.len + 1) |end| {
            const trial = trial_arena.allocator();
            const current = try snapshot.afterAdmission(trial, events, end);
            const input = try history.requestWithEvents(trial, events[0..end], current);
            const bytes = try self.engine.requestBytes(trial, input, work.session.role);
            _ = trial_arena.reset(.retain_capacity);
            if (bytes > self.limits.request_bytes) break;
            count = end;
        }
        if (count == 0) return null;
        var selected = try history.clone(self.allocator);
        errdefer selected.deinit();
        try selected.appendRecord(.{ .events = .{ .session_id = work.session.session_id, .items = events[0..count] } });
        return .{ .count = count, .context = selected };
    }

    fn admitEvents(self: *Kernel, work: Work) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var history = try self.sessions.snapshot(work.session);
        defer history.deinit();
        var snapshot = try self.sessions.runtimeSnapshot(a, work.session);
        var selection = try self.selectEvents(a, work, &history, snapshot);
        if (selection == null and history.history().len > 1) {
            const summary = try Compaction.summarize(self.engine.model, a, &history, snapshot.current, self.limits.compaction_bytes, self.limits.handover_bytes);
            var compacted = try history.withHandover(self.allocator, summary);
            defer compacted.deinit();
            snapshot = try self.sessions.runtimeSnapshot(a, work.session);
            selection = try self.selectEvents(a, work, &compacted, snapshot);
        }
        var selected = selection orelse return error.ContextBudgetExhausted;
        {
            errdefer selected.context.deinit();
            try self.sessions.admitEvents(work, selected.count, selected.context);
        }
        try self.sessions.save();
        for (work.activation.deliveries.items) |delivery| {
            const receipt = delivery.receipt orelse continue;
            try self.inbox.acknowledge(a, receipt);
            try self.sessions.acknowledged(receipt);
            delivery.receipt = null;
        }
        self.sessions.releaseDeliveries(work);
    }

    /// Owns the history snapshot borrowed by the request-arena input view.
    const RequestView = struct {
        context: Context,
        input: []const Model.Item,
        attention_revision: u64,

        fn deinit(self: *RequestView) void {
            self.context.deinit();
            self.* = undefined;
        }
    };

    fn requestContext(self: *Kernel, a: Allocator, session: *Session, delivery: Context.Delivery) !RequestView {
        var view = try self.sessions.snapshot(session);
        errdefer view.deinit();
        const snapshot = try self.sessions.runtimeSnapshot(a, session);
        const input = try view.request(a, snapshot.current, delivery);
        if (try self.engine.requestBytes(a, input, session.role) <= self.limits.request_bytes) return .{ .context = view, .input = input, .attention_revision = snapshot.attention_revision };
        const summary = try Compaction.summarize(self.engine.model, a, &view, snapshot.current, self.limits.compaction_bytes, self.limits.handover_bytes);
        var candidate = try view.withHandover(self.allocator, summary);
        var installed = false;
        errdefer if (!installed) candidate.deinit();
        var replacement = try candidate.clone(self.allocator);
        errdefer replacement.deinit();
        const replacement_snapshot = try self.sessions.runtimeSnapshot(a, session);
        const replacement_input = try replacement.request(a, replacement_snapshot.current, .none);
        if (try self.engine.requestBytes(a, replacement_input, session.role) > self.limits.request_bytes) return error.ContextBudgetExhausted;
        try self.sessions.replaceContext(session, candidate);
        installed = true;
        try self.sessions.save();
        view.deinit();
        return .{ .context = replacement, .input = replacement_input, .attention_revision = replacement_snapshot.attention_revision };
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

fn toolFailure(a: Allocator, err: anyerror) !Content {
    return switch (err) {
        error.UnknownSession => runtimeError(a, "unknown_session", "The session does not exist."),
        error.SessionQueueFull => runtimeError(a, "session_queue_full", "The session's event queue is full."),
        error.CallbackCapacityUnavailable => runtimeError(a, "callback_unavailable", "The pending callback limit has been reached."),
        else => err,
    };
}
