const std = @import("std");
const Context = @import("context.zig").Context;
const History = @import("history.zig").History;
const Persistence = @import("history.zig").Persistence;
const Subscriptions = @import("subscriptions");
const Reports = @import("reports.zig");
const Input = @import("input.zig");
const WorkInput = @import("work.zig");
const Delivery = WorkInput.Delivery;
const Activation = WorkInput.Activation;
const Allocator = std.mem.Allocator;
const contracts = @import("agent_contracts");
const Model = contracts.Model;
const Incoming = contracts.Inbox.Incoming;
const report_read_batch = 64;

const Stream = enum(u8) {
    ordinary,
    subscription,
    activity,

    fn next(self: Stream) Stream {
        return switch (self) {
            .ordinary => .subscription,
            .subscription => .activity,
            .activity => .ordinary,
        };
    }
    fn of(event: Input.Event) Stream {
        return switch (event) {
            .subscription => .subscription,
            .activity => .activity,
            else => .ordinary,
        };
    }
};

/// Identity, working context, and pending observations for one session.
pub const Session = struct {
    session_id: u64,
    focus_id: []const u8 = &.{},
    role: Input.Role,
    epoch: u64 = 0,
    context: ?Context = null,
    needs_startup: bool = false,
    state: union(enum) { idle, running: *Activation, interrupted } = .idle,
    pending: std.ArrayList(*Delivery) = .empty,
    borrowed_workers: usize = 0,
    subscription_through: u64 = 0,
    noticed_immediate: u64 = 0,
    first_stream: Stream = .ordinary,

    /// Only genuinely new work makes an interrupted focus eligible again.
    fn notify(self: *Session) void {
        switch (self.state) {
            .running => |activation| activation.new_arrival = true,
            .interrupted => self.state = .idle,
            .idle => {},
        }
    }
};

pub const Work = struct { session: *Session, activation: *Activation };
pub const ForkPlan = struct { session: *Session };

pub const Registry = struct {
    allocator: Allocator,
    io: std.Io,
    max_sessions: usize,
    max_pending: usize,
    subscriptions: *Subscriptions.Store,
    subscription_catalog: [32]u8,
    history: Persistence,
    reports: Reports.Outbox,
    mutex: std.Io.Mutex = .init,
    core: *Session,
    sessions: std.AutoHashMapUnmanaged(u64, *Session) = .empty,
    noticed: std.StringHashMapUnmanaged(enum { scheduled, acknowledged }) = .empty,
    wakeups: std.ArrayList(History.Wakeup) = .empty,
    callbacks: std.ArrayList(History.CallbackRegistration) = .empty,
    queued_callbacks: std.AutoHashMapUnmanaged(u64, void) = .empty,
    reserved_sessions: usize = 0,
    next_session_id: u64 = 2,
    next_callback_id: u64 = 1,
    next_command_id: u64 = 1,
    started_at_unix_ms: i64,

    pub fn init(allocator: Allocator, io: std.Io, max_sessions: usize, max_pending: usize, history: contracts.HistoryStore, subscriptions: *Subscriptions.Store) !Registry {
        var self: Registry = .{
            .allocator = allocator,
            .io = io,
            .max_sessions = max_sessions,
            .max_pending = max_pending,
            .subscriptions = subscriptions,
            .subscription_catalog = try subscriptions.identity(),
            .history = .init(allocator, history),
            .reports = try Reports.Outbox.init(allocator, history, null),
            .core = undefined,
            .started_at_unix_ms = std.Io.Clock.real.now(io).toMilliseconds(),
        };
        errdefer self.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const saved = try self.history.load(a, max_sessions);
        const expected_catalog = if (saved) |retained| retained.subscription_catalog else null;
        if (expected_catalog) |expected| {
            if (!std.mem.eql(u8, &expected, &self.subscription_catalog)) return error.SubscriptionCatalogMismatch;
        } else if (try subscriptions.isBound()) return error.SubscriptionCatalogMismatch;
        if (saved) |retained| {
            const reports = try Reports.Outbox.init(allocator, history, retained.activity_reports);
            self.reports.deinit();
            self.reports = reports;
            self.next_session_id = retained.next_session_id;
            self.next_callback_id = retained.next_callback_id;
            self.next_command_id = retained.next_command_id;
            for (retained.sessions) |record| {
                const session = try allocator.create(Session);
                session.* = .{
                    .session_id = record.session_id,
                    .role = record.role,
                    .epoch = record.epoch,
                    .subscription_through = record.subscription_through,
                    .needs_startup = true,
                };
                errdefer self.destroySession(session);
                session.focus_id = try allocator.dupe(u8, record.focus_id);
                if (record.role == .core) {
                    session.context = try Context.restore(allocator, .{ .session_id = record.session_id, .epoch = record.epoch }, record.focus_id, record.entries orelse return error.InvalidHistory);
                }
                try self.sessions.put(allocator, session.session_id, session);
            }
            self.core = self.sessions.get(1).?;
            for (retained.callbacks) |callback| try self.restoreCallback(callback);
            for (retained.wakeups) |wakeup| {
                const text = try allocator.dupe(u8, wakeup.text);
                errdefer allocator.free(text);
                try self.wakeups.append(allocator, .{
                    .id = wakeup.id,
                    .at_unix_ms = wakeup.at_unix_ms,
                    .text = text,
                });
            }
            for (retained.sessions) |record| {
                const session = self.sessions.get(record.session_id).?;
                if (session == self.core or record.was_running or record.observations.len != 0) try self.ensureStartupLocked(session);
                for (record.observations) |event| {
                    const delivery = try Delivery.create(allocator, event, null);
                    errdefer delivery.destroy(allocator);
                    try session.pending.append(allocator, delivery);
                }
            }
        } else {
            const core = try allocator.create(Session);
            core.* = .{ .session_id = 1, .role = .core, .needs_startup = true };
            errdefer self.destroySession(core);
            core.focus_id = try allocator.dupe(u8, "core-1");
            core.context = try Context.init(allocator, .{ .session_id = 1, .epoch = 0 }, core.focus_id);
            try self.ensureStartupLocked(core);
            try self.sessions.put(allocator, 1, core);
            self.core = core;
        }
        try self.saveLocked();
        try subscriptions.markBound();
        // A prior checkpoint may have committed just before the process stopped.
        var restored = self.sessions.valueIterator();
        while (restored.next()) |entry| {
            const session = entry.*;
            if (session.subscription_through != 0) try subscriptions.acknowledge(session.session_id, session.subscription_through);
        }
        return self;
    }

    pub fn deinit(self: *Registry) void {
        var sessions = self.sessions.valueIterator();
        while (sessions.next()) |session| self.destroySession(session.*);
        self.sessions.deinit(self.allocator);
        var notice_keys = self.noticed.keyIterator();
        while (notice_keys.next()) |key| self.allocator.free(key.*);
        self.noticed.deinit(self.allocator);
        for (self.wakeups.items) |wakeup| self.allocator.free(wakeup.text);
        self.wakeups.deinit(self.allocator);
        for (self.callbacks.items) |callback| self.freeCallback(callback);
        self.callbacks.deinit(self.allocator);
        self.queued_callbacks.deinit(self.allocator);
        self.reports.deinit();
        self.history.deinit();
        self.* = undefined;
    }

    pub fn pollRequest(self: *Registry) !contracts.Inbox.Poll {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .messages = if (self.hasCapacity(self.core)) self.noticed.count() + @max(32, self.max_pending * 2) else 0,
            .callbacks = self.noticed.count() + self.callbacks.items.len + 32,
        };
    }

    pub const Intake = enum { accepted, deferred, duplicate };

    pub fn accept(self: *Registry, incoming: Incoming) !Intake {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const session, const event = switch (incoming.content) {
            .message => |message| .{ self.core, Input.Event{ .input = message } },
            .callback => |callback| blk: {
                // Protect all transport copies until the admitted group has
                // been published and its receipt acknowledged.
                if (self.queued_callbacks.contains(callback.id)) return .deferred;
                const registration = self.callbackLocked(callback.id) orelse {
                    if (callback.id != 0 and callback.id < self.next_callback_id) return .duplicate;
                    return error.UnknownCallback;
                };
                break :blk .{ self.sessions.get(registration.session_id).?, Input.Event{ .callback = .{
                    .callback_id = registration.reference,
                    .source = registration.source,
                    .observed_at_unix_ms = callback.observed_at_unix_ms,
                    .text = callback.text,
                } } };
            },
        };
        if (incoming.receipt) |key| if (self.noticed.contains(key)) return .deferred;
        if (!self.hasCapacity(session)) return .deferred;
        const delivery = try Delivery.create(self.allocator, event, incoming.receipt);
        errdefer delivery.destroy(self.allocator);
        delivery.callback_id = if (incoming.content == .callback) incoming.content.callback.id else null;
        try self.ensureStartupLocked(session);
        try session.pending.ensureUnusedCapacity(self.allocator, 1);
        const notice_key = if (incoming.receipt) |key| try self.allocator.dupe(u8, key) else null;
        errdefer if (notice_key) |key| self.allocator.free(key);
        if (delivery.callback_id) |id| try self.queued_callbacks.put(self.allocator, id, {});
        if (notice_key) |key| try self.noticed.put(self.allocator, key, .scheduled);
        session.pending.appendAssumeCapacity(delivery);
        session.notify();
        return .accepted;
    }

    pub fn takeReadyBatch(self: *Registry, a: Allocator) ![]const Work {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var ready: std.ArrayList(Work) = .empty;
        defer ready.deinit(a);
        errdefer for (ready.items) |work| {
            work.session.borrowed_workers -= 1;
        };
        try ready.ensureTotalCapacity(a, self.sessions.count());
        const sessions = try a.alloc(*Session, self.sessions.count());
        defer a.free(sessions);
        var iterator = self.sessions.valueIterator();
        for (sessions) |*session| session.* = iterator.next().?.*;
        std.mem.sort(*Session, sessions, {}, lessSessionId);
        for (sessions) |session| {
            if (try self.takeReady(session)) |work| ready.appendAssumeCapacity(work);
        }
        return ready.toOwnedSlice(a);
    }

    /// Move arrivals into a new, initially unadmitted batch in this activation.
    pub fn collectPending(self: *Registry, work: Work) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        try self.collectLocked(work.session, work.activation);
    }

    fn collectLocked(self: *Registry, session: *Session, activation: *Activation) !void {
        std.debug.assert(activation.deliveries.items.len == 0);
        // Sample before reading so an immediate arrival after this point still
        // counts as fresh if admission or inference is interrupted.
        session.noticed_immediate = try self.subscriptions.latestImmediate(session.session_id);
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const reports = try self.subscriptions.pending(a, session.session_id, session.subscription_through, @min(self.max_pending, report_read_batch));
        var subscriptions: std.ArrayList(*Delivery) = .empty;
        try subscriptions.ensureTotalCapacity(a, reports.len);
        errdefer for (subscriptions.items) |delivery| delivery.destroy(self.allocator);
        for (reports) |report| {
            const delivery = try Delivery.create(self.allocator, .{ .subscription = .{
                .subscription_id = report.reference,
                .delivery_id = report.sequence,
                .text = report.text,
                .observed_at_unix_ms = report.observed_at_unix_ms,
                .source_time_unix_ms = report.source_time_unix_ms,
                .handle = report.handle,
                .version = report.version,
                .truncated = report.truncated,
                .retrieval = report.retrieval,
            } }, null);
            subscriptions.appendAssumeCapacity(delivery);
        }
        const activity = if (session == self.core) try self.readReportDeliveriesLocked(0) else &.{};
        defer self.allocator.free(activity);
        errdefer for (activity) |report| report.destroy(self.allocator);
        try activation.deliveries.ensureUnusedCapacity(self.allocator, session.pending.items.len + activity.len + reports.len);
        // Each source has its own arrival order. Rotate who receives the first
        // part of a bounded input so a permanently busy source cannot crowd
        // out another. Startup still introduces the first turn of a run.
        var ordinary = session.pending.items;
        if (ordinary.len != 0 and ordinary[0].event == .startup) {
            activation.deliveries.appendAssumeCapacity(ordinary[0]);
            ordinary = ordinary[1..];
        }
        var stream = session.first_stream;
        for (0..3) |_| {
            activation.deliveries.appendSliceAssumeCapacity(switch (stream) {
                .ordinary => ordinary,
                .subscription => subscriptions.items,
                .activity => activity,
            });
            stream = stream.next();
        }
        session.pending.clearRetainingCapacity();
        activation.admitted = activation.deliveries.items.len == 0;
        activation.new_arrival = false;
    }

    /// Extend an unadmitted core batch by one I/O page without invoking the model.
    pub fn extendReports(self: *Registry, work: Work) !bool {
        if (work.session != self.core) return false;
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        std.debug.assert(!work.activation.admitted);
        var staged: usize = 0;
        for (work.activation.deliveries.items) |delivery| staged += @intFromBool(delivery.event == .activity);
        const reports = try self.readReportDeliveriesLocked(staged);
        defer self.allocator.free(reports);
        errdefer for (reports) |report| report.destroy(self.allocator);
        if (reports.len == 0) return false;
        try work.activation.deliveries.appendSlice(self.allocator, reports);
        return true;
    }

    /// Already admitted observations live in Context; their receipts have been
    /// acknowledged. Releasing the transport deliveries allows another batch.
    pub fn releaseDeliveries(self: *Registry, work: Work) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        std.debug.assert(work.activation.admitted);
        for (work.activation.deliveries.items) |delivery| {
            std.debug.assert(delivery.receipt == null);
            if (delivery.callback_id) |id| _ = self.queued_callbacks.remove(id);
            delivery.destroy(self.allocator);
        }
        work.activation.deliveries.clearRetainingCapacity();
    }

    /// Save a copy of the worker's history, advance the outbox past admitted
    /// reports, and remove registrations for admitted callbacks in one checkpoint.
    /// The caller can then acknowledge the deliveries.
    pub fn commitInput(self: *Registry, work: Work, count: usize, history: *const Context) !void {
        var retained = try history.clone(self.allocator);
        defer retained.deinit();
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const session = work.session;
        const deliveries = &work.activation.deliveries;
        std.debug.assert(count != 0 or deliveries.items.len == 0);
        const suffix = deliveries.items[count..];
        var report_count: usize = 0;
        var endings: usize = 0;
        for (deliveries.items[0..count]) |delivery| if (delivery.event == .activity) {
            report_count += 1;
            endings += @intFromBool(delivery.event.activity.ended_at_unix_ms != null);
        };
        try session.pending.ensureUnusedCapacity(self.allocator, suffix.len);
        try self.reports.consume(report_count, endings);
        session.pending.insertSliceAssumeCapacity(0, self.keepQueued(suffix));
        deliveries.items.len = count;
        std.mem.swap(Context, &session.context.?, &retained);
        session.epoch = session.context.?.scope.epoch;
        work.activation.admitted = true;
        for (deliveries.items) |delivery| {
            if (delivery.event == .startup) continue;
            session.first_stream = Stream.of(delivery.event).next();
            break;
        }
        var admitted_report = false;
        for (deliveries.items) |delivery| {
            if (delivery.callback_id) |id| self.completeCallbackLocked(id);
            if (delivery.event == .subscription) {
                std.debug.assert(delivery.event.subscription.delivery_id > session.subscription_through);
                session.subscription_through = delivery.event.subscription.delivery_id;
                admitted_report = true;
            }
        }
        try self.saveLocked();
        if (admitted_report) try self.subscriptions.acknowledge(session.session_id, session.subscription_through);
    }

    pub fn prepareFork(self: *Registry, work: Work, name: []const u8, task: []const u8) !ForkPlan {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        if (self.sessions.count() + self.reserved_sessions >= self.max_sessions) return error.SessionCapacityUnavailable;
        const session = try self.allocator.create(Session);
        session.* = .{
            .session_id = self.next_session_id,
            .role = .activity,
        };
        errdefer self.destroySession(session);
        session.focus_id = try contracts.Reference.create(self.allocator, name, self.next_session_id);
        const assignment = try Delivery.create(self.allocator, .{ .assignment = .{ .task = task } }, null);
        errdefer assignment.destroy(self.allocator);
        try session.pending.append(self.allocator, assignment);
        self.next_session_id += 1;
        self.reserved_sessions += 1;
        return .{ .session = session };
    }

    pub fn abandonFork(self: *Registry, plan: ForkPlan) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.reserved_sessions -= 1;
        self.destroySession(plan.session);
    }

    /// Publish the completed context and its forks together. On every return
    /// the caller owns the context left in `completed` and any remaining plans.
    pub fn commitToolRound(self: *Registry, work: Work, completed: *Context, plans: *std.ArrayList(ForkPlan)) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const session = work.session;
        for (plans.items) |plan| {
            plan.session.context = try Context.restore(self.allocator, .{ .session_id = plan.session.session_id, .epoch = 0 }, plan.session.focus_id, completed.records());
        }
        try self.sessions.ensureUnusedCapacity(self.allocator, @intCast(plans.items.len));
        std.mem.swap(Context, &session.context.?, completed);
        for (plans.items) |plan| {
            self.sessions.putAssumeCapacity(plan.session.session_id, plan.session);
            self.reserved_sessions -= 1;
        }
        plans.clearRetainingCapacity();
        try self.saveLocked();
    }

    pub fn snapshot(self: *Registry, session: *Session) !Context {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.restoreContextLocked(session);
        return session.context.?.clone(self.allocator);
    }

    /// Keep an activity's expression available through interruption of its tools.
    pub fn recordBeforeTools(self: *Registry, work: Work, text: ?[]const u8) !void {
        if (work.session == self.core or text == null) return;
        const observed_at = self.now();
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        try self.reportResponseLocked(work.session, text, observed_at, false);
        try self.saveLocked();
    }

    pub fn maintain(self: *Registry) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.saveLocked();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        try self.history.maintain(a, try self.reports.retained(a));
    }

    fn saveLocked(self: *Registry) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var retained: std.ArrayList(History.Session) = .empty;
        var sessions = self.sessions.valueIterator();
        while (sessions.next()) |entry| {
            const session = entry.*;
            var observations: std.ArrayList(Input.Event) = .empty;
            if (session.state == .running and !session.state.running.admitted) {
                for (session.state.running.deliveries.items) |delivery| if (isInternal(delivery.event)) try observations.append(a, delivery.event);
            }
            for (session.pending.items) |delivery| if (isInternal(delivery.event)) try observations.append(a, delivery.event);
            try retained.append(a, .{
                .session_id = session.session_id,
                .focus_id = session.focus_id,
                .role = session.role,
                .epoch = session.epoch,
                .subscription_through = session.subscription_through,
                .was_running = session.role == .activity and (session.state != .idle or hasStartup(session.pending.items)),
                .entries = if (session.context) |*context| context.records() else null,
                .observations = observations.items,
            });
        }
        try self.history.save(a, .{
            .subscription_catalog = self.subscription_catalog,
            .next_session_id = self.next_session_id,
            .next_callback_id = self.next_callback_id,
            .next_command_id = self.next_command_id,
            .wakeups = self.wakeups.items,
            .callbacks = self.callbacks.items,
            .sessions = retained.items,
            .activity_reports = self.reports.checkpoint(),
        });
    }

    pub fn current(self: *Registry, a: Allocator, session: *Session) !Input.Current {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return self.currentLocked(a, session);
    }

    pub fn compactionSnapshot(self: *Registry, a: Allocator, session: *Session) !Input.Snapshot {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var activities: std.ArrayList([]const u8) = .empty;
        if (session == self.core) {
            var sessions = self.sessions.valueIterator();
            while (sessions.next()) |entry| {
                const activity = entry.*;
                if (activity == self.core) continue;
                try activities.append(a, try a.dupe(u8, activity.focus_id));
            }
            std.mem.sort([]const u8, activities.items, {}, lessActivity);
        }
        var own_callbacks: std.ArrayList(Input.PendingCallback) = .empty;
        for (self.callbacks.items) |callback| if (callback.session_id == session.session_id) try own_callbacks.append(a, .{
            .callback_id = try a.dupe(u8, callback.reference),
            .source = try cloneSource(a, callback.source),
        });
        return .{
            .current = try self.currentLocked(a, session),
            .state = .{
                .activities = try activities.toOwnedSlice(a),
                .callbacks = try own_callbacks.toOwnedSlice(a),
                .subscriptions = try self.subscriptions.registrations(a, subscriptionOwner(session)),
            },
        };
    }

    fn currentLocked(self: *Registry, a: Allocator, session: *Session) !Input.Current {
        return .{
            .focus_id = try a.dupe(u8, session.focus_id),
            .role = session.role,
            .observed_at_unix_ms = self.now(),
        };
    }

    /// Commit the outcome of a round without tool calls. Returns true when
    /// the activation has finished. On every return the caller owns the
    /// context left in `history`.
    pub fn commitResponse(self: *Registry, work: Work, history: *Context, output: []const Model.Item, text: ?[]const u8) !bool {
        const observed_at = self.now();
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const session = work.session;
        const can_end = try self.canEnd(session);
        const more_reports = if (can_end)
            try self.subscriptions.hasPending(session.session_id, session.subscription_through)
        else
            try self.subscriptions.hasImmediate(session.session_id, session.subscription_through);
        const finished = !self.hasWork(session) and !more_reports;
        const completed_activity = finished and can_end;
        if (!completed_activity) try history.appendBatch(output, &.{});
        if (session != self.core) try self.reportResponseLocked(session, text, observed_at, completed_activity);
        if (completed_activity) {
            const removed = self.sessions.remove(session.session_id);
            std.debug.assert(removed);
            self.core.notify();
        } else {
            std.mem.swap(Context, &session.context.?, history);
        }
        if (finished) {
            session.state = .idle;
            work.activation.destroy(self.allocator);
        }
        try self.saveLocked();
        if (finished and !completed_activity) unloadActivityContext(session);
        return finished;
    }

    /// The current inference could not proceed. Put its unadmitted observations
    /// back ahead of later arrivals, leaving mail receipts and callbacks owned
    /// by their original deliveries. Restart also revisits unfinished work.
    pub fn interrupt(self: *Registry, work: Work, reason: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const session = work.session;
        const activation = work.activation;
        // A reasoning failure can occur during admission or after admission
        // and acknowledgement have both finished.
        std.debug.assert(!activation.admitted or activation.deliveries.items.len == 0);
        try session.pending.ensureUnusedCapacity(self.allocator, activation.deliveries.items.len);
        if (session != self.core) try self.enqueueLocked(self.core, .{ .focus_interrupted = .{
            .focus_id = session.focus_id,
            .observed_at_unix_ms = self.now(),
            .reason = reason,
        } });
        // Further immediate reports can resume the focus. After admission, the
        // unadmitted suffix counts; before admission, wait for a new arrival.
        const report_after = if (activation.admitted) session.subscription_through else session.noticed_immediate;
        const fresh_report = try self.subscriptions.hasImmediate(session.session_id, report_after);
        const ready = fresh_report or activation.new_arrival or (activation.admitted and self.hasWork(session));
        session.pending.insertSliceAssumeCapacity(0, self.keepQueued(activation.deliveries.items));
        activation.deliveries.clearRetainingCapacity();
        session.state = if (ready) .idle else .interrupted;
        activation.destroy(self.allocator);
        try self.saveLocked();
        unloadActivityContext(session);
    }

    /// Later saves reuse the last confirmed history for an unloaded activity.
    /// Unload only after the checkpoint containing this context is confirmed.
    fn unloadActivityContext(session: *Session) void {
        if (session.role == .activity) {
            session.context.?.deinit();
            session.context = null;
        }
    }

    /// Completed sessions can be destroyed once no worker retains them.
    pub fn endWorker(self: *Registry, session: *Session) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        session.borrowed_workers -= 1;
        if (session.borrowed_workers != 0) return;
        if (!self.sessions.contains(session.session_id)) {
            self.destroySession(session);
        }
    }

    pub fn sendFocusMessage(self: *Registry, work: Work, target: []const u8, text: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        var iterator = self.sessions.valueIterator();
        const session = while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.*.focus_id, target)) break entry.*;
        } else return error.UnknownSession;
        if (!self.hasCapacity(session)) return error.SessionQueueFull;
        try self.enqueueLocked(session, .{ .focus_message = .{
            .from_focus = work.session.focus_id,
            .observed_at_unix_ms = self.now(),
            .text = text,
        } });
        try self.saveLocked();
    }

    pub fn scheduleWakeup(self: *Registry, a: Allocator, work: Work, name: []const u8, at: i64, text: []const u8) ![]const u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const owned = try self.allocator.dupe(u8, text);
        var transferred = false;
        errdefer if (!transferred) self.allocator.free(owned);
        try self.wakeups.ensureUnusedCapacity(self.allocator, 1);
        const registration = try self.registerCallbackLocked(work.session, name, .wakeup);
        self.wakeups.appendAssumeCapacity(.{ .id = registration.id, .at_unix_ms = at, .text = owned });
        transferred = true;
        try self.saveLocked();
        return a.dupe(u8, registration.reference);
    }

    pub fn dueWakeups(self: *Registry, a: Allocator) ![]const History.Wakeup {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var due: std.ArrayList(History.Wakeup) = .empty;
        const observed_at = self.now();
        for (self.wakeups.items) |wakeup_source| if (wakeup_source.at_unix_ms <= observed_at) {
            try due.append(a, .{ .id = wakeup_source.id, .at_unix_ms = wakeup_source.at_unix_ms, .text = try a.dupe(u8, wakeup_source.text) });
        };
        return due.toOwnedSlice(a);
    }

    pub fn wakeupSent(self: *Registry, id: u64) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        self.removeWakeupLocked(id);
        try self.saveLocked();
    }

    pub fn issueCommandReference(self: *Registry, a: Allocator, work: Work, name: []const u8) ![]const u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const id = self.next_command_id;
        const next = try std.math.add(u64, id, 1);
        const reference = try contracts.Reference.create(a, name, id);
        errdefer a.free(reference);
        self.next_command_id = next;
        try self.saveLocked();
        return reference;
    }

    pub fn registerCallback(self: *Registry, a: Allocator, work: Work, name: []const u8, source: contracts.Callback.Source) !contracts.Callback.Registration {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const registration = try self.registerCallbackLocked(work.session, name, source);
        try self.saveLocked();
        return .{ .id = registration.id, .reference = try a.dupe(u8, registration.reference) };
    }

    pub fn subscribe(self: *Registry, a: Allocator, work: Work, name: []const u8, reminder: Subscriptions.Reminder, listener: []const u8) !Subscriptions.Registration {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        return self.subscriptions.create(a, work.session.session_id, work.session.focus_id, name, reminder, listener);
    }

    /// The core coordinates interests across focuses. Each activity manages
    /// its own registrations.
    fn subscriptionOwner(session: *const Session) ?u64 {
        return if (session.role == .core) null else session.session_id;
    }

    pub fn withdrawSubscription(self: *Registry, work: Work, reference: []const u8) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        return self.subscriptions.withdraw(subscriptionOwner(work.session), reference);
    }

    /// Before startup dispatch, these registrations belong to commands from the
    /// previous runtime. Their processes and control handles are not restored.
    pub fn pendingHostCallbacks(self: *Registry, a: Allocator) ![]const History.CallbackRegistration {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var pending: std.ArrayList(History.CallbackRegistration) = .empty;
        for (self.callbacks.items) |callback| if (callback.source == .host) try pending.append(a, .{
            .id = callback.id,
            .reference = try a.dupe(u8, callback.reference),
            .session_id = callback.session_id,
            .source = try cloneSource(a, callback.source),
        });
        return pending.toOwnedSlice(a);
    }

    fn registerCallbackLocked(self: *Registry, session: *Session, name: []const u8, source: contracts.Callback.Source) !History.CallbackRegistration {
        const id = self.next_callback_id;
        const next = try std.math.add(u64, id, 1);
        const reference = try contracts.Reference.create(self.allocator, name, id);
        errdefer self.allocator.free(reference);
        const owned_source = try cloneSource(self.allocator, source);
        errdefer freeSource(self.allocator, owned_source);
        const registration: History.CallbackRegistration = .{ .id = id, .reference = reference, .session_id = session.session_id, .source = owned_source };
        try self.callbacks.append(self.allocator, registration);
        self.next_callback_id = next;
        return registration;
    }

    fn restoreCallback(self: *Registry, saved: History.CallbackRegistration) !void {
        const reference = try self.allocator.dupe(u8, saved.reference);
        errdefer self.allocator.free(reference);
        const source = try cloneSource(self.allocator, saved.source);
        errdefer freeSource(self.allocator, source);
        try self.callbacks.append(self.allocator, .{ .id = saved.id, .reference = reference, .session_id = saved.session_id, .source = source });
    }

    fn freeCallback(self: *Registry, callback: History.CallbackRegistration) void {
        self.allocator.free(callback.reference);
        freeSource(self.allocator, callback.source);
    }

    fn callbackLocked(self: *Registry, id: u64) ?History.CallbackRegistration {
        for (self.callbacks.items) |callback| if (callback.id == id) return callback;
        return null;
    }

    fn completeCallbackLocked(self: *Registry, id: u64) void {
        for (self.callbacks.items, 0..) |callback, index| if (callback.id == id) {
            self.freeCallback(self.callbacks.orderedRemove(index));
            break;
        };
        self.removeWakeupLocked(id);
    }

    fn removeWakeupLocked(self: *Registry, id: u64) void {
        for (self.wakeups.items, 0..) |wakeup_source, index| if (wakeup_source.id == id) {
            const removed = self.wakeups.orderedRemove(index);
            self.allocator.free(removed.text);
            return;
        };
    }

    pub fn acknowledged(self: *Registry, receipt: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        self.noticed.getPtr(receipt).?.* = .acknowledged;
    }

    pub fn reconcile(self: *Registry, waiting: []const Incoming) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var present: std.StringHashMapUnmanaged(void) = .empty;
        defer present.deinit(self.allocator);
        for (waiting) |incoming| if (incoming.receipt) |receipt| {
            try present.put(self.allocator, receipt, {});
        };
        var absent: std.ArrayList([]const u8) = .empty;
        defer absent.deinit(self.allocator);
        var notices = self.noticed.iterator();
        while (notices.next()) |entry| {
            if (entry.value_ptr.* == .acknowledged and !present.contains(entry.key_ptr.*)) try absent.append(self.allocator, entry.key_ptr.*);
        }
        for (absent.items) |key| if (self.noticed.fetchRemove(key)) |entry| self.allocator.free(entry.key);
    }

    fn reportResponseLocked(self: *Registry, session: *Session, text: ?[]const u8, observed_at: i64, ended: bool) !void {
        var buffer: [2]Reports.Entry = undefined;
        var facts: std.ArrayList(Reports.Entry) = .initBuffer(&buffer);
        if (text) |message| facts.appendAssumeCapacity(.{
            .from_focus = session.focus_id,
            .observed_at_unix_ms = observed_at,
            .content = .{ .assistant = message },
        });
        if (ended) facts.appendAssumeCapacity(.{
            .from_focus = session.focus_id,
            .observed_at_unix_ms = self.now(),
            .content = .ended,
        });
        try self.reports.append(facts.items);
    }

    /// Unadmitted subscription and activity reports remain in their stores.
    /// Ordinary deliveries retain their original ownership and order.
    fn keepQueued(self: *Registry, deliveries: []*Delivery) []*Delivery {
        var count: usize = 0;
        for (deliveries) |delivery| {
            if (delivery.event == .subscription or delivery.event == .activity) {
                delivery.destroy(self.allocator);
            } else {
                deliveries[count] = delivery;
                count += 1;
            }
        }
        return deliveries[0..count];
    }

    fn canEnd(self: *Registry, session: *Session) !bool {
        return session != self.core and self.callbackCount(session.session_id) == 0 and
            !try self.subscriptions.hasActive(session.session_id);
    }

    fn takeReady(self: *Registry, session: *Session) !?Work {
        if (session.state == .running) return null;
        if (session.state == .interrupted) {
            if (!try self.subscriptions.hasImmediate(session.session_id, session.noticed_immediate)) return null;
            session.notify();
        }
        if (!self.hasWork(session) and !try self.subscriptions.hasImmediate(session.session_id, session.subscription_through)) {
            // A sleeping activity's last registration may have been withdrawn
            // by the core, including just before a restart.
            if (!try self.canEnd(session)) return null;
            if (!try self.subscriptions.hasPending(session.session_id, session.subscription_through)) {
                try self.reportResponseLocked(session, null, self.now(), true);
                _ = self.sessions.remove(session.session_id);
                self.core.notify();
                if (session.borrowed_workers == 0) self.destroySession(session);
                try self.saveLocked();
                return null;
            }
        }
        try self.ensureStartupLocked(session);
        try self.restoreContextLocked(session);
        const activation = try Activation.create(self.allocator, &.{});
        errdefer activation.destroy(self.allocator);
        try self.collectLocked(session, activation);
        session.state = .{ .running = activation };
        session.borrowed_workers += 1;
        return .{ .session = session, .activation = activation };
    }

    fn readReportDeliveriesLocked(self: *Registry, start: usize) ![]*Delivery {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const reports = try self.reports.peek(arena.allocator(), start, report_read_batch);
        const deliveries = try self.allocator.alloc(*Delivery, reports.len);
        var initialized: usize = 0;
        errdefer {
            for (deliveries[0..initialized]) |delivery| delivery.destroy(self.allocator);
            self.allocator.free(deliveries);
        }
        for (reports, deliveries) |report, *delivery| {
            const messages: []const Input.ActivityMessage = if (report.content == .assistant) &.{.{
                .text = report.content.assistant,
                .observed_at_unix_ms = report.observed_at_unix_ms,
            }} else &.{};
            delivery.* = try Delivery.create(self.allocator, .{ .activity = .{
                .from_focus = report.from_focus,
                .messages = messages,
                .ended_at_unix_ms = if (report.content == .ended) report.observed_at_unix_ms else null,
            } }, null);
            initialized += 1;
        }
        return deliveries;
    }

    fn restoreContextLocked(self: *Registry, session: *Session) !void {
        if (session.context != null) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const entries = try self.history.restoreEntries(arena.allocator(), session.session_id);
        session.context = try Context.restore(self.allocator, .{ .session_id = session.session_id, .epoch = session.epoch }, session.focus_id, entries);
    }

    fn ensureStartupLocked(self: *Registry, session: *Session) !void {
        if (!session.needs_startup) return;
        const delivery = try Delivery.create(self.allocator, .{ .startup = .{ .observed_at_unix_ms = self.started_at_unix_ms } }, null);
        errdefer delivery.destroy(self.allocator);
        delivery.event.startup.subscriptions = try self.subscriptions.registrations(delivery.arena.allocator(), subscriptionOwner(session));
        try session.pending.insert(self.allocator, 0, delivery);
        session.needs_startup = false;
    }

    fn enqueueLocked(self: *Registry, session: *Session, event: Input.Event) !void {
        const delivery = try Delivery.create(self.allocator, event, null);
        errdefer delivery.destroy(self.allocator);
        try self.ensureStartupLocked(session);
        try session.pending.ensureUnusedCapacity(self.allocator, 1);
        session.pending.appendAssumeCapacity(delivery);
        session.notify();
    }

    fn hasWork(self: *const Registry, session: *const Session) bool {
        if (session.pending.items.len != 0) return true;
        return session == self.core and self.reports.pendingEndings() != 0;
    }

    fn callbackCount(self: *const Registry, session_id: u64) usize {
        var count: usize = 0;
        for (self.callbacks.items) |callback| count += @intFromBool(callback.session_id == session_id);
        return count;
    }

    fn hasCapacity(self: *Registry, session: *Session) bool {
        const active_count = if (session.state == .running) deliveryCount(session.state.running.deliveries.items) else 0;
        return deliveryCount(session.pending.items) + active_count < self.max_pending;
    }

    fn destroySession(self: *Registry, session: *Session) void {
        if (session.state == .running) session.state.running.destroy(self.allocator);
        for (session.pending.items) |delivery| delivery.destroy(self.allocator);
        session.pending.deinit(self.allocator);
        if (session.context) |*context| context.deinit();
        self.allocator.free(session.focus_id);
        self.allocator.destroy(session);
    }

    fn now(self: *Registry) i64 {
        return std.Io.Clock.real.now(self.io).toMilliseconds();
    }
};

fn deliveryCount(deliveries: []const *Delivery) usize {
    var count: usize = 0;
    for (deliveries) |delivery| switch (delivery.event) {
        .input, .assignment, .focus_message, .callback => count += 1,
        .startup, .activity, .subscription, .focus_interrupted => {},
    };
    return count;
}

fn hasStartup(deliveries: []const *Delivery) bool {
    for (deliveries) |delivery| if (delivery.event == .startup) return true;
    return false;
}

fn isInternal(event: Input.Event) bool {
    return switch (event) {
        .assignment, .focus_message, .focus_interrupted => true,
        .startup, .input, .callback, .subscription, .activity => false,
    };
}

fn lessActivity(_: void, left: []const u8, right: []const u8) bool {
    return (contracts.Reference.sequence(left) orelse unreachable) < (contracts.Reference.sequence(right) orelse unreachable);
}

fn lessSessionId(_: void, left: *Session, right: *Session) bool {
    return left.session_id < right.session_id;
}

fn assertWork(work: Work) void {
    std.debug.assert(work.session.state == .running and work.session.state.running == work.activation);
}

fn cloneSource(a: Allocator, source: contracts.Callback.Source) !contracts.Callback.Source {
    return switch (source) {
        .wakeup => .wakeup,
        .host => |host| .{ .host = .{ .command_id = try a.dupe(u8, host.command_id) } },
    };
}

fn freeSource(a: Allocator, source: contracts.Callback.Source) void {
    if (source == .host) a.free(source.host.command_id);
}

const TestStorage = struct {
    const Store = contracts.HistoryStore;
    groups: usize = 0,
    checkpoints: usize = 0,
    last_checkpoint: ?Store.Key = null,
    fail_save: bool = false,

    fn port(self: *TestStorage) Store {
        return .{
            .context = self,
            .vtable = &.{ .load = load, .allocateGroup = allocateGroup, .save = save, .query = query, .read = read, .create = create, .maintain = maintain },
        };
    }
    fn load(_: *anyopaque, _: Allocator) anyerror!?[]const u8 {
        return null;
    }
    fn allocateGroup(context: *anyopaque, a: Allocator) anyerror![]const u8 {
        const self: *TestStorage = @ptrCast(@alignCast(context));
        self.groups += 1;
        return std.fmt.allocPrint(a, "group-{d}", .{self.groups});
    }
    fn save(context: *anyopaque, body: []const u8) anyerror!void {
        const self: *TestStorage = @ptrCast(@alignCast(context));
        self.checkpoints += 1;
        self.last_checkpoint = @import("record_codec.zig").digest(body);
        if (self.fail_save) return error.UnconfirmedCheckpoint;
    }
    fn query(_: *anyopaque, _: Allocator, _: []const []const u8) anyerror![]const Store.Reference {
        return error.UnexpectedQuery;
    }
    fn read(_: *anyopaque, _: Allocator, _: []const Store.Reference) anyerror![]const []const u8 {
        return error.UnexpectedRead;
    }
    fn create(_: *anyopaque, _: Allocator, _: []const Store.Record) anyerror!void {}
    fn maintain(_: *anyopaque, _: Allocator, _: Store.Retention) anyerror!void {}
};

test "an interrupted activation retains its receipts and only fresh arrivals wake it" {
    var storage: TestStorage = .{};
    var subscriptions = try Subscriptions.Store.open(std.testing.allocator, ":memory:");
    defer subscriptions.close();
    var registry = try Registry.init(std.testing.allocator, std.testing.io, 2, 3, storage.port(), &subscriptions);
    defer registry.deinit();
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const first: Incoming = .{
        .receipt = "mail-1",
        .content = .{ .message = .{ .from = &.{"visitor"}, .text = "First", .observed_at_unix_ms = 10 } },
    };
    const second: Incoming = .{
        .receipt = "mail-2",
        .content = .{ .message = .{ .from = &.{"visitor"}, .text = "Second", .observed_at_unix_ms = 20 } },
    };
    try std.testing.expectEqual(Registry.Intake.accepted, try registry.accept(first));
    const initial = (try registry.takeReadyBatch(a))[0];
    try std.testing.expectEqual(Registry.Intake.accepted, try registry.accept(second));
    try registry.interrupt(initial, "An observation could not be admitted.");
    registry.endWorker(initial.session);

    // The second letter arrived while the old batch was in use.
    const resumed = (try registry.takeReadyBatch(a))[0];
    const held = resumed.activation.deliveries.items;
    try std.testing.expectEqual(3, held.len);
    try std.testing.expect(held[0].event == .startup);
    try std.testing.expectEqualStrings("mail-1", held[1].receipt.?);
    try std.testing.expectEqualStrings("mail-2", held[2].receipt.?);
    try registry.interrupt(resumed, "An observation could not be admitted.");
    registry.endWorker(resumed.session);

    try std.testing.expectEqual(Registry.Intake.deferred, try registry.accept(second));
    try std.testing.expectEqual(0, (try registry.takeReadyBatch(a)).len);
    var third = second;
    third.receipt = "mail-3";
    try std.testing.expectEqual(Registry.Intake.accepted, try registry.accept(third));
    const retry = (try registry.takeReadyBatch(a))[0];
    try std.testing.expectEqual(4, retry.activation.deliveries.items.len);
    registry.endWorker(retry.session);
}

/// Start the next ready focus and admit its single startup or assignment.
fn admitTestInput(registry: *Registry, a: Allocator) !struct { work: Work, history: Context } {
    const work = (try registry.takeReadyBatch(a))[0];
    const deliveries = work.activation.deliveries.items;
    try std.testing.expectEqual(1, deliveries.len);
    var history = try registry.snapshot(work.session);
    errdefer history.deinit();
    try history.appendRecord(.{ .events = .{ .focus_id = work.session.focus_id, .items = &.{deliveries[0].event} } });
    try registry.commitInput(work, 1, &history);
    registry.releaseDeliveries(work);
    return .{ .work = work, .history = history };
}

test "activity completion publishes once and maintenance republishes the same checkpoint after an unconfirmed save" {
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    for ([_]bool{ false, true }) |sleeping| {
        var storage: TestStorage = .{};
        var subscriptions = try Subscriptions.Store.open(std.testing.allocator, ":memory:");
        defer subscriptions.close();
        var registry = try Registry.init(std.testing.allocator, std.testing.io, 2, 3, storage.port(), &subscriptions);
        defer registry.deinit();
        var core = try admitTestInput(&registry, a);
        defer core.history.deinit();
        defer registry.endWorker(core.work.session);
        var plans: std.ArrayList(ForkPlan) = .empty;
        try plans.append(a, try registry.prepareFork(core.work, "research", "Read the notes."));
        try core.history.appendBatch(&.{.{ .continuation = "open_focus" }}, &.{.{
            .tool_result = .{ .call_id = "open", .content = .{ .parts = &.{} } },
        }});
        try registry.commitToolRound(core.work, &core.history, &plans);
        var activity = try admitTestInput(&registry, a);
        defer activity.history.deinit();
        const output: []const Model.Item = &.{.{ .continuation = "final response" }};
        if (sleeping) {
            _ = try registry.registerCallback(a, activity.work, "read", .{ .host = .{ .command_id = "read-1" } });
            storage.fail_save = true;
            try std.testing.expectError(error.UnconfirmedCheckpoint, registry.commitResponse(activity.work, &activity.history, output, "Read the notes."));
            registry.endWorker(activity.work.session);
            const unconfirmed = storage.last_checkpoint.?;
            storage.last_checkpoint = null;
            storage.fail_save = false;
            try registry.maintain();
            try std.testing.expectEqual(unconfirmed, storage.last_checkpoint.?);
        } else {
            defer registry.endWorker(activity.work.session);
            const before = storage.checkpoints;
            try std.testing.expect(try registry.commitResponse(activity.work, &activity.history, output, "Read the notes."));
            try std.testing.expectEqual(before + 1, storage.checkpoints);
        }
    }
}
