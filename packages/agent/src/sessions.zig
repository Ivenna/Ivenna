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

/// A session owns reasoning history independently of incoming communication.
/// The core is permanent; branch sessions may retain an idle context while
/// their children continue without occupying an execution slot.
pub const Session = struct {
    session_id: u64,
    role: Input.Role,
    context: Context,
    active: ?*Activation = null,
    pending: std.ArrayList(*Delivery) = .empty,
    borrowed_workers: usize = 0,
    children: usize = 0,
    /// Queue positions reserved for results of forked work.
    return_slots: usize = 0,
    /// This session's next report has a reserved position in its parent.
    return_reserved: bool = false,
};

pub const Work = struct { session: *Session, activation: *Activation };

pub const ForkRequest = struct {
    task: []const u8,
};

/// Reserved during tool invocation, published after the complete batch.
pub const ForkPlan = struct {
    child: *Session,
};

pub const Commit = enum { continuing, forked };

pub const Registry = struct {
    allocator: Allocator,
    io: std.Io,
    max_contexts: usize,
    history: Persistence,
    mutex: std.Io.Mutex = .init,
    core: *Session,
    sessions: std.AutoHashMapUnmanaged(u64, *Session) = .empty,
    noticed: std.StringHashMapUnmanaged(enum { scheduled, acknowledged }) = .empty,
    reserved: usize = 0,
    next_session_id: u64 = 2,

    pub fn init(allocator: Allocator, io: std.Io, max_contexts: usize, history: contracts.HistoryStore) !Registry {
        var self: Registry = .{ .allocator = allocator, .io = io, .max_contexts = max_contexts, .history = .init(allocator, history), .core = undefined };
        errdefer self.deinit();
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const saved = try self.history.load(arena.allocator(), max_contexts);
        if (saved) |retained| {
            self.next_session_id = retained.next_session_id;
            for (retained.sessions) |record| {
                const session = try allocator.create(Session);
                errdefer allocator.destroy(session);
                var context = try Context.restore(allocator, .{ .session_id = record.session_id, .epoch = record.epoch }, record.entries, @embedFile("system.md"));
                errdefer context.deinit();
                session.* = .{
                    .session_id = record.session_id,
                    .role = record.role,
                    .context = context,
                };
                try self.sessions.put(allocator, session.session_id, session);
            }
            self.core = self.sessions.get(1).?;
        } else {
            const core = try allocator.create(Session);
            errdefer allocator.destroy(core);
            var context = try Context.init(allocator, .{ .session_id = 1, .epoch = 0 }, @embedFile("system.md"));
            errdefer context.deinit();
            core.* = .{ .session_id = 1, .role = .core, .context = context };
            try self.sessions.put(allocator, 1, core);
            self.core = core;
        }
        // Fresh startup work reserves report space in takeReady, after unread
        // reports have been restored and parent capacity can be checked.
        var sessions = self.sessions.valueIterator();
        while (sessions.next()) |entry| {
            const session = entry.*;
            if (session.role.parentSessionId()) |parent_id| {
                const parent = self.sessions.get(parent_id).?;
                parent.children += 1;
            }
            const delivery = try Delivery.create(allocator, .{ .startup = .{
                .observed_at_unix_ms = std.Io.Clock.real.now(io).toMilliseconds(),
            } }, null);
            errdefer delivery.destroy(allocator);
            try session.pending.append(allocator, delivery);
        }
        if (saved) |retained| for (retained.sessions) |record| {
            const session = self.sessions.get(record.session_id).?;
            for (record.observations) |event| {
                const delivery = try Delivery.create(allocator, event, null);
                errdefer delivery.destroy(allocator);
                try session.pending.append(allocator, delivery);
            }
        };
        try self.save();
        return self;
    }

    pub fn deinit(self: *Registry) void {
        var sessions = self.sessions.valueIterator();
        while (sessions.next()) |session| self.destroySession(session.*);
        self.sessions.deinit(self.allocator);
        var notice_keys = self.noticed.keyIterator();
        while (notice_keys.next()) |key| self.allocator.free(key.*);
        self.noticed.deinit(self.allocator);
        self.history.deinit();
        self.* = undefined;
    }

    pub fn intakeLimit(self: *Registry) !usize {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return self.noticed.count() + @max(32, self.max_contexts * 2);
    }

    /// Queue an observation for the core. Returns false for an already tracked
    /// receipt or when the core's delivery capacity is full.
    pub fn accept(self: *Registry, incoming: Incoming) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const session = self.core;
        const receipt = incoming.receipt;
        if (receipt) |key| if (self.noticed.contains(key)) return false;
        const active_count = if (session.active) |activation| deliveryCount(activation.deliveries.items) else 0;
        if (deliveryCount(session.pending.items) + active_count + session.return_slots >= self.max_contexts) return false;
        const delivery = try Delivery.create(self.allocator, .{ .input = incoming.input }, receipt);
        errdefer delivery.destroy(self.allocator);
        try session.pending.ensureUnusedCapacity(self.allocator, 1 + session.return_slots);
        const notice_key = if (receipt) |key| try self.allocator.dupe(u8, key) else null;
        errdefer if (notice_key) |key| self.allocator.free(key);
        if (notice_key) |key| try self.noticed.put(self.allocator, key, .scheduled);
        session.pending.appendAssumeCapacity(delivery);
        return true;
    }

    /// The coordinator has its own serialized execution lane. max_parallel
    /// bounds work sessions independently, so a long work tool cannot take the
    /// coordinator's execution slot.
    pub fn takeReadyBatch(self: *Registry, a: Allocator, max_parallel: usize) ![]const Work {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var ready: std.ArrayList(Work) = .empty;
        defer ready.deinit(a);
        // A failed claim ends execution. Sessions keep the activations until
        // shutdown, but work that was never started must not borrow a worker.
        errdefer for (ready.items) |work| {
            work.session.borrowed_workers -= 1;
        };
        var available = max_parallel -| self.runningWorkers();
        try ready.ensureTotalCapacity(a, 1 + @min(available, self.sessions.count() - 1));
        if (try self.takeReady(self.core)) |work| ready.appendAssumeCapacity(work);
        var sessions = self.sessions.valueIterator();
        while (available > 0) {
            const entry = sessions.next() orelse break;
            const session = entry.*;
            if (session == self.core) continue;
            if (try self.takeReady(session)) |work| {
                ready.appendAssumeCapacity(work);
                available -= 1;
            }
        }
        return ready.toOwnedSlice(a);
    }

    /// Install the selected FIFO prefix and return its suffix ahead of any
    /// arrivals queued since claim. Success consumes context; failure leaves
    /// queue membership and the caller's context ownership unchanged.
    pub fn beginActivation(self: *Registry, work: Work, count: usize, context: Context) !void {
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
        session.context.deinit();
        session.context = context;
        work.activation.admitted = true;
    }

    pub fn prepareFork(self: *Registry, work: Work, request: ForkRequest) !ForkPlan {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        if (request.task.len == 0) return error.InvalidForkArguments;
        if (self.sessions.count() + self.reserved >= self.max_contexts) return error.AttentionCapacityUnavailable;
        if (deliveryCount(work.session.pending.items) + work.session.return_slots >= self.max_contexts)
            return error.AttentionCapacityUnavailable;
        try work.session.pending.ensureUnusedCapacity(self.allocator, work.session.return_slots + 1);
        const child = try self.allocator.create(Session);
        errdefer self.allocator.destroy(child);
        const delivery = try Delivery.create(self.allocator, .{ .assignment = .{
            .task = request.task,
            .from_session = work.session.session_id,
        } }, null);
        errdefer delivery.destroy(self.allocator);
        child.* = .{
            .session_id = self.next_session_id,
            .role = .{ .branch = .{ .parent_session_id = work.session.session_id } },
            .context = undefined,
            .return_reserved = true,
        };
        try child.pending.append(self.allocator, delivery);
        self.next_session_id += 1;
        self.reserved += 1;
        work.session.return_slots += 1;
        return .{ .child = child };
    }

    pub fn abandonFork(self: *Registry, plan: ForkPlan) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.reserved -= 1;
        self.sessions.get(plan.child.role.branch.parent_session_id).?.return_slots -= 1;
        for (plan.child.pending.items) |delivery| delivery.destroy(self.allocator);
        plan.child.pending.deinit(self.allocator);
        self.allocator.destroy(plan.child);
    }

    /// Commit before child execution: every fork includes this response and
    /// exactly one result per call, never an unfinished exchange. The plan
    /// remains caller-owned on failure; success consumes it.
    pub fn commitRound(self: *Registry, work: Work, output: []const Model.Item, replies: []const Model.Item, plan: ?ForkPlan) !Commit {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const parent = work.session;
        var completed = try parent.context.fork(self.allocator);
        errdefer completed.deinit();
        try completed.appendBatch(output, replies);
        if (plan) |fork| {
            try self.sessions.ensureUnusedCapacity(self.allocator, 1);
            fork.child.context = try completed.fork(self.allocator);
            fork.child.context.scope = .{ .session_id = fork.child.session_id, .epoch = 0 };
        }
        parent.context.deinit();
        parent.context = completed;
        if (plan) |fork| {
            const child = fork.child;
            self.sessions.putAssumeCapacity(child.session_id, child);
            self.reserved -= 1;
            parent.children += 1;
            parent.active = null;
            work.activation.destroy(self.allocator);
            return .forked;
        }
        return .continuing;
    }

    pub fn snapshot(self: *Registry, session: *Session) !Context {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return session.context.fork(self.allocator);
    }

    /// Serialize under the same lock as history changes so concurrent workers
    /// cannot replace a newer persisted view with an older snapshot.
    pub fn save(self: *Registry) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.saveLocked();
    }

    /// Publish current understanding before reconciling storage. The same lock
    /// excludes concurrent creates/publication and includes any history changes
    /// made since a worker's last save.
    pub fn maintain(self: *Registry) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.saveLocked();
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        try self.history.maintain(arena.allocator());
    }

    fn saveLocked(self: *Registry) !void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var needed: std.AutoHashMapUnmanaged(u64, void) = .empty;
        try needed.put(a, self.core.session_id, {});
        var sessions = self.sessions.valueIterator();
        while (sessions.next()) |entry| {
            const session = entry.*;
            if (session.active == null and session.pending.items.len == 0) continue;
            var ancestor = session;
            while (!needed.contains(ancestor.session_id)) {
                try needed.put(a, ancestor.session_id, {});
                ancestor = self.sessions.get(ancestor.role.parentSessionId() orelse break).?;
            }
        }
        var retained: std.ArrayList(History.Session) = .empty;
        sessions = self.sessions.valueIterator();
        while (sessions.next()) |entry| {
            const session = entry.*;
            if (!needed.contains(session.session_id)) continue;
            // Internal observations have no external inbox to read again.
            // Preserve them separately until ordinary budget admission adds
            // them to history. Runtime deliveries and receipts do not survive.
            var observations: std.ArrayList(Input.Event) = .empty;
            if (session.active) |activation| if (!activation.admitted) {
                for (activation.deliveries.items) |delivery| switch (delivery.event) {
                    .assignment, .report => try observations.append(a, delivery.event),
                    else => {},
                };
            };
            for (session.pending.items) |delivery| switch (delivery.event) {
                .assignment, .report => try observations.append(a, delivery.event),
                else => {},
            };
            try retained.append(a, .{
                .session_id = session.session_id,
                .role = session.role,
                .epoch = session.context.scope.epoch,
                .entries = session.context.records(),
                .observations = observations.items,
            });
        }
        try self.history.save(a, .{ .next_session_id = self.next_session_id, .sessions = retained.items });
    }

    pub fn replaceContext(self: *Registry, session: *Session, replacement: Context) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        session.context.deinit();
        session.context = replacement;
    }

    pub fn runtimeSnapshot(self: *Registry, session: *Session) !Input.Snapshot {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var queued: usize = 0;
        var running: usize = 0;
        var sessions = self.sessions.valueIterator();
        while (sessions.next()) |entry| {
            queued += entry.*.pending.items.len;
            running += @intFromBool(entry.*.active != null);
        }
        return .{
            .session_id = session.session_id,
            .state = .{
                .session = .{
                    .role = session.role,
                    .active_children = session.children,
                },
                .runtime = .{
                    .active_sessions = self.sessions.count(),
                    .running_sessions = running,
                    .queued_inputs = queued,
                },
            },
        };
    }

    /// Finish the activation and report to its parent when present.
    /// Context release follows remaining work, children, and borrowed workers.
    pub fn finish(self: *Registry, work: Work, text: ?[]const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const session = work.session;
        try self.notifyParent(session, text orelse "");
        session.active = null;
        work.activation.destroy(self.allocator);
        self.releaseIdle(session);
    }

    /// Keeps session pointers alive until their Kernel worker has returned,
    /// including callers whose activation ended after publishing a fork.
    pub fn endWorker(self: *Registry, session_id: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const session = self.sessions.get(session_id).?;
        session.borrowed_workers -= 1;
        self.releaseIdle(session);
    }

    fn notifyParent(self: *Registry, session: *Session, text: []const u8) !void {
        const target = session.role.parentSessionId() orelse return;
        const parent = self.sessions.get(target).?;
        const report = try Delivery.create(self.allocator, .{ .report = .{ .from_session = session.session_id, .text = text } }, null);
        std.debug.assert(session.return_reserved and parent.return_slots > 0);
        session.return_reserved = false;
        parent.return_slots -= 1;
        parent.pending.appendAssumeCapacity(report);
    }

    /// Keep acknowledged receipts tracked until polling confirms their absence:
    /// an in-progress poll can still return its earlier snapshot.
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
            if (entry.value_ptr.* != .acknowledged) continue;
            if (!present.contains(entry.key_ptr.*)) try absent.append(self.allocator, entry.key_ptr.*);
        }
        for (absent.items) |key| if (self.noticed.fetchRemove(key)) |entry| self.allocator.free(entry.key);
    }

    fn releaseIdle(self: *Registry, session: *Session) void {
        if (session == self.core or session.active != null or session.pending.items.len != 0 or session.children != 0 or session.borrowed_workers != 0) return;
        const parent_id = session.role.parentSessionId();
        _ = self.sessions.remove(session.session_id);
        self.destroySession(session);
        if (parent_id) |id| if (self.sessions.get(id)) |parent| {
            parent.children -= 1;
            self.releaseIdle(parent);
        };
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
        session.context.deinit();
        self.allocator.destroy(session);
    }

    fn takeReady(self: *Registry, session: *Session) !?Work {
        if (session.active != null or session.pending.items.len == 0) return null;
        const parent = if (!session.return_reserved)
            if (session.role.parentSessionId()) |id| self.sessions.get(id).? else null
        else
            null;
        if (parent) |target| {
            const active_count = if (target.active) |activation| deliveryCount(activation.deliveries.items) else 0;
            if (deliveryCount(target.pending.items) + active_count + target.return_slots >= self.max_contexts) return null;
            try target.pending.ensureUnusedCapacity(self.allocator, target.return_slots + 1);
        }
        const activation = try Activation.create(self.allocator, session.pending.items);
        if (parent) |target| {
            target.return_slots += 1;
            session.return_reserved = true;
        }
        session.pending.clearRetainingCapacity();
        session.active = activation;
        session.borrowed_workers += 1;
        return .{ .session = session, .activation = activation };
    }
};

/// Startup is one additional control observation, independent of the bounded
/// ordinary queue retained before this runtime began. Initialization puts it
/// first; FIFO admission and every later producer preserve that position.
fn deliveryCount(deliveries: []const *Delivery) usize {
    return deliveries.len - @intFromBool(deliveries.len != 0 and deliveries[0].event == .startup);
}

fn assertWork(work: Work) void {
    std.debug.assert(work.session.active == work.activation);
}
