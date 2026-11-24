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
const Feeds = InstanceState.feeds;
const Subscriptions = InstanceState.subscriptions;
const Communication = contracts.Communication;
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
    feeds: *Feeds.Store,
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
        feeds: *Feeds.Store,
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
        return .{
            .allocator = allocator,
            .io = io,
            .engine = dependencies.engine,
            .inbox = dependencies.inbox,
            .sender = dependencies.sender,
            .feeds = dependencies.feeds,
            .callbacks = dependencies.callbacks,
            .limits = config.limits,
            .poll_interval_ms = config.poll_interval_ms,
            .sessions = try Sessions.Registry.init(allocator, io, config.max_sessions, config.max_pending_events, dependencies.history, dependencies.subscriptions),
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
        defer self.sessions.endWorker(work.session);
        var diagnostics: std.heap.ArenaAllocator = .init(self.allocator);
        defer diagnostics.deinit();
        const interrupted = self.respond(work, diagnostics.allocator()) catch |err| {
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
                .send => |message| self.send(a, message.to, message.text),
                .create_feed => |args| blk: {
                    const id = self.kernel.feeds.create(a, self.work.session.focus_id, args.name, args.description) catch |err| return feedFailure(a, err);
                    break :blk try runtimeResult(a, .{ .feed_id = id });
                },
                .close_feed => |args| blk: {
                    const changed = self.kernel.feeds.closeFeed(args.feed_id) catch |err| return feedFailure(a, err);
                    break :blk try runtimeResult(a, .{ .feed_id = args.feed_id, .changed = changed });
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
                    try self.forks.ensureUnusedCapacity(self.kernel.allocator, 1);
                    const plan = self.kernel.sessions.prepareFork(self.work, args.name, args.task) catch |err| switch (err) {
                        error.SessionCapacityUnavailable => return try runtimeError(a, "focus_unavailable", "The focus limit has been reached."),
                        else => return err,
                    };
                    self.forks.appendAssumeCapacity(plan);
                    break :blk try runtimeResult(a, .{ .focus_id = plan.session.focus_id });
                },
            };
        }

        fn send(self: *RuntimeRound, a: Allocator, to: AgentTools.Destination, text: []const u8) !Content {
            return switch (to) {
                .correspondent_id => |id| switch (try self.kernel.sender.send(a, .{ .recipient = id, .text = text })) {
                    .submitted => |submission| try runtimeResult(a, .{ .correspondent_id = id, .reference = submission.reference }),
                    .invalid_recipient => try runtimeError(a, "invalid_recipient", "That correspondent is not registered to receive messages."),
                    .not_submitted => try runtimeError(a, "not_submitted", "Sending stopped before the submission attempt."),
                    .submission_unknown => try runtimeError(a, "submission_unknown", "The service may already have accepted this message. Sending it again could create a duplicate."),
                },
                .feed_id => |id| blk: {
                    const now = std.Io.Clock.real.now(self.kernel.io).toMilliseconds();
                    const sequence = self.kernel.feeds.publish(id, self.work.session.focus_id, text, now) catch |err| return feedFailure(a, err);
                    break :blk try runtimeResult(a, .{ .feed_id = id, .sequence = sequence });
                },
                .focus_id => |id| blk: {
                    self.kernel.sessions.sendFocusMessage(self.work, id, text) catch |err| return switch (err) {
                        error.UnknownSession => runtimeError(a, "unknown_focus", "That focus is unavailable."),
                        error.SessionQueueFull => runtimeError(a, "focus_queue_full", "The receiving focus's queue is full."),
                        else => err,
                    };
                    break :blk try runtimeResult(a, .{ .focus_id = id });
                },
            };
        }
    };

    fn respond(self: *Kernel, work: Work, diagnostics: Allocator) !?[]const u8 {
        const session = work.session;
        var soft_compaction = true;
        while (true) {
            try self.io.checkCancel();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            if (work.activation.deliveries.items.len == 0) try self.sessions.collectPending(work);
            var history = try self.sessions.snapshot(session);
            defer history.deinit();
            const input = switch (try self.prepareRequest(a, work, &history, &soft_compaction)) {
                .ready => |input| input,
                .interrupted => |reason| return try diagnostics.dupe(u8, reason),
            };
            var round = switch (try self.engine.beginRound(a, session.focus_id, input, session.role)) {
                .ready => |round| round,
                .interrupted => |reason| return try diagnostics.dupe(u8, reason),
            };
            defer round.inference.deinit();
            const response = round.inference.response;
            if (response.calls.len == 0) {
                if (response.output.len == 0 and !work.activation.admitted)
                    return "The model returned no output for the pending tool exchange. The waiting observations did not fit in that request and remain queued.";
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
            try self.sessions.commitToolRound(work, &history, &runtime.forks, response.input_tokens);
        }
    }

    const Selection = union(enum) { count: usize, over_limit: Model.Limit };
    const Prepared = struct { items: []const Model.Item, events: []const Input.Event, count: usize };
    const Fit = union(enum) { ready: Prepared, over_limit: Model.Limit };
    const CompactionTrigger = union(enum) { threshold: Prepared, limit };
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
    fn prepareRequest(self: *Kernel, a: Allocator, work: Work, history: *Context, soft_compaction: *bool) !FocusResult([]const Model.Item) {
        const current = try self.sessions.current(a, work.session);
        const keep_pending: Context.CompactionScope = .keep_latest_tool_round;
        const fit = try self.fitRequest(a, work, history, current, !history.hasHistoryForCompaction(keep_pending));
        switch (fit) {
            .ready => |prepared| {
                if (soft_compaction.* and history.canCompact(keep_pending) and try self.reachedCompactionThreshold(history, current, work.session.last_input_tokens)) {
                    const scope = try self.softCompactionScope(a, history, current.role);
                    switch (try self.compactRequest(a, work, history, current, scope, .{ .threshold = prepared })) {
                        .ready => |input| return .{ .ready = input },
                        .interrupted => |reason| {
                            std.log.warn("soft compaction skipped for {s}. {s}", .{ work.session.focus_id, reason });
                            soft_compaction.* = false;
                        },
                    }
                }
                return .{ .ready = try self.admit(a, work, history, prepared, false) };
            },
            .over_limit => |limit| {
                const has_pending = history.hasToolRoundToKeep();
                const scope: Context.CompactionScope = if (has_pending) blk: {
                    var scratch: std.heap.ArenaAllocator = .init(self.allocator);
                    defer scratch.deinit();
                    const trial = scratch.allocator();
                    const latest = try history.latestRequest(trial, current);
                    break :blk if ((try self.engine.measure(trial, latest, current.role)).violation == null) keep_pending else .all_history;
                } else keep_pending;
                if (!history.hasHistoryForCompaction(scope))
                    return .{ .interrupted = try Engine.describeRequestLimit(a, "The next request", limit) };
                const compacted = try self.compactRequest(a, work, history, current, scope, .limit);
                if (compacted == .interrupted and scope == keep_pending and has_pending) {
                    // The hard limit may only apply when the waiting observation
                    // and tool round are combined. Try the continuation on its own.
                    const continued = try self.fitSelected(a, history, current, &.{}, 0);
                    if (continued == .ready) return .{ .ready = try self.admit(a, work, history, continued.ready, false) };
                }
                return compacted;
            },
        }
    }

    fn reachedCompactionThreshold(self: *Kernel, history: *const Context, current: Input.Current, last_input_tokens: ?u64) !bool {
        if (last_input_tokens) |tokens| return tokens >= self.limits.compact_at_tokens;
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const retained = try history.retainedRequest(a, current, &.{});
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
        const measured = try self.engine.model.measure(a, .{ .history = additional, .tools = &.{}, .reasoning_effort = .none });
        return if (measured.bytes <= core_extra_history_bytes) .keep_recent_rounds else .keep_latest_tool_round;
    }

    fn compactionSnapshot(self: *Kernel, a: Allocator, session: *Sessions.Session) !Input.Snapshot {
        const is_core = session.role == .core;
        // Read feeds before the live IDs so a newly opened creator cannot be
        // missing from the registry sample for a feed already present here.
        const open_feeds = try self.feeds.openFeeds(a, if (is_core) null else session.focus_id);
        var snapshot = try self.sessions.compactionSnapshot(a, session);
        if (is_core) snapshot.state.correspondents = self.sender.registered_correspondents;

        var live_activities: std.StringHashMapUnmanaged(void) = .empty;
        defer live_activities.deinit(a);
        for (snapshot.state.activities) |id| try live_activities.put(a, id, {});

        var references: std.ArrayList([]const u8) = .empty;
        errdefer references.deinit(a);
        for (open_feeds) |feed| {
            if (live_activities.contains(feed.creator_focus_id)) continue;
            try references.append(a, feed.feed_id);
        }
        snapshot.state.feeds = try references.toOwnedSlice(a);
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
                        .limit => try self.fitRequest(a, work, &candidate, current, true),
                    };
                    switch (fit) {
                        .ready => |prepared| {
                            const items = try self.admit(a, work, &candidate, prepared, true);
                            std.mem.swap(Context, history, &candidate);
                            return .{ .ready = items };
                        },
                        .over_limit => |limit| rejection = .{ .too_large = limit },
                    }
                },
            }
        }
        return .{ .interrupted = try rejection.?.description(a) };
    }

    fn fitRequest(self: *Kernel, a: Allocator, work: Work, history: *const Context, current: Input.Current, may_defer: bool) !Fit {
        var events: std.ArrayList(Input.Event) = .empty;
        defer events.deinit(a);
        var count: usize = 0;
        if (work.activation.deliveries.items.len != 0) {
            switch (try self.selectEvents(a, work, history, current, &events)) {
                .count => |selected| count = selected,
                .over_limit => |limit| {
                    if (!may_defer or !history.hasToolRoundToKeep()) return .{ .over_limit = limit };
                },
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

fn feedFailure(a: Allocator, err: anyerror) !Content {
    return switch (err) {
        error.InvalidArguments => error.InvalidToolArguments,
        error.UnknownFeed => runtimeError(a, "unknown_feed", "No feed matches the supplied ID."),
        error.FeedClosed => runtimeError(a, "feed_closed", "This feed is closed to new messages."),
        error.StateStoreBusy => runtimeError(a, "feed_storage_busy", "Feed storage is busy."),
        error.StateStoreFull => runtimeError(a, "feed_storage_full", "Feed storage is full."),
        else => err,
    };
}

const TestStore = @import("test_history.zig").TestStore;

const SubscriptionFixture = struct {
    const testing = std.testing;
    const empty_response: Model.Response = .{ .output = &.{}, .calls = &.{}, .text = null };
    storage: TestStore = .{},
    feed_store: ?Feeds.Store = null,

    fn deinit(self: *SubscriptionFixture) void {
        if (self.feed_store) |*store| store.close();
        self.storage.arena.deinit();
    }

    fn kernel(self: *SubscriptionFixture, engine: *Engine, subscriptions: *Subscriptions.Store) !Kernel {
        if (self.feed_store == null) self.feed_store = try Feeds.Store.openInMemory(testing.allocator, testing.io);
        engine.* = .{
            .allocator = testing.allocator,
            .io = testing.io,
            .model = .{ .context = self, .vtable = &.{ .measure = measure, .next = undefined, .prepareToolReplies = undefined } },
            .shared_tools = &.{},
            .activity_tools = &.{},
        };
        return Kernel.init(testing.allocator, testing.io, .{
            .engine = engine,
            .subscriptions = subscriptions,
            .inbox = undefined,
            .sender = .{ .context = undefined, .submit = undefined },
            .feeds = &self.feed_store.?,
            .callbacks = undefined,
            .history = self.storage.port(),
        }, .{ .limits = .{}, .poll_interval_ms = 1, .max_sessions = 3, .max_pending_events = 3 });
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
        var soft_compaction = true;
        try testing.expect((try instance.prepareRequest(a, work, &history, &soft_compaction)) == .ready);
        return history;
    }

    /// Leave a subscribed activity sleeping while the core continues its round.
    fn watchingActivity(instance: *Kernel, a: Allocator, core: Work, history: *Context, name: []const u8) ![]const u8 {
        var plans: std.ArrayList(Sessions.ForkPlan) = .empty;
        try plans.append(a, try instance.sessions.prepareFork(core, name, "Watch for updates."));
        try instance.sessions.commitToolRound(core, history, &plans, null);
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

    fn callTool(a: Allocator, round: *Kernel.RuntimeRound, name: []const u8, args: anytype) !std.json.Value {
        const arguments = try std.json.Stringify.valueAlloc(a, args, .{});
        const request = (try AgentTools.Request.parse(a, round.work.session.role, name, arguments)).?;
        const reply = try Kernel.RuntimeRound.invoke(round, a, request);
        return std.json.parseFromSliceLeaky(std.json.Value, a, reply.parts[0].text, .{});
    }
};

test "ordinary turns omit directories and send resolves known IDs by destination kind" {
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
    kernel.sender.registered_correspondents = &.{"reviewer+notes"};
    var core: Kernel.RuntimeRound = .{ .kernel = &kernel, .work = try SubscriptionFixture.takeWork(&kernel, a) };
    defer core.deinit();
    defer kernel.sessions.endWorker(core.work.session);
    var history = try SubscriptionFixture.admit(&kernel, a, core.work);
    defer history.deinit();

    const opened = try call(a, &core, "open_focus", .{ .name = "research", .task = "Collect findings." });
    const sender_id = opened.object.get("result").?.object.get("focus_id").?.string;
    try kernel.sessions.commitToolRound(core.work, &history, &core.forks, null);
    var activity: Kernel.RuntimeRound = .{ .kernel = &kernel, .work = try SubscriptionFixture.takeWork(&kernel, a) };
    defer kernel.sessions.endWorker(activity.work.session);

    const created = try call(a, &activity, "create_feed", .{
        .name = "core",
        .description = "Keep release findings for readers.",
    });
    const feed_id = created.object.get("result").?.object.get("feed_id").?.string;
    try testing.expectEqualStrings(core.work.session.focus_id, feed_id);

    var activity_history = try kernel.sessions.snapshot(activity.work.session);
    defer activity_history.deinit();
    var soft_compaction = true;
    for ([_][]const Model.Item{
        (try kernel.prepareRequest(a, core.work, &history, &soft_compaction)).ready,
        (try kernel.prepareRequest(a, activity.work, &activity_history, &soft_compaction)).ready,
    }) |input| {
        const turn = input[input.len - 1].message.text;
        for ([_][]const u8{ "focuses", "correspondents", "feeds", "reviewer+notes", "Keep release findings for readers." }) |marker| {
            try testing.expect(std.mem.indexOf(u8, turn, marker) == null);
        }
    }

    const result = try call(a, &activity, "send", .{
        .to = .{ .focus_id = core.work.session.focus_id },
        .text = "Findings are ready.",
    });
    try testing.expectEqualStrings(feed_id, result.object.get("result").?.object.get("focus_id").?.string);
    const publication = try call(a, &core, "send", .{
        .to = .{ .feed_id = feed_id },
        .text = "A separate publication.",
    });
    const published = publication.object.get("result").?.object;
    try testing.expectEqualStrings(feed_id, published.get("feed_id").?.string);
    try testing.expectEqual(1, published.get("sequence").?.integer);
    try kernel.sessions.collectPending(core.work);
    const deliveries = core.work.activation.deliveries.items;
    try testing.expectEqual(1, deliveries.len);
    const message = deliveries[0].event.focus_message;
    try testing.expectEqualStrings(sender_id, message.from_focus);
    try testing.expectEqualStrings("Findings are ready.", message.text);

    _ = try call(a, &core, "close_feed", .{ .feed_id = feed_id });
    const closed = try call(a, &activity, "send", .{ .to = .{ .feed_id = feed_id }, .text = "Another publication." });
    try testing.expectEqualStrings("feed_closed", closed.object.get("error").?.object.get("code").?.string);
}

test "core compaction picks up open feeds when their creating activities end" {
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
    kernel.sender.registered_correspondents = &.{"operator"};

    var core: Kernel.RuntimeRound = .{ .kernel = &kernel, .work = try SubscriptionFixture.takeWork(&kernel, a) };
    defer core.deinit();
    defer kernel.sessions.endWorker(core.work.session);
    var history = try SubscriptionFixture.admit(&kernel, a, core.work);
    defer history.deinit();
    const core_feed = try kernel.feeds.create(a, core.work.session.focus_id, "core-news", "Core notes");
    _ = try call(a, &core, "open_focus", .{ .name = "first", .task = "Follow the first release." });
    const opened = try call(a, &core, "open_focus", .{ .name = "second", .task = "Follow the second release." });
    const second_id = opened.object.get("result").?.object.get("focus_id").?.string;
    try testing.expectEqual(0, (try kernel.compactionSnapshot(a, core.work.session)).state.activities.len);
    try kernel.sessions.commitToolRound(core.work, &history, &core.forks, null);

    const ready = try kernel.sessions.takeReadyBatch(a);
    try testing.expectEqual(2, ready.len);
    var activity: Kernel.RuntimeRound = .{ .kernel = &kernel, .work = ready[0] };
    var activity_history = try SubscriptionFixture.admit(&kernel, a, activity.work);
    defer activity_history.deinit();
    const created = try call(a, &activity, "create_feed", .{ .name = "first-news", .description = "First release notes" });
    const own_feed = created.object.get("result").?.object.get("feed_id").?.string;
    _ = try kernel.feeds.publish(core_feed, activity.work.session.focus_id, "A shared update", 100);
    const closed_feed = try kernel.feeds.create(a, activity.work.session.focus_id, "old-news", "Previous release notes");
    try testing.expect(try kernel.feeds.closeFeed(closed_feed));
    _ = try kernel.sessions.subscribe(a, activity.work, "releases", "Watch upcoming releases");
    try SubscriptionFixture.finish(&kernel, activity.work, &activity_history);

    const second = ready[1];
    var second_history = try SubscriptionFixture.admit(&kernel, a, second);
    defer second_history.deinit();
    const surviving_feed = try kernel.feeds.create(a, second.session.focus_id, "second-news", "Second release notes");
    const before_ending = (try kernel.compactionSnapshot(a, core.work.session)).state;
    try testing.expectEqualDeep(@as([]const []const u8, &.{core_feed}), before_ending.feeds);
    try SubscriptionFixture.finish(&kernel, second, &second_history);
    try testing.expectEqualDeep(@as([]const []const u8, &.{ activity.work.session.focus_id, second_id }), before_ending.activities);

    const core_state = (try kernel.compactionSnapshot(a, core.work.session)).state;
    try testing.expectEqualDeep(@as([]const []const u8, &.{ core_feed, surviving_feed }), core_state.feeds);
    try testing.expectEqualDeep(kernel.sender.registered_correspondents, core_state.correspondents);
    try testing.expectEqualDeep(@as([]const []const u8, &.{activity.work.session.focus_id}), core_state.activities);

    const activity_state = (try kernel.compactionSnapshot(a, activity.work.session)).state;
    try testing.expectEqualDeep(@as([]const []const u8, &.{own_feed}), activity_state.feeds);
    try testing.expectEqual(0, activity_state.correspondents.len);
    try testing.expectEqual(0, activity_state.activities.len);
}

test "an activity can use the reference returned by subscribe to withdraw another focus's registration" {
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
    const core_id = created.object.get("subscription_id").?.string;
    _ = try call(a, &core, "open_focus", .{ .name = "research", .task = "Watch for releases." });
    try kernel.sessions.commitToolRound(core.work, &core_history, &core.forks, null);

    var activity: Kernel.RuntimeRound = .{ .kernel = &kernel, .work = try SubscriptionFixture.takeWork(&kernel, a) };
    defer activity.deinit();
    const closed = (try call(a, &activity, "withdraw_subscription", .{ .subscription_id = core_id })).object.get("result").?.object;
    try testing.expectEqualStrings(core_id, closed.get("subscription_id").?.string);
    try testing.expect(closed.get("changed").?.bool);

    const repeated = (try call(a, &activity, "withdraw_subscription", .{ .subscription_id = core_id })).object.get("result").?.object;
    try testing.expect(!repeated.get("changed").?.bool);
}

test "startup requires the subscription catalog and working history to belong together" {
    const testing = std.testing;
    const Store = Subscriptions.Store;
    var fixture: SubscriptionFixture = .{};
    defer fixture.deinit();
    var catalog = try Store.openInMemory(testing.allocator);
    defer catalog.close();
    var engine: Engine = undefined;
    var initial = try fixture.kernel(&engine, &catalog);
    initial.deinit();

    var other = try Store.openInMemory(testing.allocator);
    defer other.close();
    try testing.expectError(error.SubscriptionCatalogMismatch, fixture.kernel(&engine, &other));
    fixture.storage.checkpoint = null;
    try testing.expectError(error.SubscriptionCatalogMismatch, fixture.kernel(&engine, &catalog));
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
            try testing.expectError(error.UnconfirmedCheckpoint, SubscriptionFixture.admit(&kernel, a, core));
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
                .rejection => .{ .rejected = .{ .request_rejected = .{ .status = 400 } } },
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
        .{ .ceiling = 15, .summary = .rejection, .compacted = false, .delivered = false },
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
        work.session.last_input_tokens = case.observed_tokens;

        var model: BudgetModel = .{ .hard_limit = case.ceiling, .summary = case.summary };
        engine.model = .{ .context = &model, .vtable = &.{ .next = BudgetModel.next, .measure = BudgetModel.measure, .prepareToolReplies = undefined } };
        kernel.limits.compact_at_bytes = case.compact_at_bytes;
        kernel.limits.compact_at_tokens = 8;
        var soft_compaction = true;
        const input = (try kernel.prepareRequest(a, work, &history, &soft_compaction)).ready;
        try testing.expectEqual(case.summaries, model.summaries);
        try testing.expectEqual(!case.kept_image, model.summary_saw_omission);
        if (case.ceiling == 40) try testing.expectEqual(case.summary == .success, soft_compaction);
        const turn = input[input.len - 1].message.text;
        try testing.expectEqual(case.delivered, std.mem.indexOf(u8, turn, "large observation marker") != null);
        if (case.kept_image) {
            try testing.expectEqualDeep(exchange[0], input[input.len - 3]);
            try testing.expectEqualDeep(exchange[1], input[input.len - 2]);
        } else {
            try testing.expectEqual(@as(usize, 3), input.len);
        }
        try testing.expectEqual(@as(u64, @intFromBool(case.compacted)), history.scope.epoch);
        if (!case.delivered) try testing.expect(!work.activation.admitted);
    }
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
            .state = .{ .activities = &.{}, .callbacks = &.{}, .subscriptions = &.{} },
        }, scope);
        defer replacement.deinit();
        const carried = replacement.records()[1..];
        try testing.expectEqualDeep(pending, carried[carried.len - 1].exchange);
        const first_response = carried[0].exchange[0].continuation;
        try testing.expectEqualStrings(if (completed_has_pdf) "Pending call" else "Recent response", first_response);
    }
}
