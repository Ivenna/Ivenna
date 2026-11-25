const std = @import("std");
const Context = @import("context.zig").Context;
const History = @import("history.zig").History;
const Persistence = @import("history.zig").Persistence;
const Subscriptions = @import("instance_state").subscriptions;
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
    /// Input usage from the latest committed ordinary inference in this epoch.
    last_input_tokens: ?u64 = null,
    /// A restored activity still needs its first observation of this runtime.
    needs_startup: bool = false,
    state: union(enum) {
        idle,
        running: *Activation,
        /// A report beyond this sequence counts as fresh input.
        interrupted: u64,
    } = .idle,
    pending: std.ArrayList(*Delivery) = .empty,
    borrowed_workers: usize = 0,
    subscription_through: u64 = 0,
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
    wakeups: std.AutoArrayHashMapUnmanaged(u64, History.Wakeup) = .empty,
    callbacks: std.ArrayList(History.CallbackRegistration) = .empty,
    /// Open channel registrations. The channel transport owns waiting readers.
    channels: std.ArrayList(History.Channel) = .empty,
    queued_callbacks: std.AutoHashMapUnmanaged(u64, void) = .empty,
    reserved_sessions: usize = 0,
    // Only withdrawal can remove the last reason for an already sleeping
    // activity to stay. On startup, reconcile withdrawals from the prior run.
    check_sleeping_activities: bool = true,
    next_session_id: u64 = 2,
    next_callback_id: u64 = 1,
    next_runtime_reference_id: u64 = 1,
    started_at_unix_ms: i64,

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        max_sessions: usize,
        max_pending: usize,
        history: contracts.HistoryStore,
        subscriptions: *Subscriptions.Store,
        correspondents: []const []const u8,
    ) !Registry {
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
        if (saved) |retained| {
            if (!std.mem.eql(u8, &retained.subscription_catalog, &self.subscription_catalog)) return error.SubscriptionCatalogMismatch;
            const reports = try Reports.Outbox.init(allocator, history, retained.activity_reports);
            self.reports.deinit();
            self.reports = reports;
            self.next_session_id = retained.next_session_id;
            self.next_callback_id = retained.next_callback_id;
            self.next_runtime_reference_id = retained.next_runtime_reference_id;
            for (retained.sessions) |record| {
                const session = try allocator.create(Session);
                session.* = .{
                    .session_id = record.session_id,
                    .role = record.role,
                    .epoch = record.epoch,
                    .subscription_through = record.subscription_through,
                    .needs_startup = record.role == .activity,
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
                var owned = wakeup;
                owned.text = if (wakeup.text) |text| try allocator.dupe(u8, text) else null;
                errdefer if (owned.text) |text| allocator.free(text);
                try self.wakeups.put(allocator, wakeup.id, owned);
            }
            for (retained.sessions) |record| {
                const session = self.sessions.get(record.session_id).?;
                if (record.was_running or record.observations.len != 0) try self.ensureActivityStartupLocked(session);
                for (record.observations) |event| {
                    const delivery = try Delivery.create(allocator, event, null);
                    errdefer delivery.destroy(allocator);
                    try session.pending.append(allocator, delivery);
                }
            }
            for (retained.channels) |record| {
                if (!self.hasFocusLocked(record.opened_by)) continue;
                try self.appendChannel(record);
            }
        } else {
            if (try subscriptions.isBound()) return error.SubscriptionCatalogMismatch;
            const core = try allocator.create(Session);
            core.* = .{ .session_id = 1, .role = .core };
            errdefer self.destroySession(core);
            core.focus_id = try allocator.dupe(u8, "core-1");
            core.context = try Context.init(allocator, .{ .session_id = 1, .epoch = 0 }, core.focus_id);
            try self.sessions.put(allocator, 1, core);
            self.core = core;
        }
        try self.queueStartupLocked(self.core, correspondents);
        try self.saveLocked();
        try subscriptions.markBound();
        // A prior checkpoint may have committed just before the process stopped.
        var restored = self.sessions.valueIterator();
        while (restored.next()) |entry| {
            const session = entry.*;
            if (session.subscription_through != 0) try subscriptions.acknowledge(session.focus_id, session.subscription_through);
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
        for (self.wakeups.values()) |wakeup| if (wakeup.text) |text| self.allocator.free(text);
        self.wakeups.deinit(self.allocator);
        for (self.callbacks.items) |callback| self.freeCallback(callback);
        self.callbacks.deinit(self.allocator);
        for (self.channels.items) |channel| self.freeChannel(channel);
        self.channels.deinit(self.allocator);
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
                    .scheduled_for_unix_ms = self.wakeupTimeLocked(callback.id),
                } } };
            },
        };
        if (incoming.receipt) |key| if (self.noticed.contains(key)) return .deferred;
        if (!self.hasCapacity(session)) return .deferred;
        const delivery = try Delivery.create(self.allocator, event, incoming.receipt);
        errdefer delivery.destroy(self.allocator);
        try session.pending.ensureUnusedCapacity(self.allocator, 1);
        const notice_key = if (incoming.receipt) |key| try self.allocator.dupe(u8, key) else null;
        errdefer if (notice_key) |key| self.allocator.free(key);
        if (incoming.content == .callback) {
            const id = incoming.content.callback.id;
            try self.queued_callbacks.put(self.allocator, id, {});
            delivery.admission = .{ .callback = id };
        }
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
        const sessions = try self.liveSessionsLocked(a);
        defer a.free(sessions);
        for (sessions) |session| {
            if (try self.takeReady(session)) |work| ready.appendAssumeCapacity(work);
        }
        self.check_sleeping_activities = false;
        return ready.toOwnedSlice(a);
    }

    /// Move arrivals into a new, initially unadmitted batch in this activation.
    pub fn collectPending(self: *Registry, work: Work) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        try self.collectLocked(work.session, work.activation, try self.subscriptions.latestSequence(work.session.focus_id));
    }

    fn collectLocked(self: *Registry, session: *Session, activation: *Activation, latest_report: u64) !void {
        const deliveries = &activation.deliveries;
        std.debug.assert(deliveries.items.len == 0);
        // Reports can be reread from their stores. Ordinary arrivals stay in
        // session.pending until the entire batch transfers to the activation.
        errdefer {
            _ = self.keepQueued(deliveries.items);
            deliveries.clearRetainingCapacity();
        }
        activation.subscription_at_collection = latest_report;
        activation.subscription_read_through = session.subscription_through;
        activation.activity_reports_read = 0;
        var ordinary = session.pending.items;
        if (ordinary.len != 0 and ordinary[0].event == .startup) {
            try deliveries.append(self.allocator, ordinary[0]);
            ordinary = ordinary[1..];
        }
        // Rotate which source receives the first part of a bounded input.
        // Each source preserves its own arrival order.
        var stream = session.first_stream;
        while (true) {
            switch (stream) {
                .ordinary => try deliveries.appendSlice(self.allocator, ordinary),
                .activity => if (session == self.core) try self.appendActivityReports(activation),
                .subscription => try self.appendSubscriptionReports(session.focus_id, activation),
            }
            stream = stream.next();
            if (stream == session.first_stream) break;
        }
        session.pending.clearRetainingCapacity();
        activation.admitted = deliveries.items.len == 0;
        activation.new_arrival = false;
    }

    /// Extend a batch that still fits by reading the next page from each report source.
    pub fn extendReports(self: *Registry, work: Work) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const activation = work.activation;
        std.debug.assert(!activation.admitted);
        const count = activation.deliveries.items.len;
        try self.appendSubscriptionReports(work.session.focus_id, activation);
        if (work.session == self.core) try self.appendActivityReports(activation);
        return activation.deliveries.items.len != count;
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
            if (delivery.admission == .callback) _ = self.queued_callbacks.remove(delivery.admission.callback);
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
        const deferred_all = count == 0 and deliveries.items.len != 0;
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
        if (session.epoch != history.scope.epoch) {
            session.epoch = history.scope.epoch;
            session.last_input_tokens = null;
        }
        work.activation.admitted = !deferred_all;
        for (deliveries.items) |delivery| {
            if (delivery.event == .startup) continue;
            session.first_stream = Stream.of(delivery.event).next();
            break;
        }
        const previous_through = session.subscription_through;
        for (deliveries.items) |delivery| switch (delivery.admission) {
            .none => {},
            .callback => |id| self.completeCallbackLocked(id),
            .subscription => |sequence| {
                std.debug.assert(sequence > session.subscription_through);
                session.subscription_through = sequence;
            },
        };
        try self.saveLocked();
        if (session.subscription_through != previous_through) try self.subscriptions.acknowledge(session.focus_id, session.subscription_through);
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
    pub fn commitToolRound(self: *Registry, work: Work, completed: *Context, plans: *std.ArrayList(ForkPlan), input_tokens: ?u64) !void {
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
        session.last_input_tokens = input_tokens;
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
            .next_runtime_reference_id = self.next_runtime_reference_id,
            .wakeups = self.wakeups.values(),
            .callbacks = self.callbacks.items,
            .sessions = retained.items,
            .channels = try self.restartableChannelsLocked(a),
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
        const activities: []const []const u8 = if (session == self.core) blk: {
            const live = try self.liveSessionsLocked(a);
            defer a.free(live);
            std.debug.assert(live[0] == self.core);
            const ids = try a.alloc([]const u8, live.len - 1);
            for (ids, live[1..]) |*id, activity| id.* = try a.dupe(u8, activity.focus_id);
            break :blk ids;
        } else &.{};
        var own_callbacks: std.ArrayList(Input.PendingCallback) = .empty;
        for (self.callbacks.items) |callback| if (callback.session_id == session.session_id) try own_callbacks.append(a, .{
            .callback_id = try a.dupe(u8, callback.reference),
            .source = try cloneSource(a, callback.source),
            .scheduled_for_unix_ms = self.wakeupTimeLocked(callback.id),
        });
        const subscriptions = try self.subscriptions.activeRegistrations(a, session.focus_id);
        const registrations = try a.alloc(Input.SampledSubscription, subscriptions.len);
        for (subscriptions, registrations) |subscription, *registration| registration.* = .{
            .subscription_id = subscription.subscription_id,
            .listener = subscription.listener,
        };
        return .{
            .current = try self.currentLocked(a, session),
            .state = .{
                .activities = activities,
                .callbacks = try own_callbacks.toOwnedSlice(a),
                .subscription_registrations = registrations,
            },
        };
    }

    fn liveSessionsLocked(self: *Registry, a: Allocator) ![]*Session {
        const live = try a.alloc(*Session, self.sessions.count());
        var sessions = self.sessions.valueIterator();
        for (live) |*session| session.* = sessions.next().?.*;
        std.mem.sort(*Session, live, {}, lessSessionId);
        return live;
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
    pub fn commitResponse(self: *Registry, work: Work, history: *Context, response: Model.Response) !bool {
        const observed_at = self.now();
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const session = work.session;
        const finished = !self.hasQueuedWork(session) and
            try self.subscriptions.latestSequence(session.focus_id) <= session.subscription_through;
        const completed_activity = finished and try self.canEnd(session);
        if (!completed_activity) try history.appendBatch(response.output, &.{});
        if (session != self.core) try self.reportResponseLocked(session, response.text, observed_at, completed_activity);
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
        session.last_input_tokens = response.input_tokens;
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
        // After admission the remaining suffix can resume work. A failed
        // admission waits for an arrival newer than the attempted batch.
        const resume_after = if (activation.admitted) session.subscription_through else activation.subscription_at_collection;
        const ready = activation.new_arrival or (activation.admitted and self.hasQueuedWork(session));
        session.pending.insertSliceAssumeCapacity(0, self.keepQueued(activation.deliveries.items));
        activation.deliveries.clearRetainingCapacity();
        session.state = if (ready) .idle else .{ .interrupted = resume_after };
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
        const registration = registered: {
            try self.wakeups.ensureUnusedCapacity(self.allocator, 1);
            const owned = try self.allocator.dupe(u8, text);
            errdefer self.allocator.free(owned);
            const callback = try self.registerCallbackLocked(work.session, name, .wakeup);
            self.wakeups.putAssumeCapacityNoClobber(callback.id, .{ .id = callback.id, .at_unix_ms = at, .text = owned });
            break :registered callback;
        };
        try self.saveLocked();
        return a.dupe(u8, registration.reference);
    }

    pub fn dueWakeups(self: *Registry, a: Allocator) ![]const contracts.Callback.Message {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var due: std.ArrayList(contracts.Callback.Message) = .empty;
        const observed_at = self.now();
        for (self.wakeups.values()) |wakeup| {
            if (wakeup.at_unix_ms > observed_at) continue;
            const text = wakeup.text orelse continue;
            try due.append(a, .{ .id = wakeup.id, .text = try a.dupe(u8, text) });
        }
        return due.toOwnedSlice(a);
    }

    /// Intake confirms a due wakeup's publication before polling for callbacks.
    pub fn markWakeupPublished(self: *Registry, id: u64) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const wakeup = self.wakeups.getPtr(id) orelse return; // An earlier publication was already admitted.
        self.allocator.free(wakeup.text.?);
        wakeup.text = null;
        try self.saveLocked();
    }

    pub fn issueRuntimeReference(self: *Registry, a: Allocator, work: Work, name: []const u8) ![]const u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const id = self.next_runtime_reference_id;
        const next = try std.math.add(u64, id, 1);
        const reference = try contracts.Reference.create(a, name, id);
        errdefer a.free(reference);
        self.next_runtime_reference_id = next;
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

    pub fn subscribe(self: *Registry, a: Allocator, work: Work, name: []const u8, listener: []const u8) !Subscriptions.Created {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        return self.subscriptions.create(a, work.session.focus_id, name, listener);
    }

    pub fn withdrawSubscription(self: *Registry, work: Work, reference: []const u8) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const changed = try self.subscriptions.withdraw(reference);
        if (changed) self.check_sleeping_activities = true;
        return changed;
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
        if (self.wakeups.fetchOrderedRemove(id)) |wakeup| {
            if (wakeup.value.text) |text| self.allocator.free(text);
        }
    }

    fn wakeupTimeLocked(self: *const Registry, id: u64) ?i64 {
        const wakeup = self.wakeups.get(id) orelse return null;
        return wakeup.at_unix_ms;
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

    /// Called after checking for work under the lock that guards withdrawal.
    /// Only an active subscription can accept a report after that check.
    fn canEnd(self: *Registry, session: *Session) !bool {
        if (session == self.core) return false;
        for (self.callbacks.items) |callback| if (callback.session_id == session.session_id) return false;
        return !try self.subscriptions.hasActive(session.focus_id);
    }

    fn takeReady(self: *Registry, session: *Session) !?Work {
        if (session.state == .running) return null;
        const latest_report = try self.subscriptions.latestSequence(session.focus_id);
        if (session.state == .interrupted) {
            if (latest_report <= session.state.interrupted) return null;
        } else if (!self.hasQueuedWork(session) and latest_report <= session.subscription_through) {
            if (self.check_sleeping_activities and try self.canEnd(session)) {
                try self.reportResponseLocked(session, null, self.now(), true);
                _ = self.sessions.remove(session.session_id);
                self.core.notify();
                if (session.borrowed_workers == 0) self.destroySession(session);
                try self.saveLocked();
            }
            return null;
        }
        try self.ensureActivityStartupLocked(session);
        try self.restoreContextLocked(session);
        const activation = try self.allocator.create(Activation);
        activation.* = .{};
        errdefer activation.destroy(self.allocator);
        try self.collectLocked(session, activation, latest_report);
        session.state = .{ .running = activation };
        session.borrowed_workers += 1;
        return .{ .session = session, .activation = activation };
    }

    fn appendSubscriptionReports(self: *Registry, focus_id: []const u8, activation: *Activation) !void {
        if (activation.subscription_read_through >= activation.subscription_at_collection) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const reports = try self.subscriptions.pending(arena.allocator(), focus_id, activation.subscription_read_through, activation.subscription_at_collection, report_read_batch);
        try activation.deliveries.ensureUnusedCapacity(self.allocator, reports.len);
        for (reports) |report| {
            const delivery = try Delivery.create(self.allocator, .{ .subscription = .{
                .subscription_id = report.reference,
                .text = report.text,
                .observed_at_unix_ms = report.observed_at_unix_ms,
                .source_time_unix_ms = report.source_time_unix_ms,
            } }, null);
            delivery.admission = .{ .subscription = report.sequence };
            activation.deliveries.appendAssumeCapacity(delivery);
            activation.subscription_read_through = report.sequence;
        }
    }

    fn appendActivityReports(self: *Registry, activation: *Activation) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const reports = try self.reports.peek(arena.allocator(), activation.activity_reports_read, report_read_batch);
        try activation.deliveries.ensureUnusedCapacity(self.allocator, reports.len);
        for (reports) |report| {
            const messages: []const Input.ActivityMessage = if (report.content == .assistant) &.{.{
                .text = report.content.assistant,
                .observed_at_unix_ms = report.observed_at_unix_ms,
            }} else &.{};
            activation.deliveries.appendAssumeCapacity(try Delivery.create(self.allocator, .{ .activity = .{
                .from_focus = report.from_focus,
                .messages = messages,
                .ended_at_unix_ms = if (report.content == .ended) report.observed_at_unix_ms else null,
            } }, null));
        }
        activation.activity_reports_read += reports.len;
    }

    fn restoreContextLocked(self: *Registry, session: *Session) !void {
        if (session.context != null) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const entries = try self.history.restoreEntries(arena.allocator(), session.session_id);
        session.context = try Context.restore(self.allocator, .{ .session_id = session.session_id, .epoch = session.epoch }, session.focus_id, entries);
    }

    fn ensureActivityStartupLocked(self: *Registry, session: *Session) !void {
        if (!session.needs_startup) return;
        try self.queueStartupLocked(session, null);
        session.needs_startup = false;
    }

    fn queueStartupLocked(self: *Registry, session: *Session, correspondents: ?[]const []const u8) !void {
        const delivery = try Delivery.create(self.allocator, .{ .startup = .{
            .observed_at_unix_ms = self.started_at_unix_ms,
            .correspondents = correspondents,
        } }, null);
        errdefer delivery.destroy(self.allocator);
        try session.pending.insert(self.allocator, 0, delivery);
    }

    fn enqueueLocked(self: *Registry, session: *Session, event: Input.Event) !void {
        const delivery = try Delivery.create(self.allocator, event, null);
        errdefer delivery.destroy(self.allocator);
        try session.pending.append(self.allocator, delivery);
        session.notify();
    }

    fn hasQueuedWork(self: *const Registry, session: *const Session) bool {
        return session.pending.items.len != 0 or (session == self.core and self.reports.pendingEndings() != 0);
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

    /// Publish registration before making the channel addressable.
    pub fn openChannel(self: *Registry, a: Allocator, work: Work, transport: contracts.Channels, name: []const u8, description: []const u8) ![]const u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const next = try std.math.add(u64, self.next_runtime_reference_id, 1);
        const id = try contracts.Reference.create(a, name, self.next_runtime_reference_id);
        errdefer a.free(id);
        try self.appendChannel(.{
            .id = id,
            .opened_by = work.session.focus_id,
            .opened_at_unix_ms = self.now(),
            .description = description,
        });
        self.next_runtime_reference_id = next;
        try self.saveLocked();
        try transport.open(id, work.session.focus_id, description);
        return id;
    }

    /// Confirm retirement before the transport ends waiting reads.
    pub fn closeChannel(self: *Registry, transport: contracts.Channels, id: []const u8) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        for (self.channels.items, 0..) |channel, index| {
            if (!std.mem.eql(u8, channel.id, id)) continue;
            self.freeChannel(self.channels.orderedRemove(index));
            try self.saveLocked();
            return transport.close(id);
        }
        return false;
    }

    /// Called during startup before the registry is shared with any worker.
    pub fn restoreChannels(self: *const Registry, transport: contracts.Channels) !void {
        for (self.channels.items) |channel| {
            try transport.open(channel.id, channel.opened_by, channel.description);
        }
    }

    fn restartableChannelsLocked(self: *Registry, a: Allocator) ![]const History.Channel {
        var restartable: std.ArrayList(History.Channel) = .empty;
        for (self.channels.items) |channel| {
            if (!self.hasFocusLocked(channel.opened_by)) continue;
            try restartable.append(a, channel);
        }
        return restartable.items;
    }

    fn hasFocusLocked(self: *Registry, focus_id: []const u8) bool {
        const id = contracts.Reference.sequence(focus_id) orelse return false;
        const session = self.sessions.get(id) orelse return false;
        return std.mem.eql(u8, session.focus_id, focus_id);
    }

    fn appendChannel(self: *Registry, channel: History.Channel) !void {
        var owned = channel;
        owned.id = try self.allocator.dupe(u8, channel.id);
        errdefer self.allocator.free(owned.id);
        owned.opened_by = try self.allocator.dupe(u8, channel.opened_by);
        errdefer self.allocator.free(owned.opened_by);
        owned.description = if (channel.description) |text| try self.allocator.dupe(u8, text) else null;
        errdefer if (owned.description) |text| self.allocator.free(text);
        try self.channels.append(self.allocator, owned);
    }

    fn freeChannel(self: *Registry, channel: History.Channel) void {
        self.allocator.free(channel.id);
        self.allocator.free(channel.opened_by);
        if (channel.description) |text| self.allocator.free(text);
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

const TestStore = @import("test_history.zig").TestStore;

test "an interrupted activation retains its receipts and only fresh arrivals wake it" {
    var storage: TestStore = .{};
    defer storage.arena.deinit();
    var subscriptions = try Subscriptions.Store.openInMemory(std.testing.allocator);
    defer subscriptions.close();
    var registry = try Registry.init(std.testing.allocator, std.testing.io, 2, 3, storage.port(), &subscriptions, &.{});
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

test "a wakeup retains its scheduled time after publication and restart" {
    const testing = std.testing;
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var storage: TestStore = .{};
    defer storage.arena.deinit();
    var subscriptions = try Subscriptions.Store.openInMemory(testing.allocator);
    defer subscriptions.close();

    const scheduled_for = 1_000;
    const observed_at = 61_000;
    const text = "Return to the plan.";
    const published = scheduled: {
        var registry = try Registry.init(testing.allocator, testing.io, 2, 3, storage.port(), &subscriptions, &.{});
        defer registry.deinit();
        var core = try admitTestInput(&registry, a);
        defer core.history.deinit();
        defer registry.endWorker(core.work.session);
        const callback_id = try registry.scheduleWakeup(a, core.work, "revisit", scheduled_for, text);
        const due = try registry.dueWakeups(a);
        try testing.expectEqual(1, due.len);
        try registry.markWakeupPublished(due[0].id);
        break :scheduled .{ .callback_id = callback_id, .message = due[0] };
    };

    var registry = try Registry.init(testing.allocator, testing.io, 2, 3, storage.port(), &subscriptions, &.{});
    defer registry.deinit();
    try testing.expectEqual(0, (try registry.dueWakeups(a)).len);
    const snapshot = try registry.compactionSnapshot(a, registry.core);
    try testing.expectEqual(1, snapshot.state.callbacks.len);
    try testing.expectEqualStrings(published.callback_id, snapshot.state.callbacks[0].callback_id);
    try testing.expectEqual(scheduled_for, snapshot.state.callbacks[0].scheduled_for_unix_ms.?);

    var core = try admitTestInput(&registry, a);
    defer core.history.deinit();
    defer registry.endWorker(core.work.session);
    try testing.expectEqual(.accepted, try registry.accept(.{ .content = .{ .callback = .{
        .id = published.message.id,
        .text = published.message.text,
        .observed_at_unix_ms = observed_at,
    } } }));
    try registry.collectPending(core.work);
    const deliveries = core.work.activation.deliveries.items;
    try testing.expectEqual(1, deliveries.len);
    try core.history.appendRecord(.{ .events = .{ .focus_id = core.work.session.focus_id, .items = &.{deliveries[0].event} } });
    try registry.commitInput(core.work, deliveries.len, &core.history);
    const observation = core.history.records()[core.history.records().len - 1].record.events.items[0].callback;
    try testing.expectEqual(scheduled_for, observation.scheduled_for_unix_ms.?);
    try testing.expectEqual(observed_at, observation.observed_at_unix_ms);
    try testing.expectEqualStrings(text, observation.text);
    try testing.expectEqual(0, (try registry.compactionSnapshot(a, registry.core)).state.callbacks.len);
}

test "compaction samples the active subscriptions addressed to this focus" {
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var storage: TestStore = .{};
    defer storage.arena.deinit();
    var subscriptions = try Subscriptions.Store.openInMemory(std.testing.allocator);
    defer subscriptions.close();
    var registry = try Registry.init(std.testing.allocator, std.testing.io, 2, 3, storage.port(), &subscriptions, &.{});
    defer registry.deinit();
    var core = try admitTestInput(&registry, a);
    defer core.history.deinit();
    defer registry.endWorker(core.work.session);
    const core_watch = try registry.subscribe(a, core.work, "releases", "Release feed");
    var plans: std.ArrayList(ForkPlan) = .empty;
    try plans.append(a, try registry.prepareFork(core.work, "research", "Follow revisions."));
    try registry.commitToolRound(core.work, &core.history, &plans, null);
    var activity = try admitTestInput(&registry, a);
    defer activity.history.deinit();
    defer registry.endWorker(activity.work.session);
    const activity_watch = try registry.subscribe(a, activity.work, "edits", "Document edits");
    const withdrawn = try registry.subscribe(a, activity.work, "previous", "Previous publisher");
    try std.testing.expect(try registry.withdrawSubscription(core.work, withdrawn.subscription_id));

    const core_sample = try registry.compactionSnapshot(a, core.work.session);
    try std.testing.expectEqualDeep(@as([]const Input.SampledSubscription, &.{.{
        .subscription_id = core_watch.subscription_id,
        .listener = "Release feed",
    }}), core_sample.state.subscription_registrations);
    const activity_sample = try registry.compactionSnapshot(a, activity.work.session);
    try std.testing.expectEqualDeep(@as([]const Input.SampledSubscription, &.{.{
        .subscription_id = activity_watch.subscription_id,
        .listener = "Document edits",
    }}), activity_sample.state.subscription_registrations);
}

test "activity completion publishes once and maintenance republishes the same checkpoint after an unconfirmed save" {
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    for ([_]bool{ false, true }) |sleeping| {
        var storage: TestStore = .{};
        defer storage.arena.deinit();
        var subscriptions = try Subscriptions.Store.openInMemory(std.testing.allocator);
        defer subscriptions.close();
        var registry = try Registry.init(std.testing.allocator, std.testing.io, 2, 3, storage.port(), &subscriptions, &.{});
        defer registry.deinit();
        var core = try admitTestInput(&registry, a);
        defer core.history.deinit();
        defer registry.endWorker(core.work.session);
        var plans: std.ArrayList(ForkPlan) = .empty;
        try plans.append(a, try registry.prepareFork(core.work, "research", "Read the notes."));
        try core.history.appendBatch(&.{.{ .continuation = "open_focus" }}, &.{.{
            .tool_result = .{ .call_id = "open", .content = .{ .parts = &.{} } },
        }});
        try registry.commitToolRound(core.work, &core.history, &plans, null);
        var activity = try admitTestInput(&registry, a);
        defer activity.history.deinit();
        const response: Model.Response = .{ .output = &.{.{ .continuation = "final response" }}, .calls = &.{}, .text = "Read the notes." };
        if (sleeping) {
            _ = try registry.registerCallback(a, activity.work, "read", .{ .host = .{ .command_id = "read-1" } });
            storage.fail_save = .after_commit;
            try std.testing.expectError(error.UnconfirmedCheckpoint, registry.commitResponse(activity.work, &activity.history, response));
            registry.endWorker(activity.work.session);
            const unconfirmed = storage.checkpoint.?;
            const before = storage.saves;
            storage.fail_save = .none;
            try registry.maintain();
            try std.testing.expectEqual(before + 1, storage.saves);
            try std.testing.expectEqualStrings(unconfirmed, storage.checkpoint.?);
        } else {
            defer registry.endWorker(activity.work.session);
            const before = storage.saves;
            try std.testing.expect(try registry.commitResponse(activity.work, &activity.history, response));
            try std.testing.expectEqual(before + 1, storage.saves);
        }
    }
}
