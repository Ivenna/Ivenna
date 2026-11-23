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
    callbacks: contracts.Callback.Publisher,
    limits: Limits,
    poll_interval_ms: u32,
    sessions: Sessions.Registry,
    reception: std.atomic.Value(enum(u8) { starting, open, closed }) = .init(.starting),

    pub const Limits = struct {
        request_bytes: u64 = 1024 * 1024,
        compaction_bytes: u64 = 2 * 1024 * 1024,
    };

    pub const Dependencies = struct {
        engine: *Engine,
        inbox: contracts.Inbox,
        sender: Communication.Sender,
        callbacks: contracts.Callback.Publisher,
        history: contracts.HistoryStore,
        subscriptions: *@import("subscriptions").Store,
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
                    .invalid_recipient => try runtimeError(a, "invalid_recipient", "At least one recipient ID is unsupported. No message was submitted."),
                    .not_submitted => try runtimeError(a, "not_submitted", "Preparation stopped before any attempt to submit this message."),
                    .submission_unknown => try runtimeError(a, "submission_unknown", "The service may already have accepted this message. Sending it again could create a duplicate."),
                },
                .send_focus_message => |message| blk: {
                    self.kernel.sessions.sendFocusMessage(self.work, message.focus_id, message.text) catch |err| return try toolFailure(a, err);
                    break :blk try runtimeResult(a, .{ .focus_id = message.focus_id });
                },
                .schedule_attention => |args| blk: {
                    const id = self.kernel.sessions.scheduleWakeup(a, self.work, args.name, args.at.unix_ms, args.text) catch |err| return try toolFailure(a, err);
                    break :blk try runtimeResult(a, .{ .callback_id = id });
                },
                .subscribe => |args| blk: {
                    const subscription = self.kernel.sessions.subscribe(a, self.work, args.name, args.listener) catch |err| return toolFailure(a, err);
                    break :blk try runtimeResult(a, subscription);
                },
                .withdraw_subscription => |args| blk: {
                    const changed = try self.kernel.sessions.withdrawSubscription(self.work, args.subscription_id);
                    break :blk try runtimeResult(a, .{ .subscription_id = args.subscription_id, .changed = changed });
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
                if (try self.sessions.commitResponse(work, &history, response.output, response.text)) return null;
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
            }, self.limits.request_bytes);
            try history.appendBatch(response.output, replies);
            try self.sessions.commitToolRound(work, &history, &runtime.forks);
        }
    }

    const Selection = struct { count: usize, events: []const Input.Event };
    const max_summary_attempts = 2;

    /// Fill one ordinary input across I/O pages, measuring grouped activity
    /// reports. The retained selection still identifies a raw delivery prefix.
    fn selectEvents(self: *Kernel, a: Allocator, work: Work, history: *const Context, current: Input.Current) !?Selection {
        var count: usize = 0;
        var events: std.ArrayList(Input.Event) = .empty;
        defer events.deinit(a);
        var trial_arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer trial_arena.deinit();
        while (true) {
            for (work.activation.deliveries.items[events.items.len..]) |delivery| try events.append(a, delivery.event);
            if (try self.eventsFit(&trial_arena, work.session.role, history, current, events.items, events.items.len)) {
                count = events.items.len;
                if (!try self.sessions.extendReports(work)) break;
                continue;
            }
            // The previous page's prefix already fit this snapshot.
            for (count + 1..events.items.len) |end| {
                if (try self.eventsFit(&trial_arena, work.session.role, history, current, events.items, end)) count = end;
            }
            break;
        }
        if (count == 0) return null;
        const grouped = try Input.coalesceActivityReports(a, events.items[0..count]);
        return .{ .count = count, .events = grouped };
    }

    fn eventsFit(self: *Kernel, scratch: *std.heap.ArenaAllocator, role: Input.Role, history: *const Context, current: Input.Current, events: []const Input.Event, count: usize) !bool {
        const trial = scratch.allocator();
        defer _ = scratch.reset(.retain_capacity);
        const grouped = try Input.coalesceActivityReports(trial, events[0..count]);
        const input = try history.request(trial, current, grouped);
        return try self.engine.requestBytes(trial, input, role) <= self.limits.request_bytes;
    }

    /// Fit continuation and admission against the same snapshot. A rejected
    /// handover changes neither the selected history nor any inbox receipt.
    fn prepareRequest(self: *Kernel, a: Allocator, work: Work, history: *Context) !FocusResult([]const Model.Item) {
        if (try self.fitRequest(a, work, history, false)) |input| return .{ .ready = input };
        if (history.records().len == 0)
            return .{ .interrupted = "The next request exceeds the context budget even with no retained history." };

        var rejection: ?Compaction.Rejection = null;
        for (0..max_summary_attempts) |_| {
            const state = try self.sessions.compactionSnapshot(a, work.session);
            switch (try Compaction.summarize(self.engine, a, history, state, self.limits.compaction_bytes, rejection)) {
                .interrupted => |reason| return .{ .interrupted = reason },
                .rejected => |reason| rejection = reason,
                .handover => |handover| {
                    var candidate = try history.withHandover(self.allocator, handover);
                    errdefer candidate.deinit();
                    if (try self.fitRequest(a, work, &candidate, true)) |input| {
                        history.deinit();
                        history.* = candidate;
                        return .{ .ready = input };
                    }
                    candidate.deinit();
                    rejection = .too_large;
                },
            }
        }
        return .{ .interrupted = rejection.?.description() };
    }

    /// The returned input borrows history. Render selected events in the current
    /// turn before appending them to history so this request presents them once.
    fn fitRequest(self: *Kernel, a: Allocator, work: Work, history: *Context, compacted: bool) !?[]const Model.Item {
        const current = try self.sessions.current(a, work.session);
        const selection = if (work.activation.deliveries.items.len != 0)
            try self.selectEvents(a, work, history, current) orelse return null
        else
            null;
        const input = try history.request(a, current, if (selection) |selected| selected.events else &.{});
        if (selection == null) {
            if (try self.engine.requestBytes(a, input, work.session.role) > self.limits.request_bytes) return null;
            if (!compacted) return input;
        }
        if (selection) |selected| {
            try history.appendRecord(.{ .events = .{ .focus_id = work.session.focus_id, .items = selected.events } });
        }
        try self.sessions.commitInput(work, if (selection) |selected| selected.count else 0, history);
        if (selection != null) {
            for (work.activation.deliveries.items) |delivery| {
                const receipt = delivery.receipt orelse continue;
                try self.inbox.acknowledge(a, receipt);
                try self.sessions.acknowledged(receipt);
                delivery.receipt = null;
            }
            self.sessions.releaseDeliveries(work);
        }
        return input;
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
        error.InvalidArguments => error.InvalidToolArguments,
        error.UnknownSession => runtimeError(a, "unknown_focus", "The focus is not addressable."),
        error.SessionQueueFull => runtimeError(a, "focus_queue_full", "The focus cannot currently accept another observation."),
        else => err,
    };
}

const TestStore = @import("test_history.zig").TestStore;

const SubscriptionFixture = struct {
    const testing = std.testing;
    storage: TestStore = .{},

    fn kernel(self: *SubscriptionFixture, engine: *Engine, subscriptions: *@import("subscriptions").Store) !Kernel {
        engine.* = .{
            .allocator = testing.allocator,
            .io = testing.io,
            .model = .{ .context = self, .vtable = &.{ .requestBytes = requestBytes, .next = undefined, .limitToolReplies = undefined } },
            .shared_tools = &.{},
            .activity_tools = &.{},
        };
        return Kernel.init(testing.allocator, testing.io, .{
            .engine = engine,
            .subscriptions = subscriptions,
            .inbox = undefined,
            .sender = undefined,
            .callbacks = undefined,
            .history = self.storage.port(),
        }, .{ .limits = .{}, .poll_interval_ms = 1, .max_sessions = 3, .max_pending_events = 3 });
    }

    fn requestBytes(_: *anyopaque, _: Allocator, request: Model.Request) anyerror!u64 {
        return std.mem.count(u8, request.history[request.history.len - 1].message.text, "budget-marker");
    }

    fn takeWork(instance: *Kernel, a: Allocator) !Work {
        const ready = try instance.sessions.takeReadyBatch(a);
        try testing.expectEqual(1, ready.len);
        return ready[0];
    }

    fn admit(instance: *Kernel, a: Allocator, work: Work) !Context {
        var history = try instance.sessions.snapshot(work.session);
        errdefer history.deinit();
        try testing.expect(try instance.fitRequest(a, work, &history, false) != null);
        return history;
    }

    /// Leave a subscribed activity sleeping while the core continues its round.
    fn watchingActivity(instance: *Kernel, a: Allocator, core: Work, history: *Context, name: []const u8) ![]const u8 {
        var plans: std.ArrayList(Sessions.ForkPlan) = .empty;
        try plans.append(a, try instance.sessions.prepareFork(core, name, "Watch for updates."));
        try instance.sessions.commitToolRound(core, history, &plans);
        const work = try takeWork(instance, a);
        var activity = try admit(instance, a, work);
        defer activity.deinit();
        const sub = try instance.sessions.subscribe(a, work, "updates", "Source listener");
        try finish(instance, work, &activity);
        return sub.subscription_id;
    }

    fn finish(instance: *Kernel, work: Work, history: *Context) !void {
        defer instance.sessions.endWorker(work.session);
        try testing.expect(try instance.sessions.commitResponse(work, history, &.{}, null));
    }
};

test "an activity can use the reference returned by subscribe to withdraw another focus's registration" {
    const testing = std.testing;
    const Tool = struct {
        fn call(a: Allocator, round: *Kernel.RuntimeRound, name: []const u8, args: anytype) !std.json.Value {
            const arguments = try std.json.Stringify.valueAlloc(a, args, .{});
            const request = (try AgentTools.Request.parse(a, round.work.session.role, name, arguments)).?;
            const reply = try Kernel.RuntimeRound.invoke(round, a, request);
            return std.json.parseFromSliceLeaky(std.json.Value, a, reply.parts[0].text, .{});
        }
    };
    var fixture: SubscriptionFixture = .{};
    defer fixture.storage.arena.deinit();
    const a = fixture.storage.arena.allocator();
    var store = try @import("subscriptions").Store.open(a, ":memory:");
    defer store.close();
    var engine: Engine = undefined;
    var kernel = try fixture.kernel(&engine, &store);
    defer kernel.deinit();
    var core: Kernel.RuntimeRound = .{ .kernel = &kernel, .work = try SubscriptionFixture.takeWork(&kernel, a) };
    defer core.deinit();
    var core_history = try SubscriptionFixture.admit(&kernel, a, core.work);
    defer core_history.deinit();
    const created = (try Tool.call(a, &core, "subscribe", .{ .name = "releases", .listener = "release feed" })).object.get("result").?;
    const core_id = created.object.get("subscription_id").?.string;
    _ = try Tool.call(a, &core, "open_focus", .{ .name = "research", .task = "Watch for releases." });
    try kernel.sessions.commitToolRound(core.work, &core_history, &core.forks);

    var activity: Kernel.RuntimeRound = .{ .kernel = &kernel, .work = try SubscriptionFixture.takeWork(&kernel, a) };
    defer activity.deinit();
    const closed = (try Tool.call(a, &activity, "withdraw_subscription", .{ .subscription_id = core_id })).object.get("result").?.object;
    try testing.expectEqualStrings(core_id, closed.get("subscription_id").?.string);
    try testing.expect(closed.get("changed").?.bool);

    const repeated = (try Tool.call(a, &activity, "withdraw_subscription", .{ .subscription_id = core_id })).object.get("result").?.object;
    try testing.expect(!repeated.get("changed").?.bool);
}

test "startup requires the subscription catalog and working history to belong together" {
    const testing = std.testing;
    const Store = @import("subscriptions").Store;
    var fixture: SubscriptionFixture = .{};
    defer fixture.storage.arena.deinit();
    var catalog = try Store.open(testing.allocator, ":memory:");
    defer catalog.close();
    var engine: Engine = undefined;
    var initial = try fixture.kernel(&engine, &catalog);
    initial.deinit();

    var other = try Store.open(testing.allocator, ":memory:");
    defer other.close();
    try testing.expectError(error.SubscriptionCatalogMismatch, fixture.kernel(&engine, &other));
    fixture.storage.checkpoint = null;
    try testing.expectError(error.SubscriptionCatalogMismatch, fixture.kernel(&engine, &catalog));
}

test "subscription admission and database acknowledgement survive either outcome of an unconfirmed checkpoint" {
    const testing = std.testing;
    const Subs = @import("subscriptions");
    for ([_]TestStore.SaveFailure{ .before_commit, .after_commit }) |failure| {
        var fixture: SubscriptionFixture = .{};
        defer fixture.storage.arena.deinit();
        const a = fixture.storage.arena.allocator();
        var store = try Subs.Store.open(a, ":memory:");
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
            try testing.expect(!try kernel.sessions.commitResponse(core, &history, &.{}, null));
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
        defer fixture.storage.arena.deinit();
        const a = fixture.storage.arena.allocator();
        var store = try @import("subscriptions").Store.open(a, ":memory:");
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
    defer fixture.storage.arena.deinit();
    const a = fixture.storage.arena.allocator();
    var store = try @import("subscriptions").Store.open(a, ":memory:");
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
    try testing.expect(!try kernel.sessions.commitResponse(activity, &received, &.{}, null));
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
    defer fixture.storage.arena.deinit();
    const a = fixture.storage.arena.allocator();
    var store = try @import("subscriptions").Store.open(a, ":memory:");
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
    kernel.limits.request_bytes = 1;
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
        try testing.expect(!try kernel.sessions.commitResponse(resumed, &admitted, &.{}, null));
    }
    try testing.expect(served.contains(.callback) and served.contains(.subscription) and served.contains(.activity));
    try testing.expectEqual(.duplicate, try kernel.sessions.accept(callback));
}

test "a rejected inference resumes for remaining reports while failed admission waits for fresh input" {
    const testing = std.testing;
    var fixture: SubscriptionFixture = .{};
    defer fixture.storage.arena.deinit();
    const a = fixture.storage.arena.allocator();
    var store = try @import("subscriptions").Store.open(a, ":memory:");
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
    kernel.limits.request_bytes = 1;
    const first = try SubscriptionFixture.takeWork(&kernel, a);
    var admitted = try SubscriptionFixture.admit(&kernel, a, first);
    defer admitted.deinit();
    try kernel.sessions.interrupt(first, "The model rejected the inference after admission.");
    kernel.sessions.endWorker(first.session);
    const second = try SubscriptionFixture.takeWork(&kernel, a);
    try testing.expectEqual(1, second.activation.deliveries.items.len);
    const third = @import("subscriptions").NewReport{ .key = "third", .text = "budget-marker" };
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
