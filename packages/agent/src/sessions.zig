const std = @import("std");
const Context = @import("context.zig").Context;
const Input = @import("input.zig");
const WorkInput = @import("work.zig");
const Delivery = WorkInput.Delivery;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// A session owns reasoning history independently of communication routing.
/// The core is permanent; branch sessions may retain an idle context while
/// their children continue without occupying an execution slot.
pub const Session = struct {
    session_id: u64,
    role: Input.Role,
    context: Context,
    parent_session_id: ?u64 = null,
    parent_generation: ?u64 = null,
    generation: u64 = 0,
    state: enum { ready, running, waiting } = .ready,
    active: ?*Delivery = null,
    pending: std.ArrayList(*Delivery) = .empty,
    borrowed_workers: usize = 0,
    children: usize = 0,
    waiting_reports: usize = 0,
    report_to: ?u64 = null,
};

pub const Work = struct { session: *Session, delivery: *Delivery };

pub const ForkRequest = struct {
    task: []const u8,
    mode: union(enum) { handoff: struct {}, subtask: struct { report_to_parent: bool = false } } = .{ .handoff = .{} },
};

/// Reserved during tool invocation, materialized only after the complete batch.
pub const ForkPlan = struct {
    child: *Session,
    request: ForkRequest,
};

pub const Commit = enum { continuing, handed_off, waiting };

pub const Registry = struct {
    allocator: Allocator,
    io: std.Io,
    max_contexts: usize,
    mutex: std.Io.Mutex = .init,
    core: *Session,
    sessions: std.AutoHashMapUnmanaged(u64, *Session) = .empty,
    routes: std.StringHashMapUnmanaged(u64) = .empty,
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
        var route_keys = self.routes.keyIterator();
        while (route_keys.next()) |key| self.allocator.free(key.*);
        self.routes.deinit(self.allocator);
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

    pub fn acceptExisting(self: *Registry, incoming: WorkInput.Incoming) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const source = incoming.source_state orelse return false;
        const route = source.route orelse return false;
        const owner = self.routes.get(route) orelse return false;
        _ = try self.acceptLocked(self.sessions.get(owner).?, incoming);
        return true;
    }

    /// Native input enters the coordinator unless its producer has explicitly
    /// associated it with an existing work route. Source evidence alone neither
    /// deduplicates input nor gives it routing or response responsibility.
    pub fn accept(self: *Registry, incoming: WorkInput.Incoming) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const route = if (incoming.source_state) |source| source.route else null;
        const session = if (route) |key| if (self.routes.get(key)) |owner| self.sessions.get(owner).? else self.core else self.core;
        return self.acceptLocked(session, incoming);
    }

    fn acceptLocked(self: *Registry, session: *Session, incoming: WorkInput.Incoming) !bool {
        if (incoming.source_state) |source| if (self.noticed.contains(source.input_key)) return false;
        if (session.pending.items.len + @as(usize, @intFromBool(session.active != null)) >= self.max_contexts) return false;
        const delivery = try Delivery.fromIncoming(self.allocator, incoming);
        errdefer delivery.destroy(self.allocator);
        try session.pending.ensureUnusedCapacity(self.allocator, 1 + @as(usize, @intFromBool(session.active != null)));
        const notice_key = if (incoming.source_state) |source| try self.allocator.dupe(u8, source.input_key) else null;
        errdefer if (notice_key) |key| self.allocator.free(key);
        var added_route: ?[]const u8 = null;
        if (incoming.source_state) |source| if (source.route) |route| {
            if (!self.routes.contains(route)) {
                const key = try self.allocator.dupe(u8, route);
                self.routes.put(self.allocator, key, session.session_id) catch |err| {
                    self.allocator.free(key);
                    return err;
                };
                added_route = key;
            }
        };
        errdefer if (added_route) |route| self.removeRoute(route, session.session_id);
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
        if (work.session == self.core and request.mode != .handoff) return error.CoreRequiresHandoff;
        if (self.sessions.count() + self.reserved >= self.max_contexts) return error.AttentionCapacityUnavailable;
        const child = try self.allocator.create(Session);
        errdefer self.allocator.destroy(child);
        const source_refs: []const []const u8 = switch (work.delivery.input) {
            .input => |input| if (input.source) |source| &.{source.reference} else &.{},
            .assignment => |assignment| assignment.source_refs,
        };
        const delivery = try Delivery.create(self.allocator, .{ .assignment = .{
            .task = request.task,
            .from_session = work.session.session_id,
            .source_refs = source_refs,
        } }, if (request.mode == .handoff) work.delivery.reply else null, if (request.mode == .handoff) work.delivery.source_state else null);
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
        return .{ .child = child, .request = .{ .task = delivery.input.assignment.task, .mode = request.mode } };
    }

    pub fn abandonForks(self: *Registry, plans: []const ForkPlan) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (plans) |plan| {
            self.reserved -= 1;
            for (plan.child.pending.items) |delivery| delivery.destroy(self.allocator);
            plan.child.pending.deinit(self.allocator);
            self.allocator.destroy(plan.child);
        }
    }

    /// Commit before child execution: every fork includes this response and
    /// exactly one result per call, never an unfinished exchange. All plans
    /// remain caller-owned on failure; success consumes them together.
    pub fn commitRound(self: *Registry, work: Work, output: []const Value, replies: []const Value, plans: []const ForkPlan) !Commit {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const parent = work.session;
        var completed = try parent.context.fork(self.allocator);
        errdefer completed.deinit();
        try completed.appendBatch(output, replies);
        try self.sessions.ensureUnusedCapacity(self.allocator, @intCast(plans.len));
        try parent.pending.ensureUnusedCapacity(self.allocator, 1);
        var prepared: usize = 0;
        errdefer for (plans[0..prepared]) |plan| plan.child.context.deinit();
        for (plans) |plan| {
            try plan.child.pending.ensureUnusedCapacity(self.allocator, parent.pending.items.len);
            plan.child.context = try completed.fork(self.allocator);
            prepared += 1;
        }
        parent.context.deinit();
        parent.context = completed;
        parent.generation += 1;
        var result: Commit = .continuing;
        for (plans) |plan| {
            const child = plan.child;
            child.parent_generation = parent.generation;
            self.sessions.putAssumeCapacity(child.session_id, child);
            self.reserved -= 1;
            parent.children += 1;
            switch (plan.request.mode) {
                .handoff => {
                    child.report_to = parent.report_to;
                    parent.report_to = null;
                    if (work.delivery.source_state) |source| if (source.route) |route| {
                        self.routes.getPtr(route).?.* = child.session_id;
                        var index: usize = 0;
                        while (index < parent.pending.items.len) {
                            const queued = parent.pending.items[index].source_state;
                            const queued_route = if (queued) |source_state| source_state.route else null;
                            if (queued_route != null and std.mem.eql(u8, queued_route.?, route)) {
                                child.pending.appendAssumeCapacity(parent.pending.orderedRemove(index));
                            } else index += 1;
                        }
                    };
                    parent.active = null;
                    parent.state = .ready;
                    work.delivery.destroy(self.allocator);
                    result = .handed_off;
                },
                .subtask => |subtask| if (subtask.report_to_parent) {
                    child.report_to = parent.session_id;
                    parent.waiting_reports += 1;
                },
            }
        }
        if (result != .handed_off and parent.waiting_reports != 0) {
            parent.state = .waiting;
            result = .waiting;
        }
        return result;
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
        const active = session.active;
        return .{
            .session_id = session.session_id,
            .state = .{
                .session = .{
                    .role = session.role,
                    .parent_generation = session.parent_generation,
                    .parent_session_id = session.parent_session_id,
                    .active_children = session.children,
                },
                .response = if (active) |delivery| responseFor(session, delivery) else .{ .internal = .{} },
                .runtime = .{
                    .active_sessions = self.sessions.count(),
                    .running_sessions = running,
                    .queued_inputs = queued,
                },
            },
        };
    }

    /// Finishing an activation releases context independently of transport
    /// retention. Kernel completes required handover storage before this call.
    pub fn finish(self: *Registry, work: Work, text: ?[]const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        assertWork(work);
        const session = work.session;
        try self.notifyParent(session, text orelse "");
        if (work.delivery.source_state) |source| {
            self.markHandled(source.input_key);
            if (source.route) |route| if (session == self.core and !hasPendingRoute(session, route))
                self.removeRoute(route, session.session_id);
        }
        session.active = null;
        session.state = .ready;
        work.delivery.destroy(self.allocator);
        self.releaseIdle(session);
    }

    /// Keeps session pointers alive until their Kernel worker has returned,
    /// including handoff workers whose active delivery moved to another session.
    pub fn endWorker(self: *Registry, session_id: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const session = self.sessions.get(session_id).?;
        session.borrowed_workers -= 1;
        self.releaseIdle(session);
    }

    fn notifyParent(self: *Registry, session: *Session, text: []const u8) !void {
        const target = session.report_to orelse return;
        const parent = self.sessions.get(target).?;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        try parent.context.appendInput(try Input.serialize(a, parent.session_id, .{ .report = .{ .from_session = session.session_id, .text = text } }));
        parent.generation += 1;
        parent.waiting_reports -= 1;
        if (parent.waiting_reports == 0 and parent.state == .waiting) {
            parent.pending.insertAssumeCapacity(0, parent.active.?);
            parent.active = null;
            parent.state = .ready;
        }
        session.report_to = null;
    }

    pub fn handled(self: *Registry, input_key: []const u8) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return self.noticed.get(input_key) == .handled;
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
                const source = incoming.source_state orelse continue;
                if (std.mem.eql(u8, entry.key_ptr.*, source.input_key)) break true;
            } else false;
            if (!present) try absent.append(self.allocator, entry.key_ptr.*);
        }
        for (absent.items) |key| if (self.noticed.fetchRemove(key)) |entry| self.allocator.free(entry.key);
    }

    /// Reply targets and source-state bindings independently keep adapter-owned
    /// receipts live. Both can be absent from native input or internal work.
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
            if (entry.*.active) |delivery| try retainDeliveryReceipts(a, &receipts, delivery);
            for (entry.*.pending.items) |delivery| try retainDeliveryReceipts(a, &receipts, delivery);
        }
        return receipts.toOwnedSlice(a);
    }

    fn releaseIdle(self: *Registry, session: *Session) void {
        if (session == self.core or session.state != .ready or session.active != null or session.pending.items.len != 0 or session.children != 0 or session.borrowed_workers != 0) return;
        const parent_id = session.parent_session_id;
        self.removeOwnedRoutes(session.session_id);
        _ = self.sessions.remove(session.session_id);
        self.destroySession(session);
        if (parent_id) |id| if (self.sessions.get(id)) |parent| {
            parent.children -= 1;
            self.releaseIdle(parent);
        };
    }

    fn removeRoute(self: *Registry, route: []const u8, owner: u64) void {
        if (self.routes.get(route) != owner) return;
        if (self.routes.fetchRemove(route)) |entry| self.allocator.free(entry.key);
    }

    fn removeOwnedRoutes(self: *Registry, owner: u64) void {
        while (true) {
            var routes = self.routes.iterator();
            const key = while (routes.next()) |entry| {
                if (entry.value_ptr.* == owner) break entry.key_ptr.*;
            } else return;
            self.removeRoute(key, owner);
        }
    }

    fn runningWorkers(self: *Registry) usize {
        var running: usize = 0;
        var sessions = self.sessions.valueIterator();
        while (sessions.next()) |entry| if (entry.* != self.core and entry.*.state == .running) {
            running += 1;
        };
        return running;
    }

    fn markHandled(self: *Registry, input_key: []const u8) void {
        self.noticed.getPtr(input_key).?.* = .handled;
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

fn hasPendingRoute(session: *const Session, route: []const u8) bool {
    for (session.pending.items) |delivery| {
        const source = delivery.source_state orelse continue;
        const queued_route = source.route orelse continue;
        if (std.mem.eql(u8, queued_route, route)) return true;
    }
    return false;
}

fn responseFor(session: *const Session, delivery: *const Delivery) Input.Response {
    if (delivery.reply) |reply| return .{ .reply = .{ .audience = reply.audience } };
    if (session.report_to) |parent| return .{ .report = .{ .session_id = parent } };
    return .{ .internal = .{} };
}

fn retainDeliveryReceipts(a: Allocator, receipts: *std.ArrayList([]const u8), delivery: *const Delivery) !void {
    if (delivery.reply) |reply| try retainReceipt(a, receipts, reply.receipt);
    if (delivery.source_state) |source| try retainReceipt(a, receipts, source.receipt);
}

fn retainReceipt(a: Allocator, receipts: *std.ArrayList([]const u8), value: []const u8) !void {
    for (receipts.items) |receipt| if (std.mem.eql(u8, receipt, value)) return;
    try receipts.ensureUnusedCapacity(a, 1);
    receipts.appendAssumeCapacity(try a.dupe(u8, value));
}

fn assertWork(work: Work) void {
    std.debug.assert(work.session.state == .running and work.session.active == work.delivery);
}
