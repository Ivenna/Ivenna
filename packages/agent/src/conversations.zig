const std = @import("std");
const Context = @import("context.zig").Context;
const Input = @import("input.zig");
const Mail = @import("mail.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Delivery = struct {
    pub const Kind = union(enum) {
        input,
        assignment: []const u8,
    };

    arena: std.heap.ArenaAllocator,
    letter: Mail.Letter,
    kind: Kind,
    audience: Input.Audience,
    tracks_mail: bool,
    background: []const Input.Background = &.{},
    supplied: bool = false,

    fn create(allocator: Allocator, letter: Mail.Letter, kind: Kind, audience: Input.Audience, tracks_mail: bool, background: []const Input.Background) !*Delivery {
        const self = try allocator.create(Delivery);
        errdefer allocator.destroy(self);
        self.* = .{ .arena = .init(allocator), .letter = undefined, .kind = undefined, .audience = audience, .tracks_mail = tracks_mail };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        self.letter = try std.json.parseFromSliceLeaky(Mail.Letter, a, try std.json.Stringify.valueAlloc(a, letter, .{}), .{ .allocate = .alloc_always });
        self.kind = switch (kind) {
            .input => .input,
            .assignment => |task| .{ .assignment = try a.dupe(u8, task) },
        };
        self.background = try std.json.parseFromSliceLeaky([]const Input.Background, a, try std.json.Stringify.valueAlloc(a, background, .{}), .{ .allocate = .alloc_always });
        return self;
    }

    fn destroy(self: *Delivery, allocator: Allocator) void {
        self.arena.deinit();
        allocator.destroy(self);
    }
};

/// A session owns reasoning history independently of mail-thread routing.
/// The core is permanent; branch sessions may retain an idle context while
/// their children continue without occupying an execution slot.
pub const Conversation = struct {
    session_id: u64,
    role: Input.Role,
    context: Context,
    thread_id: []const u8,
    parent_session_id: ?u64 = null,
    parent_generation: ?u64 = null,
    generation: u64 = 0,
    state: enum { ready, running, waiting, paused } = .ready,
    active: ?*Delivery = null,
    pending: std.ArrayList(*Delivery) = .empty,
    borrowed_workers: usize = 0,
    children: usize = 0,
    waiting_reports: usize = 0,
    report_to: ?u64 = null,
    releasable: bool = true,
};

pub const Work = struct { conversation: *Conversation, delivery: *Delivery };

pub const ForkRequest = struct {
    task: []const u8,
    mode: union(enum) { handoff: struct {}, subtask: struct { report_to_parent: bool = false } } = .{ .handoff = .{} },
};

/// Reserved during tool invocation, materialized only after the complete batch.
pub const ForkPlan = struct {
    child: *Conversation,
    request: ForkRequest,
};

pub const Commit = struct { handed_off: bool = false, waiting: bool = false };

pub const Registry = struct {
    allocator: Allocator,
    io: std.Io,
    max_contexts: usize,
    mutex: std.Io.Mutex = .init,
    core: *Conversation,
    sessions: std.AutoHashMapUnmanaged(u64, *Conversation) = .empty,
    routes: std.StringHashMapUnmanaged(u64) = .empty,
    noticed: std.StringHashMapUnmanaged(enum { scheduled, handled }) = .empty,
    reserved: usize = 0,
    next_session_id: u64 = 2,

    pub fn init(allocator: Allocator, io: std.Io, max_contexts: usize) !Registry {
        if (max_contexts == 0) return error.InvalidConversationLimit;
        const core = try allocator.create(Conversation);
        errdefer allocator.destroy(core);
        var context = try Context.init(allocator, @embedFile("system.md"));
        errdefer context.deinit();
        const thread = try allocator.dupe(u8, "");
        errdefer allocator.free(thread);
        core.* = .{ .session_id = 1, .role = .core, .context = context, .thread_id = thread };
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

    pub fn acceptExisting(self: *Registry, letter: Mail.Letter, audience: Input.Audience) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const owner = self.routes.get(letter.thread_id) orelse return false;
        _ = try self.acceptLocked(self.sessions.get(owner).?, letter, audience, &.{});
        return true;
    }

    /// An unknown thread always enters the permanent coordinator. Thread
    /// reconstruction is observation background, never an implicit fork.
    pub fn accept(self: *Registry, letter: Mail.Letter, audience: Input.Audience, background: []const Input.Background) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const session = if (self.routes.get(letter.thread_id)) |owner| self.sessions.get(owner).? else self.core;
        return self.acceptLocked(session, letter, audience, background);
    }

    fn acceptLocked(self: *Registry, session: *Conversation, letter: Mail.Letter, audience: Input.Audience, background: []const Input.Background) !bool {
        const notice = letter.message_id orelse letter.id;
        if (self.noticed.contains(notice)) return false;
        if (session.pending.items.len + @as(usize, @intFromBool(session.active != null)) >= self.max_contexts and session.state != .paused) return false;
        const delivery = try Delivery.create(self.allocator, letter, .input, audience, true, background);
        errdefer delivery.destroy(self.allocator);
        try session.pending.ensureUnusedCapacity(self.allocator, 1 + @as(usize, @intFromBool(session.active != null)));
        const key = try self.allocator.dupe(u8, notice);
        errdefer self.allocator.free(key);
        var added_route = false;
        if (!self.routes.contains(letter.thread_id)) {
            const thread = try self.allocator.dupe(u8, letter.thread_id);
            errdefer self.allocator.free(thread);
            try self.routes.put(self.allocator, thread, session.session_id);
            added_route = true;
        }
        errdefer if (added_route) self.removeRoute(letter.thread_id, session.session_id);
        try self.noticed.put(self.allocator, key, .scheduled);
        if (letter.flagged or session.state == .paused) session.pending.insertAssumeCapacity(0, delivery) else session.pending.appendAssumeCapacity(delivery);
        if (session.state == .paused) session.state = .ready;
        return true;
    }

    /// The coordinator has its own serialized execution lane. max_parallel
    /// bounds work sessions independently, so a long work tool cannot take the
    /// coordinator's execution slot.
    pub fn nextReady(self: *Registry, max_parallel: usize) !?Work {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (ready(self.core)) return take(self.core);
        if (self.runningWorkers() >= max_parallel) return null;
        var chosen: ?*Conversation = null;
        var sessions = self.sessions.valueIterator();
        while (sessions.next()) |entry| {
            const session = entry.*;
            if (session == self.core or !ready(session)) continue;
            if (chosen == null or (session.pending.items[0].letter.flagged and !chosen.?.pending.items[0].letter.flagged)) chosen = session;
        }
        return if (chosen) |session| take(session) else null;
    }

    pub fn prepareFork(self: *Registry, work: Work, request: ForkRequest) !ForkPlan {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try validateWork(work);
        if (request.task.len == 0 or std.mem.indexOfScalar(u8, request.task, 0) != null) return error.InvalidForkArguments;
        if (work.conversation == self.core and request.mode != .handoff) return error.CoreRequiresHandoff;
        if (self.sessions.count() + self.reserved >= self.max_contexts) return error.AttentionCapacityUnavailable;
        const child = try self.allocator.create(Conversation);
        errdefer self.allocator.destroy(child);
        const thread = try self.allocator.dupe(u8, work.delivery.letter.thread_id);
        errdefer self.allocator.free(thread);
        const delivery = try Delivery.create(self.allocator, work.delivery.letter, .{ .assignment = request.task }, if (request.mode == .handoff) work.delivery.audience else .internal, request.mode == .handoff and work.delivery.tracks_mail, &.{});
        errdefer delivery.destroy(self.allocator);
        child.* = .{
            .session_id = self.next_session_id,
            .role = .branch,
            .context = undefined,
            .thread_id = thread,
            .parent_session_id = work.conversation.session_id,
        };
        try child.pending.append(self.allocator, delivery);
        self.next_session_id += 1;
        self.reserved += 1;
        return .{ .child = child, .request = .{ .task = delivery.kind.assignment, .mode = request.mode } };
    }

    pub fn abandonForks(self: *Registry, plans: []const ForkPlan) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (plans) |plan| {
            self.reserved -= 1;
            for (plan.child.pending.items) |delivery| delivery.destroy(self.allocator);
            plan.child.pending.deinit(self.allocator);
            self.allocator.free(plan.child.thread_id);
            self.allocator.destroy(plan.child);
        }
    }

    /// Commit before child execution: every fork includes this response and
    /// exactly one result per call, never an unfinished exchange. All plans
    /// remain caller-owned on failure; success consumes them together.
    pub fn commitRound(self: *Registry, work: Work, output: []const Value, replies: []const Value, plans: []const ForkPlan) !Commit {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try validateWork(work);
        const parent = work.conversation;
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
        var result: Commit = .{};
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
                    if (work.delivery.tracks_mail) {
                        self.routes.getPtr(work.delivery.letter.thread_id).?.* = child.session_id;
                        var index: usize = 0;
                        while (index < parent.pending.items.len) {
                            if (std.mem.eql(u8, parent.pending.items[index].letter.thread_id, work.delivery.letter.thread_id)) {
                                child.pending.appendAssumeCapacity(parent.pending.orderedRemove(index));
                            } else index += 1;
                        }
                    }
                    parent.active = null;
                    parent.state = .ready;
                    work.delivery.destroy(self.allocator);
                    result.handed_off = true;
                },
                .subtask => |subtask| if (subtask.report_to_parent) {
                    child.report_to = parent.session_id;
                    parent.waiting_reports += 1;
                },
            }
        }
        if (!result.handed_off and parent.waiting_reports != 0) {
            parent.state = .waiting;
            result.waiting = true;
        }
        return result;
    }

    pub fn snapshot(self: *Registry, session: *Conversation) !Context {
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

    pub fn appendInput(self: *Registry, session: *Conversation, text: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try session.context.appendInput(text);
        session.generation += 1;
    }

    pub fn replaceContext(self: *Registry, session: *Conversation, replacement: Context) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        session.context.deinit();
        session.context = replacement;
        session.generation += 1;
    }

    pub fn runtimeSnapshot(self: *Registry, session: *Conversation) !Input.Snapshot {
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
                .conversation = .{
                    .role = session.role,
                    .parent_generation = session.parent_generation,
                    .parent_session_id = session.parent_session_id,
                    .active_children = session.children,
                    .thread_id = if (active) |delivery| delivery.letter.thread_id else session.thread_id,
                },
                .response = .{
                    .audience = if (active) |delivery| delivery.audience else .internal,
                    .source_mail_id = if (active) |delivery| delivery.letter.id else null,
                },
                .runtime = .{
                    .active_sessions = self.sessions.count(),
                    .running_sessions = running,
                    .active_conversations = self.routes.count(),
                    .queued_turns = queued,
                },
            },
        };
    }

    /// A completed activation can release its working context without moving
    /// any source correspondence out of Inbox. A failed handover keeps context.
    pub fn finish(self: *Registry, work: Work, text: ?[]const u8, releasable: bool) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try validateWork(work);
        const session = work.conversation;
        try self.notifyParent(session, .{ .completed = text orelse "" });
        if (work.delivery.tracks_mail) self.markHandled(work.delivery.letter);
        const finished_thread = work.delivery.letter.thread_id;
        if (session == self.core and !hasPendingThread(session, finished_thread)) self.removeRoute(finished_thread, session.session_id);
        session.active = null;
        session.state = .ready;
        session.releasable = releasable;
        work.delivery.destroy(self.allocator);
        self.releaseIdle(session);
    }

    pub fn fail(self: *Registry, work: Work, failure: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        validateWork(work) catch return;
        if (!work.delivery.tracks_mail) {
            try self.notifyParent(work.conversation, .{ .failed = failure });
            work.conversation.active = null;
            work.conversation.state = .ready;
            work.delivery.destroy(self.allocator);
            self.releaseIdle(work.conversation);
        } else {
            work.conversation.pending.insertAssumeCapacity(0, work.delivery);
            work.conversation.active = null;
            work.conversation.state = .paused;
        }
    }

    /// Keeps session pointers alive until their Kernel worker has returned,
    /// including handoff workers whose active delivery moved to another session.
    pub fn endWorker(self: *Registry, session_id: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const session = self.sessions.get(session_id) orelse return;
        session.borrowed_workers -= 1;
        self.releaseIdle(session);
    }

    fn notifyParent(self: *Registry, session: *Conversation, outcome: Input.ReportOutcome) !void {
        const target = session.report_to orelse return;
        const parent = self.sessions.get(target) orelse return error.ReportParentUnavailable;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        try parent.context.appendInput(try Input.serialize(a, parent.session_id, .{ .report = .{ .from_session = session.session_id, .outcome = outcome } }));
        parent.generation += 1;
        parent.waiting_reports -= 1;
        if (parent.waiting_reports == 0 and parent.state == .waiting) {
            parent.pending.insertAssumeCapacity(0, parent.active.?);
            parent.active = null;
            parent.state = .ready;
        }
        session.report_to = null;
    }

    pub fn handled(self: *Registry, letter: Mail.Letter) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return self.noticed.get(letter.message_id orelse letter.id) == .handled;
    }

    pub fn reconcile(self: *Registry, waiting: []const Mail.Letter) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var absent: std.ArrayList([]const u8) = .empty;
        defer absent.deinit(self.allocator);
        var notices = self.noticed.iterator();
        while (notices.next()) |entry| {
            if (entry.value_ptr.* != .handled) continue;
            const present = for (waiting) |letter| {
                if (std.mem.eql(u8, entry.key_ptr.*, letter.message_id orelse letter.id)) break true;
            } else false;
            if (!present) try absent.append(self.allocator, entry.key_ptr.*);
        }
        for (absent.items) |key| if (self.noticed.fetchRemove(key)) |entry| self.allocator.free(entry.key);
    }

    fn releaseIdle(self: *Registry, session: *Conversation) void {
        if (session == self.core or session.state != .ready or session.active != null or session.pending.items.len != 0 or session.children != 0 or session.borrowed_workers != 0 or !session.releasable) return;
        const parent_id = session.parent_session_id;
        self.removeRoute(session.thread_id, session.session_id);
        _ = self.sessions.remove(session.session_id);
        self.destroySession(session);
        if (parent_id) |id| if (self.sessions.get(id)) |parent| {
            parent.children -= 1;
            self.releaseIdle(parent);
        };
    }

    fn removeRoute(self: *Registry, thread_id: []const u8, owner: u64) void {
        if (self.routes.get(thread_id) != owner) return;
        if (self.routes.fetchRemove(thread_id)) |entry| self.allocator.free(entry.key);
    }

    fn runningWorkers(self: *Registry) usize {
        var running: usize = 0;
        var sessions = self.sessions.valueIterator();
        while (sessions.next()) |entry| if (entry.* != self.core and entry.*.state == .running) {
            running += 1;
        };
        return running;
    }

    fn markHandled(self: *Registry, letter: Mail.Letter) void {
        if (self.noticed.getPtr(letter.message_id orelse letter.id)) |notice| notice.* = .handled;
    }

    fn destroySession(self: *Registry, session: *Conversation) void {
        if (session.active) |delivery| delivery.destroy(self.allocator);
        for (session.pending.items) |delivery| delivery.destroy(self.allocator);
        session.pending.deinit(self.allocator);
        session.context.deinit();
        self.allocator.free(session.thread_id);
        self.allocator.destroy(session);
    }
};

fn ready(session: *const Conversation) bool {
    return session.state == .ready and session.pending.items.len != 0;
}

fn take(session: *Conversation) Work {
    const delivery = session.pending.orderedRemove(0);
    session.active = delivery;
    session.borrowed_workers += 1;
    session.state = .running;
    return .{ .conversation = session, .delivery = delivery };
}

fn hasPendingThread(session: *const Conversation, thread_id: []const u8) bool {
    for (session.pending.items) |delivery| if (std.mem.eql(u8, delivery.letter.thread_id, thread_id)) return true;
    return false;
}

fn validateWork(work: Work) !void {
    if (work.conversation.state != .running or work.conversation.active != work.delivery) return error.InvalidConversationWork;
}
