const std = @import("std");
const Context = @import("context.zig").Context;
const History = @import("history.zig").History;
const Persistence = @import("history.zig").Persistence;
const Input = @import("input.zig");
const WorkInput = @import("work.zig");
const Delivery = WorkInput.Delivery;
const Activation = WorkInput.Activation;
const Allocator = std.mem.Allocator;
const contracts = @import("agent_contracts");
const Model = contracts.Model;
const Incoming = contracts.Inbox.Incoming;

/// Identity and saved understanding outlive execution. Dormant contexts can be
/// unloaded after publication and restored when another observation arrives.
pub const Session = struct {
    session_id: u64,
    role: Input.Role,
    epoch: u64 = 0,
    context: ?Context = null,
    last_active_unix_ms: i64 = 0,
    needs_startup: bool = false,
    active: ?*Activation = null,
    pending: std.ArrayList(*Delivery) = .empty,
    borrowed_workers: usize = 0,
    children: usize = 0,
    /// Capacity reserved for direct children's next reports.
    return_slots: usize = 0,
    return_reserved: bool = false,
    core_return_reserved: bool = false,
};

pub const Work = struct { session: *Session, activation: *Activation };
pub const ForkRequest = struct { task: []const u8 };
pub const ForkPlan = struct { child: *Session, created: ?*Delivery, core_slot_from_caller: bool };
pub const Commit = enum { continuing, forked };

/// Current model input and the internal attention generation captured with it.
/// Measuring or summarizing this snapshot does not consume the generation.
pub const Snapshot = struct {
    current: Input.Current,
    attention_revision: u64,

    /// Project the registry effects of admitting a prefix, without changing
    /// this snapshot or consuming attention. Each candidate owns its arrays.
    pub fn afterAdmission(self: Snapshot, a: Allocator, events: []const Input.Event, count: usize) !Input.Current {
        std.debug.assert(count > 0 and count <= events.len);
        var current = self.current;
        const remaining = events.len - count;
        current.state.runtime.queued_inputs += remaining;
        const directory = try a.dupe(Input.SessionInfo, self.current.state.runtime.sessions);
        current.state.runtime.sessions = directory;

        var callbacks: std.ArrayList(Input.PendingCallback) = .empty;
        for (self.current.state.session.callbacks) |callback| {
            const admitted = for (events[0..count]) |event| {
                if (event == .callback and event.callback.id == callback.id) break true;
            } else false;
            if (!admitted) try callbacks.append(a, callback);
        }
        current.state.session.callbacks = try callbacks.toOwnedSlice(a);
        for (directory) |*session| if (session.session_id == current.session_id) {
            session.queued_inputs += remaining;
            session.pending_callbacks = current.state.session.callbacks.len;
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
    max_callbacks: usize,
    history: Persistence,
    mutex: std.Io.Mutex = .init,
    core: *Session,
    sessions: std.AutoHashMapUnmanaged(u64, *Session) = .empty,
    noticed: std.StringHashMapUnmanaged(enum { scheduled, acknowledged }) = .empty,
    wakeups: std.ArrayList(History.Wakeup) = .empty,
    callbacks: std.ArrayList(Input.PendingCallback) = .empty,
    queued_callbacks: std.AutoHashMapUnmanaged(u64, void) = .empty,
    reserved: usize = 0,
    next_session_id: u64 = 2,
    next_callback_id: u64 = 1,
    last_dispatched_id: u64 = 0,
    attention_revision: u64 = 0,
    observed_revision: u64 = 0,
    started_at_unix_ms: i64,

    pub fn init(allocator: Allocator, io: std.Io, max_sessions: usize, max_pending: usize, max_callbacks: usize, history: contracts.HistoryStore) !Registry {
        var self: Registry = .{
            .allocator = allocator,
            .io = io,
            .max_sessions = max_sessions,
            .max_pending = max_pending,
            .max_callbacks = max_callbacks,
            .history = .init(allocator, history),
            .core = undefined,
            .started_at_unix_ms = std.Io.Clock.real.now(io).toMilliseconds(),
        };
        errdefer self.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const saved = try self.history.load(a, max_sessions);
        if (saved) |retained| {
            self.next_session_id = retained.next_session_id;
            self.next_callback_id = retained.next_callback_id;
            for (retained.sessions) |record| {
                const session = try allocator.create(Session);
                session.* = .{
                    .session_id = record.session_id,
                    .role = record.role,
                    .epoch = record.epoch,
                    .last_active_unix_ms = record.last_active_unix_ms,
                    .needs_startup = true,
                };
                errdefer self.destroySession(session);
                if (record.role == .core) {
                    session.context = try Context.restore(allocator, .{ .session_id = record.session_id, .epoch = record.epoch }, record.entries orelse return error.InvalidHistory, @embedFile("system.md"));
                }
                try self.sessions.put(allocator, session.session_id, session);
            }
            self.core = self.sessions.get(1).?;
            try self.callbacks.appendSlice(allocator, retained.callbacks);
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
                if (record.role.parentSessionId()) |parent_id| self.sessions.get(parent_id).?.children += 1;
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
            core.context = try Context.init(allocator, .{ .session_id = 1, .epoch = 0 }, @embedFile("system.md"));
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
        self.callbacks.deinit(self.allocator);
        self.queued_callbacks.deinit(self.allocator);
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
                    .id = callback.id,
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
        try self.ensureStartupLocked(session);
        try session.pending.ensureUnusedCapacity(self.allocator, 1 + session.return_slots);
        self.changedLocked(session);
        const notice_key = if (incoming.receipt) |key| try self.allocator.dupe(u8, key) else null;
        errdefer if (notice_key) |key| self.allocator.free(key);
        if (event == .callback) try self.queued_callbacks.put(self.allocator, event.callback.id, {});
        if (notice_key) |key| try self.noticed.put(self.allocator, key, .scheduled);
        session.pending.appendAssumeCapacity(delivery);
        return .accepted;
    }

    pub fn takeReadyBatch(self: *Registry, a: Allocator, max_parallel: usize) ![]const Work {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var ready: std.ArrayList(Work) = .empty;
        defer ready.deinit(a);
        errdefer for (ready.items) |work| {
            work.session.borrowed_workers -= 1;
        };
        var available = max_parallel -| self.runningWorkers();
        try ready.ensureTotalCapacity(a, 1 + @min(available, self.sessions.count() - 1));
        if (try self.takeReady(self.core)) |work| ready.appendAssumeCapacity(work);
        const branches = try a.alloc(*Session, self.sessions.count() - 1);
        defer a.free(branches);
        var sessions = self.sessions.valueIterator();
        var count: usize = 0;
        while (sessions.next()) |entry| if (entry.* != self.core) {
            branches[count] = entry.*;
            count += 1;
        };
        std.mem.sort(*Session, branches, {}, lessSessionId);
        var start: usize = 0;
        while (start < branches.len and branches[start].session_id <= self.last_dispatched_id) start += 1;
        if (start == branches.len) start = 0;
        for (0..branches.len) |offset| {
            if (available == 0) break;
            const session = branches[(start + offset) % branches.len];
            if (try self.takeReady(session)) |work| {
                ready.appendAssumeCapacity(work);
                available -= 1;
                self.last_dispatched_id = session.session_id;
            }
        }
        return ready.toOwnedSlice(a);
    }

    /// Move arrivals into a new, initially unadmitted batch in this activation.
    pub fn collectPending(self: *Registry, work: Work) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        std.debug.assert(work.activation.deliveries.items.len == 0);
        if (work.session.pending.items.len == 0) return false;
        try work.activation.deliveries.appendSlice(self.allocator, work.session.pending.items);
        work.session.pending.clearRetainingCapacity();
        work.activation.admitted = false;
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
            if (delivery.event == .callback) _ = self.queued_callbacks.remove(delivery.event.callback.id);
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
        try session.pending.ensureUnusedCapacity(self.allocator, suffix.len + session.return_slots);
        session.pending.insertSliceAssumeCapacity(0, suffix);
        deliveries.items.len = count;
        if (session.context) |*previous| previous.deinit();
        session.context = context;
        session.epoch = context.scope.epoch;
        work.activation.admitted = true;
        for (deliveries.items) |delivery| if (delivery.event == .callback) {
            self.completeCallbackLocked(delivery.event.callback.id);
        };
    }

    pub fn prepareFork(self: *Registry, work: Work, request: ForkRequest) !ForkPlan {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        if (request.task.len == 0) return error.InvalidForkArguments;
        if (self.sessions.count() + self.reserved >= self.max_sessions) return error.SessionCapacityUnavailable;
        const reuse_core_slot = work.session != self.core and (work.session.core_return_reserved or
            (work.session.return_reserved and work.session.role.parentSessionId().? == self.core.session_id));
        if (!self.hasCapacity(work.session) or
            (work.session != self.core and !reuse_core_slot and !self.hasCapacity(self.core))) return error.SessionQueueFull;
        try work.session.pending.ensureUnusedCapacity(self.allocator, work.session.return_slots + 1);
        if (work.session != self.core) try self.core.pending.ensureUnusedCapacity(self.allocator, self.core.return_slots + 1);
        const child = try self.allocator.create(Session);
        child.* = .{
            .session_id = self.next_session_id,
            .role = .{ .branch = .{ .parent_session_id = work.session.session_id } },
            .return_reserved = true,
            .core_return_reserved = work.session != self.core and !reuse_core_slot,
        };
        errdefer self.destroySession(child);
        const assignment = try Delivery.create(self.allocator, .{ .assignment = .{ .task = request.task, .from_session = work.session.session_id } }, null);
        errdefer assignment.destroy(self.allocator);
        const created = if (work.session != self.core)
            try Delivery.create(self.allocator, .{ .session_created = .{
                .session_id = child.session_id,
                .parent_session_id = work.session.session_id,
                .task = request.task,
            } }, null)
        else
            null;
        errdefer if (created) |delivery| delivery.destroy(self.allocator);
        try child.pending.append(self.allocator, assignment);
        self.next_session_id += 1;
        self.reserved += 1;
        work.session.return_slots += 1;
        if (child.core_return_reserved) self.core.return_slots += 1;
        return .{ .child = child, .created = created, .core_slot_from_caller = reuse_core_slot };
    }

    pub fn abandonFork(self: *Registry, plan: ForkPlan) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.reserved -= 1;
        self.releaseReturnLocked(plan.child);
        self.destroySession(plan.child);
        if (plan.created) |delivery| delivery.destroy(self.allocator);
    }

    pub fn commitRound(self: *Registry, work: Work, output: []const Model.Item, replies: []const Model.Item, plan: ?ForkPlan) !Commit {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const parent = work.session;
        var completed = try parent.context.?.fork(self.allocator);
        errdefer completed.deinit();
        try completed.appendBatch(output, replies);
        if (plan) |fork| {
            try self.sessions.ensureUnusedCapacity(self.allocator, 1);
            fork.child.context = try completed.fork(self.allocator);
            fork.child.context.?.scope = .{ .session_id = fork.child.session_id, .epoch = 0 };
            // Publication consumes the plan. Reserve a nested creation
            // notice's queue allocation before that ownership boundary.
            self.changedLocked(fork.child);
            self.changedLocked(parent);
            if (fork.created != null) try self.core.pending.ensureUnusedCapacity(self.allocator, 1 + self.core.return_slots);
        }
        parent.context.?.deinit();
        parent.context = completed;
        if (plan) |fork| {
            const child = fork.child;
            self.sessions.putAssumeCapacity(child.session_id, child);
            self.reserved -= 1;
            if (fork.created) |delivery| self.core.pending.appendAssumeCapacity(delivery);
            if (fork.core_slot_from_caller) {
                if (parent.core_return_reserved) parent.core_return_reserved = false else parent.return_reserved = false;
                child.core_return_reserved = true;
            }
            parent.children += 1;
            // A fork produces no report from this activation. Return its own
            // reserved slot so a dormant ancestor does not retain a phantom.
            self.releaseReturnLocked(parent);
            parent.active = null;
            work.activation.destroy(self.allocator);
            parent.last_active_unix_ms = self.now();
            return .forked;
        }
        return .continuing;
    }

    pub fn snapshot(self: *Registry, session: *Session) !Context {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.restoreContextLocked(session);
        return session.context.?.fork(self.allocator);
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
        try self.history.maintain(arena.allocator());
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
                .role = session.role,
                .epoch = session.epoch,
                .last_active_unix_ms = session.last_active_unix_ms,
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
        var queued: usize = 0;
        var running: usize = 0;
        const directory = try a.alloc(Input.SessionInfo, self.sessions.count());
        var sessions = self.sessions.valueIterator();
        for (directory) |*info| {
            const item = sessions.next().?.*;
            info.* = self.sessionInfoLocked(item);
            queued += item.pending.items.len;
            running += @intFromBool(item.active != null);
        }
        std.mem.sort(Input.SessionInfo, directory, {}, lessSession);
        var own_callbacks: std.ArrayList(Input.PendingCallback) = .empty;
        for (self.callbacks.items) |callback| if (callback.session_id == session.session_id) try own_callbacks.append(a, callback);
        return .{
            .current = .{
                .session_id = session.session_id,
                .state = .{
                    .session = .{ .role = session.role, .child_sessions = session.children, .callbacks = own_callbacks.items },
                    .runtime = .{
                        .observed_at_unix_ms = self.now(),
                        .registered_sessions = self.sessions.count(),
                        .running_sessions = running,
                        .queued_inputs = queued,
                        .sessions = directory,
                    },
                },
            },
            .attention_revision = self.attention_revision,
        };
    }

    /// Consume only the generation supplied to a real ordinary inference. A
    /// later change remains pending even when it arrives after its snapshot.
    pub fn observeAttention(self: *Registry, work: Work, revision: u64) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        if (work.session != self.core) return;
        std.debug.assert(revision <= self.attention_revision);
        self.observed_revision = @max(self.observed_revision, revision);
    }

    /// Finalization and the queue check share one lock: an arrival is either
    /// included in this activation or makes the now-dormant session runnable.
    pub fn finish(self: *Registry, work: Work, text: ?[]const u8) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const session = work.session;
        if (session.pending.items.len != 0 or (session == self.core and self.attentionPending())) return false;
        self.changedLocked(session);
        try self.notifyReports(session, text orelse "");
        session.last_active_unix_ms = self.now();
        session.active = null;
        work.activation.destroy(self.allocator);
        return true;
    }

    /// The kernel saves before releasing its borrow. Only then can these
    /// in-memory records be discarded and recovered from the published spans.
    pub fn endWorker(self: *Registry, session_id: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const session = self.sessions.get(session_id).?;
        session.borrowed_workers -= 1;
        if (session != self.core and session.active == null and session.borrowed_workers == 0) {
            if (session.context) |*context| context.deinit();
            session.context = null;
        }
    }

    pub fn sendSessionMessage(self: *Registry, work: Work, target: u64, text: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const session = self.sessions.get(target) orelse return error.UnknownSession;
        if (!self.hasCapacity(session)) return error.SessionQueueFull;
        try self.enqueueLocked(session, .{ .session_message = .{
            .from_session = work.session.session_id,
            .observed_at_unix_ms = self.now(),
            .text = text,
        } });
        try self.saveLocked();
    }

    /// The invocation binds this source to the calling branch before any host
    /// work is published. The registration survives uncertain execution.
    pub fn registerHostCallback(self: *Registry, work: Work) !u64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const id = try self.registerCallbackLocked(work.session, .host);
        try self.saveLocked();
        return id;
    }

    pub fn scheduleWakeup(self: *Registry, work: Work, at: i64, text: []const u8) !u64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const owned = try self.allocator.dupe(u8, text);
        var transferred = false;
        errdefer if (!transferred) self.allocator.free(owned);
        try self.wakeups.ensureUnusedCapacity(self.allocator, 1);
        const id = try self.registerCallbackLocked(work.session, .wakeup);
        self.wakeups.appendAssumeCapacity(.{ .id = id, .at_unix_ms = at, .text = owned });
        transferred = true;
        try self.saveLocked();
        return id;
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

    /// Called before starting this runtime's work. Old host processes are not
    /// replayed; the mailbox preserves a completion already published first.
    pub fn interruptedHostCallbacks(self: *Registry, a: Allocator) ![]const u64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var ids: std.ArrayList(u64) = .empty;
        for (self.callbacks.items) |callback| if (callback.source == .host) try ids.append(a, callback.id);
        return ids.toOwnedSlice(a);
    }

    fn registerCallbackLocked(self: *Registry, session: *Session, source: Input.CallbackSource) !u64 {
        var count: usize = 0;
        for (self.callbacks.items) |callback| count += @intFromBool(callback.session_id == session.session_id);
        if (count >= self.max_callbacks) return error.CallbackCapacityUnavailable;
        try self.callbacks.ensureUnusedCapacity(self.allocator, 1);
        self.changedLocked(session);
        const id = self.next_callback_id;
        self.callbacks.appendAssumeCapacity(.{ .id = id, .session_id = session.session_id, .source = source });
        self.next_callback_id += 1;
        return id;
    }

    fn callbackLocked(self: *Registry, id: u64) ?Input.PendingCallback {
        for (self.callbacks.items) |callback| if (callback.id == id) return callback;
        return null;
    }

    fn completeCallbackLocked(self: *Registry, id: u64) void {
        for (self.callbacks.items, 0..) |callback, index| if (callback.id == id) {
            _ = self.callbacks.orderedRemove(index);
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

    fn notifyReports(self: *Registry, session: *Session, text: []const u8) !void {
        const target = session.role.parentSessionId() orelse return;
        const parent = self.sessions.get(target).?;
        const report = try Delivery.create(self.allocator, .{ .report = .{ .from_session = session.session_id, .text = text } }, null);
        errdefer report.destroy(self.allocator);
        const core_report = if (parent != self.core)
            try Delivery.create(self.allocator, .{ .report = .{ .from_session = session.session_id, .text = text } }, null)
        else
            null;
        errdefer if (core_report) |delivery| delivery.destroy(self.allocator);
        std.debug.assert(session.return_reserved and parent.return_slots > 0);
        try self.ensureStartupLocked(parent);
        self.changedLocked(parent);
        try parent.pending.ensureUnusedCapacity(self.allocator, 1 + parent.return_slots);
        if (core_report != null) {
            std.debug.assert(session.core_return_reserved and self.core.return_slots > 0);
            try self.core.pending.ensureUnusedCapacity(self.allocator, 1 + self.core.return_slots);
        }
        self.releaseReturnLocked(session);
        parent.pending.appendAssumeCapacity(report);
        if (core_report) |delivery| self.core.pending.appendAssumeCapacity(delivery);
    }

    fn releaseReturnLocked(self: *Registry, session: *Session) void {
        if (session.return_reserved) {
            self.sessions.get(session.role.parentSessionId().?).?.return_slots -= 1;
            session.return_reserved = false;
        }
        if (session.core_return_reserved) {
            self.core.return_slots -= 1;
            session.core_return_reserved = false;
        }
    }

    fn takeReady(self: *Registry, session: *Session) !?Work {
        if (session.active != null or !self.hasWork(session)) return null;
        const parent = if (session.role.parentSessionId()) |id| self.sessions.get(id).? else null;
        if (parent) |target| {
            if (!session.return_reserved) {
                if (!self.hasCapacity(target)) return null;
                try target.pending.ensureUnusedCapacity(self.allocator, target.return_slots + 1);
            }
            if (target != self.core and !session.core_return_reserved) {
                if (!self.hasCapacity(self.core)) return null;
                try self.core.pending.ensureUnusedCapacity(self.allocator, self.core.return_slots + 1);
            }
        }
        try self.restoreContextLocked(session);
        const activation = try Activation.create(self.allocator, session.pending.items);
        activation.admitted = session.pending.items.len == 0;
        if (parent) |target| {
            if (!session.return_reserved) {
                target.return_slots += 1;
                session.return_reserved = true;
            }
            if (target != self.core and !session.core_return_reserved) {
                self.core.return_slots += 1;
                session.core_return_reserved = true;
            }
        }
        session.pending.clearRetainingCapacity();
        session.active = activation;
        session.borrowed_workers += 1;
        session.last_active_unix_ms = self.now();
        self.changedLocked(session);
        return .{ .session = session, .activation = activation };
    }

    fn restoreContextLocked(self: *Registry, session: *Session) !void {
        if (session.context != null) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const entries = try self.history.restoreEntries(arena.allocator(), session.session_id);
        session.context = try Context.restore(self.allocator, .{ .session_id = session.session_id, .epoch = session.epoch }, entries, @embedFile("system.md"));
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
        try session.pending.ensureUnusedCapacity(self.allocator, 1 + session.return_slots);
        self.changedLocked(session);
        session.pending.appendAssumeCapacity(delivery);
    }

    fn changedLocked(self: *Registry, session: *Session) void {
        if (session == self.core) return;
        self.attention_revision += 1;
    }

    fn attentionPending(self: *const Registry) bool {
        return self.attention_revision != self.observed_revision;
    }

    fn hasWork(self: *const Registry, session: *const Session) bool {
        return session.pending.items.len != 0 or (session == self.core and self.attentionPending());
    }

    fn sessionInfoLocked(self: *Registry, session: *Session) Input.SessionInfo {
        var pending: usize = 0;
        for (self.callbacks.items) |callback| pending += @intFromBool(callback.session_id == session.session_id);
        return .{
            .session_id = session.session_id,
            .role = session.role,
            .status = if (session.active != null) .running else if (self.hasWork(session)) .ready else .dormant,
            .queued_inputs = session.pending.items.len,
            .pending_callbacks = pending,
            .last_active_unix_ms = session.last_active_unix_ms,
        };
    }

    fn hasCapacity(self: *Registry, session: *Session) bool {
        const active_count = if (session.active) |activation| deliveryCount(activation.deliveries.items) else 0;
        return deliveryCount(session.pending.items) + active_count + session.return_slots < self.max_pending;
    }

    fn runningWorkers(self: *Registry) usize {
        var running: usize = 0;
        var sessions = self.sessions.valueIterator();
        while (sessions.next()) |entry| if (entry.* != self.core and entry.*.active != null) {
            running += 1;
        };
        return running;
    }

    fn destroySession(self: *Registry, session: *Session) void {
        if (session.active) |activation| activation.destroy(self.allocator);
        for (session.pending.items) |delivery| delivery.destroy(self.allocator);
        session.pending.deinit(self.allocator);
        if (session.context) |*context| context.deinit();
        self.allocator.destroy(session);
    }

    fn now(self: *Registry) i64 {
        return std.Io.Clock.real.now(self.io).toMilliseconds();
    }
};

fn deliveryCount(deliveries: []const *Delivery) usize {
    var count: usize = 0;
    for (deliveries) |delivery| count += switch (delivery.event) {
        .startup, .session_created => @as(usize, 0),
        else => 1,
    };
    return count;
}

fn hasStartup(deliveries: []const *Delivery) bool {
    for (deliveries) |delivery| if (delivery.event == .startup) return true;
    return false;
}

fn isInternal(event: Input.Event) bool {
    return switch (event) {
        .assignment, .report, .session_message, .session_created => true,
        .startup, .input, .callback => false,
    };
}

fn lessSession(_: void, left: Input.SessionInfo, right: Input.SessionInfo) bool {
    return left.session_id < right.session_id;
}

fn lessSessionId(_: void, left: *Session, right: *Session) bool {
    return left.session_id < right.session_id;
}

fn assertWork(work: Work) void {
    std.debug.assert(work.session.active == work.activation);
}
