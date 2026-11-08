const std = @import("std");
const Context = @import("context.zig").Context;
const History = @import("history.zig").History;
const Persistence = @import("history.zig").Persistence;
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

/// Identity, working context, and pending observations for one session.
pub const Session = struct {
    session_id: u64,
    focus_id: []const u8 = &.{},
    role: Input.Role,
    epoch: u64 = 0,
    context: ?Context = null,
    needs_startup: bool = false,
    active: ?*Activation = null,
    pending: std.ArrayList(*Delivery) = .empty,
    borrowed_workers: usize = 0,
};

pub const Work = struct { session: *Session, activation: *Activation };
pub const ForkPlan = struct { session: *Session };

/// Current model input projected for admission candidates.
pub const Snapshot = struct {
    current: Input.Current,

    /// Project the registry effects of admitting a prefix, without changing
    /// this snapshot. Each candidate owns its arrays.
    pub fn afterAdmission(self: Snapshot, a: Allocator, events: []const Input.Event, count: usize) !Input.Current {
        std.debug.assert(count > 0 and count <= events.len);
        var current = self.current;
        var remaining: usize = 0;
        for (events[count..]) |event| remaining += @intFromBool(isInput(event));
        const directory = try a.dupe(Input.FocusInfo, self.current.focuses);
        current.focuses = directory;

        var callbacks: std.ArrayList(Input.PendingCallback) = .empty;
        for (self.current.callbacks) |callback| {
            const admitted = for (events[0..count]) |event| {
                if (event == .callback and std.mem.eql(u8, event.callback.callback_id, callback.callback_id)) break true;
            } else false;
            if (!admitted) try callbacks.append(a, callback);
        }
        current.callbacks = try callbacks.toOwnedSlice(a);
        for (directory) |*session| if (std.mem.eql(u8, session.focus_id, current.focus_id)) {
            session.queued_inputs += remaining;
            session.pending_callbacks = current.callbacks.len;
            break;
        };
        return current;
    }
};

pub const Registry = struct {
    allocator: Allocator,
    io: std.Io,
    max_sessions: usize,
    max_pending: usize,
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
    started_at_unix_ms: i64,

    pub fn init(allocator: Allocator, io: std.Io, max_sessions: usize, max_pending: usize, history: contracts.HistoryStore) !Registry {
        var self: Registry = .{
            .allocator = allocator,
            .io = io,
            .max_sessions = max_sessions,
            .max_pending = max_pending,
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
            const reports = try Reports.Outbox.init(allocator, history, retained.activity_reports);
            self.reports.deinit();
            self.reports = reports;
            self.next_session_id = retained.next_session_id;
            self.next_callback_id = retained.next_callback_id;
            for (retained.sessions) |record| {
                const session = try allocator.create(Session);
                session.* = .{
                    .session_id = record.session_id,
                    .role = record.role,
                    .epoch = record.epoch,
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
    pub fn collectPending(self: *Registry, work: Work) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        std.debug.assert(work.activation.deliveries.items.len == 0);
        const reports = try self.reportDeliveriesLocked(work.session);
        defer self.allocator.free(reports);
        errdefer for (reports) |report| report.destroy(self.allocator);
        const count = work.session.pending.items.len + reports.len;
        if (count == 0) return false;
        try work.activation.deliveries.ensureUnusedCapacity(self.allocator, count);
        work.activation.deliveries.appendSliceAssumeCapacity(work.session.pending.items);
        work.activation.deliveries.appendSliceAssumeCapacity(reports);
        work.session.pending.clearRetainingCapacity();
        work.activation.admitted = false;
        return true;
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

    pub fn admitEvents(self: *Registry, work: Work, count: usize, context: Context) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const session = work.session;
        const deliveries = &work.activation.deliveries;
        std.debug.assert(count != 0 and count <= deliveries.items.len);
        const suffix = deliveries.items[count..];
        var report_count: usize = 0;
        var endings: usize = 0;
        for (deliveries.items[0..count]) |delivery| if (delivery.event == .activity) {
            report_count += 1;
            endings += @intFromBool(delivery.event.activity.ended_at_unix_ms != null);
        };
        try session.pending.ensureUnusedCapacity(self.allocator, suffix.len);
        if (report_count != 0) try self.reports.consume(report_count, endings);
        session.pending.insertSliceAssumeCapacity(0, suffix);
        deliveries.items.len = count;
        if (session.context) |*previous| previous.deinit();
        session.context = context;
        session.epoch = context.scope.epoch;
        work.activation.admitted = true;
        for (deliveries.items) |delivery| if (delivery.callback_id) |id| {
            self.completeCallbackLocked(id);
        };
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

    /// Failure leaves every unpublished plan with its caller for abandonFork,
    /// including any independent contexts already prepared for publication.
    pub fn commitRound(self: *Registry, work: Work, output: []const Model.Item, replies: []const Model.Item, plans: []const ForkPlan) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const session = work.session;
        var completed = try session.context.?.clone(self.allocator);
        errdefer completed.deinit();
        try completed.appendBatch(output, replies);
        for (plans) |plan| {
            plan.session.context = try completed.clone(self.allocator);
            plan.session.context.?.scope = .{ .session_id = plan.session.session_id, .epoch = 0 };
            plan.session.context.?.focus_id = try plan.session.context.?.arena.allocator().dupe(u8, plan.session.focus_id);
        }
        try self.sessions.ensureUnusedCapacity(self.allocator, @intCast(plans.len));
        session.context.?.deinit();
        session.context = completed;
        for (plans) |plan| {
            self.sessions.putAssumeCapacity(plan.session.session_id, plan.session);
            self.reserved_sessions -= 1;
        }
    }

    pub fn snapshot(self: *Registry, session: *Session) !Context {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.restoreContextLocked(session);
        return session.context.?.clone(self.allocator);
    }

    /// Retain newly emitted activity text without scheduling the core.
    pub fn recordAssistant(self: *Registry, work: Work, text: ?[]const u8) !void {
        if (work.session == self.core or text == null) return;
        const observed_at = self.now();
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        try self.reports.append(.{
            .from_focus = work.session.focus_id,
            .observed_at_unix_ms = observed_at,
            .content = .{ .assistant = text.? },
        });
        try self.saveLocked();
    }

    pub fn save(self: *Registry) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
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
            if (session.active) |activation| if (!activation.admitted) {
                for (activation.deliveries.items) |delivery| if (isInternal(delivery.event)) try observations.append(a, delivery.event);
            };
            for (session.pending.items) |delivery| if (isInternal(delivery.event)) try observations.append(a, delivery.event);
            try retained.append(a, .{
                .session_id = session.session_id,
                .focus_id = session.focus_id,
                .role = session.role,
                .epoch = session.epoch,
                .was_running = session.active != null or hasStartup(session.pending.items),
                .entries = if (session.context) |*context| context.records() else null,
                .observations = observations.items,
            });
        }
        try self.history.save(a, .{
            .next_session_id = self.next_session_id,
            .next_callback_id = self.next_callback_id,
            .wakeups = self.wakeups.items,
            .callbacks = self.callbacks.items,
            .sessions = retained.items,
            .activity_reports = self.reports.checkpoint(),
        });
    }

    pub fn replaceContext(self: *Registry, session: *Session, replacement: Context) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (session.context) |*previous| previous.deinit();
        session.context = replacement;
        session.epoch = replacement.scope.epoch;
    }

    pub fn runtimeSnapshot(self: *Registry, a: Allocator, session: *Session) !Snapshot {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const directory = try a.alloc(Input.FocusInfo, self.sessions.count());
        var sessions = self.sessions.valueIterator();
        for (directory) |*info| info.* = self.sessionInfoLocked(sessions.next().?.*);
        std.mem.sort(Input.FocusInfo, directory, {}, lessFocus);
        var own_callbacks: std.ArrayList(Input.PendingCallback) = .empty;
        for (self.callbacks.items) |callback| if (callback.session_id == session.session_id) try own_callbacks.append(a, .{
            .callback_id = try a.dupe(u8, callback.reference),
            .source = try cloneSource(a, callback.source),
        });
        // Snapshot strings outlive mutations and removal of their source sessions.
        for (directory) |*info| info.focus_id = try a.dupe(u8, info.focus_id);
        return .{ .current = .{
            .focus_id = try a.dupe(u8, session.focus_id),
            .role = session.role,
            .observed_at_unix_ms = self.now(),
            .callbacks = try own_callbacks.toOwnedSlice(a),
            .focuses = directory,
        } };
    }

    /// Finalize a response without tool calls when no queued input requires
    /// another round. Callback checks, reporting, and session retirement share
    /// the same lock.
    pub fn finish(self: *Registry, work: Work) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const session = work.session;
        if (self.hasWork(session)) return false;
        const completed_activity = session != self.core and self.callbackCount(session.session_id) == 0;
        const finished_at = self.now();
        if (completed_activity) try self.recordCompletionLocked(session, finished_at);
        session.active = null;
        work.activation.destroy(self.allocator);
        if (completed_activity) {
            const removed = self.sessions.remove(session.session_id);
            std.debug.assert(removed);
        }
        return true;
    }

    /// Release a worker borrow after saving. Waiting contexts can be unloaded;
    /// completed sessions can be destroyed once no worker retains them.
    pub fn endWorker(self: *Registry, session: *Session) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        session.borrowed_workers -= 1;
        if (session.borrowed_workers != 0) return;
        if (!self.sessions.contains(session.session_id)) {
            self.destroySession(session);
        } else if (session != self.core and session.active == null) {
            if (session.context) |*context| context.deinit();
            session.context = null;
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

    pub fn registerCallback(self: *Registry, a: Allocator, work: Work, name: []const u8, source: contracts.Callback.Source) !contracts.Callback.Registration {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const registration = try self.registerCallbackLocked(work.session, name, source);
        try self.saveLocked();
        return .{ .id = registration.id, .reference = try a.dupe(u8, registration.reference) };
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

    fn recordCompletionLocked(self: *Registry, session: *Session, ended_at: i64) !void {
        try self.ensureStartupLocked(self.core);
        try self.reports.append(.{
            .from_focus = session.focus_id,
            .observed_at_unix_ms = ended_at,
            .content = .ended,
        });
    }

    fn takeReady(self: *Registry, session: *Session) !?Work {
        if (session.active != null or !self.hasWork(session)) return null;
        try self.restoreContextLocked(session);
        const reports = try self.reportDeliveriesLocked(session);
        defer self.allocator.free(reports);
        errdefer for (reports) |report| report.destroy(self.allocator);
        var deliveries: std.ArrayList(*Delivery) = .empty;
        defer deliveries.deinit(self.allocator);
        try deliveries.appendSlice(self.allocator, session.pending.items);
        try deliveries.appendSlice(self.allocator, reports);
        const activation = try Activation.create(self.allocator, deliveries.items);
        activation.admitted = deliveries.items.len == 0;
        session.pending.clearRetainingCapacity();
        session.active = activation;
        session.borrowed_workers += 1;
        return .{ .session = session, .activation = activation };
    }

    fn reportDeliveriesLocked(self: *Registry, session: *Session) ![]*Delivery {
        if (session != self.core) return self.allocator.alloc(*Delivery, 0);
        for (session.pending.items) |delivery| if (delivery.event == .activity) return self.allocator.alloc(*Delivery, 0);
        return self.readReportDeliveriesLocked(0);
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
        try session.pending.insert(self.allocator, 0, delivery);
        session.needs_startup = false;
    }

    fn enqueueLocked(self: *Registry, session: *Session, event: Input.Event) !void {
        const delivery = try Delivery.create(self.allocator, event, null);
        errdefer delivery.destroy(self.allocator);
        try self.ensureStartupLocked(session);
        try session.pending.ensureUnusedCapacity(self.allocator, 1);
        session.pending.appendAssumeCapacity(delivery);
    }

    fn hasWork(self: *const Registry, session: *const Session) bool {
        for (session.pending.items) |delivery| if (delivery.event != .activity) return true;
        return session == self.core and self.reports.pendingEndings() != 0;
    }

    fn callbackCount(self: *const Registry, session_id: u64) usize {
        var count: usize = 0;
        for (self.callbacks.items) |callback| count += @intFromBool(callback.session_id == session_id);
        return count;
    }

    pub fn setToolWait(self: *Registry, work: Work, waiting: bool) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        if (work.activation.waiting_for_tools == waiting) return;
        work.activation.waiting_for_tools = waiting;
    }

    fn sessionInfoLocked(self: *Registry, session: *Session) Input.FocusInfo {
        var endings: usize = 0;
        if (session == self.core) {
            endings = self.reports.pendingEndings();
            if (session.active) |activation| if (!activation.admitted) {
                for (activation.deliveries.items) |delivery| if (delivery.event == .activity and delivery.event.activity.ended_at_unix_ms != null) {
                    endings -= 1;
                };
            };
        }
        return .{
            .focus_id = session.focus_id,
            .role = session.role,
            .status = if (session.active) |activation| (if (activation.waiting_for_tools) .waiting_for_tools else .running) else if (self.hasWork(session)) .ready else .dormant,
            .queued_inputs = queuedOrdinary(session.pending.items) + endings,
            .pending_callbacks = self.callbackCount(session.session_id),
        };
    }

    fn hasCapacity(self: *Registry, session: *Session) bool {
        const active_count = if (session.active) |activation| deliveryCount(activation.deliveries.items) else 0;
        return deliveryCount(session.pending.items) + active_count < self.max_pending;
    }

    fn destroySession(self: *Registry, session: *Session) void {
        if (session.active) |activation| activation.destroy(self.allocator);
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
    for (deliveries) |delivery| count += @intFromBool(delivery.event != .startup and delivery.event != .activity);
    return count;
}

fn queuedOrdinary(deliveries: []const *Delivery) usize {
    var count: usize = 0;
    for (deliveries) |delivery| count += @intFromBool(delivery.event != .activity);
    return count;
}

fn isInput(event: Input.Event) bool {
    return switch (event) {
        .activity => |report| report.ended_at_unix_ms != null,
        else => true,
    };
}

fn hasStartup(deliveries: []const *Delivery) bool {
    for (deliveries) |delivery| if (delivery.event == .startup) return true;
    return false;
}

fn isInternal(event: Input.Event) bool {
    return switch (event) {
        .assignment, .focus_message => true,
        .startup, .input, .callback, .activity => false,
    };
}

fn lessFocus(_: void, left: Input.FocusInfo, right: Input.FocusInfo) bool {
    return (contracts.Reference.sequence(left.focus_id) orelse unreachable) < (contracts.Reference.sequence(right.focus_id) orelse unreachable);
}

fn lessSessionId(_: void, left: *Session, right: *Session) bool {
    return left.session_id < right.session_id;
}

fn assertWork(work: Work) void {
    std.debug.assert(work.session.active == work.activation);
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
