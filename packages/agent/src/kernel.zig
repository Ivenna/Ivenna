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
            try self.receivePending(a);
            try self.dispatch(tasks);
            const now = std.Io.Clock.awake.now(self.io).toMilliseconds();
            if (now - maintained_at >= 60_000) {
                try self.sessions.maintain();
                maintained_at = std.Io.Clock.awake.now(self.io).toMilliseconds();
            }
            try self.io.sleep(.fromMilliseconds(self.poll_interval_ms), .awake);
        }
    }

    fn receivePending(self: *Kernel, a: Allocator) !void {
        const waiting = try self.inbox.poll(a, try self.sessions.pollRequest());
        try self.sessions.reconcile(waiting);
        for (waiting) |incoming| switch (try self.sessions.accept(incoming)) {
            .accepted, .deferred => {},
            .duplicate, .absorbed => if (incoming.receipt) |receipt| try self.inbox.acknowledge(a, receipt),
        };
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
            });
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
        error.UnknownSession => runtimeError(a, "unknown_focus", "The focus is not addressable."),
        error.SessionQueueFull => runtimeError(a, "focus_queue_full", "The focus cannot currently accept another observation."),
        else => err,
    };
}

const CallbackFixture = struct {
    const Store = contracts.HistoryStore;
    const Incoming = contracts.Inbox.Incoming;
    const testing = std.testing;

    arena: std.heap.ArenaAllocator = .init(testing.allocator),
    checkpoint: ?[]const u8 = null,
    fail_save: bool = false,
    groups: usize = 0,
    records: std.ArrayList(Store.Record) = .empty,
    reports: std.ArrayList(Incoming) = .empty,
    receipts: std.ArrayList([]const u8) = .empty,

    fn kernel(self: *CallbackFixture, engine: *Engine) !Kernel {
        engine.* = .{
            .allocator = testing.allocator,
            .io = testing.io,
            .model = .{ .context = self, .vtable = &.{ .requestBytes = requestBytes, .next = undefined, .limitToolReplies = undefined } },
            .shared_tools = &.{},
            .activity_tools = &.{},
        };
        return Kernel.init(testing.allocator, testing.io, .{
            .engine = engine,
            .inbox = .{ .context = self, .vtable = &.{ .poll = poll, .acknowledge = acknowledge } },
            .sender = undefined,
            .callbacks = .{ .context = self, .publish = publish },
            .history = .{ .context = self, .vtable = &.{
                .load = load,
                .allocateGroup = allocateGroup,
                .query = query,
                .read = read,
                .create = create,
                .save = save,
                .maintain = maintain,
            } },
        }, .{ .limits = .{}, .poll_interval_ms = 1, .max_sessions = 2, .max_pending_events = 3 });
    }

    fn requestBytes(_: *anyopaque, _: Allocator, _: Model.Request) anyerror!u64 {
        return 0;
    }

    fn publish(context: *anyopaque, _: Allocator, message: contracts.Callback.Message) anyerror!void {
        const self: *CallbackFixture = @ptrCast(@alignCast(context));
        const a = self.arena.allocator();
        const sequence = self.reports.items.len + 1;
        try self.reports.append(a, .{
            .content = .{ .callback = .{ .id = message.id, .text = try a.dupe(u8, message.text), .observed_at_unix_ms = @intCast(sequence) } },
            .receipt = try std.fmt.allocPrint(a, "report-{d}", .{sequence}),
        });
    }

    fn poll(context: *anyopaque, a: Allocator, request: contracts.Inbox.Poll) anyerror![]const Incoming {
        const self: *CallbackFixture = @ptrCast(@alignCast(context));
        var waiting: std.ArrayList(Incoming) = .empty;
        for (self.reports.items) |report| {
            if (waiting.items.len == request.callbacks) break;
            for (self.receipts.items) |receipt| {
                if (std.mem.eql(u8, receipt, report.receipt.?)) break;
            } else try waiting.append(a, report);
        }
        return waiting.toOwnedSlice(a);
    }

    fn acknowledge(context: *anyopaque, _: Allocator, receipt: []const u8) anyerror!void {
        const self: *CallbackFixture = @ptrCast(@alignCast(context));
        const a = self.arena.allocator();
        try self.receipts.append(a, try a.dupe(u8, receipt));
    }

    fn load(context: *anyopaque, a: Allocator) anyerror!?[]const u8 {
        const self: *CallbackFixture = @ptrCast(@alignCast(context));
        return if (self.checkpoint) |body| try a.dupe(u8, body) else null;
    }

    fn allocateGroup(context: *anyopaque, a: Allocator) anyerror![]const u8 {
        const self: *CallbackFixture = @ptrCast(@alignCast(context));
        self.groups += 1;
        return std.fmt.allocPrint(a, "group-{d}", .{self.groups});
    }

    fn query(context: *anyopaque, a: Allocator, groups: []const []const u8) anyerror![]const Store.Reference {
        const self: *CallbackFixture = @ptrCast(@alignCast(context));
        var references: std.ArrayList(Store.Reference) = .empty;
        for (self.records.items) |record| {
            for (groups) |group| {
                if (!std.mem.eql(u8, group, record.group)) continue;
                try references.append(a, .{ .group = try a.dupe(u8, record.group), .key = record.key, .previous = record.previous, .locator = "" });
                break;
            }
        }
        return references.toOwnedSlice(a);
    }

    fn read(context: *anyopaque, a: Allocator, references: []const Store.Reference) anyerror![]const []const u8 {
        const self: *CallbackFixture = @ptrCast(@alignCast(context));
        const bodies = try a.alloc([]const u8, references.len);
        for (references, bodies) |reference, *body| {
            for (self.records.items) |record| {
                if (std.mem.eql(u8, record.group, reference.group) and std.mem.eql(u8, &record.key, &reference.key)) {
                    body.* = try a.dupe(u8, record.body);
                    break;
                }
            } else return error.MissingTestRecord;
        }
        return bodies;
    }

    fn create(context: *anyopaque, _: Allocator, records: []const Store.Record) anyerror!void {
        const self: *CallbackFixture = @ptrCast(@alignCast(context));
        const a = self.arena.allocator();
        for (records) |record| {
            var owned = record;
            owned.group = try a.dupe(u8, record.group);
            owned.body = try a.dupe(u8, record.body);
            try self.records.append(a, owned);
        }
    }

    fn save(context: *anyopaque, body: []const u8) anyerror!void {
        const self: *CallbackFixture = @ptrCast(@alignCast(context));
        if (self.fail_save) return error.UnconfirmedCheckpoint;
        self.checkpoint = try self.arena.allocator().dupe(u8, body);
    }

    fn maintain(_: *anyopaque, _: Allocator, _: Store.Retention) anyerror!void {}

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

    fn finish(instance: *Kernel, work: Work, history: *Context) !void {
        defer instance.sessions.endWorker(work.session);
        try testing.expect(try instance.sessions.commitResponse(work, history, &.{}, null));
    }
};

test "subscription reports wake a focus repeatedly and withdrawal absorbs late receipts across restart" {
    const testing = std.testing;
    var fixture: CallbackFixture = .{};
    defer fixture.arena.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var engine: Engine = undefined;
    const name = "listener";
    const withdrawn, const replacement = blk: {
        var kernel = try fixture.kernel(&engine);
        defer kernel.deinit();
        const startup = try CallbackFixture.takeWork(&kernel, a);
        var initial = try CallbackFixture.admit(&kernel, a, startup);
        defer initial.deinit();
        const wakeup = try kernel.sessions.registerCallback(a, startup, name, .wakeup);
        const reference = try kernel.sessions.subscribe(a, startup, name, .next_input);
        const subscription = (try kernel.sessions.subscription(a, reference)).?;
        const callback_reference = try contracts.Reference.create(a, name, subscription.callback_id);
        try testing.expectEqualStrings(wakeup.reference, reference);
        const state = (try kernel.sessions.compactionSnapshot(a, startup.session)).state;
        try testing.expectEqual(2, state.callbacks.len);
        try testing.expectEqualStrings(wakeup.reference, state.callbacks[0].callback_id);
        try testing.expectEqualStrings(callback_reference, state.callbacks[1].callback_id);
        try CallbackFixture.finish(&kernel, startup, &initial);
        try testing.expectEqual(0, (try kernel.sessions.takeReadyBatch(a)).len);

        try kernel.callbacks.send(a, .{ .id = subscription.callback_id, .text = "first" });
        try kernel.callbacks.send(a, .{ .id = subscription.callback_id, .text = "second" });
        try kernel.receivePending(a);
        try testing.expectEqual(0, fixture.receipts.items.len);
        const work = try CallbackFixture.takeWork(&kernel, a);
        try testing.expectEqual(subscription.session_id, work.session.session_id);
        var history = try CallbackFixture.admit(&kernel, a, work);
        defer history.deinit();
        const events = history.records()[1].record.events.items;
        try testing.expectEqual(2, events.len);
        for (events, [_][]const u8{ "first", "second" }) |event, expected| {
            try testing.expectEqualStrings(expected, event.callback.text);
            try testing.expectEqualStrings(callback_reference, event.callback.callback_id);
            try testing.expectEqual(subscription.id, event.callback.source.subscription.subscription_id);
        }
        try testing.expectEqual(2, fixture.receipts.items.len);

        fixture.fail_save = true;
        try testing.expectError(error.UnconfirmedCheckpoint, kernel.sessions.withdrawSubscription(subscription.id));
        fixture.fail_save = false;
        const before_retry = fixture.checkpoint.?;
        try kernel.sessions.withdrawSubscription(subscription.id);
        try testing.expect(!std.mem.eql(u8, before_retry, fixture.checkpoint.?));
        try kernel.sessions.withdrawSubscription(subscription.id);
        const inactive = (try kernel.sessions.subscription(a, reference)).?;
        try testing.expectEqual(.withdrawn, inactive.status);
        const new_reference = try kernel.sessions.subscribe(a, work, name, .immediate);
        const active = (try kernel.sessions.subscription(a, new_reference)).?;
        try testing.expect(active.id > subscription.id and active.callback_id > subscription.callback_id);
        try CallbackFixture.finish(&kernel, work, &history);

        try kernel.callbacks.send(a, .{ .id = subscription.callback_id, .text = "late" });
        try kernel.receivePending(a);
        try testing.expectEqualStrings("report-3", fixture.receipts.items[2]);
        try testing.expectEqual(0, (try kernel.sessions.takeReadyBatch(a)).len);
        break :blk .{ inactive, active };
    };

    var kernel = try fixture.kernel(&engine);
    defer kernel.deinit();
    const retained_withdrawn = (try kernel.sessions.subscription(a, withdrawn.reference)).?;
    const retained_active = (try kernel.sessions.subscription(a, replacement.reference)).?;
    try testing.expectEqualDeep(withdrawn, retained_withdrawn);
    try testing.expectEqualDeep(replacement, retained_active);
    const startup = try CallbackFixture.takeWork(&kernel, a);
    var history = try CallbackFixture.admit(&kernel, a, startup);
    defer history.deinit();
    const retained_events = history.records()[1].record.events.items;
    try testing.expectEqualStrings("first", retained_events[0].callback.text);
    try testing.expectEqualStrings("second", retained_events[1].callback.text);
    try testing.expectEqualStrings(try contracts.Reference.create(a, name, withdrawn.callback_id), retained_events[1].callback.callback_id);
    const next_reference = try kernel.sessions.subscribe(a, startup, name, .immediate);
    try testing.expectEqual(replacement.id + 1, (try kernel.sessions.subscription(a, next_reference)).?.id);
    try CallbackFixture.finish(&kernel, startup, &history);

    try kernel.callbacks.send(a, .{ .id = withdrawn.callback_id, .text = "late after restart" });
    try kernel.receivePending(a);
    try testing.expectEqualStrings("report-4", fixture.receipts.items[3]);
    try testing.expectEqual(0, (try kernel.sessions.takeReadyBatch(a)).len);

    try kernel.callbacks.send(a, .{ .id = replacement.callback_id, .text = "new listener" });
    try kernel.receivePending(a);
    const work = try CallbackFixture.takeWork(&kernel, a);
    var resumed = try CallbackFixture.admit(&kernel, a, work);
    defer resumed.deinit();
    const event = resumed.records()[resumed.records().len - 1].record.events.items[0];
    try testing.expectEqualStrings("new listener", event.callback.text);
    try testing.expectEqualStrings(try contracts.Reference.create(a, name, replacement.callback_id), event.callback.callback_id);
    try testing.expectEqualStrings("report-5", fixture.receipts.items[4]);
    try CallbackFixture.finish(&kernel, work, &resumed);
}

test "withdrawal preserves an activity report already held for admission" {
    const testing = std.testing;
    var fixture: CallbackFixture = .{};
    defer fixture.arena.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var engine: Engine = undefined;
    var kernel = try fixture.kernel(&engine);
    defer kernel.deinit();
    const startup = try CallbackFixture.takeWork(&kernel, a);
    var initial = try CallbackFixture.admit(&kernel, a, startup);
    defer initial.deinit();
    var forks: std.ArrayList(Sessions.ForkPlan) = .empty;
    try forks.ensureUnusedCapacity(a, 1);
    forks.appendAssumeCapacity(try kernel.sessions.prepareFork(startup, "activity", "Listen for reports."));
    try kernel.sessions.commitToolRound(startup, &initial, &forks);
    try CallbackFixture.finish(&kernel, startup, &initial);

    const assignment = try CallbackFixture.takeWork(&kernel, a);
    var assigned = try CallbackFixture.admit(&kernel, a, assignment);
    defer assigned.deinit();
    const reference = try kernel.sessions.subscribe(a, assignment, "listener", .immediate);
    const subscription = (try kernel.sessions.subscription(a, reference)).?;
    try CallbackFixture.finish(&kernel, assignment, &assigned);

    try kernel.callbacks.send(a, .{ .id = subscription.callback_id, .text = "held report" });
    try kernel.receivePending(a);
    try kernel.sessions.withdrawSubscription(subscription.id);
    try kernel.callbacks.send(a, .{ .id = subscription.callback_id, .text = "late report" });
    try kernel.receivePending(a);
    try testing.expectEqual(1, fixture.receipts.items.len);
    try testing.expectEqualStrings("report-2", fixture.receipts.items[0]);

    const work = try CallbackFixture.takeWork(&kernel, a);
    try testing.expectEqual(subscription.session_id, work.session.session_id);
    var history = try CallbackFixture.admit(&kernel, a, work);
    defer history.deinit();
    const events = history.records()[history.records().len - 1].record.events.items;
    try testing.expectEqual(1, events.len);
    try testing.expectEqualStrings("held report", events[0].callback.text);
    try testing.expectEqualStrings("report-1", fixture.receipts.items[1]);
    try CallbackFixture.finish(&kernel, work, &history);
}

test "wakeup and host callbacks remain one-shot" {
    const testing = std.testing;
    var fixture: CallbackFixture = .{};
    defer fixture.arena.deinit();
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var engine: Engine = undefined;
    var kernel = try fixture.kernel(&engine);
    defer kernel.deinit();
    const startup = try CallbackFixture.takeWork(&kernel, a);
    var initial = try CallbackFixture.admit(&kernel, a, startup);
    defer initial.deinit();
    const wakeup = try kernel.sessions.registerCallback(a, startup, "wake", .wakeup);
    const host = try kernel.sessions.registerCallback(a, startup, "read", .{ .host = .{ .command_id = "read-1" } });
    try CallbackFixture.finish(&kernel, startup, &initial);

    for ([_]contracts.Callback.Registration{ wakeup, host }) |registration| {
        try kernel.callbacks.send(a, .{ .id = registration.id, .text = "first result" });
        try kernel.callbacks.send(a, .{ .id = registration.id, .text = "second result" });
        try kernel.receivePending(a);
        const work = try CallbackFixture.takeWork(&kernel, a);
        var history = try CallbackFixture.admit(&kernel, a, work);
        defer history.deinit();
        const events = history.records()[history.records().len - 1].record.events.items;
        try testing.expectEqual(1, events.len);
        try testing.expectEqualStrings("first result", events[0].callback.text);
        try CallbackFixture.finish(&kernel, work, &history);
        try kernel.receivePending(a);
        try testing.expectEqual(0, (try kernel.sessions.takeReadyBatch(a)).len);
    }
    try testing.expectEqual(4, fixture.receipts.items.len);
}
