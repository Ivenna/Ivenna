const std = @import("std");
const Context = @import("context.zig").Context;
const Compaction = @import("compaction.zig");
const Engine = @import("engine.zig").Engine;
const Input = @import("input.zig");
const Conversations = @import("conversations.zig");
const Mail = @import("mail.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Conversation = Conversations.Conversation;
const Work = Conversations.Work;

/// Owns external I/O and task scopes. Registry owns the permanent core and
/// active correspondence; a worker handles one incoming letter's mail turn.
pub const Kernel = struct {
    allocator: Allocator,
    io: std.Io,
    engine: *Engine,
    mailbox: *Mail.Mailbox,
    limits: Limits,
    poll_interval_ms: u32,
    max_parallel: usize,
    conversations: Conversations.Registry,
    workers: std.Io.Group = .init,

    /// Whole serialized request bounds. Exact model-specific token and image
    /// accounting is a separate, currently planned capability.
    pub const Limits = struct {
        request_bytes: u64 = 65536,
        compaction_bytes: u64 = 131072,
        handover_bytes: usize = 8192,
    };

    pub fn init(allocator: Allocator, io: std.Io, engine: *Engine, mailbox: *Mail.Mailbox, limits: Limits, poll_interval_ms: u32, max_parallel: usize, max_contexts: usize) !Kernel {
        if (max_parallel == 0 or max_contexts < max_parallel or poll_interval_ms == 0 or
            limits.request_bytes == 0 or limits.compaction_bytes < limits.request_bytes or limits.handover_bytes == 0)
            return error.InvalidKernelConfiguration;
        return .{
            .allocator = allocator,
            .io = io,
            .engine = engine,
            .mailbox = mailbox,
            .limits = limits,
            .poll_interval_ms = poll_interval_ms,
            .max_parallel = max_parallel,
            .conversations = try Conversations.Registry.init(allocator, io, max_contexts),
        };
    }

    pub fn deinit(self: *Kernel) void {
        self.conversations.deinit();
        self.* = undefined;
    }

    pub fn run(self: *Kernel) !void {
        defer self.workers.cancel(self.io);
        try self.recollect();
        while (true) {
            try self.io.checkCancel();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const waiting = self.mailbox.unread(a, try self.conversations.intakeLimit()) catch |err| {
                if (err == error.Canceled) return err;
                std.log.warn("could not check mail: {s}", .{@errorName(err)});
                try self.dispatch();
                try self.io.sleep(.fromMilliseconds(self.poll_interval_ms), .awake);
                continue;
            };
            try self.conversations.reconcile(waiting);
            for (waiting) |letter| self.receive(a, letter) catch |err| {
                if (err == error.Canceled) return err;
                std.log.warn("could not receive mail {s}: {s}", .{ letter.id, @errorName(err) });
            };
            try self.dispatch();
            try self.io.sleep(.fromMilliseconds(self.poll_interval_ms), .awake);
        }
    }

    fn recollect(self: *Kernel) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        if (try self.mailbox.latestHandover(a)) |letter| {
            const fields = try self.source(a, letter, self.limits.handover_bytes, "handover");
            try self.conversations.appendCoreInput(try Input.serialize(a, 1, .{ .object = .empty }, fields));
            std.log.info("core recollected its handover", .{});
        }
        var background: std.ArrayList(Value) = .empty;
        var base = try self.conversations.snapshotCore();
        defer base.deinit();
        const reserve = @min(4096, self.limits.request_bytes / 4);
        var selected: ?[]const u8 = null;
        for (try self.mailbox.recent(a, 32)) |letter| {
            try background.append(a, try self.source(a, letter, 512, "correspondence"));
            const fields = try jsonValue(a, .{ .message = "", .background = background.items });
            const rendered_frame = try Input.serialize(a, 1, .{ .object = .empty }, fields);
            var candidate = try base.fork(self.allocator);
            defer candidate.deinit();
            try candidate.appendInput(rendered_frame);
            if (try self.engine.provider.requestBytes(a, candidate.history()) > self.limits.request_bytes - reserve) break;
            selected = rendered_frame;
        }
        if (selected) |rendered_frame| try self.conversations.appendCoreInput(rendered_frame);
    }

    fn receive(self: *Kernel, a: Allocator, letter: Mail.Letter) !void {
        if (try self.conversations.handled(letter)) {
            try self.mailbox.markRead(a, letter.id);
            return;
        }
        if (letter.purpose == .report and self.isSelf(letter)) {
            _ = try self.conversations.acceptCore(letter);
            return;
        }
        if (try self.conversations.acceptExisting(letter)) return;
        const thread = try self.mailbox.thread(a, letter.thread_id, 32);
        const reopening = thread.handover != null or thread.has_archived_history;
        var restored: ?Context = if (reopening) try Context.init(self.allocator, @embedFile("system.md")) else null;
        defer if (restored) |*view| view.deinit();
        const conversation = try self.conversations.accept(letter, restored) orelse return;
        restored = null;
        if (!reopening) return;
        if (thread.handover) |handover| {
            try self.conversations.appendInput(conversation, try self.frame(a, conversation, handover, self.limits.handover_bytes, "handover"));
        }
        // Prefer the newest evidence that fits, retaining chronological order.
        // Historical correspondence never becomes queued active work.
        var base = try self.conversations.snapshot(conversation);
        defer base.deinit();
        var frames: std.ArrayList([]const u8) = .empty;
        var index = thread.letters.len;
        while (index != 0) {
            index -= 1;
            const past = thread.letters[index];
            if (std.mem.eql(u8, past.id, letter.id) or past.purpose == .handover or past.purpose == .core_handover) continue;
            const rendered = try self.frame(a, conversation, past, 512, "history");
            try frames.insert(a, 0, rendered);
            var candidate = try base.fork(self.allocator);
            errdefer candidate.deinit();
            for (frames.items) |past_frame| try candidate.appendInput(past_frame);
            if (try self.engine.provider.requestBytes(a, candidate.history()) > self.limits.request_bytes - @min(4096, self.limits.request_bytes / 4)) {
                candidate.deinit();
                break;
            }
            try self.conversations.replaceContext(conversation, candidate);
        }
        std.log.info("session {d} reopened archived correspondence", .{conversation.session_id});
    }

    fn dispatch(self: *Kernel) !void {
        while (try self.conversations.nextReady(self.max_parallel)) |work| {
            self.workers.concurrent(self.io, execute, .{ self, work }) catch |err| {
                try self.conversations.finish(work, false);
                return err;
            };
        }
    }

    fn execute(self: *Kernel, work: Work) std.Io.Cancelable!void {
        const retired = self.respond(work) catch |err| {
            self.conversations.finish(work, false) catch |failure|
                std.log.err("could not pause conversation: {s}", .{@errorName(failure)});
            if (err == error.Canceled) return error.Canceled;
            std.log.err("session {d} paused: {s}", .{ work.conversation.session_id, @errorName(err) });
            return;
        };
        if (!retired) self.conversations.finish(work, true) catch |err|
            std.log.err("could not finish mail turn: {s}", .{@errorName(err)});
    }

    fn respond(self: *Kernel, work: Work) !bool {
        const conversation = work.conversation;
        const origin = work.delivery.letter;
        if (try self.withdrawn(origin)) {
            if (!try self.conversations.beginArchive(conversation)) return false;
            return self.conversations.retire(work);
        }
        if (!work.delivery.supplied) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            try self.conversations.appendInput(conversation, try self.frame(arena.allocator(), conversation, origin, @intCast(@min(4096, self.limits.request_bytes / 8)), if (work.delivery.kind == .report) "report" else "input"));
            work.delivery.supplied = true;
        }
        try self.conversations.recordLetterID(conversation, origin.id);
        while (true) {
            try self.io.checkCancel();
            if (try self.withdrawn(origin)) return self.withdraw(work);
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var view = try self.requestContext(a, conversation, origin);
            defer view.deinit();
            const round = try self.engine.turn(a, conversation.session_id, view.history());
            try self.conversations.appendBatch(conversation, round.output, round.replies);
            if (try self.takeReport(a, conversation)) continue;
            // Continue with tool results; a response without tool calls ends
            // the current mail turn.
            if (round.replies.len != 0) continue;
            if (try self.withdrawn(origin)) return self.withdraw(work);
            if (round.text) |text| {
                if (!self.isSelf(origin) and origin.from.len != 0) {
                    const id = try self.mailbox.send(a, .{
                        .to = origin.from,
                        .subject = try replySubject(a, origin.subject),
                        .body = text,
                        .in_reply_to = origin.message_id,
                        .references = try replyReferences(a, origin),
                    });
                    try self.conversations.recordLetterID(conversation, id);
                    try self.mailbox.markAnswered(a, origin.id);
                }
            }
            try self.mailbox.markRead(a, origin.id);
            const outcome = round.text orelse "No result text was produced.";
            if (conversation.role == .branch) {
                const body = try std.fmt.allocPrint(a, "Work: {s}\nSource: {s}\nSession: {d}\n\n{s}", .{ origin.subject, origin.message_id orelse origin.id, conversation.session_id, outcome });
                _ = self.mailbox.saveInternal(a, .{
                    .to = &.{.{ .email = self.mailbox.address }},
                    .subject = try std.fmt.allocPrint(a, "Report: {s}", .{origin.subject}),
                    .body = body,
                    .purpose = .report,
                }, .inbox) catch |err| {
                    if (err == error.Canceled) return err;
                    std.log.warn("core report delivery failed; conversation retained: {s}", .{@errorName(err)});
                    return false;
                };
            }
            return self.close(work, outcome);
        }
    }

    fn takeReport(self: *Kernel, a: Allocator, conversation: *Conversation) !bool {
        const report = try self.conversations.takeCoreReport(conversation) orelse return false;
        const id = blk: {
            errdefer self.conversations.returnReport(conversation, report);
            const source_id = try a.dupe(u8, report.letter.id);
            const rendered = try self.frame(a, conversation, report.letter, self.limits.handover_bytes, "report");
            try self.conversations.consumeReport(conversation, report, rendered);
            break :blk source_id;
        };
        try self.mailbox.markRead(a, id);
        try self.mailbox.archive(a, &.{id});
        return true;
    }

    fn withdraw(self: *Kernel, work: Work) !bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const fields = try jsonValue(a, .{ .message = "", .source_update = .{ .id = work.delivery.letter.id, .state = "withdrawn" } });
        try self.conversations.appendInput(work.conversation, try Input.serialize(a, work.conversation.session_id, .{ .object = .empty }, fields));
        return self.close(work, "The input was withdrawn; completed actions retain their effects.");
    }

    fn requestContext(self: *Kernel, a: Allocator, conversation: *Conversation, origin: Mail.Letter) !Context {
        var view = try self.conversations.snapshot(conversation);
        errdefer view.deinit();
        const current = try Input.serializeSnapshot(a, try self.conversations.runtimeSnapshot(conversation));
        try view.appendInput(current);
        if (try self.engine.provider.requestBytes(a, view.history()) <= self.limits.request_bytes) return view;
        const summary = try Compaction.summarize(self.engine.provider, a, view.history(), try self.conversations.runtimeSnapshot(conversation), self.limits.compaction_bytes, self.limits.handover_bytes);
        const summary_fields = try jsonValue(a, .{ .message = summary, .kind = "handover", .source = .{ .thread_id = conversation.thread_id } });
        const rendered = try Input.serialize(a, conversation.session_id, .{ .object = .empty }, summary_fields);
        var candidate = try view.withHandover(self.allocator, rendered, 0);
        errdefer candidate.deinit();
        var request = try candidate.fork(self.allocator);
        errdefer request.deinit();
        try request.appendInput(current);
        if (try self.engine.provider.requestBytes(a, request.history()) > self.limits.request_bytes) return error.ContextBudgetExhausted;
        const note = try self.mailbox.saveInternal(a, .{
            .to = &.{.{ .email = self.mailbox.address }},
            .subject = try replySubject(a, origin.subject),
            .body = summary,
            .in_reply_to = origin.message_id,
            .references = try replyReferences(a, origin),
            .purpose = if (conversation.role == .core) .core_handover else .handover,
        }, .archive);
        try self.conversations.recordLetterID(conversation, note.id);
        try self.conversations.replaceContext(conversation, candidate);
        view.deinit();
        std.log.info("session {d} compacted its working context", .{conversation.session_id});
        return request;
    }

    /// Archival is correspondence housekeeping after the turn. A failure keeps
    /// its active context available without repeating an already-delivered result.
    fn close(self: *Kernel, work: Work, outcome: []const u8) !bool {
        return self.archive(work, outcome) catch |err| {
            if (err == error.Canceled) return err;
            std.log.warn("correspondence kept active; archive unavailable: {s}", .{@errorName(err)});
            return false;
        };
    }

    fn archive(self: *Kernel, work: Work, outcome: []const u8) !bool {
        const conversation = work.conversation;
        if (!try self.conversations.beginArchive(conversation)) return false;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var view = try self.conversations.snapshot(conversation);
        defer view.deinit();
        const summary = try Compaction.summarize(self.engine.provider, a, view.history(), try self.conversations.runtimeSnapshot(conversation), self.limits.compaction_bytes, self.limits.handover_bytes);
        const body = try std.fmt.allocPrint(a, "{s}\n\nLast outcome: {s}", .{ summary, outcome });
        // The bounded summary is the handover; the complete last result already
        // lives in the thread and must not silently inflate this context note.
        const handover_body = if (body.len <= self.limits.handover_bytes) body else summary;
        const origin = work.delivery.letter;
        const note = try self.mailbox.saveInternal(a, .{
            .to = &.{.{ .email = self.mailbox.address }},
            .subject = try replySubject(a, origin.subject),
            .body = handover_body,
            .in_reply_to = origin.message_id,
            .references = try replyReferences(a, origin),
            .purpose = if (conversation.role == .core) .core_handover else .handover,
        }, .archive);
        try self.conversations.recordLetterID(conversation, note.id);
        try self.mailbox.archive(a, try self.conversations.processedIDs(a, conversation));
        const session_id = conversation.session_id;
        const retired = try self.conversations.retire(work);
        if (retired) std.log.info("session {d} correspondence archived", .{session_id});
        return retired;
    }

    fn frame(self: *Kernel, a: Allocator, conversation: *Conversation, letter: Mail.Letter, limit: usize, kind: []const u8) ![]const u8 {
        const snapshot = try self.conversations.runtimeSnapshot(conversation);
        const fields = try self.source(a, letter, limit, kind);
        return Input.serialize(a, snapshot.session_id, try jsonValue(a, .{
            .conversation = .{ .role = snapshot.role, .thread_id = snapshot.thread_id, .parent_generation = snapshot.parent_generation },
            .runtime = snapshot.runtime,
        }), fields);
    }

    fn source(self: *Kernel, a: Allocator, letter: Mail.Letter, limit: usize, kind: []const u8) !Value {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(letter.id, &hash, .{});
        const name = std.fmt.bytesToHex(hash, .lower);
        const directory = try std.fs.path.join(a, &.{ self.engine.host.shell.data_directory, "mail" });
        _ = try std.Io.Dir.cwd().createDirPathStatus(self.io, directory, .fromMode(0o700));
        const path = try std.fmt.allocPrint(a, "{s}/{s}.txt", .{ directory, name });
        const file = try std.Io.Dir.createFileAbsolute(self.io, path, .{ .permissions = .fromMode(0o600) });
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, letter.body);
        var end = @min(limit, letter.body.len);
        while (end > 0 and end < letter.body.len and (letter.body[end] & 0xc0) == 0x80) end -= 1;
        return jsonValue(a, .{
            .message = letter.body[0..end],
            .kind = kind,
            .subject = letter.subject,
            .observed_at_unix_ms = std.Io.Clock.real.now(self.io).toMilliseconds(),
            .source = .{
                .mail_id = letter.id,
                .thread_id = letter.thread_id,
                .message_id = letter.message_id,
                .from = letter.from,
                .to = letter.to,
                .body_file = path,
                .body_bytes = letter.body.len,
                .excerpt_bytes = end,
            },
        });
    }

    fn withdrawn(self: *Kernel, origin: Mail.Letter) !bool {
        if (self.isSelf(origin)) return false;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const current = self.mailbox.read(arena.allocator(), origin.id) catch |err| switch (err) {
            error.MailNotFound => return true,
            else => return err,
        };
        return !current.in_inbox;
    }

    fn isSelf(self: *Kernel, letter: Mail.Letter) bool {
        return letter.from.len == 1 and std.ascii.eqlIgnoreCase(letter.from[0].email, self.mailbox.address);
    }
};

fn jsonValue(a: Allocator, value: anytype) !Value {
    return std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, value, .{}), .{});
}

fn replySubject(a: Allocator, subject: []const u8) ![]const u8 {
    if (subject.len >= 3 and std.ascii.eqlIgnoreCase(subject[0..3], "re:")) return subject;
    return std.fmt.allocPrint(a, "Re: {s}", .{subject});
}

fn replyReferences(a: Allocator, letter: Mail.Letter) ![]const []const u8 {
    const retained = @min(letter.references.len, 31);
    const refs = try a.alloc([]const u8, retained + @as(usize, @intFromBool(letter.message_id != null)));
    @memcpy(refs[0..retained], letter.references[letter.references.len - retained ..]);
    if (letter.message_id) |id| refs[retained] = id;
    return refs;
}
