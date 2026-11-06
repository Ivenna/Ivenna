const std = @import("std");
const Context = @import("context.zig").Context;
const Input = @import("input.zig");
const WorkInput = @import("work.zig");
const Delivery = WorkInput.Delivery;
const Activation = WorkInput.Activation;
const Allocator = std.mem.Allocator;
const Model = @import("model.zig");

/// A session owns reasoning history independently of external correspondence.
/// The core is permanent; branch sessions may retain an idle context while
/// their children continue without occupying an execution slot.
pub const Session = struct {
    session_id: u64,
    role: Input.Role,
    context: Context,
    parent_session_id: ?u64 = null,
    parent_generation: ?u64 = null,
    generation: u64 = 0,
    active: ?*Activation = null,
    pending: std.ArrayList(*Delivery) = .empty,
    borrowed_workers: usize = 0,
    children: usize = 0,
    /// Queue positions reserved for results of forked work.
    return_slots: usize = 0,
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
    mutex: std.Io.Mutex = .init,
    core: *Session,
    sessions: std.AutoHashMapUnmanaged(u64, *Session) = .empty,
    noticed: std.StringHashMapUnmanaged(enum { scheduled, handled }) = .empty,
    reserved: usize = 0,
    next_session_id: u64 = 2,

    pub fn init(allocator: Allocator, io: std.Io, max_contexts: usize) !Registry {
        const core = try allocator.create(Session);
        errdefer allocator.destroy(core);
        var context = try Context.init(allocator, @embedFile("system.md"));
        errdefer context.deinit();
        core.* = .{ .session_id = 1, .role = .core, .context = context };
        var self: Registry = .{ .allocator = allocator, .io = io, .max_contexts = max_contexts, .core = core };
        try self.sessions.put(allocator, 1, core);
        return self;
    }

    pub fn deinit(self: *Registry) void {
        var sessions = self.sessions.valueIterator();
        while (sessions.next()) |session| self.destroySession(session.*);
        self.sessions.deinit(self.allocator);
        var notice_keys = self.noticed.keyIterator();
        while (notice_keys.next()) |key| self.allocator.free(key.*);
        self.noticed.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn intakeLimit(self: *Registry) !usize {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return self.noticed.count() + @max(32, self.max_contexts * 2);
    }

    /// Every external input enters the core. Source evidence does not select
    /// an existing focus or impose a response obligation.
    pub fn accept(self: *Registry, incoming: WorkInput.Incoming) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const session = self.core;
        const receipt = incoming.receipt;
        if (receipt) |key| if (self.noticed.contains(key)) return false;
        const active_count = if (session.active) |activation| activation.deliveries.items.len else 0;
        if (session.pending.items.len + active_count + session.return_slots >= self.max_contexts) return false;
        const delivery = try Delivery.create(self.allocator, .{ .input = incoming.input }, if (receipt) |key| &.{key} else &.{});
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
    pub fn nextReady(self: *Registry, max_parallel: usize) !?Work {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (try takeReady(self.allocator, self.core)) |work| return work;
        if (self.runningWorkers() >= max_parallel) return null;
        var sessions = self.sessions.valueIterator();
        while (sessions.next()) |entry| {
            const session = entry.*;
            if (session == self.core) continue;
            if (try takeReady(self.allocator, session)) |work| return work;
        }
        return null;
    }

    /// Install the selected FIFO prefix and return its suffix ahead of any
    /// arrivals admitted since claim. Success consumes context; failure leaves
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
        session.generation += 1;
    }

    pub fn prepareFork(self: *Registry, work: Work, request: ForkRequest) !ForkPlan {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        if (request.task.len == 0) return error.InvalidForkArguments;
        if (self.sessions.count() + self.reserved >= self.max_contexts) return error.AttentionCapacityUnavailable;
        const child = try self.allocator.create(Session);
        errdefer self.allocator.destroy(child);
        var source_refs: std.ArrayList([]const u8) = .empty;
        defer source_refs.deinit(self.allocator);
        var receipts: std.ArrayList([]const u8) = .empty;
        defer receipts.deinit(self.allocator);
        for (work.activation.deliveries.items) |item| {
            switch (item.event) {
                .input => |input| if (input.source) |source| try source_refs.append(self.allocator, source.reference),
                .assignment => |assignment| try source_refs.appendSlice(self.allocator, assignment.source_refs),
                .report => {},
            }
            try receipts.appendSlice(self.allocator, item.receipts);
        }
        const delivery = try Delivery.create(self.allocator, .{ .assignment = .{
            .task = request.task,
            .from_session = work.session.session_id,
            .source_refs = source_refs.items,
        } }, receipts.items);
        errdefer delivery.destroy(self.allocator);
        child.* = .{
            .session_id = self.next_session_id,
            .role = .branch,
            .context = undefined,
            .parent_session_id = work.session.session_id,
        };
        try child.pending.append(self.allocator, delivery);
        self.next_session_id += 1;
        self.reserved += 1;
        return .{ .child = child };
    }

    pub fn abandonFork(self: *Registry, plan: ForkPlan) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.reserved -= 1;
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
            try parent.pending.ensureUnusedCapacity(self.allocator, parent.return_slots + 1);
            fork.child.context = try completed.fork(self.allocator);
        }
        parent.context.deinit();
        parent.context = completed;
        parent.generation += 1;
        if (plan) |fork| {
            const child = fork.child;
            child.parent_generation = parent.generation;
            self.sessions.putAssumeCapacity(child.session_id, child);
            self.reserved -= 1;
            parent.children += 1;
            parent.return_slots += 1;
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

    pub fn snapshotCore(self: *Registry) !Context {
        return self.snapshot(self.core);
    }

    pub fn appendCoreContext(self: *Registry, context: []const Input.ContextItem) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.core.context.appendRecord(.{ .session_id = self.core.session_id, .context = context });
        self.core.generation += 1;
    }

    pub fn replaceContext(self: *Registry, session: *Session, replacement: Context) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        session.context.deinit();
        session.context = replacement;
        session.generation += 1;
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
                    .parent_generation = session.parent_generation,
                    .parent_session_id = session.parent_session_id,
                    .active_children = session.children,
                },
                .response = if (session.parent_session_id) |parent_id|
                    .{ .report = .{ .session_id = parent_id } }
                else
                    .{ .internal = .{} },
                .runtime = .{
                    .active_sessions = self.sessions.count(),
                    .running_sessions = running,
                    .queued_inputs = queued,
                },
            },
        };
    }

    /// Finishing an activation releases idle context independently of stored
    /// correspondence and explicit communication effects.
    pub fn finish(self: *Registry, work: Work, text: ?[]const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const session = work.session;
        try self.notifyParent(session, text orelse "");
        for (work.activation.deliveries.items) |delivery|
            for (delivery.receipts) |key| {
                self.noticed.getPtr(key).?.* = .handled;
            };
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
        const target = session.parent_session_id orelse return;
        const parent = self.sessions.get(target).?;
        const report = try Delivery.create(self.allocator, .{ .report = .{ .from_session = session.session_id, .text = text } }, &.{});
        std.debug.assert(parent.return_slots > 0);
        parent.return_slots -= 1;
        parent.pending.appendAssumeCapacity(report);
    }

    pub fn reconcile(self: *Registry, waiting: []const WorkInput.Incoming) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var absent: std.ArrayList([]const u8) = .empty;
        defer absent.deinit(self.allocator);
        var notices = self.noticed.iterator();
        while (notices.next()) |entry| {
            if (entry.value_ptr.* != .handled) continue;
            const present = for (waiting) |incoming| {
                const receipt = incoming.receipt orelse continue;
                if (std.mem.eql(u8, entry.key_ptr.*, receipt)) break true;
            } else false;
            if (!present) try absent.append(self.allocator, entry.key_ptr.*);
        }
        for (absent.items) |key| if (self.noticed.fetchRemove(key)) |entry| self.allocator.free(entry.key);
    }

    /// Consumption bindings keep adapter receipts live until processing ends.
    pub fn receiptsInUse(self: *Registry, a: Allocator) ![]const []const u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var receipts: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (receipts.items) |receipt| a.free(receipt);
            receipts.deinit(a);
        }
        var sessions = self.sessions.valueIterator();
        while (sessions.next()) |entry| {
            if (entry.*.active) |activation|
                for (activation.deliveries.items) |delivery| try retainDeliveryReceipts(a, &receipts, delivery);
            for (entry.*.pending.items) |delivery| try retainDeliveryReceipts(a, &receipts, delivery);
        }
        return receipts.toOwnedSlice(a);
    }

    fn releaseIdle(self: *Registry, session: *Session) void {
        if (session == self.core or session.active != null or session.pending.items.len != 0 or session.children != 0 or session.borrowed_workers != 0) return;
        const parent_id = session.parent_session_id;
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
};

fn takeReady(allocator: Allocator, session: *Session) !?Work {
    if (session.active != null) return null;
    if (session.pending.items.len == 0) return null;
    const activation = try Activation.create(allocator, session.pending.items);
    session.pending.clearRetainingCapacity();
    session.active = activation;
    session.borrowed_workers += 1;
    return .{ .session = session, .activation = activation };
}

fn retainDeliveryReceipts(a: Allocator, receipts: *std.ArrayList([]const u8), delivery: *const Delivery) !void {
    try receipts.ensureUnusedCapacity(a, delivery.receipts.len);
    for (delivery.receipts) |receipt|
        receipts.appendAssumeCapacity(try a.dupe(u8, receipt));
}

fn assertWork(work: Work) void {
    std.debug.assert(work.session.active == work.activation);
}
