const std = @import("std");
const Context = @import("context.zig").Context;
const History = @import("history.zig").History;
const StartupHistory = @import("history.zig").StartupHistory;
const Scope = @import("history.zig").Scope;
const Persistence = @import("history.zig").Persistence;
const Subscriptions = @import("instance_state").subscriptions;
const Reports = @import("reports.zig");
const Input = @import("input.zig");
const WorkInput = @import("work.zig");
const Delivery = WorkInput.Delivery;
const Activation = WorkInput.Activation;
const Stream = WorkInput.Stream;
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
    progress: History.Progress = .{},
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

    /// Only genuinely new work makes an interrupted focus eligible again.
    fn notify(self: *Session) void {
        switch (self.state) {
            .running => |activation| activation.new_arrival = true,
            .interrupted => self.state = .idle,
            .idle => {},
        }
    }

    fn awaitsAssignment(self: *const Session) bool {
        return self.pending.items.len != 0 and self.pending.items[0].event == .assignment;
    }
};

pub const Work = struct { session: *Session, activation: *Activation };

/// Changes that become visible with the tool round that reports them.
pub const RoundChanges = struct {
    forks: std.ArrayList(*Session) = .empty,
    channels: std.ArrayList(StagedChannel) = .empty,
};

const StagedChannel = struct {
    record: History.Channel,
    transport: contracts.Channels,
};

pub const Registry = struct {
    allocator: Allocator,
    io: std.Io,
    max_sessions: usize,
    max_pending: usize,
    subscriptions: *Subscriptions.Store,
    subscription_catalog: [32]u8,
    usage_scope: ?[32]u8,
    history: Persistence,
    reports: Reports.Outbox,
    mutex: std.Io.Mutex = .init,
    /// The first save error stops further work in this registry.
    checkpoint_failure: ?anyerror = null,
    core: *Session,
    sessions: std.AutoHashMapUnmanaged(u64, *Session) = .empty,
    noticed: std.StringHashMapUnmanaged(enum { scheduled, acknowledged }) = .empty,
    callbacks: std.ArrayList(History.CallbackRegistration) = .empty,
    /// Open channel registrations confirmed by a checkpoint. The channel
    /// transport owns waiting readers.
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

    pub const Startup = struct {
        correspondents: []const []const u8 = &.{},
        usage_scope: ?[32]u8 = null,
    };

    pub fn init(
        allocator: Allocator,
        io: std.Io,
        max_sessions: usize,
        max_pending: usize,
        startup_history: StartupHistory,
        subscriptions: *Subscriptions.Store,
        startup: Startup,
    ) !Registry {
        const history = startup_history.store;
        var self: Registry = .{
            .allocator = allocator,
            .io = io,
            .max_sessions = max_sessions,
            .max_pending = max_pending,
            .subscriptions = subscriptions,
            .subscription_catalog = startup_history.subscriptionCatalog() orelse try subscriptions.identity(),
            .usage_scope = startup.usage_scope,
            .history = .init(allocator, history),
            .reports = try Reports.Outbox.init(allocator, history, null),
            .core = undefined,
            .started_at_unix_ms = std.Io.Clock.real.now(io).toMilliseconds(),
        };
        errdefer self.deinit();
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        if (startup_history.checkpoint) |checkpoint| {
            const retained = try self.history.restore(a, max_sessions, checkpoint);
            const reports = try Reports.Outbox.init(allocator, history, retained.activity_reports);
            self.reports.deinit();
            self.reports = reports;
            self.next_session_id = retained.next_session_id;
            self.next_callback_id = retained.next_callback_id;
            self.next_runtime_reference_id = retained.next_runtime_reference_id;
            const same_usage_scope = self.usage_scope != null and std.meta.eql(retained.usage_scope, self.usage_scope);
            for (retained.sessions) |record| {
                const session = try allocator.create(Session);
                session.* = .{
                    .session_id = record.session_id,
                    .role = record.role,
                    .epoch = record.epoch,
                    .subscription_through = record.subscription_through,
                    .progress = record.progress,
                    .needs_startup = record.role == .activity,
                };
                if (!same_usage_scope) session.progress.last_input_tokens = null;
                errdefer self.destroySession(session);
                session.focus_id = try allocator.dupe(u8, record.focus_id);
                if (record.role == .core) {
                    session.context = try Context.restore(allocator, .{ .session_id = record.session_id, .epoch = record.epoch }, record.focus_id, record.entries orelse return error.InvalidHistory);
                }
                try self.sessions.put(allocator, session.session_id, session);
            }
            self.core = self.sessions.get(1).?;
            for (retained.callbacks) |callback| try self.appendCallback(callback);
            for (retained.sessions) |record| {
                const session = self.sessions.get(record.session_id).?;
                for (record.observations) |event| {
                    const delivery = try Delivery.create(allocator, event, null);
                    errdefer delivery.destroy(allocator);
                    try session.pending.append(allocator, delivery);
                }
                if (record.was_running or record.observations.len != 0) try self.ensureActivityStartupLocked(session);
            }
            for (retained.channels) |record| try self.appendChannel(record);
        } else {
            const core = try allocator.create(Session);
            core.* = .{ .session_id = 1, .role = .core };
            errdefer self.destroySession(core);
            core.focus_id = try allocator.dupe(u8, "core-1");
            core.context = try Context.init(allocator, .{ .session_id = 1, .epoch = 0 }, core.focus_id);
            try self.sessions.put(allocator, 1, core);
            self.core = core;
        }
        try self.queueStartupLocked(self.core, startup.correspondents);
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
        for (self.callbacks.items) |callback| self.freeCallback(callback);
        self.callbacks.deinit(self.allocator);
        for (self.channels.items) |channel| self.freeChannel(channel);
        self.channels.deinit(self.allocator);
        self.queued_callbacks.deinit(self.allocator);
        self.reports.deinit();
        self.history.deinit();
        self.* = undefined;
    }

    /// Acquire the registry for work. Cleanup takes the mutex directly after a save failure.
    fn lock(self: *Registry) !void {
        try self.mutex.lock(self.io);
        errdefer self.mutex.unlock(self.io);
        if (self.checkpoint_failure) |err| return err;
    }

    pub fn pollRequest(self: *Registry) !contracts.Inbox.Poll {
        try self.lock();
        defer self.mutex.unlock(self.io);
        return .{
            .messages = if (self.hasCapacity(self.core)) self.noticed.count() + @max(32, self.max_pending * 2) else 0,
            .callbacks = self.noticed.count() + self.callbacks.items.len + 32,
        };
    }

    pub const Intake = enum { accepted, deferred, duplicate };

    pub fn accept(self: *Registry, incoming: Incoming) !Intake {
        try self.lock();
        defer self.mutex.unlock(self.io);
        const session, const event = switch (incoming.content) {
            .message => |message| .{ self.core, Input.Event{ .input = message } },
            .callback => |callback| blk: {
                // Protect all transport copies until the admitted group has
                // been published and its receipt acknowledged.
                if (self.queued_callbacks.contains(callback.id)) return .deferred;
                const registration = self.callbackLocked(callback.id) orelse {
                    if (callback.id < self.next_callback_id) return .duplicate;
                    return error.UnknownCallback;
                };
                break :blk .{ self.sessions.get(registration.session_id).?, Input.Event{ .callback = .{
                    .callback_id = registration.reference,
                    .source = .{ .host = .{ .command_id = registration.command_id } },
                    .observed_at_unix_ms = callback.observed_at_unix_ms,
                    .text = callback.text,
                } } };
            },
        };
        // A scheduled receipt still belongs to an unfinished batch. An
        // acknowledged receipt can reappear in a poll collected before the
        // acknowledgement finished.
        if (incoming.receipt) |key| if (self.noticed.get(key)) |state| switch (state) {
            .scheduled => return .deferred,
            .acknowledged => return .duplicate,
        };
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
        try self.lock();
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
        try self.lock();
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
        var stream = session.progress.first_stream;
        while (true) {
            switch (stream) {
                .ordinary => try deliveries.appendSlice(self.allocator, ordinary),
                .activity => if (session == self.core) try self.appendActivityReports(activation),
                .subscription => try self.appendSubscriptionReports(session.focus_id, activation),
            }
            stream = stream.next();
            if (stream == session.progress.first_stream) break;
        }
        session.pending.clearRetainingCapacity();
        activation.admitted = deliveries.items.len == 0;
        activation.new_arrival = false;
    }

    /// Extend a batch that still fits by reading the next page from each report source.
    pub fn extendReports(self: *Registry, work: Work) !bool {
        try self.lock();
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
        try self.lock();
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
            session.progress.last_input_tokens = null;
        }
        work.activation.admitted = !deferred_all;
        for (deliveries.items) |delivery| {
            if (delivery.event == .startup) continue;
            session.progress.first_stream = Stream.of(delivery.event).next();
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

    pub fn prepareFork(self: *Registry, work: Work, changes: *RoundChanges, name: []const u8, task: []const u8) ![]const u8 {
        try self.lock();
        defer self.mutex.unlock(self.io);
        assertWork(work);
        if (self.sessions.count() + self.reserved_sessions >= self.max_sessions) return error.SessionCapacityUnavailable;
        try changes.forks.ensureUnusedCapacity(self.allocator, 1);
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
        changes.forks.appendAssumeCapacity(session);
        return session.focus_id;
    }

    /// Release reservations that did not become part of a confirmed round.
    pub fn discardRound(self: *Registry, changes: *RoundChanges) void {
        if (changes.forks.items.len != 0) {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.reserved_sessions -= changes.forks.items.len;
            for (changes.forks.items) |fork| self.destroySession(fork);
        }
        for (changes.channels.items) |channel| {
            channel.transport.close(channel.record.id);
            self.freeChannel(channel.record);
        }
        changes.forks.deinit(self.allocator);
        changes.channels.deinit(self.allocator);
    }

    /// Publish the completed context, forks and channel registrations together.
    /// The caller owns the context left in completed and releases any remaining
    /// reservations when the round exits.
    pub fn commitToolRound(self: *Registry, work: Work, completed: *Context, changes: *RoundChanges, input_tokens: ?u64) !void {
        try self.lock();
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const session = work.session;
        for (changes.forks.items) |fork| {
            fork.context = try Context.inherit(self.allocator, .{ .session_id = fork.session_id, .epoch = 0 }, fork.focus_id, completed.records());
        }
        try self.sessions.ensureUnusedCapacity(self.allocator, @intCast(changes.forks.items.len));
        try self.channels.ensureUnusedCapacity(self.allocator, changes.channels.items.len);

        std.mem.swap(Context, &session.context.?, completed);
        session.progress.last_input_tokens = input_tokens;
        for (changes.forks.items) |fork| self.sessions.putAssumeCapacity(fork.session_id, fork);
        errdefer for (changes.forks.items) |fork| {
            _ = self.sessions.remove(fork.session_id);
        };
        const confirmed_channels = self.channels.items.len;
        for (changes.channels.items) |channel| self.channels.appendAssumeCapacity(channel.record);
        errdefer self.channels.shrinkRetainingCapacity(confirmed_channels);
        try self.saveLocked();

        self.reserved_sessions -= changes.forks.items.len;
        changes.forks.clearRetainingCapacity();
        for (changes.channels.items) |channel| channel.transport.activate(channel.record.id);
        changes.channels.clearRetainingCapacity();
    }

    pub fn snapshot(self: *Registry, session: *Session) !Context {
        try self.lock();
        defer self.mutex.unlock(self.io);
        try self.restoreContextLocked(session);
        return session.context.?.clone(self.allocator);
    }

    /// Keep an activity's expression available through interruption of its tools.
    pub fn recordBeforeTools(self: *Registry, work: Work, text: ?[]const u8) !void {
        if (work.session == self.core or text == null) return;
        const observed_at = self.now();
        try self.lock();
        defer self.mutex.unlock(self.io);
        assertWork(work);
        try self.reportResponseLocked(work.session, text, observed_at, false);
        try self.saveLocked();
    }

    pub fn maintain(self: *Registry) !void {
        try self.lock();
        defer self.mutex.unlock(self.io);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        try self.history.maintain(a, try self.reports.retained(a));
    }

    fn saveLocked(self: *Registry) !void {
        // A failed save can leave a new checkpoint in the mailbox. Block
        // later work and maintenance before releasing the lock.
        self.writeCheckpointLocked() catch |err| {
            self.checkpoint_failure = err;
            return err;
        };
    }

    fn writeCheckpointLocked(self: *Registry) !void {
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
                .progress = session.progress,
                .was_running = session.role == .activity and (session.state != .idle or hasStartup(session.pending.items)),
                .entries = if (session.context) |*context| context.records() else null,
                .observations = observations.items,
            });
        }
        try self.history.save(a, .{
            .subscription_catalog = self.subscription_catalog,
            .usage_scope = self.usage_scope,
            .next_session_id = self.next_session_id,
            .next_callback_id = self.next_callback_id,
            .next_runtime_reference_id = self.next_runtime_reference_id,
            .callbacks = self.callbacks.items,
            .sessions = retained.items,
            .channels = self.channels.items,
            .activity_reports = self.reports.checkpoint(),
        });
    }

    /// The focus ID borrows the worker's session through request rendering.
    pub fn current(self: *Registry, session: *const Session) Input.Current {
        return .{
            .focus_id = session.focus_id,
            .role = session.role,
            .observed_at_unix_ms = self.now(),
        };
    }

    pub fn currentWithConnectionStatus(self: *Registry, a: Allocator, session: *Session, transport: contracts.Channels) !?Input.Current {
        try self.lock();
        defer self.mutex.unlock(self.io);
        const limit = 8;
        var channel_ids: std.ArrayList([]const u8) = .empty;
        var index = self.channels.items.len;
        while (index > 0 and channel_ids.items.len < limit) {
            index -= 1;
            const channel = self.channels.items[index];
            if (!self.channelVisibleTo(session, channel)) continue;
            const has_receiver = (try transport.hasReceiver(channel.id)) orelse continue;
            if (!has_receiver) try channel_ids.append(a, try a.dupe(u8, channel.id));
        }
        const subscription_ids = self.subscriptions.subscriptionsWithoutListeners(a, session.focus_id, limit) catch |err| switch (err) {
            error.StateStoreBusy => blk: {
                std.log.warn("subscription registrations are busy while sampling listeners for '{s}'", .{session.focus_id});
                break :blk &.{};
            },
            else => return err,
        };
        if (channel_ids.items.len == 0 and subscription_ids.len == 0) return null;
        var sample = self.current(session);
        sample.channels_without_receivers = try channel_ids.toOwnedSlice(a);
        sample.subscriptions_without_listeners = subscription_ids;
        return sample;
    }

    pub fn compactionSnapshot(self: *Registry, a: Allocator, session: *Session) !Input.Snapshot {
        try self.lock();
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
            .source = .{ .host = .{ .command_id = try a.dupe(u8, callback.command_id) } },
        });
        const subscriptions = try self.subscriptions.activeRegistrations(a, session.focus_id);
        const registrations = try a.alloc(Input.SampledSubscription, subscriptions.len);
        for (subscriptions, registrations) |subscription, *registration| registration.* = .{
            .subscription_id = subscription.subscription_id,
            .listener = subscription.listener,
        };
        var channels: std.ArrayList(Input.SampledChannel) = .empty;
        for (self.channels.items) |channel| {
            if (!self.channelVisibleTo(session, channel)) continue;
            try channels.append(a, .{
                .channel_id = try a.dupe(u8, channel.id),
                .description = if (channel.description) |text| try a.dupe(u8, text) else null,
            });
        }
        return .{
            .current = self.current(session),
            .state = .{
                .activities = activities,
                .callbacks = try own_callbacks.toOwnedSlice(a),
                .subscription_registrations = registrations,
                .channel_registrations = channels.items,
            },
        };
    }

    fn channelVisibleTo(self: *const Registry, session: *const Session, channel: History.Channel) bool {
        return session == self.core or std.mem.eql(u8, channel.opened_by, session.focus_id);
    }

    fn liveSessionsLocked(self: *Registry, a: Allocator) ![]*Session {
        const live = try a.alloc(*Session, self.sessions.count());
        var sessions = self.sessions.valueIterator();
        for (live) |*session| session.* = sessions.next().?.*;
        std.mem.sort(*Session, live, {}, lessSessionId);
        return live;
    }

    /// Commit the outcome of a round without tool calls. Returns true when
    /// the activation has finished. On every return the caller owns the
    /// context left in `history`.
    pub fn commitResponse(self: *Registry, work: Work, history: *Context, response: Model.Response) !bool {
        const observed_at = self.now();
        try self.lock();
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
            session.progress.last_input_tokens = response.input_tokens;
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
        try self.lock();
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
        try self.lock();
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

    pub fn issueRuntimeReference(self: *Registry, a: Allocator, work: Work, name: []const u8) ![]const u8 {
        try self.lock();
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

    pub fn registerCallback(self: *Registry, a: Allocator, work: Work, name: []const u8, command_id: []const u8) !contracts.Callback.Registration {
        try self.lock();
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const id = self.next_callback_id;
        const next = try std.math.add(u64, id, 1);
        const reference = try contracts.Reference.create(a, name, id);
        errdefer a.free(reference);
        try self.appendCallback(.{ .id = id, .reference = reference, .session_id = work.session.session_id, .command_id = command_id });
        self.next_callback_id = next;
        try self.saveLocked();
        return .{ .id = id, .reference = reference };
    }

    pub fn subscribe(self: *Registry, a: Allocator, work: Work, name: []const u8, listener: []const u8) !Subscriptions.Created {
        try self.lock();
        defer self.mutex.unlock(self.io);
        assertWork(work);
        return self.subscriptions.create(a, work.session.focus_id, name, listener);
    }

    pub fn withdrawSubscription(self: *Registry, work: Work, reference: []const u8) !bool {
        try self.lock();
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const changed = try self.subscriptions.withdraw(reference);
        if (changed) self.check_sleeping_activities = true;
        return changed;
    }

    /// Before startup dispatch, these registrations belong to commands from the
    /// previous runtime. Their processes and control handles are not restored.
    pub fn pendingCallbackIds(self: *Registry, a: Allocator) ![]const u64 {
        try self.lock();
        defer self.mutex.unlock(self.io);
        const ids = try a.alloc(u64, self.callbacks.items.len);
        for (self.callbacks.items, ids) |callback, *id| id.* = callback.id;
        return ids;
    }

    fn appendCallback(self: *Registry, registration: History.CallbackRegistration) !void {
        const reference = try self.allocator.dupe(u8, registration.reference);
        errdefer self.allocator.free(reference);
        const command_id = try self.allocator.dupe(u8, registration.command_id);
        errdefer self.allocator.free(command_id);
        try self.callbacks.append(self.allocator, .{ .id = registration.id, .reference = reference, .session_id = registration.session_id, .command_id = command_id });
    }

    fn freeCallback(self: *Registry, callback: History.CallbackRegistration) void {
        self.allocator.free(callback.reference);
        self.allocator.free(callback.command_id);
    }

    fn callbackLocked(self: *Registry, id: u64) ?History.CallbackRegistration {
        for (self.callbacks.items) |callback| if (callback.id == id) return callback;
        return null;
    }

    fn completeCallbackLocked(self: *Registry, id: u64) void {
        for (self.callbacks.items, 0..) |callback, index| if (callback.id == id) {
            self.freeCallback(self.callbacks.orderedRemove(index));
            return;
        };
        unreachable; // A queued callback retains its registration until admission.
    }

    pub fn acknowledged(self: *Registry, receipt: []const u8) !void {
        try self.lock();
        defer self.mutex.unlock(self.io);
        self.noticed.getPtr(receipt).?.* = .acknowledged;
    }

    pub fn reconcile(self: *Registry, waiting: []const Incoming) !void {
        try self.lock();
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
        const scope: Scope = .{ .session_id = session.session_id, .epoch = session.epoch };
        session.context = if (session.awaitsAssignment())
            try Context.inherit(self.allocator, scope, session.focus_id, entries)
        else
            try Context.restore(self.allocator, scope, session.focus_id, entries);
    }

    fn ensureActivityStartupLocked(self: *Registry, session: *Session) !void {
        if (!session.needs_startup) return;
        // A focus that has yet to begin starts with its assignment.
        if (!session.awaitsAssignment()) try self.queueStartupLocked(session, null);
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

    /// Reserve an entry for the tool round.
    /// The reservation is addressable only after the round commits.
    pub fn openChannel(self: *Registry, a: Allocator, work: Work, changes: *RoundChanges, transport: contracts.Channels, name: []const u8, description: []const u8) ![]const u8 {
        try self.lock();
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const reference = self.next_runtime_reference_id;
        const next = try std.math.add(u64, reference, 1);
        const id = try contracts.Reference.create(a, name, reference);
        errdefer a.free(id);
        const record = try self.copyChannel(.{
            .id = id,
            .opened_by = work.session.focus_id,
            .opened_at_unix_ms = self.now(),
            .description = description,
        });
        errdefer self.freeChannel(record);
        try changes.channels.ensureUnusedCapacity(self.allocator, 1);
        try transport.reserve(id);
        changes.channels.appendAssumeCapacity(.{ .record = record, .transport = transport });
        self.next_runtime_reference_id = next;
        return id;
    }

    /// Confirm retirement before the transport ends waiting reads.
    pub fn closeChannel(self: *Registry, transport: contracts.Channels, id: []const u8) !bool {
        try self.lock();
        defer self.mutex.unlock(self.io);
        for (self.channels.items, 0..) |channel, index| {
            if (!std.mem.eql(u8, channel.id, id)) continue;
            _ = self.channels.orderedRemove(index);
            defer self.freeChannel(channel);
            try self.saveLocked();
            transport.close(id);
            return true;
        }
        return false;
    }

    /// Called during startup before the registry is shared with any worker.
    /// Every saved channel is restored, even when its opening focus ended.
    pub fn restoreChannels(self: *const Registry, transport: contracts.Channels) !void {
        for (self.channels.items) |channel| {
            try transport.reserve(channel.id);
            transport.activate(channel.id);
        }
    }

    fn appendChannel(self: *Registry, channel: History.Channel) !void {
        const owned = try self.copyChannel(channel);
        errdefer self.freeChannel(owned);
        try self.channels.append(self.allocator, owned);
    }

    fn copyChannel(self: *Registry, channel: History.Channel) !History.Channel {
        var owned = channel;
        owned.id = try self.allocator.dupe(u8, channel.id);
        errdefer self.allocator.free(owned.id);
        owned.opened_by = try self.allocator.dupe(u8, channel.opened_by);
        errdefer self.allocator.free(owned.opened_by);
        owned.description = if (channel.description) |text| try self.allocator.dupe(u8, text) else null;
        return owned;
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

const TestStore = @import("test_history.zig").TestStore;

fn initTestRegistry(storage: *TestStore, subscriptions: *Subscriptions.Store, startup: Registry.Startup) !Registry {
    const testing = std.testing;
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const selected = try StartupHistory.load(scratch.allocator(), storage.port());
    return Registry.init(testing.allocator, testing.io, 2, 3, selected, subscriptions, startup);
}

test "an interrupted activation retains its receipts and only fresh arrivals wake it" {
    var storage: TestStore = .{};
    defer storage.arena.deinit();
    var subscriptions = try Subscriptions.Store.openInMemory(std.testing.allocator);
    defer subscriptions.close();
    var registry = try initTestRegistry(&storage, &subscriptions, .{});
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

test "a stale poll distinguishes queued and acknowledged mail" {
    const testing = std.testing;
    var storage: TestStore = .{};
    defer storage.arena.deinit();
    var subscriptions = try Subscriptions.Store.openInMemory(testing.allocator);
    defer subscriptions.close();
    var registry = try initTestRegistry(&storage, &subscriptions, .{});
    defer registry.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const letter: Incoming = .{
        .receipt = "mail-1",
        .content = .{ .message = .{ .from = &.{"visitor"}, .text = "Hello", .observed_at_unix_ms = 10 } },
    };
    const waiting: []const Incoming = &.{letter};
    const initial_budget = try registry.pollRequest();
    try testing.expectEqual(Registry.Intake.accepted, try registry.accept(letter));
    const work = (try registry.takeReadyBatch(a))[0];
    defer registry.endWorker(work.session);
    try testing.expectEqual(Registry.Intake.deferred, try registry.accept(letter));

    var history = try registry.snapshot(work.session);
    defer history.deinit();
    const deliveries = work.activation.deliveries.items;
    try testing.expectEqual(2, deliveries.len);
    try history.appendRecord(.{ .events = .{ .focus_id = work.session.focus_id, .items = &.{ deliveries[0].event, deliveries[1].event } } });
    try registry.commitInput(work, deliveries.len, &history);
    try registry.acknowledged(deliveries[1].receipt.?);
    deliveries[1].receipt = null;
    registry.releaseDeliveries(work);

    // The poll can still hold a snapshot taken before acknowledgement.
    try registry.reconcile(waiting);
    try testing.expectEqual(Registry.Intake.duplicate, try registry.accept(letter));
    try registry.reconcile(&.{});
    try testing.expectEqualDeep(initial_budget, try registry.pollRequest());
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

test "startup retires old wakeup registrations without reusing their callback IDs" {
    const testing = std.testing;
    var storage: TestStore = .{};
    defer storage.arena.deinit();
    const a = storage.arena.allocator();
    var subscriptions = try Subscriptions.Store.openInMemory(testing.allocator);
    defer subscriptions.close();
    const catalog = try subscriptions.identity();
    try storage.port().save(try std.mem.concat(a, u8, &.{
        \\.{ .subscription_catalog =
        ,
        try @import("record_codec.zig").encode(a, catalog),
        \\, .next_session_id = 2, .next_callback_id = 3, .next_command_id = 2,
        \\   .sessions = .{.{ .session_id = 1, .focus_id = "core-1", .role = .core, .was_running = false,
        \\       .subscription_through = 0, .epoch = 0, .group = "core", .head = null, .count = 0, .observations = null }},
        \\   .wakeups = .{
        \\       .{ .id = 2, .at_unix_ms = 1000, .text = null },
        \\   },
        \\   .callbacks = .{
        \\       .{ .id = 1, .reference = "build-1", .session_id = 1, .source = .{ .host = .{ .command_id = "build-1" } } },
        \\       .{ .id = 2, .reference = "published-2", .session_id = 1, .source = .wakeup },
        \\   }, .activity_reports = null,
        \\}
        ,
    }));

    var registry = try initTestRegistry(&storage, &subscriptions, .{});
    defer registry.deinit();
    try testing.expectEqualSlices(u64, &.{1}, try registry.pendingCallbackIds(a));
    try testing.expect(std.mem.indexOf(u8, storage.checkpoint.?, ".wakeups") == null);
    // The retired wakeup was the last issued ID and its mail can still arrive.
    try testing.expectEqual(.duplicate, try registry.accept(.{ .content = .{ .callback = .{
        .id = 2,
        .text = "Already published by the previous kernel.",
        .observed_at_unix_ms = 1000,
    } } }));
}

test "compaction samples the active subscriptions addressed to this focus" {
    var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var storage: TestStore = .{};
    defer storage.arena.deinit();
    var subscriptions = try Subscriptions.Store.openInMemory(std.testing.allocator);
    defer subscriptions.close();
    var registry = try initTestRegistry(&storage, &subscriptions, .{});
    defer registry.deinit();
    var core = try admitTestInput(&registry, a);
    defer core.history.deinit();
    defer registry.endWorker(core.work.session);
    const core_watch = try registry.subscribe(a, core.work, "releases", "Release feed");
    var changes: RoundChanges = .{};
    defer registry.discardRound(&changes);
    _ = try registry.prepareFork(core.work, &changes, "research", "Follow revisions.");
    try registry.commitToolRound(core.work, &core.history, &changes, null);
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

test "restart restores activity reports together with completion or sleeping history" {
    const testing = std.testing;
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const startup: Registry.Startup = .{ .usage_scope = @splat(1) };
    const response: Model.Response = .{
        .output = &.{.{ .continuation = "final response" }},
        .calls = &.{},
        .text = "Read the notes.",
        .input_tokens = 7,
    };
    for ([_]bool{ false, true }) |sleeping| {
        var storage: TestStore = .{};
        defer storage.arena.deinit();
        var subscriptions = try Subscriptions.Store.openInMemory(testing.allocator);
        defer subscriptions.close();

        const previous = attempt: {
            var registry = try initTestRegistry(&storage, &subscriptions, startup);
            defer registry.deinit();
            var core = try admitTestInput(&registry, a);
            defer core.history.deinit();
            defer registry.endWorker(core.work.session);
            var changes: RoundChanges = .{};
            defer registry.discardRound(&changes);
            _ = try registry.prepareFork(core.work, &changes, "research", "Read the notes.");
            try core.history.appendBatch(&.{.{ .continuation = "open_focus" }}, &.{.{
                .tool_result = .{ .call_id = "open", .content = .{ .parts = &.{} } },
            }});
            try registry.commitToolRound(core.work, &core.history, &changes, null);
            var activity = try admitTestInput(&registry, a);
            defer activity.history.deinit();
            defer registry.endWorker(activity.work.session);
            const previous = .{
                .activity_id = activity.work.session.session_id,
                .records = activity.history.records().len,
            };
            if (sleeping) {
                _ = try registry.registerCallback(a, activity.work, "read", "read-1");
                storage.fail_save = .after_commit;
                try testing.expectError(error.MailMutationUnconfirmed, registry.commitResponse(activity.work, &activity.history, response));
            } else {
                try testing.expect(try registry.commitResponse(activity.work, &activity.history, response));
            }
            break :attempt previous;
        };

        storage.fail_save = .none;
        var registry = try initTestRegistry(&storage, &subscriptions, startup);
        defer registry.deinit();
        const activity = registry.sessions.get(previous.activity_id);
        try testing.expectEqual(sleeping, activity != null);
        if (activity) |session| {
            var history = try registry.snapshot(session);
            defer history.deinit();
            const records = history.records();
            try testing.expectEqual(previous.records + 1, records.len);
            try testing.expectEqual(response.input_tokens, session.progress.last_input_tokens);
            try testing.expectEqualStrings(response.output[0].continuation, records[records.len - 1].exchange[0].continuation);
        }
        const reports = try registry.reports.peek(a, 0, 3);
        try testing.expectEqual(@as(usize, if (sleeping) 1 else 2), reports.len);
        try testing.expectEqualStrings("research-2", reports[0].from_focus);
        try testing.expectEqualStrings(response.text.?, reports[0].content.assistant);
        if (!sleeping) try testing.expect(reports[1].content == .ended);
    }
}

test "a fork inherits the complete opening round and continues its own history" {
    const testing = std.testing;
    var storage: TestStore = .{};
    defer storage.arena.deinit();
    const a = storage.arena.allocator();
    var subscriptions = try Subscriptions.Store.openInMemory(testing.allocator);
    defer subscriptions.close();
    var registry = try initTestRegistry(&storage, &subscriptions, .{});
    defer registry.deinit();
    var core = try admitTestInput(&registry, a);
    defer core.history.deinit();
    defer registry.endWorker(core.work.session);

    try core.history.appendBatch(&.{.{ .continuation = "An earlier response" }}, &.{});
    const continuity: Input.Continuity = .{
        .focus_id = core.work.session.focus_id,
        .observed_at_unix_ms = 100,
        .text = "I chose to keep exploring this plan.\n\nFollow the plan.",
        .state = .{ .activities = &.{}, .callbacks = &.{} },
    };
    var opening = try core.history.withContinuity(testing.allocator, continuity, .keep_latest_tool_round);
    defer opening.deinit();
    try registry.commitInput(core.work, 0, &opening);
    const letter: Input.Record = .{ .events = .{
        .focus_id = core.work.session.focus_id,
        .items = &.{.{ .input = .{ .from = &.{"operator"}, .text = "We have a plan.", .observed_at_unix_ms = 120 } }},
    } };
    try opening.appendRecord(letter);

    var changes: RoundChanges = .{};
    defer registry.discardRound(&changes);
    const task = "Read the plan.";
    const focus_id = try registry.prepareFork(core.work, &changes, "research", task);
    const exchange: []const contracts.Model.Item = &.{
        .{ .continuation = "Open a focus and read a memory." },
        .{ .tool_result = .{ .call_id = "open_focus", .content = .{ .parts = &.{.{ .text = focus_id }} } } },
        .{ .tool_result = .{ .call_id = "recall", .content = .{ .parts = &.{.{ .text = "The latest plan is in the research room." }} } } },
    };
    try opening.appendBatch(exchange[0..1], exchange[1..]);
    try registry.commitToolRound(core.work, &opening, &changes, null);

    var activity = try admitTestInput(&registry, a);
    defer registry.endWorker(activity.work.session);
    defer activity.history.deinit();
    const expected: []const @import("history.zig").Entry = &.{
        .{ .record = .{ .continuity = continuity } },
        .{ .record = letter },
        .{ .exchange = exchange },
        .{ .record = .{ .events = .{ .focus_id = focus_id, .items = &.{.{ .assignment = .{ .task = task } }} } } },
    };
    var continued = try registry.snapshot(core.work.session);
    defer continued.deinit();
    try testing.expectEqualDeep(expected[0 .. expected.len - 1], continued.records());
    const response = "The core continues separately.";
    try testing.expect(try registry.commitResponse(core.work, &continued, .{
        .output = &.{.{ .continuation = response }},
        .calls = &.{},
        .text = response,
    }));

    var activity_history = try registry.snapshot(activity.work.session);
    defer activity_history.deinit();
    try testing.expectEqualDeep(expected, activity_history.records());
}

test "restart retains the assignment as a new activity's first delivery" {
    const testing = std.testing;
    var storage: TestStore = .{};
    defer storage.arena.deinit();
    const a = storage.arena.allocator();
    var subscriptions = try Subscriptions.Store.openInMemory(testing.allocator);
    defer subscriptions.close();
    const task = "Read the plan.";
    {
        var registry = try initTestRegistry(&storage, &subscriptions, .{});
        defer registry.deinit();
        var core = try admitTestInput(&registry, a);
        defer core.history.deinit();
        defer registry.endWorker(core.work.session);
        var changes: RoundChanges = .{};
        defer registry.discardRound(&changes);
        const focus_id = try registry.prepareFork(core.work, &changes, "research", task);
        try core.history.appendBatch(&.{.{ .continuation = "Open the focus." }}, &.{.{ .tool_result = .{ .call_id = "open_focus", .content = .{ .parts = &.{} } } }});
        try registry.commitToolRound(core.work, &core.history, &changes, null);
        try registry.sendFocusMessage(core.work, focus_id, "The file is in the research room.");

        // An older kernel could keep the inherited tool round after an activity
        // handover and defer the assignment when the two did not fit together.
        const activity = (try registry.takeReadyBatch(a))[0];
        defer registry.endWorker(activity.session);
        var inherited = try registry.snapshot(activity.session);
        defer inherited.deinit();
        const inherited_note: Input.Continuity = .{
            .focus_id = focus_id,
            .observed_at_unix_ms = 100,
            .text = "The core's earlier work.",
            .state = .{ .activities = &.{}, .callbacks = &.{} },
        };
        var legacy = try Context.restore(testing.allocator, .{ .session_id = activity.session.session_id, .epoch = 1 }, focus_id, &.{
            .{ .record = .{ .continuity = inherited_note } }, inherited.records()[inherited.records().len - 1],
        });
        defer legacy.deinit();
        try registry.commitInput(activity, 0, &legacy);
    }

    {
        var restored = try initTestRegistry(&storage, &subscriptions, .{});
        defer restored.deinit();
        const ready = try restored.takeReadyBatch(a);
        defer for (ready) |work| restored.endWorker(work.session);
        const work = ready[1];
        const activity_events = work.activation.deliveries.items;
        const assignment: Input.Event = .{ .assignment = .{ .task = task } };
        try testing.expectEqual(2, activity_events.len);
        try testing.expectEqualDeep(assignment, activity_events[0].event);
        try testing.expect(activity_events[1].event == .focus_message);

        var history = try restored.snapshot(work.session);
        defer history.deinit();
        try testing.expect(!history.hasPendingContinuation());
        try history.appendRecord(.{ .events = .{ .focus_id = work.session.focus_id, .items = &.{assignment} } });
        try restored.commitInput(work, 1, &history);
        restored.releaseDeliveries(work);
    }

    var resumed = try initTestRegistry(&storage, &subscriptions, .{});
    defer resumed.deinit();
    const ready = try resumed.takeReadyBatch(a);
    defer for (ready) |work| resumed.endWorker(work.session);
    var history = try resumed.snapshot(ready[1].session);
    defer history.deinit();
    var compacted = try history.withContinuity(testing.allocator, history.records()[0].record.continuity, .keep_latest_tool_round);
    defer compacted.deinit();
    const records = compacted.records();
    try testing.expectEqual(2, records.len);
    try testing.expectEqualStrings(task, records[1].record.events.items[0].assignment.task);
}
