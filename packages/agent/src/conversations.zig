const std = @import("std");
const Context = @import("context.zig").Context;
const Input = @import("input.zig");
const Mail = @import("mail.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Delivery = struct {
    arena: std.heap.ArenaAllocator,
    letter: Mail.Letter,
    supplied: bool = false,
    kind: enum { input, report } = .input,

    fn create(allocator: Allocator, letter: Mail.Letter, report: bool) !*Delivery {
        const self = try allocator.create(Delivery);
        errdefer allocator.destroy(self);
        self.* = .{ .arena = .init(allocator), .letter = undefined, .kind = if (report) .report else .input };
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const encoded = try std.json.Stringify.valueAlloc(a, letter, .{});
        self.letter = try std.json.parseFromSliceLeaky(Mail.Letter, a, encoded, .{ .allocate = .alloc_always });
        return self;
    }

    fn destroy(self: *Delivery, allocator: Allocator) void {
        self.arena.deinit();
        allocator.destroy(self);
    }
};

pub const Conversation = struct {
    session_id: u64,
    thread_id: []const u8,
    role: union(enum) { core, branch: Context },
    parent_generation: ?u64,
    state: union(enum) { ready, running: *Delivery, paused, archiving: *Delivery } = .ready,
    pending: std.ArrayList(*Delivery) = .empty,
    processed_ids: std.ArrayList([]const u8) = .empty,
    borrowed_reports: usize = 0,
};

/// A worker borrows the conversation and owns this delivery until finish or a
/// successful retire. Kernel must end its workers before deinitializing Registry.
pub const Work = struct {
    conversation: *Conversation,
    delivery: *Delivery,
};

/// The core outlives correspondence. Only active correspondence owns entries
/// here; archived threads are restored from the mailbox when new mail arrives.
pub const Registry = struct {
    allocator: Allocator,
    io: std.Io,
    max_contexts: usize,
    mutex: std.Io.Mutex = .init,
    core: Context,
    core_generation: u64 = 0,
    core_owner: ?*Conversation = null,
    live: std.StringHashMapUnmanaged(*Conversation) = .empty,
    noticed: std.StringHashMapUnmanaged(enum { scheduled, handled }) = .empty,
    next_session_id: u64 = 2,

    pub const deletion = enum { planned }.planned;

    pub fn init(allocator: Allocator, io: std.Io, max_contexts: usize) !Registry {
        if (max_contexts == 0) return error.InvalidConversationLimit;
        return .{ .allocator = allocator, .io = io, .max_contexts = max_contexts, .core = try Context.init(allocator, @embedFile("system.md")) };
    }

    pub fn deinit(self: *Registry) void {
        var conversations = self.live.valueIterator();
        while (conversations.next()) |conversation| self.destroyConversation(conversation.*);
        self.live.deinit(self.allocator);
        var keys = self.noticed.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.noticed.deinit(self.allocator);
        self.core.deinit();
        self.* = undefined;
    }

    pub fn contains(self: *Registry, thread_id: []const u8) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return self.live.contains(thread_id);
    }

    pub fn intakeLimit(self: *Registry) !usize {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return self.noticed.count() + @max(32, self.max_contexts * 2);
    }

    /// A non-null accepted result takes ownership of restored, even when an
    /// existing live thread made that prepared restoration unnecessary. Rejected
    /// input leaves restored owned by the caller. New restored threads always
    /// get a dedicated branch, while new threads otherwise use a free core.
    pub fn accept(self: *Registry, letter: Mail.Letter, restored: ?Context) !?*Conversation {
        return self.acceptLetter(letter, restored, false);
    }

    /// True means the live thread was found, including duplicate or deferred
    /// input. Lookup and admission share the retirement lock, so callers never
    /// accidentally reopen a retired thread without its archived background.
    pub fn acceptExisting(self: *Registry, letter: Mail.Letter) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.live.contains(letter.thread_id)) return false;
        _ = try self.acceptLetterLocked(letter, null, false);
        return true;
    }

    /// Kernel has already checked that this is a report for the core. It joins
    /// the current core conversation without becoming another routing alias.
    pub fn acceptCore(self: *Registry, letter: Mail.Letter) !?*Conversation {
        return self.acceptLetter(letter, null, true);
    }

    fn acceptLetter(self: *Registry, letter: Mail.Letter, restored: ?Context, report: bool) !?*Conversation {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return self.acceptLetterLocked(letter, restored, report);
    }

    fn acceptLetterLocked(self: *Registry, letter: Mail.Letter, restored: ?Context, report: bool) !?*Conversation {
        const notice_key = letter.message_id orelse letter.id;
        if (self.noticed.contains(notice_key)) return null;
        var target = if (report) self.core_owner else self.live.get(letter.thread_id);
        var created = false;
        var takes_restored = false;
        if (target == null) {
            if (self.live.contains(letter.thread_id)) return error.CoreThreadAlreadyActive;
            const branch = restored != null or self.core_owner != null;
            if (branch and self.contextCount() >= self.max_contexts) return null;
            const conversation = try self.allocator.create(Conversation);
            errdefer self.allocator.destroy(conversation);
            const thread_id = try self.allocator.dupe(u8, letter.thread_id);
            errdefer self.allocator.free(thread_id);
            var role: @FieldType(Conversation, "role") = .core;
            if (branch) role = .{ .branch = if (restored) |restored_view| restored_view else try self.core.fork(self.allocator) };
            errdefer if (branch and restored == null) role.branch.deinit();
            conversation.* = .{
                .session_id = if (branch) self.next_session_id else 1,
                .thread_id = thread_id,
                .role = role,
                .parent_generation = if (branch and restored == null) self.core_generation else null,
            };
            try self.live.put(self.allocator, thread_id, conversation);
            if (branch) self.next_session_id += 1 else self.core_owner = conversation;
            target = conversation;
            created = true;
            takes_restored = restored != null;
        }
        const conversation = target.?;
        // Capacity reserves every borrowed delivery, allowing failure cleanup to
        // return it without allocating. One new direction can wake a full pause.
        const held = conversation.borrowed_reports + @as(usize, @intFromBool(isWorking(conversation)));
        const waking = conversation.state == .paused;
        if (conversation.pending.items.len + held >= self.max_contexts and !waking) return null;
        errdefer if (created) {
            _ = self.live.remove(conversation.thread_id);
            if (conversation.role == .core) self.core_owner = null;
            // A restored context remains caller-owned if admission fails.
            if (takes_restored) conversation.role = .core;
            self.destroyConversation(conversation);
        };
        try conversation.pending.ensureUnusedCapacity(self.allocator, 1 + held);
        const delivery = try Delivery.create(self.allocator, letter, report);
        errdefer delivery.destroy(self.allocator);
        const key = try self.allocator.dupe(u8, notice_key);
        errdefer self.allocator.free(key);
        try self.noticed.put(self.allocator, key, .scheduled);
        if (letter.flagged or waking) conversation.pending.insertAssumeCapacity(0, delivery) else conversation.pending.appendAssumeCapacity(delivery);
        if (waking) conversation.state = .ready;
        if (restored != null and !takes_restored) {
            var unused = restored.?;
            unused.deinit();
        }
        return conversation;
    }

    pub fn nextReady(self: *Registry, max_parallel: usize) !?Work {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.runningCount() >= max_parallel) return null;
        var chosen: ?*Conversation = null;
        var conversations = self.live.valueIterator();
        while (conversations.next()) |entry| {
            const conversation = entry.*;
            if (conversation.state != .ready or conversation.pending.items.len == 0) continue;
            if (chosen == null or (conversation.pending.items[0].letter.flagged and !chosen.?.pending.items[0].letter.flagged)) chosen = conversation;
        }
        const conversation = chosen orelse return null;
        const delivery = conversation.pending.orderedRemove(0);
        conversation.state = .{ .running = delivery };
        return .{ .conversation = conversation, .delivery = delivery };
    }

    pub fn snapshot(self: *Registry, conversation: *Conversation) !Context {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return self.context(conversation).fork(self.allocator);
    }

    pub fn snapshotCore(self: *Registry) !Context {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return self.core.fork(self.allocator);
    }

    pub fn appendCoreInput(self: *Registry, text: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.core.appendInput(text);
        self.core_generation += 1;
    }

    pub fn appendInput(self: *Registry, conversation: *Conversation, text: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.context(conversation).appendInput(text);
        if (conversation.role == .core) self.core_generation += 1;
    }

    pub fn appendBatch(self: *Registry, conversation: *Conversation, output: []const Value, replies: []const Value) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.context(conversation).appendBatch(output, replies);
        if (conversation.role == .core) self.core_generation += 1;
    }

    /// Ownership transfers only on success.
    pub fn replaceContext(self: *Registry, conversation: *Conversation, replacement: Context) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const current = self.context(conversation);
        current.deinit();
        current.* = replacement;
        if (conversation.role == .core) self.core_generation += 1;
    }

    pub fn runtimeSnapshot(self: *Registry, conversation: *Conversation) !Input.Snapshot {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        var queued: usize = 0;
        var conversations = self.live.valueIterator();
        while (conversations.next()) |entry| queued += entry.*.pending.items.len;
        return .{
            .session_id = conversation.session_id,
            .role = if (conversation.role == .core) .core else .branch,
            .parent_generation = conversation.parent_generation,
            .thread_id = conversation.thread_id,
            .runtime = .{
                .active_sessions = self.contextCount(),
                .running_sessions = self.runningCount(),
                .active_conversations = self.live.count(),
                .queued_turns = queued,
            },
        };
    }

    pub fn recordLetterID(self: *Registry, conversation: *Conversation, id: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        for (conversation.processed_ids.items) |known| if (std.mem.eql(u8, known, id)) return;
        const copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(copy);
        try conversation.processed_ids.append(self.allocator, copy);
    }

    /// Copies IDs because archive I/O must not borrow registry-owned buffers.
    pub fn processedIDs(self: *Registry, a: Allocator, conversation: *Conversation) ![]const []const u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const ids = try a.alloc([]const u8, conversation.processed_ids.items.len);
        for (ids, conversation.processed_ids.items) |*copy, id| copy.* = try a.dupe(u8, id);
        return ids;
    }

    pub fn beginArchive(self: *Registry, conversation: *Conversation) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (conversation.pending.items.len != 0 or conversation.borrowed_reports != 0) return false;
        switch (conversation.state) {
            .running => |delivery| conversation.state = .{ .archiving = delivery },
            .archiving => {},
            else => return false,
        }
        return true;
    }

    /// True consumes Work and releases the whole active conversation. False
    /// leaves Work with its caller, who can finish it and schedule queued mail.
    /// The permanent core context is never retired with correspondence.
    pub fn retire(self: *Registry, work: Work) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try validateWork(work);
        const conversation = work.conversation;
        if (conversation.state != .archiving) return error.ConversationNotArchiving;
        if (conversation.pending.items.len != 0 or conversation.borrowed_reports != 0) {
            conversation.state = .{ .running = work.delivery };
            return false;
        }
        self.markHandled(work.delivery.letter);
        _ = self.live.remove(conversation.thread_id);
        if (conversation.role == .core) self.core_owner = null;
        work.delivery.destroy(self.allocator);
        conversation.state = .ready;
        self.destroyConversation(conversation);
        return true;
    }

    pub fn finish(self: *Registry, work: Work, success: bool) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try validateWork(work);
        const conversation = work.conversation;
        if (conversation.borrowed_reports != 0) return error.ReportStillBorrowed;
        if (success) {
            self.markHandled(work.delivery.letter);
            work.delivery.destroy(self.allocator);
            conversation.state = .ready;
        } else {
            conversation.pending.insertAssumeCapacity(0, work.delivery);
            conversation.state = .paused;
        }
    }

    pub fn takeCoreReport(self: *Registry, conversation: *Conversation) !?*Delivery {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (conversation.role != .core) return null;
        for (conversation.pending.items, 0..) |delivery, index| {
            if (delivery.kind != .report) continue;
            _ = conversation.pending.orderedRemove(index);
            conversation.borrowed_reports += 1;
            return delivery;
        }
        return null;
    }

    /// Takes ownership only after the source frame has been copied. Read means
    /// incorporation into context, not completed model interpretation. Report
    /// IDs are not part of this external thread's archive set.
    pub fn consumeReport(self: *Registry, conversation: *Conversation, delivery: *Delivery, rendered_yaml: []const u8) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.context(conversation).appendInput(rendered_yaml);
        self.core_generation += 1;
        self.markHandled(delivery.letter);
        conversation.borrowed_reports -= 1;
        delivery.destroy(self.allocator);
    }

    pub fn returnReport(self: *Registry, conversation: *Conversation, delivery: *Delivery) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        conversation.pending.insertAssumeCapacity(0, delivery);
        conversation.borrowed_reports -= 1;
    }

    pub fn handled(self: *Registry, letter: Mail.Letter) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return self.noticed.get(letter.message_id orelse letter.id) == .handled;
    }

    /// Keep completion notices through stale unread snapshots. Seeing absence
    /// permits a later deliberate mark-unread operation to submit the mail again.
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

    fn context(self: *Registry, conversation: *Conversation) *Context {
        return switch (conversation.role) {
            .core => &self.core,
            .branch => |*branch| branch,
        };
    }

    fn contextCount(self: *Registry) usize {
        var count: usize = 1;
        var conversations = self.live.valueIterator();
        while (conversations.next()) |entry| if (entry.*.role == .branch) {
            count += 1;
        };
        return count;
    }

    fn runningCount(self: *Registry) usize {
        var count: usize = 0;
        var conversations = self.live.valueIterator();
        while (conversations.next()) |entry| if (isWorking(entry.*)) {
            count += 1;
        };
        return count;
    }

    fn markHandled(self: *Registry, letter: Mail.Letter) void {
        if (self.noticed.getPtr(letter.message_id orelse letter.id)) |notice| notice.* = .handled;
    }

    fn destroyConversation(self: *Registry, conversation: *Conversation) void {
        for (conversation.pending.items) |delivery| delivery.destroy(self.allocator);
        conversation.pending.deinit(self.allocator);
        for (conversation.processed_ids.items) |id| self.allocator.free(id);
        conversation.processed_ids.deinit(self.allocator);
        if (conversation.role == .branch) conversation.role.branch.deinit();
        self.allocator.free(conversation.thread_id);
        self.allocator.destroy(conversation);
    }
};

fn isWorking(conversation: *const Conversation) bool {
    return conversation.state == .running or conversation.state == .archiving;
}

fn validateWork(work: Work) !void {
    switch (work.conversation.state) {
        .running, .archiving => |delivery| if (delivery != work.delivery) return error.InvalidConversationWork,
        else => return error.InvalidConversationWork,
    }
}
