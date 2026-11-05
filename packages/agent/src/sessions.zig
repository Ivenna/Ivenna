const std = @import("std");
const Context = @import("context.zig").Context;
const Input = @import("input.zig");
const WorkInput = @import("work.zig");
const Delivery = WorkInput.Delivery;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

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
    state: enum { ready, running } = .ready,
    active: ?*Delivery = null,
    pending: std.ArrayList(*Delivery) = .empty,
    borrowed_workers: usize = 0,
    children: usize = 0,
    /// Queue positions reserved for results of forked work.
    return_slots: usize = 0,
};

pub const Work = struct { session: *Session, delivery: *Delivery };

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
        if (session.pending.items.len + @as(usize, @intFromBool(session.active != null)) + session.return_slots >= self.max_contexts) return false;
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
    pub fn nextReady(self: *Registry, max_parallel: usize) !?Work {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (takeReady(self.core)) |work| return work;
        if (self.runningWorkers() >= max_parallel) return null;
        var sessions = self.sessions.valueIterator();
        while (sessions.next()) |entry| {
            const session = entry.*;
            if (session == self.core) continue;
            if (takeReady(session)) |work| return work;
        }
        return null;
    }

    pub fn prepareFork(self: *Registry, work: Work, request: ForkRequest) !ForkPlan {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        if (request.task.len == 0) return error.InvalidForkArguments;
        if (self.sessions.count() + self.reserved >= self.max_contexts) return error.AttentionCapacityUnavailable;
        const child = try self.allocator.create(Session);
        errdefer self.allocator.destroy(child);
        const source_refs: []const []const u8 = switch (work.delivery.input) {
            .input => |input| if (input.source) |source| &.{source.reference} else &.{},
            .assignment => |assignment| assignment.source_refs,
            .report => &.{},
        };
        const delivery = try Delivery.create(self.allocator, .{ .assignment = .{
            .task = request.task,
            .from_session = work.session.session_id,
            .source_refs = source_refs,
        } }, work.delivery.receipt);
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
    pub fn commitRound(self: *Registry, work: Work, output: []const Value, replies: []const Value, plan: ?ForkPlan) !Commit {
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
            parent.state = .ready;
            work.delivery.destroy(self.allocator);
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

    pub fn appendCoreInput(self: *Registry, text: []const u8) !void {
        try self.appendInput(self.core, text);
    }

    pub fn appendInput(self: *Registry, session: *Session, text: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try session.context.appendInput(text);
        session.generation += 1;
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
            running += @intFromBool(entry.*.state == .running);
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
        if (work.delivery.receipt) |key| self.noticed.getPtr(key).?.* = .handled;
        session.active = null;
        session.state = .ready;
        work.delivery.destroy(self.allocator);
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
        const report = try Delivery.create(self.allocator, .{ .report = .{ .from_session = session.session_id, .text = text } }, null);
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
            if (entry.*.active) |delivery| try retainDeliveryReceipt(a, &receipts, delivery);
            for (entry.*.pending.items) |delivery| try retainDeliveryReceipt(a, &receipts, delivery);
        }
        return receipts.toOwnedSlice(a);
    }

    fn releaseIdle(self: *Registry, session: *Session) void {
        if (session == self.core or session.state != .ready or session.active != null or session.pending.items.len != 0 or session.children != 0 or session.borrowed_workers != 0) return;
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
        while (sessions.next()) |entry| if (entry.* != self.core and entry.*.state == .running) {
            running += 1;
        };
        return running;
    }

    fn destroySession(self: *Registry, session: *Session) void {
        if (session.active) |delivery| delivery.destroy(self.allocator);
        for (session.pending.items) |delivery| delivery.destroy(self.allocator);
        session.pending.deinit(self.allocator);
        session.context.deinit();
        self.allocator.destroy(session);
    }
};

fn takeReady(session: *Session) ?Work {
    if (session.state != .ready) return null;
    if (session.pending.items.len == 0) return null;
    const delivery = session.pending.orderedRemove(0);
    session.active = delivery;
    session.borrowed_workers += 1;
    session.state = .running;
    return .{ .session = session, .delivery = delivery };
}

fn retainDeliveryReceipt(a: Allocator, receipts: *std.ArrayList([]const u8), delivery: *const Delivery) !void {
    const receipt = delivery.receipt orelse return;
    try receipts.ensureUnusedCapacity(a, 1);
    receipts.appendAssumeCapacity(try a.dupe(u8, receipt));
}

fn assertWork(work: Work) void {
    std.debug.assert(work.session.state == .running and work.session.active == work.delivery);
}
