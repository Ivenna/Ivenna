const std = @import("std");
const Context = @import("context.zig").Context;
const Compaction = @import("compaction.zig");
const Engine = @import("engine.zig").Engine;
const Content = @import("content").Content;
const Input = @import("input.zig");
const AgentTools = @import("tools.zig");
const Sessions = @import("sessions.zig");
const contracts = @import("agent_contracts");
const Communication = contracts.Communication;
const Model = contracts.Model;
const Allocator = std.mem.Allocator;
const Session = Sessions.Session;
const Work = Sessions.Work;

/// Coordinate sessions, model/tool rounds, communication, and retained history within
/// worker scopes. Each ready session owns one worker through its activation.
pub const Kernel = struct {
    allocator: Allocator,
    io: std.Io,
    engine: *Engine,
    inbox: contracts.Inbox,
    sender: Communication.Sender,
    callbacks: contracts.Callback.Publisher,
    limits: Limits,
    poll_interval_ms: u32,
    sessions: Sessions.Registry,
    reception: std.atomic.Value(enum(u8) { starting, open, closed }) = .init(.starting),

    pub const Limits = struct {
        request_bytes: u64 = 65536,
        compaction_bytes: u64 = 131072,
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
        max_sessions: usize,
        max_pending_events: usize,
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
            .sessions = try Sessions.Registry.init(allocator, io, config.max_sessions, config.max_pending_events, dependencies.history),
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
        try self.restoreHostCallbacks();
        try self.sessions.maintain();
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

    fn restoreHostCallbacks(self: *Kernel) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const pending = try self.sessions.pendingHostCallbacks(a);
        if (pending.len == 0) return;
        const text = try std.json.Stringify.valueAlloc(a, .{ .@"error" = .{
            .code = "host_interrupted",
            .message = "The command's outcome is unknown after restart. Effects may already have occurred. The command was not replayed; the source command_id belongs to the previous runtime and is not a current control handle.",
        } }, .{});
        for (pending) |callback| try self.callbacks.send(a, .{ .id = callback.id, .text = text });
    }

    fn dispatch(self: *Kernel, tasks: *Tasks) !void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const ready = try self.sessions.takeReadyBatch(arena.allocator());
        var started: usize = 0;
        defer for (ready[started..]) |work| self.sessions.endWorker(work.session);
        for (ready) |work| {
            try tasks.concurrent(.work, execute, .{ self, work });
            started += 1;
        }
    }

    fn execute(self: *Kernel, work: Work) !void {
        const session_id = work.session.session_id;
        const result = self.respond(work);
        defer self.sessions.endWorker(work.session);
        result catch |err| {
            if (err == error.Canceled) return error.Canceled;
            std.log.err("session {d} execution failed: {s}", .{ session_id, @errorName(err) });
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

        fn registerCallback(context: *anyopaque, a: Allocator, name: []const u8, source: contracts.Callback.Source) anyerror!contracts.Callback.Registration {
            const self: *RuntimeRound = @ptrCast(@alignCast(context));
            return self.kernel.sessions.registerCallback(a, self.work, name, source);
        }

        fn issueCommandReference(context: *anyopaque, a: Allocator, name: []const u8) anyerror![]const u8 {
            const self: *RuntimeRound = @ptrCast(@alignCast(context));
            return self.kernel.sessions.issueCommandReference(a, self.work, name);
        }

        fn invoke(context: *anyopaque, a: Allocator, request: AgentTools.Request) anyerror!Content {
            const self: *RuntimeRound = @ptrCast(@alignCast(context));
            return switch (request) {
                .send_message => |message| switch (try self.kernel.sender.send(a, message)) {
                    .submitted => |submission| try runtimeResult(a, submission),
                    .invalid_recipient => try runtimeError(a, "invalid_recipient", "The recipient ID is invalid."),
                },
                .send_focus_message => |message| blk: {
                    self.kernel.sessions.sendFocusMessage(self.work, message.focus_id, message.text) catch |err| return try toolFailure(a, err);
                    break :blk try runtimeResult(a, .{ .focus_id = message.focus_id });
                },
                .schedule_attention => |args| blk: {
                    const id = self.kernel.sessions.scheduleWakeup(a, self.work, args.name, args.at.unix_ms, args.text) catch |err| return try toolFailure(a, err);
                    break :blk try runtimeResult(a, .{ .callback_id = id });
                },
                .open_focus => |args| blk: {
                    try self.forks.ensureUnusedCapacity(self.kernel.allocator, 1);
                    const plan = self.kernel.sessions.prepareFork(self.work, args.name, args.task) catch |err| switch (err) {
                        error.SessionCapacityUnavailable => return try runtimeError(a, "focus_unavailable", "The focus limit has been reached. Existing focuses remain addressable."),
                        else => return err,
                    };
                    self.forks.appendAssumeCapacity(plan);
                    break :blk try runtimeResult(a, .{ .focus_id = plan.session.focus_id });
                },
            };
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
            const inference = try self.engine.infer(a, view.input, session.role);
            try self.sessions.recordAssistant(work, inference.response.text);
            const has_tools = inference.response.calls.len != 0;
            if (has_tools) try self.sessions.setToolWait(work, true);
            const replies = try self.engine.executeTools(a, .{
                .session_id = session.session_id,
                .focus_id = session.focus_id,
                .callback = .{ .context = &runtime, .register = RuntimeRound.registerCallback },
                .command_reference = .{ .context = &runtime, .issue = RuntimeRound.issueCommandReference },
            }, inference, .{
                .context = &runtime,
                .invoke = RuntimeRound.invoke,
            });
            if (has_tools) try self.sessions.setToolWait(work, false);
            delivery = .none;
            try self.sessions.commitRound(work, inference.response.output, replies, runtime.forks.items);
            runtime.forks.clearRetainingCapacity();
            try self.sessions.save();
            if (replies.len == 0 and try self.sessions.finish(work)) return;
            if (try self.sessions.collectPending(work)) {
                try self.admitEvents(work);
                delivery = .latest;
            }
        }
    }

    const Selection = struct { count: usize, context: Context };
    const max_summary_attempts = 2;

    /// Fill one ordinary input across I/O pages, measuring grouped activity
    /// reports. The retained selection still identifies a raw delivery prefix.
    fn selectEvents(self: *Kernel, a: Allocator, work: Work, history: *const Context, initial: Sessions.Snapshot) !?Selection {
        var count: usize = 0;
        var snapshot = initial;
        var events: std.ArrayList(Input.Event) = .empty;
        defer events.deinit(a);
        var trial_arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer trial_arena.deinit();
        while (true) {
            for (work.activation.deliveries.items[events.items.len..]) |delivery| try events.append(a, delivery.event);
            if (try self.eventsFit(&trial_arena, work.session.role, history, snapshot, events.items, events.items.len)) {
                count = events.items.len;
                if (!try self.sessions.extendReports(work)) break;
                snapshot = try self.sessions.runtimeSnapshot(a, work.session);
                continue;
            }
            // After an overflow, select the largest fitting prefix of the loaded
            // deliveries using the current snapshot.
            var start: usize = 1;
            if (count != 0 and try self.eventsFit(&trial_arena, work.session.role, history, snapshot, events.items, count)) {
                start = count + 1;
            } else count = 0;
            for (start..events.items.len) |end| {
                if (try self.eventsFit(&trial_arena, work.session.role, history, snapshot, events.items, end)) count = end;
            }
            break;
        }
        if (count == 0) return null;
        var selected = try history.clone(self.allocator);
        errdefer selected.deinit();
        const grouped = try Input.coalesceActivityReports(a, events.items[0..count]);
        try selected.appendRecord(.{ .events = .{ .focus_id = work.session.focus_id, .items = grouped } });
        return .{ .count = count, .context = selected };
    }

    fn eventsFit(self: *Kernel, scratch: *std.heap.ArenaAllocator, role: Input.Role, history: *const Context, snapshot: Sessions.Snapshot, events: []const Input.Event, count: usize) !bool {
        const trial = scratch.allocator();
        defer _ = scratch.reset(.retain_capacity);
        const current = try snapshot.afterAdmission(trial, events, count);
        const grouped = try Input.coalesceActivityReports(trial, events[0..count]);
        const input = try history.requestWithEvents(trial, grouped, current);
        return try self.engine.requestBytes(trial, input, role) <= self.limits.request_bytes;
    }

    fn admitEvents(self: *Kernel, work: Work) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var history = try self.sessions.snapshot(work.session);
        defer history.deinit();
        var snapshot = try self.sessions.runtimeSnapshot(a, work.session);
        var selection = try self.selectEvents(a, work, &history, snapshot);
        if (selection == null and history.records().len != 0) {
            var rejection: ?Compaction.Rejection = null;
            for (0..max_summary_attempts) |_| {
                snapshot = try self.sessions.runtimeSnapshot(a, work.session);
                const result = try Compaction.summarize(self.engine.model, a, &history, snapshot.current, self.limits.compaction_bytes, rejection);
                switch (result) {
                    .rejected => |reason| rejection = reason,
                    .summary => |summary| {
                        var compacted = try history.withHandover(self.allocator, summary);
                        defer compacted.deinit();
                        snapshot = try self.sessions.runtimeSnapshot(a, work.session);
                        selection = try self.selectEvents(a, work, &compacted, snapshot);
                        if (selection != null) break;
                        rejection = .too_large;
                    },
                }
            }
            if (selection == null) return rejection.?.failure();
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
        if (try self.engine.requestBytes(a, input, session.role) <= self.limits.request_bytes) return .{ .context = view, .input = input };
        var rejection: ?Compaction.Rejection = null;
        for (0..max_summary_attempts) |_| {
            const current = (try self.sessions.runtimeSnapshot(a, session)).current;
            const result = try Compaction.summarize(self.engine.model, a, &view, current, self.limits.compaction_bytes, rejection);
            switch (result) {
                .rejected => |reason| rejection = reason,
                .summary => |summary| {
                    var candidate = try view.withHandover(self.allocator, summary);
                    var installed = false;
                    defer if (!installed) candidate.deinit();
                    var replacement = try candidate.clone(self.allocator);
                    errdefer replacement.deinit();
                    const replacement_snapshot = try self.sessions.runtimeSnapshot(a, session);
                    const replacement_input = try replacement.request(a, replacement_snapshot.current, .none);
                    if (try self.engine.requestBytes(a, replacement_input, session.role) > self.limits.request_bytes) {
                        replacement.deinit();
                        rejection = .too_large;
                        continue;
                    }
                    try self.sessions.replaceContext(session, candidate);
                    installed = true;
                    try self.sessions.save();
                    view.deinit();
                    return .{ .context = replacement, .input = replacement_input };
                },
            }
        }
        return rejection.?.failure();
    }
};

fn runtimeResult(a: Allocator, value: anytype) !Content {
    return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .result = value }, .{}));
}

fn runtimeError(a: Allocator, code: []const u8, message: []const u8) !Content {
    return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .@"error" = .{ .code = code, .message = message } }, .{}));
}

fn toolFailure(a: Allocator, err: anyerror) !Content {
    return switch (err) {
        error.UnknownSession => runtimeError(a, "unknown_focus", "The focus does not exist."),
        error.SessionQueueFull => runtimeError(a, "focus_queue_full", "The focus cannot currently accept another observation."),
        else => err,
    };
}
