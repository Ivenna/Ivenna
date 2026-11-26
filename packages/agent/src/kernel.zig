const std = @import("std");
const Context = @import("context.zig").Context;
const Compaction = @import("compaction.zig");
const Engine = @import("engine.zig").Engine;
const FocusResult = @import("engine.zig").FocusResult;
const Content = @import("content").Content;
const Input = @import("input.zig");
const AgentTools = @import("tools.zig");
const Sessions = @import("sessions.zig");
const contracts = @import("agent_contracts");
const InstanceState = @import("instance_state");
const Subscriptions = InstanceState.subscriptions;
const Communication = contracts.Communication;
const Channels = contracts.Channels;
const Model = contracts.Model;
const Allocator = std.mem.Allocator;
const Work = Sessions.Work;

/// Coordinate sessions, model/tool rounds, communication, and retained history within
/// worker scopes. Each ready session owns one worker through its activation.
pub const Kernel = struct {
    allocator: Allocator,
    io: std.Io,
    engine: *Engine,
    inbox: contracts.Inbox,
    sender: Communication.Sender,
    channels: Channels,
    callbacks: contracts.Callback.Publisher,
    limits: Limits,
    poll_interval_ms: u32,
    sessions: Sessions.Registry,
    reception: std.atomic.Value(enum(u8) { starting, open, closed }) = .init(.starting),
    pub const Limits = struct {
        compact_at_tokens: u64 = 256 * 1024,
        compact_at_bytes: u64 = 1024 * 1024,
        observation_batch_bytes: u64 = 1024 * 1024,
    };

    pub const Dependencies = struct {
        engine: *Engine,
        inbox: contracts.Inbox,
        sender: Communication.Sender,
        channels: Channels,
        callbacks: contracts.Callback.Publisher,
        history: contracts.HistoryStore,
        subscriptions: *Subscriptions.Store,
    };

    pub const Config = struct {
        limits: Limits,
        poll_interval_ms: u32,
        max_sessions: usize,
        max_pending_events: usize,
    };

    pub fn init(allocator: Allocator, io: std.Io, dependencies: Dependencies, config: Config) !Kernel {
        var kernel: Kernel = .{
            .allocator = allocator,
            .io = io,
            .engine = dependencies.engine,
            .inbox = dependencies.inbox,
            .sender = dependencies.sender,
            .channels = dependencies.channels,
            .callbacks = dependencies.callbacks,
            .limits = config.limits,
            .poll_interval_ms = config.poll_interval_ms,
            .sessions = try Sessions.Registry.init(
                allocator,
                io,
                config.max_sessions,
                config.max_pending_events,
                dependencies.history,
                dependencies.subscriptions,
                .{
                    .correspondents = dependencies.sender.registered_correspondents,
                    .usage_scope = dependencies.engine.model.usage_scope,
                },
            ),
        };
        errdefer kernel.deinit();
        try kernel.sessions.restoreChannels(kernel.channels);
        return kernel;
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
        try self.restoreHostCallbacks();
        if (self.reception.cmpxchgStrong(.starting, .open, .release, .monotonic) != null) return;
        try self.dispatch(tasks);
        var maintained_at = std.Io.Clock.awake.now(self.io).toMilliseconds();
        while (true) {
            try self.io.checkCancel();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            for (try self.sessions.dueWakeups(a)) |wakeup| {
                try self.callbacks.send(a, wakeup);
                try self.sessions.markWakeupPublished(wakeup.id);
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
            .message = "The command's outcome is unknown after restart. It may already have had effects. Its command ID is no longer valid for shell control.",
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
        defer self.sessions.endWorker(work.session);
        const interrupted = self.respond(work) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            std.log.err("execution failed in {s}: {s}", .{ work.session.focus_id, @errorName(err) });
            return err;
        };
        if (interrupted) |reason| {
            std.log.warn("focus {s} interrupted: {s}", .{ work.session.focus_id, reason });
            return self.sessions.interrupt(work, reason);
        }
    }

    const RuntimeRound = struct {
        kernel: *Kernel,
        work: Work,
        changes: Sessions.RoundChanges = .{},

        fn deinit(self: *RuntimeRound) void {
            self.kernel.sessions.discardRound(&self.changes);
        }

        fn commit(self: *RuntimeRound, completed: *Context, input_tokens: ?u64) !void {
            try self.kernel.sessions.commitToolRound(self.work, completed, &self.changes, input_tokens);
        }

        fn registerCallback(context: *anyopaque, a: Allocator, name: []const u8, source: contracts.Callback.Source) anyerror!contracts.Callback.Registration {
            const self: *RuntimeRound = @ptrCast(@alignCast(context));
            return self.kernel.sessions.registerCallback(a, self.work, name, source);
        }

        fn issueCommandReference(context: *anyopaque, a: Allocator, name: []const u8) anyerror![]const u8 {
            const self: *RuntimeRound = @ptrCast(@alignCast(context));
            return self.kernel.sessions.issueRuntimeReference(a, self.work, name);
        }

        fn invoke(context: *anyopaque, a: Allocator, request: AgentTools.Request) anyerror!Content {
            const self: *RuntimeRound = @ptrCast(@alignCast(context));
            return switch (request) {
                .send => |message| self.send(a, message.to, message.text),
                .open_channel => |args| blk: {
                    const channel_id = try self.kernel.sessions.openChannel(a, self.work, &self.changes, self.kernel.channels, args.name, args.description);
                    break :blk try runtimeResult(a, .{ .channel_id = channel_id });
                },
                .close_channel => |args| blk: {
                    const changed = try self.kernel.sessions.closeChannel(self.kernel.channels, args.channel_id);
                    break :blk try runtimeResult(a, .{ .channel_id = args.channel_id, .changed = changed });
                },
                .schedule_attention => |args| blk: {
                    const id = try self.kernel.sessions.scheduleWakeup(a, self.work, args.name, args.at.unix_ms, args.text);
                    break :blk try runtimeResult(a, .{ .callback_id = id });
                },
                .subscribe => |args| blk: {
                    const subscription = self.kernel.sessions.subscribe(a, self.work, args.name, args.listener) catch |err| switch (err) {
                        error.InvalidArguments => return error.InvalidToolArguments,
                        else => return err,
                    };
                    break :blk try runtimeResult(a, subscription);
                },
                .withdraw_subscription => |args| blk: {
                    const changed = try self.kernel.sessions.withdrawSubscription(self.work, args.subscription_id);
                    break :blk try runtimeResult(a, .{ .subscription_id = args.subscription_id, .changed = changed });
                },
                .open_focus => |args| blk: {
                    const focus_id = self.kernel.sessions.prepareFork(self.work, &self.changes, args.name, args.task) catch |err| switch (err) {
                        error.SessionCapacityUnavailable => return try runtimeError(a, "focus_unavailable", "The focus limit has been reached."),
                        else => return err,
                    };
                    break :blk try runtimeResult(a, .{ .focus_id = focus_id });
                },
            };
        }

        fn send(self: *RuntimeRound, a: Allocator, to: AgentTools.Destination, text: []const u8) !Content {
            return switch (to) {
                .correspondent_id => |id| switch (try self.kernel.sender.send(a, .{ .recipient = id, .text = text })) {
                    .submitted => |submission| try runtimeResult(a, .{ .correspondent_id = id, .reference = submission.reference }),
                    .invalid_recipient => try runtimeError(a, "invalid_recipient", "No outgoing correspondent is registered with that ID."),
                    .not_submitted => try runtimeError(a, "not_submitted", "Sending stopped before the submission attempt."),
                    .submission_unknown => try runtimeError(a, "submission_unknown", "The service may already have accepted this message. Sending it again could create a duplicate."),
                },
                .channel_id => |id| switch (try self.kernel.channels.trySend(id, text)) {
                    .accepted => try runtimeResult(a, .{ .channel_id = id, .status = "accepted" }),
                    .would_block => try runtimeError(a, "channel_would_block", "The text remains unsent and unqueued. You can retry while a receiver is waiting."),
                    .unknown_channel => try runtimeError(a, "unknown_channel", "No open channel matches that ID."),
                    .too_long => try runtimeError(a, "channel_message_too_long", std.fmt.comptimePrint(
                        "Channel messages can contain up to {d} UTF-8 bytes.",
                        .{Channels.max_message_bytes},
                    )),
                },
                .focus_id => |id| blk: {
                    self.kernel.sessions.sendFocusMessage(self.work, id, text) catch |err| return switch (err) {
                        error.UnknownSession => runtimeError(a, "unknown_focus", "No existing focus matches that ID."),
                        error.SessionQueueFull => runtimeError(a, "focus_queue_full", "The receiving focus's queue is full."),
                        else => err,
                    };
                    break :blk try runtimeResult(a, .{ .focus_id = id });
                },
            };
        }
    };

    fn respond(self: *Kernel, work: Work) !?[]const u8 {
        const session = work.session;
        while (true) {
            try self.io.checkCancel();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            if (work.activation.deliveries.items.len == 0) try self.sessions.collectPending(work);
            var history = try self.sessions.snapshot(session);
            defer history.deinit();
            const input = switch (try self.prepareRequest(a, work, &history)) {
                .ready => |input| input,
                .interrupted => |reason| return reason,
            };
            var round = switch (try self.engine.beginRound(a, session.focus_id, input, session.role)) {
                .ready => |round| round,
                .interrupted => |reason| return reason,
            };
            defer round.inference.deinit();
            const response = round.inference.response;
            if (response.calls.len == 0) {
                if (try self.sessions.commitResponse(work, &history, response)) return null;
                continue;
            }
            var runtime: RuntimeRound = .{ .kernel = self, .work = work };
            defer runtime.deinit();
            try self.sessions.recordBeforeTools(work, response.text);
            const replies = try self.engine.executeTools(a, .{
                .session_id = session.session_id,
                .focus_id = session.focus_id,
                .callback = .{ .context = &runtime, .register = RuntimeRound.registerCallback },
                .command_reference = .{ .context = &runtime, .issue = RuntimeRound.issueCommandReference },
            }, &round, .{
                .context = &runtime,
                .invoke = RuntimeRound.invoke,
            });
            try history.appendBatch(response.output, replies);
            try runtime.commit(&history, response.input_tokens);
        }
    }

    const Selection = union(enum) { count: usize, over_limit: Model.Limit };
    const Prepared = struct { items: []const Model.Item, events: []const Input.Event, count: usize };
    const Fit = union(enum) { ready: Prepared, over_limit: Model.Limit };
    const LimitContinuation = enum { with_observations, pending_only };
    const CompactionTrigger = union(enum) { threshold: Prepared, limit: LimitContinuation };
    const core_extra_history_bytes = 256 * 1024;

    /// Bound the space added by a batch of observations across I/O pages.
    /// Always give the first observation the full space available to it.
    fn selectEvents(self: *Kernel, a: Allocator, work: Work, history: *const Context, current: Input.Current, events: *std.ArrayList(Input.Event)) !Selection {
        var count: usize = 0;
        var trial_arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer trial_arena.deinit();
        var batch_target = self.limits.observation_batch_bytes;
        var included_history = false;
        while (true) {
            for (work.activation.deliveries.items[events.items.len..]) |delivery| try events.append(a, delivery.event);
            const page = try self.measureEvents(&trial_arena, history, current, events.items);
            if (!included_history and page.bytes >= batch_target) {
                const base = try self.measureEvents(&trial_arena, history, current, &.{});
                batch_target +|= base.bytes;
                included_history = true;
            }
            if (page.violation == null and page.bytes <= batch_target) {
                count = events.items.len;
                if (page.bytes == batch_target) break;
                if (!try self.sessions.extendReports(work)) break;
                continue;
            }
            for (count + 1..events.items.len + 1) |end| {
                const measured = if (end == events.items.len) page else try self.measureEvents(&trial_arena, history, current, events.items[0..end]);
                if (measured.violation) |limit| {
                    if (count == 0) return .{ .over_limit = limit };
                    break;
                }
                if (count != 0 and measured.bytes > batch_target) break;
                count = end;
            }
            break;
        }
        return .{ .count = count };
    }

    fn measureEvents(self: *Kernel, scratch: *std.heap.ArenaAllocator, history: *const Context, current: Input.Current, events: []const Input.Event) !Model.Measurement {
        const trial = scratch.allocator();
        defer _ = scratch.reset(.retain_capacity);
        const grouped = try Input.coalesceActivityReports(trial, events);
        const input = try history.request(trial, current, grouped);
        return self.engine.measure(trial, input, current.role);
    }

    /// Fit continuation and admission against the same snapshot. A rejected
    /// handover changes neither the selected history nor any inbox receipt.
    fn prepareRequest(self: *Kernel, a: Allocator, work: Work, history: *Context) !FocusResult([]const Model.Item) {
        const current = try self.sessions.current(a, work.session);
        const prepared = switch (try self.fitRequest(a, work, history, current)) {
            .ready => |ready| ready,
            .over_limit => |limit| return self.prepareLimitedRequest(a, work, history, current, limit),
        };
        if (history.canCompact(.keep_latest_tool_round) and try self.reachedCompactionThreshold(history, current, work.session.progress.last_input_tokens)) {
            const scope = try self.softCompactionScope(a, history, current.role);
            switch (try self.compactRequest(a, work, history, current, scope, .{ .threshold = prepared })) {
                .ready => |input| return .{ .ready = input },
                .interrupted => |reason| std.log.warn("soft compaction skipped for {s}. {s}", .{ work.session.focus_id, reason }),
            }
        }
        return .{ .ready = try self.admit(a, work, history, prepared, false) };
    }

    fn prepareLimitedRequest(self: *Kernel, a: Allocator, work: Work, history: *Context, current: Input.Current, limit: Model.Limit) !FocusResult([]const Model.Item) {
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        const trial = scratch.allocator();
        var scope: Context.CompactionScope = .keep_latest_tool_round;
        var minimal = try history.continuationRequest(trial, current, &.{}, scope);
        if ((try self.engine.measure(trial, minimal, current.role)).violation) |pending_limit| {
            if (!history.hasToolRoundToKeep()) return requestOverLimit(work, pending_limit);
            // Summarize an open exchange only when it cannot fit by itself.
            scope = .keep_pending_observations;
            minimal = try history.continuationRequest(trial, current, &.{}, scope);
            if ((try self.engine.measure(trial, minimal, current.role)).violation) |observations_limit|
                return requestOverLimit(work, observations_limit);
        }

        var target: LimitContinuation = .with_observations;
        if (work.activation.deliveries.items.len != 0) {
            const first = work.activation.deliveries.items[0].event;
            minimal = try history.continuationRequest(trial, current, &.{first}, scope);
            if ((try self.engine.measure(trial, minimal, current.role)).violation) |next_limit| {
                // Removing older history cannot make this observation fit.
                if (!history.hasPendingContinuation()) return requestOverLimit(work, next_limit);
                const continuation = try self.fitSelected(a, history, current, &.{}, 0);
                if (continuation == .ready) return .{ .ready = try self.admit(a, work, history, continuation.ready, false) };
                target = .pending_only;
            }
        }

        const compacted = if (history.hasSummaryHistory(scope))
            try self.compactRequest(a, work, history, current, scope, .{ .limit = target })
        else
            requestOverLimit(work, limit);
        if (compacted == .interrupted and target == .with_observations and history.hasPendingContinuation() and work.activation.deliveries.items.len != 0) {
            const continuation = try self.fitSelected(a, history, current, &.{}, 0);
            if (continuation == .ready) return .{ .ready = try self.admit(a, work, history, continuation.ready, false) };
        }
        return compacted;
    }

    fn requestOverLimit(work: Work, limit: Model.Limit) FocusResult([]const Model.Item) {
        return .{ .interrupted = Engine.reportRequestLimit(work.session.focus_id, "next request", limit) };
    }

    /// Prior usage measures a committed request. Without usage, apply the
    /// byte budget to the eligible history in the provider's encoding.
    fn reachedCompactionThreshold(self: *Kernel, history: *const Context, current: Input.Current, last_input_tokens: ?u64) !bool {
        if (last_input_tokens) |tokens| return tokens >= self.limits.compact_at_tokens;
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const retained = try history.retainedRequest(a, current);
        return (try self.engine.measure(a, retained, current.role)).bytes >= self.limits.compact_at_bytes;
    }

    fn softCompactionScope(self: *Kernel, a: Allocator, history: *const Context, role: Input.Role) !Context.CompactionScope {
        if (role != .core or !history.canCompact(.keep_recent_rounds)) return .keep_latest_tool_round;
        const additional = history.additionalRecentItems();
        if (additional.len == 0) return .keep_latest_tool_round;
        for (additional) |item| {
            if (item != .tool_result) continue;
            for (item.tool_result.content.parts) |part| {
                // The provider expands files, whose IDs do not represent their input cost.
                if (part == .file) return .keep_latest_tool_round;
            }
        }
        const measured = try self.engine.model.measure(a, .{ .history = additional, .tools = &.{}, .reasoning_effort = "none" });
        return if (measured.bytes <= core_extra_history_bytes) .keep_recent_rounds else .keep_latest_tool_round;
    }

    fn compactionSnapshot(self: *Kernel, a: Allocator, session: *Sessions.Session) !Input.Snapshot {
        var snapshot = try self.sessions.compactionSnapshot(a, session);
        if (session.role == .core) snapshot.state.correspondents = self.sender.registered_correspondents;
        return snapshot;
    }

    fn compactRequest(self: *Kernel, a: Allocator, work: Work, history: *Context, current: Input.Current, scope: Context.CompactionScope, trigger: CompactionTrigger) !FocusResult([]const Model.Item) {
        var rejection: ?Compaction.Rejection = null;
        const retry: Engine.Retry = if (trigger == .limit) .wait_for_service else .single_attempt;
        const summary_attempts: usize = if (trigger == .limit) 2 else 1;
        for (0..summary_attempts) |_| {
            const snapshot = try self.compactionSnapshot(a, work.session);
            switch (try Compaction.summarize(self.engine, a, history, snapshot, scope, rejection, retry)) {
                .interrupted => |reason| return .{ .interrupted = reason },
                .rejected => |reason| rejection = reason,
                .handover => |handover| {
                    var candidate = try history.withHandover(self.allocator, handover, scope);
                    defer candidate.deinit();
                    const fit = switch (trigger) {
                        .threshold => |selected| try self.fitSelected(a, &candidate, current, selected.events, selected.count),
                        .limit => |target| switch (target) {
                            .with_observations => try self.fitRequest(a, work, &candidate, current),
                            .pending_only => try self.fitSelected(a, &candidate, current, &.{}, 0),
                        },
                    };
                    switch (fit) {
                        .ready => |prepared| {
                            const items = try self.admit(a, work, &candidate, prepared, true);
                            std.mem.swap(Context, history, &candidate);
                            std.log.debug("compacted {s}: {s} trigger, history epoch {d}", .{
                                work.session.focus_id, @tagName(trigger), history.scope.epoch,
                            });
                            return .{ .ready = items };
                        },
                        .over_limit => |limit| rejection = .{ .too_large = limit },
                    }
                },
            }
        }
        return .{ .interrupted = rejection.?.interruption(work.session.focus_id) };
    }

    fn fitRequest(self: *Kernel, a: Allocator, work: Work, history: *const Context, current: Input.Current) !Fit {
        var events: std.ArrayList(Input.Event) = .empty;
        defer events.deinit(a);
        var count: usize = 0;
        if (work.activation.deliveries.items.len != 0) {
            switch (try self.selectEvents(a, work, history, current, &events)) {
                .count => |selected| count = selected,
                .over_limit => |limit| return .{ .over_limit = limit },
            }
        }
        if (count == 0) return self.fitSelected(a, history, current, &.{}, 0);
        const selected = try Input.coalesceActivityReports(a, events.items[0..count]);
        return .{ .ready = .{ .items = try history.request(a, current, selected), .events = selected, .count = count } };
    }

    fn fitSelected(self: *Kernel, a: Allocator, history: *const Context, current: Input.Current, events: []const Input.Event, count: usize) !Fit {
        const items = try history.request(a, current, events);
        const measured = try self.engine.measure(a, items, current.role);
        if (measured.violation) |limit| return .{ .over_limit = limit };
        return .{ .ready = .{ .items = items, .events = events, .count = count } };
    }

    /// Rendered input borrows history. Commit the selected events only after
    /// assembly so the request presents them once.
    fn admit(self: *Kernel, a: Allocator, work: Work, history: *Context, prepared: Prepared, compacted: bool) ![]const Model.Item {
        const pending = work.activation.deliveries.items.len != 0;
        if (prepared.count != 0) try history.appendRecord(.{ .events = .{ .focus_id = work.session.focus_id, .items = prepared.events } });
        if (pending or compacted) try self.sessions.commitInput(work, prepared.count, history);
        if (prepared.count != 0) {
            for (work.activation.deliveries.items) |delivery| {
                const receipt = delivery.receipt orelse continue;
                try self.inbox.acknowledge(a, receipt);
                try self.sessions.acknowledged(receipt);
                delivery.receipt = null;
            }
            self.sessions.releaseDeliveries(work);
        }
        return prepared.items;
    }
};

fn runtimeResult(a: Allocator, value: anytype) !Content {
    return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .result = value }, .{}));
}

fn runtimeError(a: Allocator, code: []const u8, message: []const u8) !Content {
    return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .@"error" = .{ .code = code, .message = message } }, .{}));
}

const TestStore = @import("test_history.zig").TestStore;

const SubscriptionFixture = struct {
    const testing = std.testing;
    const empty_response: Model.Response = .{ .output = &.{}, .calls = &.{}, .text = null };
    storage: TestStore = .{},
    correspondents: []const []const u8 = &.{},
    usage_scope: ?[32]u8 = null,
    send_outcome: Channels.SendOutcome = .accepted,
    channel_send: ?struct { id: []const u8, text: []const u8 } = null,
    open_channel_id: ?[]const u8 = null,
    reserved_channel_id: ?[]const u8 = null,

    fn deinit(self: *SubscriptionFixture) void {
        self.storage.arena.deinit();
    }

    fn kernel(self: *SubscriptionFixture, engine: *Engine, subscriptions: *Subscriptions.Store) !Kernel {
        engine.* = .{
            .allocator = testing.allocator,
            .io = testing.io,
            .model = .{
                .context = self,
                .vtable = &.{ .measure = measure, .next = undefined, .prepareToolReplies = undefined },
                .usage_scope = self.usage_scope,
            },
            .shared_tools = &.{},
            .activity_tools = &.{},
        };
        return Kernel.init(testing.allocator, testing.io, .{
            .engine = engine,
            .subscriptions = subscriptions,
            .inbox = undefined,
            .sender = .{ .context = undefined, .submit = undefined, .registered_correspondents = self.correspondents },
            .channels = .{
                .context = self,
                .vtable = &.{
                    .trySend = trySendToChannel,
                    .reserve = reserveChannel,
                    .activate = activateChannel,
                    .close = closeChannel,
                },
            },
            .callbacks = undefined,
            .history = self.storage.port(),
        }, .{ .limits = .{}, .poll_interval_ms = 1, .max_sessions = 3, .max_pending_events = 3 });
    }

    fn trySendToChannel(context: *anyopaque, id: []const u8, text: []const u8) !Channels.SendOutcome {
        const self: *SubscriptionFixture = @ptrCast(@alignCast(context));
        self.channel_send = .{ .id = id, .text = text };
        const open_id = self.open_channel_id orelse return .unknown_channel;
        if (!std.mem.eql(u8, open_id, id)) return .unknown_channel;
        return self.send_outcome;
    }

    fn reserveChannel(context: *anyopaque, channel_id: []const u8) !void {
        const self: *SubscriptionFixture = @ptrCast(@alignCast(context));
        std.debug.assert(self.reserved_channel_id == null);
        self.reserved_channel_id = try self.storage.arena.allocator().dupe(u8, channel_id);
    }

    fn activateChannel(context: *anyopaque, channel_id: []const u8) void {
        const self: *SubscriptionFixture = @ptrCast(@alignCast(context));
        const reserved = self.reserved_channel_id.?;
        std.debug.assert(std.mem.eql(u8, reserved, channel_id));
        self.open_channel_id = reserved;
        self.reserved_channel_id = null;
    }

    fn closeChannel(context: *anyopaque, channel_id: []const u8) void {
        const self: *SubscriptionFixture = @ptrCast(@alignCast(context));
        if (self.reserved_channel_id) |reserved| {
            if (std.mem.eql(u8, reserved, channel_id)) {
                self.reserved_channel_id = null;
                return;
            }
        }
        std.debug.assert(std.mem.eql(u8, self.open_channel_id.?, channel_id));
        self.open_channel_id = null;
    }

    fn measure(_: *anyopaque, _: Allocator, request: Model.Request) anyerror!Model.Measurement {
        const turn = request.history[request.history.len - 1].message.text;
        const events_start = std.mem.indexOf(u8, turn, "\nevents:") orelse turn.len;
        return .{ .bytes = std.mem.count(u8, turn[events_start..], "budget-marker") };
    }

    fn takeWork(instance: *Kernel, a: Allocator) !Work {
        const ready = try instance.sessions.takeReadyBatch(a);
        try testing.expectEqual(1, ready.len);
        return ready[0];
    }

    fn admit(instance: *Kernel, a: Allocator, work: Work) !Context {
        var history = try instance.sessions.snapshot(work.session);
        errdefer history.deinit();
        try testing.expect((try instance.prepareRequest(a, work, &history)) == .ready);
        return history;
    }

    /// Leave a subscribed activity sleeping while the core continues its round.
    fn watchingActivity(instance: *Kernel, a: Allocator, core: Work, history: *Context, name: []const u8) ![]const u8 {
        var round: Kernel.RuntimeRound = .{ .kernel = instance, .work = core };
        defer round.deinit();
        _ = try instance.sessions.prepareFork(core, &round.changes, name, "Watch for updates.");
        try round.commit(history, null);
        const work = try takeWork(instance, a);
        var activity = try admit(instance, a, work);
        defer activity.deinit();
        const sub = try instance.sessions.subscribe(a, work, "updates", "Source listener");
        try finish(instance, work, &activity);
        return sub.subscription_id;
    }

    fn finish(instance: *Kernel, work: Work, history: *Context) !void {
        defer instance.sessions.endWorker(work.session);
        try testing.expect(try instance.sessions.commitResponse(work, history, empty_response));
    }

    fn appendChannelReply(a: Allocator, history: *Context, reply: std.json.Value) !void {
        const text = try std.json.Stringify.valueAlloc(a, reply, .{});
        try history.appendBatch(&.{.{ .continuation = "Call open_channel" }}, &.{.{
            .tool_result = .{ .call_id = "open-channel", .content = try Content.fromText(a, text) },
        }});
    }

    fn callTool(a: Allocator, round: *Kernel.RuntimeRound, name: []const u8, args: anytype) !std.json.Value {
        const arguments = try std.json.Stringify.valueAlloc(a, args, .{});
        const request = (try AgentTools.Request.parse(a, round.work.session.role, name, arguments)).?;
        const reply = try Kernel.RuntimeRound.invoke(round, a, request);
        return std.json.parseFromSliceLeaky(std.json.Value, a, reply.parts[0].text, .{});
    }
};

test "core startup reports the outgoing registration of each runtime" {
    const testing = std.testing;
    var fixture: SubscriptionFixture = .{};
    defer fixture.deinit();
    const a = fixture.storage.arena.allocator();
    var store = try Subscriptions.Store.openInMemory(a);
    defer store.close();
    const registrations: []const []const []const u8 = &.{ &.{"operator"}, &.{"Reviewer+Ops"}, &.{} };
    for (registrations) |ids| {
        fixture.correspondents = ids;
        var engine: Engine = undefined;
        var kernel = try fixture.kernel(&engine, &store);
        defer kernel.deinit();
        const work = try SubscriptionFixture.takeWork(&kernel, a);
        var history = try kernel.sessions.snapshot(work.session);
        defer history.deinit();
        const input = (try kernel.prepareRequest(a, work, &history)).ready;
        const turn = input[input.len - 1].message.text;
        const marker = if (ids.len == 0) "correspondents: []" else ids[0];
        try testing.expect(std.mem.indexOf(u8, turn, marker) != null);
        const records = history.records();
        const startup = records[records.len - 1].record.events.items[0].startup;
        try testing.expectEqualDeep(ids, startup.correspondents.?);
        if (ids.len == 0) {
            const snapshot = try kernel.compactionSnapshot(a, work.session);
            const summary = try history.summaryRequest(a, snapshot, "Summarize.", .keep_latest_tool_round);
            try testing.expect(std.mem.indexOf(u8, summary[summary.len - 1].message.text, marker) != null);
        }
        try SubscriptionFixture.finish(&kernel, work, &history);
    }
}

test "continuations omit destination directories and focus and channel sends resolve separately" {
    const testing = std.testing;
    const call = SubscriptionFixture.callTool;
    var fixture: SubscriptionFixture = .{ .correspondents = &.{"reviewer+notes"} };
    defer fixture.deinit();
    const a = fixture.storage.arena.allocator();
    var store = try Subscriptions.Store.openInMemory(a);
    defer store.close();
    var engine: Engine = undefined;
    var kernel = try fixture.kernel(&engine, &store);
    defer kernel.deinit();
    var core: Kernel.RuntimeRound = .{ .kernel = &kernel, .work = try SubscriptionFixture.takeWork(&kernel, a) };
    defer core.deinit();
    defer kernel.sessions.endWorker(core.work.session);
    var history = try SubscriptionFixture.admit(&kernel, a, core.work);
    defer history.deinit();

    const opened = try call(a, &core, "open_focus", .{ .name = "research", .task = "Collect findings." });
    const sender_id = opened.object.get("result").?.object.get("focus_id").?.string;
    try core.commit(&history, null);
    var activity: Kernel.RuntimeRound = .{ .kernel = &kernel, .work = try SubscriptionFixture.takeWork(&kernel, a) };
    defer kernel.sessions.endWorker(activity.work.session);
    defer activity.deinit();
    var activity_history = try SubscriptionFixture.admit(&kernel, a, activity.work);
    defer activity_history.deinit();

    const description = "Receives paths to the findings ready for processing.";
    const opened_channel = try call(a, &activity, "open_channel", .{ .name = "core", .description = description });
    const channel_id = opened_channel.object.get("result").?.object.get("channel_id").?.string;
    const before_commit = try kernel.compactionSnapshot(a, core.work.session);
    try testing.expectEqual(0, before_commit.state.channel_registrations.len);
    const closed = try call(a, &core, "close_channel", .{ .channel_id = channel_id });
    try testing.expect(!closed.object.get("result").?.object.get("changed").?.bool);
    try SubscriptionFixture.appendChannelReply(a, &activity_history, opened_channel);
    try activity.commit(&activity_history, null);

    for ([_]*Sessions.Session{ core.work.session, activity.work.session }) |session| {
        const sample = try kernel.compactionSnapshot(a, session);
        try testing.expectEqualDeep(@as([]const Input.SampledChannel, &.{.{
            .channel_id = channel_id,
            .description = description,
        }}), sample.state.channel_registrations);
    }

    const input = (try kernel.prepareRequest(a, core.work, &history)).ready;
    const turn = input[input.len - 1].message.text;
    for ([_][]const u8{ "activities:", "correspondents:", "channels:", description }) |field| {
        try testing.expect(std.mem.indexOf(u8, turn, field) == null);
    }

    const result = try call(a, &activity, "send", .{
        .to = .{ .focus_id = core.work.session.focus_id },
        .text = "Findings are ready.",
    });
    const core_id = core.work.session.focus_id;
    try testing.expectEqualStrings(core_id, result.object.get("result").?.object.get("focus_id").?.string);
    const sent = try call(a, &core, "send", .{
        .to = .{ .channel_id = channel_id },
        .text = "Process these findings.",
    });
    const receipt = sent.object.get("result").?.object;
    try testing.expectEqualStrings(channel_id, receipt.get("channel_id").?.string);
    try testing.expectEqualStrings("accepted", receipt.get("status").?.string);
    try testing.expectEqualStrings(channel_id, fixture.channel_send.?.id);
    try testing.expectEqualStrings("Process these findings.", fixture.channel_send.?.text);
    try kernel.sessions.collectPending(core.work);
    const deliveries = core.work.activation.deliveries.items;
    try testing.expectEqual(1, deliveries.len);
    const message = deliveries[0].event.focus_message;
    try testing.expectEqualStrings(sender_id, message.from_focus);
    try testing.expectEqualStrings("Findings are ready.", message.text);

    fixture.send_outcome = .would_block;
    const rejected = try call(a, &activity, "send", .{ .to = .{ .channel_id = channel_id }, .text = "Process more findings." });
    try testing.expectEqualStrings("channel_would_block", rejected.object.get("error").?.object.get("code").?.string);
}

test "an activity can withdraw another focus's subscription by reference" {
    const testing = std.testing;
    const call = SubscriptionFixture.callTool;
    var fixture: SubscriptionFixture = .{};
    defer fixture.deinit();
    const a = fixture.storage.arena.allocator();
    var store = try Subscriptions.Store.openInMemory(a);
    defer store.close();
    var engine: Engine = undefined;
    var kernel = try fixture.kernel(&engine, &store);
    defer kernel.deinit();
    var core: Kernel.RuntimeRound = .{ .kernel = &kernel, .work = try SubscriptionFixture.takeWork(&kernel, a) };
    defer core.deinit();
    var core_history = try SubscriptionFixture.admit(&kernel, a, core.work);
    defer core_history.deinit();
    const created = (try call(a, &core, "subscribe", .{ .name = "releases", .listener = "release feed" })).object.get("result").?;
    const subscription_id = created.object.get("subscription_id").?.string;
    _ = try call(a, &core, "open_focus", .{ .name = "research", .task = "Watch for releases." });
    try core.commit(&core_history, null);

    var activity: Kernel.RuntimeRound = .{ .kernel = &kernel, .work = try SubscriptionFixture.takeWork(&kernel, a) };
    defer activity.deinit();
    const closed = (try call(a, &activity, "withdraw_subscription", .{ .subscription_id = subscription_id })).object.get("result").?.object;
    try testing.expectEqualStrings(subscription_id, closed.get("subscription_id").?.string);
    try testing.expect(closed.get("changed").?.bool);

    const repeated = (try call(a, &activity, "withdraw_subscription", .{ .subscription_id = subscription_id })).object.get("result").?.object;
    try testing.expect(!repeated.get("changed").?.bool);
}

test "subscription admission and database acknowledgement survive either outcome of an unconfirmed checkpoint" {
    const testing = std.testing;
    for ([_]TestStore.SaveFailure{ .before_commit, .after_commit }) |failure| {
        var fixture: SubscriptionFixture = .{};
        defer fixture.deinit();
        const a = fixture.storage.arena.allocator();
        var store = try Subscriptions.Store.openInMemory(a);
        defer store.close();
        var engine: Engine = undefined;
        {
            var kernel = try fixture.kernel(&engine, &store);
            defer kernel.deinit();
            const core = try SubscriptionFixture.takeWork(&kernel, a);
            var history = try SubscriptionFixture.admit(&kernel, a, core);
            defer history.deinit();
            const sub = try kernel.sessions.subscribe(a, core, "releases", "release listener");
            _ = try store.publish(sub.subscription_id, .{ .key = "release", .text = "Release published" }, 10);
            try testing.expect(!try kernel.sessions.commitResponse(core, &history, SubscriptionFixture.empty_response));
            try kernel.sessions.collectPending(core);
            fixture.storage.fail_save = failure;
            try testing.expectError(error.MailMutationUnconfirmed, SubscriptionFixture.admit(&kernel, a, core));
        }
        fixture.storage.fail_save = .none;
        var kernel = try fixture.kernel(&engine, &store);
        defer kernel.deinit();
        try testing.expectEqual(failure == .before_commit, try store.latestSequence("core-1") != 0);
        const resumed = try SubscriptionFixture.takeWork(&kernel, a);
        var history = try SubscriptionFixture.admit(&kernel, a, resumed);
        defer history.deinit();
        var reports: usize = 0;
        for (history.records()) |entry| {
            if (entry != .record or entry.record != .events) continue;
            for (entry.record.events.items) |event| if (event == .subscription) {
                try testing.expectEqualStrings("Release published", event.subscription.text);
                reports += 1;
            };
        }
        try testing.expectEqual(1, reports);
        try SubscriptionFixture.finish(&kernel, resumed, &history);
    }
}

test "dispatch retires a withdrawn activity once its accepted reports have been admitted" {
    const testing = std.testing;
    const Case = enum { live, restart_empty, restart_with_report };
    for ([_]Case{ .live, .restart_empty, .restart_with_report }) |scenario| {
        var fixture: SubscriptionFixture = .{};
        defer fixture.deinit();
        const a = fixture.storage.arena.allocator();
        var store = try Subscriptions.Store.openInMemory(a);
        defer store.close();
        var engine: Engine = undefined;
        var kernel = try fixture.kernel(&engine, &store);
        defer kernel.deinit();
        const core = try SubscriptionFixture.takeWork(&kernel, a);
        var core_history = try SubscriptionFixture.admit(&kernel, a, core);
        defer core_history.deinit();
        const sub = try SubscriptionFixture.watchingActivity(&kernel, a, core, &core_history, "watch");
        if (scenario == .restart_with_report) _ = try store.publish(sub, .{ .key = "final", .text = "Final report" }, 100);
        _ = try kernel.sessions.withdrawSubscription(core, sub);
        try SubscriptionFixture.finish(&kernel, core, &core_history);

        if (scenario != .live) {
            const restored = try fixture.kernel(&engine, &store);
            kernel.deinit();
            kernel = restored;
        }
        // Retiring an idle activity can notify the core after its dispatch slot.
        var ready = try kernel.sessions.takeReadyBatch(a);
        if (ready.len == 0) ready = try kernel.sessions.takeReadyBatch(a);
        if (scenario == .restart_with_report) {
            try testing.expectEqual(2, ready.len);
            var final_report = try SubscriptionFixture.admit(&kernel, a, ready[1]);
            defer final_report.deinit();
            const events = final_report.records()[final_report.records().len - 1].record.events.items;
            try testing.expectEqualStrings("Final report", events[events.len - 1].subscription.text);
            try SubscriptionFixture.finish(&kernel, ready[1], &final_report);
        } else try testing.expectEqual(1, ready.len);
        const ending = ready[0];
        var received = try SubscriptionFixture.admit(&kernel, a, ending);
        defer received.deinit();
        const events = received.records()[received.records().len - 1].record.events.items;
        const observation = events[events.len - 1].activity;
        try testing.expectEqualStrings("watch-2", observation.from_focus);
        try testing.expect(observation.ended_at_unix_ms != null);
        try SubscriptionFixture.finish(&kernel, ending, &received);
    }
}

test "an activity admits its sampled backlog in one input and receives a later report after withdrawal" {
    const testing = std.testing;
    var fixture: SubscriptionFixture = .{};
    defer fixture.deinit();
    const a = fixture.storage.arena.allocator();
    var store = try Subscriptions.Store.openInMemory(a);
    defer store.close();
    var engine: Engine = undefined;
    var kernel = try fixture.kernel(&engine, &store);
    defer kernel.deinit();
    kernel.sessions.max_pending = 1;
    const core = try SubscriptionFixture.takeWork(&kernel, a);
    defer kernel.sessions.endWorker(core.session);
    var core_history = try SubscriptionFixture.admit(&kernel, a, core);
    defer core_history.deinit();
    const watch = try SubscriptionFixture.watchingActivity(&kernel, a, core, &core_history, "watch");
    const backlog = 70;
    for (0..backlog) |i| {
        const text = try std.fmt.allocPrint(a, "update {d}", .{i});
        _ = try store.publish(watch, .{ .key = text, .text = text }, @intCast(i));
    }
    const activity = try SubscriptionFixture.takeWork(&kernel, a);
    // Publication races with admission after the first I/O page was collected.
    _ = try store.publish(watch, .{ .key = "later", .text = "One more" }, backlog);
    try testing.expect(try kernel.sessions.withdrawSubscription(core, watch));
    var received = try SubscriptionFixture.admit(&kernel, a, activity);
    defer received.deinit();
    const events = received.records()[received.records().len - 1].record.events.items;
    try testing.expectEqual(backlog, events.len);
    for (events, 0..) |event, index| {
        try testing.expectEqual(@as(i64, @intCast(index)), event.subscription.observed_at_unix_ms);
    }
    try testing.expect(!try kernel.sessions.commitResponse(activity, &received, SubscriptionFixture.empty_response));
    try kernel.sessions.collectPending(activity);
    var later = try SubscriptionFixture.admit(&kernel, a, activity);
    defer later.deinit();
    const next = later.records()[later.records().len - 1].record.events.items;
    try testing.expectEqual(1, next.len);
    try testing.expectEqualStrings("One more", next[0].subscription.text);
    try SubscriptionFixture.finish(&kernel, activity, &later);
}

test "a subscription backlog leaves another focus schedulable and each source gets a turn under a one-event budget" {
    const testing = std.testing;
    var fixture: SubscriptionFixture = .{};
    defer fixture.deinit();
    const a = fixture.storage.arena.allocator();
    var store = try Subscriptions.Store.openInMemory(a);
    defer store.close();
    var engine: Engine = undefined;
    var kernel = try fixture.kernel(&engine, &store);
    defer kernel.deinit();

    const core = try SubscriptionFixture.takeWork(&kernel, a);
    var history = try SubscriptionFixture.admit(&kernel, a, core);
    defer history.deinit();
    const wakeup = try kernel.sessions.registerCallback(a, core, "wake", .wakeup);
    const stream = try kernel.sessions.subscribe(a, core, "stream", "listener");
    const build = try SubscriptionFixture.watchingActivity(&kernel, a, core, &history, "budget-marker");
    try SubscriptionFixture.finish(&kernel, core, &history);

    for (0..4) |index| try testing.expectEqual(.accepted, try store.publish(stream.subscription_id, .{
        .key = try std.fmt.allocPrint(a, "report-{d}", .{index}),
        .text = "budget-marker",
    }, @intCast(index)));
    try testing.expectEqual(.accepted, try store.publish(build, .{
        .key = "done",
        .text = "ready",
    }, 90));
    const callback: contracts.Inbox.Incoming = .{
        .content = .{ .callback = .{ .id = wakeup.id, .text = "budget-marker", .observed_at_unix_ms = 100 } },
    };
    try testing.expectEqual(.accepted, try kernel.sessions.accept(callback));
    for (0..2) |_| try testing.expectEqual(.accepted, try kernel.sessions.accept(.{
        .content = .{ .message = .{ .from = &.{"operator"}, .text = "budget-marker", .observed_at_unix_ms = 100 } },
    }));
    kernel.limits.observation_batch_bytes = 1;
    const ready = try kernel.sessions.takeReadyBatch(a);
    try testing.expectEqual(2, ready.len);
    const work = ready[1];
    try testing.expectEqualStrings("budget-marker-2", work.session.focus_id);
    var received = try SubscriptionFixture.admit(&kernel, a, work);
    defer received.deinit();
    try testing.expect(try kernel.sessions.withdrawSubscription(work, build));
    try SubscriptionFixture.finish(&kernel, work, &received);

    const resumed = ready[0];
    try testing.expectEqualStrings("core-1", resumed.session.focus_id);
    defer kernel.sessions.endWorker(resumed.session);
    var served: std.EnumSet(std.meta.Tag(Input.Event)) = .empty;
    for (0..3) |index| {
        if (index != 0) try kernel.sessions.collectPending(resumed);
        var admitted = try SubscriptionFixture.admit(&kernel, a, resumed);
        defer admitted.deinit();
        const events = admitted.records()[admitted.records().len - 1].record.events.items;
        try testing.expectEqual(1, events.len);
        served.insert(std.meta.activeTag(events[0]));
        try testing.expect(!try kernel.sessions.commitResponse(resumed, &admitted, SubscriptionFixture.empty_response));
    }
    try testing.expect(served.contains(.callback) and served.contains(.subscription) and served.contains(.activity));
    try testing.expectEqual(.duplicate, try kernel.sessions.accept(callback));
}

test "restart resumes observation source rotation after the startup observation" {
    const testing = std.testing;
    var fixture: SubscriptionFixture = .{};
    defer fixture.deinit();
    const a = fixture.storage.arena.allocator();
    var store = try Subscriptions.Store.openInMemory(a);
    defer store.close();
    var engine: Engine = undefined;
    const ordinary: contracts.Inbox.Incoming = .{ .content = .{ .message = .{
        .from = &.{"operator"},
        .text = "budget-marker",
        .observed_at_unix_ms = 100,
    } } };
    const stream = registered: {
        var kernel = try fixture.kernel(&engine, &store);
        defer kernel.deinit();
        try testing.expectEqual(.accepted, try kernel.sessions.accept(ordinary));
        const startup = try SubscriptionFixture.takeWork(&kernel, a);
        var initial = try SubscriptionFixture.admit(&kernel, a, startup);
        defer initial.deinit();
        const stream = try kernel.sessions.subscribe(a, startup, "stream", "listener");
        try SubscriptionFixture.finish(&kernel, startup, &initial);
        break :registered stream;
    };

    var kernel = try fixture.kernel(&engine, &store);
    defer kernel.deinit();
    kernel.limits.observation_batch_bytes = 1;
    try testing.expectEqual(.accepted, try kernel.sessions.accept(ordinary));
    try testing.expectEqual(.accepted, try store.publish(stream.subscription_id, .{ .key = "first", .text = "budget-marker" }, 110));
    const work = try SubscriptionFixture.takeWork(&kernel, a);
    defer kernel.sessions.endWorker(work.session);
    var history = try SubscriptionFixture.admit(&kernel, a, work);
    defer history.deinit();
    const observations = history.records()[history.records().len - 1].record.events.items;
    try testing.expectEqual(2, observations.len);
    try testing.expect(observations[0] == .startup and observations[1] == .subscription);
}

test "restart uses saved input-token counts only for a matching model scope" {
    const testing = std.testing;
    const Budget = struct {
        fn measure(_: *anyopaque, _: Allocator, _: Model.Request) anyerror!Model.Measurement {
            return .{ .bytes = 100 };
        }

        fn next(_: *anyopaque, _: Allocator, _: Model.Request) anyerror!Model.Outcome {
            return .{ .response = .{ .output = &.{}, .calls = &.{}, .text = "Retained summary." } };
        }
    };
    const cases = [_]struct { before: ?[32]u8, after: ?[32]u8, compacts: bool }{
        .{ .before = @splat(1), .after = @splat(1), .compacts = false },
        .{ .before = @splat(1), .after = @splat(2), .compacts = true },
        .{ .before = null, .after = null, .compacts = true },
    };
    for (cases) |case| {
        var fixture: SubscriptionFixture = .{ .usage_scope = case.before };
        defer fixture.deinit();
        const a = fixture.storage.arena.allocator();
        var store = try Subscriptions.Store.openInMemory(a);
        defer store.close();
        var engine: Engine = undefined;
        {
            var kernel = try fixture.kernel(&engine, &store);
            defer kernel.deinit();
            const startup = try SubscriptionFixture.takeWork(&kernel, a);
            defer kernel.sessions.endWorker(startup.session);
            var history = try SubscriptionFixture.admit(&kernel, a, startup);
            defer history.deinit();
            try testing.expect(try kernel.sessions.commitResponse(startup, &history, .{
                .output = &.{.{ .continuation = "Latest response" }},
                .calls = &.{},
                .text = null,
                .input_tokens = 7,
            }));
        }

        fixture.usage_scope = case.after;
        var kernel = try fixture.kernel(&engine, &store);
        defer kernel.deinit();
        engine.model.vtable = &.{ .next = Budget.next, .measure = Budget.measure, .prepareToolReplies = undefined };
        kernel.limits.compact_at_bytes = 50;
        kernel.limits.compact_at_tokens = 8;
        const startup = try SubscriptionFixture.takeWork(&kernel, a);
        defer kernel.sessions.endWorker(startup.session);
        var history = try SubscriptionFixture.admit(&kernel, a, startup);
        defer history.deinit();
        try testing.expectEqual(@intFromBool(case.compacts), history.scope.epoch);
    }
}

test "a rejected inference resumes for remaining reports while failed admission waits for fresh input" {
    const testing = std.testing;
    var fixture: SubscriptionFixture = .{};
    defer fixture.deinit();
    const a = fixture.storage.arena.allocator();
    var store = try Subscriptions.Store.openInMemory(a);
    defer store.close();
    var engine: Engine = undefined;
    var kernel = try fixture.kernel(&engine, &store);
    defer kernel.deinit();
    const startup = try SubscriptionFixture.takeWork(&kernel, a);
    var initial = try SubscriptionFixture.admit(&kernel, a, startup);
    defer initial.deinit();
    const subscription = try kernel.sessions.subscribe(a, startup, "read", "feed listener");
    try SubscriptionFixture.finish(&kernel, startup, &initial);
    for ([_][]const u8{ "first", "second" }) |key| {
        _ = try store.publish(subscription.subscription_id, .{ .key = key, .text = "budget-marker" }, 100);
    }
    kernel.limits.observation_batch_bytes = 1;
    const first = try SubscriptionFixture.takeWork(&kernel, a);
    var admitted = try SubscriptionFixture.admit(&kernel, a, first);
    defer admitted.deinit();
    try kernel.sessions.interrupt(first, "The model rejected the inference after admission.");
    kernel.sessions.endWorker(first.session);
    const second = try SubscriptionFixture.takeWork(&kernel, a);
    try testing.expectEqual(1, second.activation.deliveries.items.len);
    const third = Subscriptions.NewReport{ .key = "third", .text = "budget-marker" };
    _ = try store.publish(subscription.subscription_id, third, 110);
    try kernel.sessions.interrupt(second, "The remaining observation could not be admitted.");
    kernel.sessions.endWorker(second.session);
    const retry = try SubscriptionFixture.takeWork(&kernel, a);
    try testing.expectEqual(2, retry.activation.deliveries.items.len);
    try kernel.sessions.interrupt(retry, "The batch still cannot be admitted.");
    kernel.sessions.endWorker(retry.session);
    try testing.expectEqual(.duplicate, try store.publish(subscription.subscription_id, third, 120));
    try testing.expectEqual(0, (try kernel.sessions.takeReadyBatch(a)).len);
    _ = try store.publish(subscription.subscription_id, .{ .key = "fourth", .text = "budget-marker" }, 130);
    const resumed = try SubscriptionFixture.takeWork(&kernel, a);
    try testing.expectEqual(3, resumed.activation.deliveries.items.len);
    kernel.sessions.endWorker(resumed.session);
}

test "compaction gives a complete fresh exchange and observation room beyond the soft threshold" {
    const testing = std.testing;
    const BudgetModel = struct {
        hard_limit: u64,
        summaries: usize = 0,
        summary_saw_omission: bool = false,
        summary: enum { success, rejection, outage } = .success,

        fn measure(context: *anyopaque, _: Allocator, request: Model.Request) anyerror!Model.Measurement {
            const self: *@This() = @ptrCast(@alignCast(context));
            var bytes: u64 = 0;
            for (request.history) |item| switch (item) {
                .message => |message| {
                    if (std.mem.indexOf(u8, message.text, "older context marker") != null) bytes += 5;
                    if (std.mem.indexOf(u8, message.text, "large observation marker") != null) bytes += 6;
                },
                .tool_result => |result| for (result.content.parts) |part| {
                    if (part == .image) bytes += part.image.data.bytes.len;
                },
                .continuation => {},
            };
            return .{ .bytes = bytes, .violation = if (bytes > self.hard_limit)
                .{ .kind = .request_bytes, .actual = bytes, .maximum = self.hard_limit }
            else
                null };
        }

        fn next(context: *anyopaque, _: Allocator, request: Model.Request) anyerror!Model.Outcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            try testing.expectEqual(@as(usize, 0), request.tools.len);
            try testing.expectEqualStrings("max", request.reasoning_effort);
            const turn = request.history[request.history.len - 1].message.text;
            try testing.expect(std.mem.indexOf(u8, turn, "\nsummarize:") != null);
            for (request.history) |item| {
                if (item != .tool_result) continue;
                try testing.expect(item.tool_result.content.parts[0] == .text);
                self.summary_saw_omission = true;
            }
            self.summaries += 1;
            return switch (self.summary) {
                .success => .{ .response = .{ .output = &.{}, .calls = &.{}, .text = "A useful handover." } },
                .rejection => .{ .rejected = .request_rejected },
                .outage => .{ .unavailable = .{} },
            };
        }
    };

    const exchange: []const Model.Item = &.{
        .{ .continuation = "native image tool call" },
        .{ .tool_result = .{ .call_id = "read-1", .content = .{ .parts = &.{
            .{ .image = .{ .data = .{ .format = .png, .bytes = "image-data" } } },
        } } } },
    };
    const Case = struct {
        ceiling: u64,
        summary: @FieldType(BudgetModel, "summary") = .success,
        compacted: bool = true,
        delivered: bool = true,
        kept_image: bool = true,
        observed_tokens: ?u64 = null,
        compact_at_bytes: u64 = 4,
        summaries: usize = 1,
    };
    for ([_]Case{
        .{ .ceiling = 40 },
        .{ .ceiling = 40, .summary = .outage, .compacted = false },
        .{ .ceiling = 40, .observed_tokens = 7, .compacted = false, .summaries = 0 },
        .{ .ceiling = 40, .observed_tokens = 8, .compact_at_bytes = 100 },
        .{ .ceiling = 16 },
        .{ .ceiling = 16, .summary = .rejection, .compacted = false, .delivered = false },
        .{ .ceiling = 15, .compacted = false, .delivered = false, .summaries = 0 },
        .{ .ceiling = 14, .delivered = false },
        .{ .ceiling = 8, .kept_image = false },
    }) |case| {
        var fixture: SubscriptionFixture = .{};
        defer fixture.deinit();
        const a = fixture.storage.arena.allocator();
        var store = try Subscriptions.Store.openInMemory(a);
        defer store.close();
        var engine: Engine = undefined;
        var kernel = try fixture.kernel(&engine, &store);
        defer kernel.deinit();
        const startup = try SubscriptionFixture.takeWork(&kernel, a);
        var initial = try SubscriptionFixture.admit(&kernel, a, startup);
        defer initial.deinit();
        try SubscriptionFixture.finish(&kernel, startup, &initial);

        try testing.expectEqual(.accepted, try kernel.sessions.accept(.{ .content = .{ .message = .{
            .from = &.{"operator"},
            .text = "large observation marker",
            .observed_at_unix_ms = 100,
        } } }));
        const work = try SubscriptionFixture.takeWork(&kernel, a);
        defer kernel.sessions.endWorker(work.session);
        var history = try kernel.sessions.snapshot(work.session);
        defer history.deinit();
        try history.appendRecord(.{ .events = .{ .focus_id = work.session.focus_id, .items = &.{.{
            .input = .{ .from = &.{"operator"}, .text = "older context marker", .observed_at_unix_ms = 90 },
        }} } });
        try history.appendBatch(exchange[0..1], exchange[1..]);
        work.session.progress.last_input_tokens = case.observed_tokens;

        var model: BudgetModel = .{ .hard_limit = case.ceiling, .summary = case.summary };
        engine.model = .{ .context = &model, .vtable = &.{ .next = BudgetModel.next, .measure = BudgetModel.measure, .prepareToolReplies = undefined } };
        kernel.limits.compact_at_bytes = case.compact_at_bytes;
        kernel.limits.compact_at_tokens = 8;
        const input = (try kernel.prepareRequest(a, work, &history)).ready;
        try testing.expectEqual(case.summaries, model.summaries);
        try testing.expectEqual(!case.kept_image, model.summary_saw_omission);
        const turn = input[input.len - 1].message.text;
        try testing.expectEqual(case.delivered, std.mem.indexOf(u8, turn, "large observation marker") != null);
        if (case.kept_image) {
            try testing.expectEqualDeep(exchange[0], input[input.len - 3]);
            try testing.expectEqualDeep(exchange[1], input[input.len - 2]);
        } else {
            try testing.expectEqual(@as(usize, 3), input.len);
        }
        try testing.expectEqual(@as(u64, @intFromBool(case.compacted)), history.scope.epoch);
        try testing.expectEqual(if (case.compacted) null else case.observed_tokens, work.session.progress.last_input_tokens);
        if (!case.delivered) try testing.expect(!work.activation.admitted);
    }
}

test "an empty completion closes admitted work before retrying an oversized waiting observation" {
    const testing = std.testing;
    const Stub = struct {
        inferences: usize = 0,

        fn measure(_: *anyopaque, _: Allocator, request: Model.Request) anyerror!Model.Measurement {
            const turn = request.history[request.history.len - 1].message.text;
            if (std.mem.indexOf(u8, turn, "Oversized observation") != null)
                return .{ .bytes = 2, .violation = .{ .kind = .request_bytes, .actual = 2, .maximum = 1 } };
            return .{ .bytes = 1 };
        }

        fn next(context: *anyopaque, _: Allocator, _: Model.Request) anyerror!Model.Outcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.inferences += 1;
            return .{ .response = SubscriptionFixture.empty_response };
        }
    };
    var fixture: SubscriptionFixture = .{};
    defer fixture.deinit();
    const a = fixture.storage.arena.allocator();
    var store = try Subscriptions.Store.openInMemory(a);
    defer store.close();
    var engine: Engine = undefined;
    var kernel = try fixture.kernel(&engine, &store);
    defer kernel.deinit();
    const work = try SubscriptionFixture.takeWork(&kernel, a);
    defer kernel.sessions.endWorker(work.session);
    var initial = try SubscriptionFixture.admit(&kernel, a, work);
    defer initial.deinit();
    try testing.expect(initial.hasPendingContinuation());
    try testing.expectEqual(.accepted, try kernel.sessions.accept(.{ .content = .{ .message = .{
        .from = &.{"operator"},
        .text = "Oversized observation",
        .observed_at_unix_ms = 100,
    } } }));

    var stub: Stub = .{};
    engine.model = .{ .context = &stub, .vtable = &.{ .next = Stub.next, .measure = Stub.measure, .prepareToolReplies = undefined } };
    try testing.expectEqualStrings("The context was too large to continue.", (try kernel.respond(work)) orelse return error.TestUnexpectedResult);
    try testing.expectEqual(@as(usize, 1), stub.inferences);
    try testing.expectEqual(@as(usize, 1), work.activation.deliveries.items.len);
    var completed = try kernel.sessions.snapshot(work.session);
    defer completed.deinit();
    try testing.expect(!completed.hasPendingContinuation());
}

test "the byte ruler reads retained history, not the pending observation" {
    const testing = std.testing;
    const Counting = struct {
        summaries: usize = 0,

        fn measure(_: *anyopaque, _: Allocator, request: Model.Request) anyerror!Model.Measurement {
            var bytes: u64 = 0;
            for (request.history) |item| switch (item) {
                .message => |message| {
                    bytes += std.mem.count(u8, message.text, "old marker");
                    bytes += std.mem.count(u8, message.text, "new marker");
                },
                else => {},
            };
            return .{ .bytes = bytes };
        }

        fn next(context: *anyopaque, _: Allocator, request: Model.Request) anyerror!Model.Outcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            for (request.history) |item| {
                if (item == .message) try testing.expect(std.mem.indexOf(u8, item.message.text, "new marker") == null);
            }
            self.summaries += 1;
            return .{ .response = .{ .output = &.{}, .calls = &.{}, .text = "A useful handover." } };
        }
    };
    // The observation alone is over the byte threshold. Only history decides.
    for ([_]bool{ false, true }) |inherited_over_threshold| {
        var fixture: SubscriptionFixture = .{};
        defer fixture.deinit();
        const a = fixture.storage.arena.allocator();
        var store = try Subscriptions.Store.openInMemory(a);
        defer store.close();
        var engine: Engine = undefined;
        var kernel = try fixture.kernel(&engine, &store);
        defer kernel.deinit();
        var counting: Counting = .{};
        engine.model = .{ .context = &counting, .vtable = &.{ .next = Counting.next, .measure = Counting.measure, .prepareToolReplies = undefined } };
        kernel.limits.compact_at_tokens = 1_000_000;
        kernel.limits.compact_at_bytes = 1;

        try testing.expectEqual(.accepted, try kernel.sessions.accept(.{ .content = .{ .message = .{
            .from = &.{"operator"},
            .text = "new marker",
            .observed_at_unix_ms = 100,
        } } }));
        const work = try SubscriptionFixture.takeWork(&kernel, a);
        defer kernel.sessions.endWorker(work.session);
        var history = try kernel.sessions.snapshot(work.session);
        defer history.deinit();
        try history.appendRecord(.{ .events = .{ .focus_id = work.session.focus_id, .items = &.{.{ .input = .{
            .from = &.{"operator"},
            .text = if (inherited_over_threshold) "old marker" else "older context",
            .observed_at_unix_ms = 90,
        } }} } });
        try history.appendBatch(&.{.{ .continuation = "A prior reply" }}, &.{});
        const input = (try kernel.prepareRequest(a, work, &history)).ready;
        try testing.expectEqual(@as(usize, @intFromBool(inherited_over_threshold)), counting.summaries);
        var occurrences: usize = 0;
        for (input) |item| {
            if (item == .message) occurrences += std.mem.count(u8, item.message.text, "new marker");
        }
        try testing.expectEqual(@as(usize, 1), occurrences);
    }
}

test "a lone handover is shortened only if needed to fit the next observation" {
    const testing = std.testing;
    const Stub = struct {
        limit: u64,
        summaries: usize = 0,

        fn measure(context: *anyopaque, _: Allocator, request: Model.Request) anyerror!Model.Measurement {
            const self: *@This() = @ptrCast(@alignCast(context));
            var bytes: u64 = 0;
            for (request.history) |item| {
                if (item != .message) continue;
                if (std.mem.indexOf(u8, item.message.text, "Earlier commitments") != null) bytes += 24;
                if (std.mem.indexOf(u8, item.message.text, "Incoming letter") != null) bytes += 16;
            }
            return .{ .bytes = bytes, .violation = if (bytes > self.limit)
                .{ .kind = .request_bytes, .actual = bytes, .maximum = self.limit }
            else
                null };
        }

        fn next(context: *anyopaque, _: Allocator, request: Model.Request) anyerror!Model.Outcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            try testing.expect(std.mem.indexOf(u8, request.history[1].message.text, "Earlier commitments") != null);
            try testing.expect(std.mem.indexOf(u8, request.history[2].message.text, "Incoming letter") == null);
            self.summaries += 1;
            return .{ .response = .{ .output = &.{}, .calls = &.{}, .text = "Prior commitments, condensed." } };
        }
    };
    for ([_]u64{ 64, 32, 8 }) |limit| {
        var fixture: SubscriptionFixture = .{};
        defer fixture.deinit();
        const a = fixture.storage.arena.allocator();
        var store = try Subscriptions.Store.openInMemory(a);
        defer store.close();
        var engine: Engine = undefined;
        var kernel = try fixture.kernel(&engine, &store);
        defer kernel.deinit();
        var stub: Stub = .{ .limit = limit };
        engine.model = .{ .context = &stub, .vtable = &.{ .next = Stub.next, .measure = Stub.measure, .prepareToolReplies = undefined } };
        kernel.limits.compact_at_bytes = 8;

        const startup = try SubscriptionFixture.takeWork(&kernel, a);
        var core = try SubscriptionFixture.admit(&kernel, a, startup);
        defer core.deinit();
        try SubscriptionFixture.finish(&kernel, startup, &core);
        try testing.expectEqual(.accepted, try kernel.sessions.accept(.{ .content = .{ .message = .{
            .from = &.{"operator"},
            .text = "Incoming letter",
            .observed_at_unix_ms = 100,
        } } }));
        const work = try SubscriptionFixture.takeWork(&kernel, a);
        defer kernel.sessions.endWorker(work.session);
        const handover: Input.Handover = .{
            .focus_id = work.session.focus_id,
            .observed_at_unix_ms = 90,
            .summary = "Earlier commitments and open questions.",
            .state = .{ .activities = &.{}, .callbacks = &.{} },
        };
        var history = try Context.restore(testing.allocator, .{ .session_id = work.session.session_id, .epoch = 0 }, work.session.focus_id, &.{
            .{ .record = .{ .handover = handover } },
        });
        defer history.deinit();

        const result = try kernel.prepareRequest(a, work, &history);
        try testing.expectEqual(@as(usize, @intFromBool(limit == 32)), stub.summaries);
        if (limit == 8) {
            try testing.expect(result == .interrupted);
            try testing.expect(!work.activation.admitted);
        } else {
            try testing.expect(std.mem.indexOf(u8, result.ready[result.ready.len - 1].message.text, "Incoming letter") != null);
        }
        try testing.expectEqualStrings(if (limit == 32) "Prior commitments, condensed." else handover.summary, history.records()[0].record.handover.summary);
    }
}

test "a fork continues with its first assignment and applies the ordinary compaction rule" {
    const testing = std.testing;
    const opening_call =
        \\{"type":"function_call","call_id":"open-focus","name":"open_focus","arguments":"{\"name\":\"research\",\"task\":\"Read the plan.\"}"}
    ;
    const Stub = struct {
        limit: u64,
        summaries: usize = 0,

        fn measure(context: *anyopaque, _: Allocator, request: Model.Request) anyerror!Model.Measurement {
            const self: *@This() = @ptrCast(@alignCast(context));
            var bytes: u64 = 0;
            for (request.history) |item| switch (item) {
                .message => |message| {
                    if (std.mem.indexOf(u8, message.text, "Read the plan.") != null) bytes += 6;
                },
                .tool_result => bytes += 16,
                else => {},
            };
            return .{ .bytes = bytes, .violation = if (bytes > self.limit)
                .{ .kind = .request_bytes, .actual = bytes, .maximum = self.limit }
            else
                null };
        }

        fn next(context: *anyopaque, _: Allocator, request: Model.Request) anyerror!Model.Outcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            try testing.expectEqualStrings("provider-effort", request.reasoning_effort);
            var inherited_call = false;
            var inherited_reply = false;
            for (request.history) |item| switch (item) {
                .message => |message| try testing.expect(std.mem.indexOf(u8, message.text, "Read the plan.") == null),
                .continuation => |bytes| inherited_call = std.mem.eql(u8, bytes, opening_call),
                .tool_result => |result| inherited_reply = std.mem.eql(u8, result.call_id, "open-focus"),
            };
            try testing.expect(inherited_call);
            try testing.expect(inherited_reply);
            self.summaries += 1;
            return .{ .response = .{ .output = &.{}, .calls = &.{}, .text = "A summary of the core's work." } };
        }
    };
    const Case = struct { threshold: u64, limit: u64, compacted: bool = false };
    for ([_]Case{
        .{ .threshold = 32, .limit = 32 },
        .{ .threshold = 16, .limit = 32, .compacted = true },
        .{ .threshold = 32, .limit = 20, .compacted = true },
        .{ .threshold = 32, .limit = 5 },
    }) |case| {
        var fixture: SubscriptionFixture = .{};
        defer fixture.deinit();
        const a = fixture.storage.arena.allocator();
        var store = try Subscriptions.Store.openInMemory(a);
        defer store.close();
        var engine: Engine = undefined;
        var kernel = try fixture.kernel(&engine, &store);
        defer kernel.deinit();
        var stub: Stub = .{ .limit = case.limit };
        engine.model = .{ .context = &stub, .vtable = &.{ .next = Stub.next, .measure = Stub.measure, .prepareToolReplies = undefined } };
        engine.reasoning.compaction = "provider-effort";
        kernel.limits.compact_at_bytes = case.threshold;

        const startup = try SubscriptionFixture.takeWork(&kernel, a);
        defer kernel.sessions.endWorker(startup.session);
        var core = try SubscriptionFixture.admit(&kernel, a, startup);
        defer core.deinit();
        var round: Kernel.RuntimeRound = .{ .kernel = &kernel, .work = startup };
        defer round.deinit();
        _ = try kernel.sessions.prepareFork(startup, &round.changes, "research", "Read the plan.");
        try core.appendBatch(&.{.{ .continuation = opening_call }}, &.{.{
            .tool_result = .{ .call_id = "open-focus", .content = .{ .parts = &.{} } },
        }});
        try round.commit(&core, null);

        const assignment = try SubscriptionFixture.takeWork(&kernel, a);
        defer kernel.sessions.endWorker(assignment.session);
        var history = try kernel.sessions.snapshot(assignment.session);
        defer history.deinit();

        const result = try kernel.prepareRequest(a, assignment, &history);
        try testing.expectEqual(@as(usize, @intFromBool(case.compacted)), stub.summaries);
        if (case.limit == 5) {
            try testing.expect(result == .interrupted);
            try testing.expect(!assignment.activation.admitted);
            continue;
        }
        const input = result.ready;
        try testing.expect(std.mem.indexOf(u8, input[input.len - 1].message.text, "Read the plan.") != null);
        try testing.expectEqual(@as(u64, @intFromBool(case.compacted)), history.scope.epoch);
        if (case.compacted) {
            try testing.expect(std.mem.indexOf(u8, input[1].message.text, "A summary of the core's work.") != null);
        } else {
            try testing.expectEqualStrings("open-focus", input[input.len - 2].tool_result.call_id);
        }
    }
}

test "the first inference after a handover checkpoint receives the original observation after restart" {
    const testing = std.testing;
    const Stub = struct {
        pending: bool = false,

        fn measure(_: *anyopaque, _: Allocator, _: Model.Request) anyerror!Model.Measurement {
            return .{ .bytes = 32 };
        }

        fn next(context: *anyopaque, _: Allocator, request: Model.Request) anyerror!Model.Outcome {
            const self: *@This() = @ptrCast(@alignCast(context));
            var observations: usize = 0;
            for (request.history) |item| {
                if (item == .message) observations += std.mem.count(u8, item.message.text, "Original question");
            }
            if (!self.pending) {
                try testing.expectEqual(@as(usize, 0), observations);
                self.pending = true;
                return .{ .response = .{ .output = &.{}, .calls = &.{}, .text = "A useful handover." } };
            }
            try testing.expectEqual(@as(usize, 1), observations);
            try testing.expect(std.mem.indexOf(u8, request.history[1].message.text, "A useful handover.") != null);
            self.pending = false;
            return .{ .response = SubscriptionFixture.empty_response };
        }
    };
    var fixture: SubscriptionFixture = .{};
    defer fixture.deinit();
    const a = fixture.storage.arena.allocator();
    var store = try Subscriptions.Store.openInMemory(a);
    defer store.close();
    var stub: Stub = .{};
    const port: Model.Port = .{ .context = &stub, .vtable = &.{ .next = Stub.next, .measure = Stub.measure, .prepareToolReplies = undefined } };
    var engine: Engine = undefined;
    {
        var kernel = try fixture.kernel(&engine, &store);
        defer kernel.deinit();
        const startup = try SubscriptionFixture.takeWork(&kernel, a);
        var initial = try SubscriptionFixture.admit(&kernel, a, startup);
        defer initial.deinit();
        try SubscriptionFixture.finish(&kernel, startup, &initial);

        try testing.expectEqual(.accepted, try kernel.sessions.accept(.{ .content = .{ .message = .{
            .from = &.{"operator"},
            .text = "Original question",
            .observed_at_unix_ms = 100,
        } } }));
        const work = try SubscriptionFixture.takeWork(&kernel, a);
        defer kernel.sessions.endWorker(work.session);
        var history = try kernel.sessions.snapshot(work.session);
        defer history.deinit();
        engine.model = port;
        kernel.limits.compact_at_bytes = 32;
        try testing.expect((try kernel.prepareRequest(a, work, &history)) == .ready);
        try testing.expect(stub.pending);
    }
    var restored = try fixture.kernel(&engine, &store);
    defer restored.deinit();
    engine.model = port;
    restored.limits.compact_at_bytes = 32;
    const work = try SubscriptionFixture.takeWork(&restored, a);
    defer restored.sessions.endWorker(work.session);
    try testing.expectEqual(null, try restored.respond(work));
    try testing.expect(!stub.pending);
}

test "a pending document can accompany completed exchanges across a handover" {
    const testing = std.testing;
    const probe = struct {
        fn measure(_: *anyopaque, _: Allocator, _: Model.Request) anyerror!Model.Measurement {
            return .{ .bytes = 40 };
        }
    };
    var fixture: SubscriptionFixture = .{};
    defer fixture.deinit();
    const a = fixture.storage.arena.allocator();
    var store = try Subscriptions.Store.openInMemory(a);
    defer store.close();
    var engine: Engine = undefined;
    var kernel = try fixture.kernel(&engine, &store);
    defer kernel.deinit();
    engine.model.vtable = &.{ .next = undefined, .measure = probe.measure, .prepareToolReplies = undefined };

    const pdf: Content.Part = .{ .file = .{ .bytes = "%PDF", .reference = "file-ref" } };
    const pending: []const Model.Item = &.{
        .{ .continuation = "Pending call" },
        .{ .tool_result = .{ .call_id = "pending", .content = .{ .parts = &.{pdf} } } },
    };
    for ([_]bool{ false, true }) |completed_has_pdf| {
        var history = try Context.init(testing.allocator, .{ .session_id = 1, .epoch = 0 }, "core-1");
        defer history.deinit();
        const completed: Content.Part = if (completed_has_pdf) pdf else .{ .text = "Completed result" };
        try history.appendBatch(&.{.{ .continuation = "Old exchange" }}, &.{});
        try history.appendBatch(&.{.{ .continuation = "Recent response" }}, &.{});
        try history.appendBatch(&.{.{ .continuation = "Completed call" }}, &.{.{ .tool_result = .{ .call_id = "completed", .content = .{ .parts = &.{completed} } } }});
        try history.appendBatch(pending[0..1], pending[1..]);

        const scope = try kernel.softCompactionScope(a, &history, .core);
        var replacement = try history.withHandover(testing.allocator, .{
            .focus_id = "core-1",
            .observed_at_unix_ms = 100,
            .summary = "Older work.",
            .state = .{ .activities = &.{}, .callbacks = &.{} },
        }, scope);
        defer replacement.deinit();
        const carried = replacement.records()[1..];
        try testing.expectEqualDeep(pending, carried[carried.len - 1].exchange);
        const first_response = carried[0].exchange[0].continuation;
        try testing.expectEqualStrings(if (completed_has_pdf) "Pending call" else "Recent response", first_response);
    }
}

test "restart restores a channel after its activity ends until the channel is closed" {
    const testing = std.testing;
    const call = SubscriptionFixture.callTool;
    var fixture: SubscriptionFixture = .{};
    defer fixture.deinit();
    const a = fixture.storage.arena.allocator();
    var store = try Subscriptions.Store.openInMemory(a);
    defer store.close();
    var engine: Engine = undefined;
    var kernel = try fixture.kernel(&engine, &store);
    defer kernel.deinit();
    var core: Kernel.RuntimeRound = .{ .kernel = &kernel, .work = try SubscriptionFixture.takeWork(&kernel, a) };
    defer core.deinit();
    var core_history = try SubscriptionFixture.admit(&kernel, a, core.work);
    defer core_history.deinit();
    _ = try call(a, &core, "open_focus", .{ .name = "research", .task = "Collect findings." });
    try core.commit(&core_history, null);
    var activity: Kernel.RuntimeRound = .{ .kernel = &kernel, .work = try SubscriptionFixture.takeWork(&kernel, a) };
    defer activity.deinit();
    var activity_history = try SubscriptionFixture.admit(&kernel, a, activity.work);
    defer activity_history.deinit();
    const description = "Send findings for the local program to process.";
    const opened = try call(a, &activity, "open_channel", .{ .name = "findings", .description = description });
    const channel_id = opened.object.get("result").?.object.get("channel_id").?.string;
    const activity_id = activity.work.session.session_id;
    try SubscriptionFixture.appendChannelReply(a, &activity_history, opened);
    try activity.commit(&activity_history, null);
    try testing.expectEqualStrings(channel_id, fixture.open_channel_id.?);

    // A response without tool calls ends the activity; its channel outlives it.
    var closing = try kernel.sessions.snapshot(activity.work.session);
    defer closing.deinit();
    try testing.expect(try kernel.sessions.commitResponse(activity.work, &closing, SubscriptionFixture.empty_response));
    kernel.sessions.endWorker(activity.work.session);
    try testing.expect(!kernel.sessions.sessions.contains(activity_id));

    fixture.open_channel_id = null;
    const restarted = try fixture.kernel(&engine, &store);
    kernel.deinit();
    kernel = restarted;
    try testing.expectEqualStrings(channel_id, fixture.open_channel_id.?);
    const sample = try kernel.compactionSnapshot(a, kernel.sessions.core);
    try testing.expectEqualDeep(@as([]const Input.SampledChannel, &.{.{
        .channel_id = channel_id,
        .description = description,
    }}), sample.state.channel_registrations);

    var restarted_core: Kernel.RuntimeRound = .{ .kernel = &kernel, .work = try SubscriptionFixture.takeWork(&kernel, a) };
    defer restarted_core.deinit();
    var restarted_history = try SubscriptionFixture.admit(&kernel, a, restarted_core.work);
    defer restarted_history.deinit();
    const closed = try call(a, &restarted_core, "close_channel", .{ .channel_id = channel_id });
    try testing.expect(closed.object.get("result").?.object.get("changed").?.bool);
    try testing.expect(fixture.open_channel_id == null);
    try SubscriptionFixture.finish(&kernel, restarted_core.work, &restarted_history);

    const after_close = try fixture.kernel(&engine, &store);
    kernel.deinit();
    kernel = after_close;
    try testing.expect(fixture.open_channel_id == null);
}

test "restart selects a tool round, its tokens, channel and fork together after a failed save" {
    const testing = std.testing;
    const call = SubscriptionFixture.callTool;
    for ([_]TestStore.SaveFailure{ .before_commit, .after_commit }) |failure| {
        var fixture: SubscriptionFixture = .{ .usage_scope = @splat(1) };
        defer fixture.deinit();
        const a = fixture.storage.arena.allocator();
        var store = try Subscriptions.Store.openInMemory(a);
        defer store.close();
        var engine: Engine = undefined;
        var kernel = try fixture.kernel(&engine, &store);
        defer kernel.deinit();

        var previous_count: usize = undefined;
        var channel_id: []const u8 = undefined;
        var focus_id: []const u8 = undefined;
        {
            var core: Kernel.RuntimeRound = .{ .kernel = &kernel, .work = try SubscriptionFixture.takeWork(&kernel, a) };
            defer kernel.sessions.endWorker(core.work.session);
            defer core.deinit();
            var history = try SubscriptionFixture.admit(&kernel, a, core.work);
            defer history.deinit();
            previous_count = history.records().len;
            const opened = try call(a, &core, "open_channel", .{ .name = "imports", .description = "Accept CSV paths." });
            channel_id = opened.object.get("result").?.object.get("channel_id").?.string;
            const forked = try call(a, &core, "open_focus", .{ .name = "research", .task = "Collect findings." });
            focus_id = forked.object.get("result").?.object.get("focus_id").?.string;
            const channel_reply = try std.json.Stringify.valueAlloc(a, opened, .{});
            const focus_reply = try std.json.Stringify.valueAlloc(a, forked, .{});
            try history.appendBatch(&.{.{ .continuation = "Call open_channel and open_focus" }}, &.{
                .{ .tool_result = .{ .call_id = "open-channel", .content = try Content.fromText(a, channel_reply) } },
                .{ .tool_result = .{ .call_id = "open-focus", .content = try Content.fromText(a, focus_reply) } },
            });

            fixture.storage.fail_save = failure;
            try testing.expectError(error.MailMutationUnconfirmed, core.commit(&history, 123));
            try testing.expect(fixture.open_channel_id == null);

            const saves = fixture.storage.saves;
            fixture.storage.fail_save = .none;
            try testing.expectError(error.MailMutationUnconfirmed, kernel.sessions.sendFocusMessage(core.work, "core-1", "A later message."));
            try testing.expectError(error.MailMutationUnconfirmed, kernel.sessions.maintain());
            try testing.expectEqual(saves, fixture.storage.saves);
        }

        const restarted = try fixture.kernel(&engine, &store);
        kernel.deinit();
        kernel = restarted;
        var retained = try kernel.sessions.snapshot(kernel.sessions.core);
        defer retained.deinit();
        const records = retained.records();
        const sample = try kernel.compactionSnapshot(a, kernel.sessions.core);
        if (failure == .after_commit) {
            try testing.expectEqual(@as(?u64, 123), kernel.sessions.core.progress.last_input_tokens);
            try testing.expectEqualStrings(channel_id, fixture.open_channel_id.?);
            try testing.expectEqualDeep(@as([]const []const u8, &.{focus_id}), sample.state.activities);
            try testing.expectEqual(previous_count + 1, records.len);
            const exchange = records[records.len - 1].exchange;
            const channel_reply = try std.json.parseFromSliceLeaky(std.json.Value, a, exchange[1].tool_result.content.parts[0].text, .{});
            const focus_reply = try std.json.parseFromSliceLeaky(std.json.Value, a, exchange[2].tool_result.content.parts[0].text, .{});
            try testing.expectEqualStrings(channel_id, channel_reply.object.get("result").?.object.get("channel_id").?.string);
            try testing.expectEqualStrings(focus_id, focus_reply.object.get("result").?.object.get("focus_id").?.string);
        } else {
            try testing.expectEqual(null, kernel.sessions.core.progress.last_input_tokens);
            try testing.expect(fixture.open_channel_id == null);
            try testing.expectEqual(0, sample.state.activities.len);
            try testing.expectEqual(previous_count, records.len);
        }
    }
}
