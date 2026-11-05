const std = @import("std");
const Context = @import("context.zig").Context;
const Compaction = @import("compaction.zig");
const Engine = @import("engine.zig").Engine;
const Content = @import("content.zig").Content;
const Input = @import("input.zig");
const Conversations = @import("conversations.zig");
const Mail = @import("mail.zig");
const Allocator = std.mem.Allocator;
const Conversation = Conversations.Conversation;
const Work = Conversations.Work;

/// Owns mail I/O and worker scopes. Core coordination and delegated work have
/// independent execution lanes; Registry owns histories and task routing.
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

    pub const Limits = struct {
        request_bytes: u64 = 65536,
        compaction_bytes: u64 = 131072,
        handover_bytes: usize = 8192,
    };

    pub fn init(allocator: Allocator, io: std.Io, engine: *Engine, mailbox: *Mail.Mailbox, limits: Limits, poll_interval_ms: u32, max_parallel: usize, max_contexts: usize) !Kernel {
        if (max_parallel == 0 or max_contexts == 0 or poll_interval_ms == 0 or
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
            const record = try self.source(a, letter, self.limits.handover_bytes);
            try self.conversations.appendCoreInput(try Input.serialize(a, 1, .{ .background = .{ .items = &.{.{ .handover = record }} } }));
        }
        var background: std.ArrayList(Input.Background) = .empty;
        var base = try self.conversations.snapshotCore();
        defer base.deinit();
        var provider = self.engine.provider;
        provider.tool_scope = .coordination;
        const reserve = @min(4096, self.limits.request_bytes / 4);
        var selected: ?[]const u8 = null;
        for (try self.mailbox.recent(a, 32)) |letter| {
            try background.append(a, .{ .history = try self.source(a, letter, 512) });
            const rendered = try Input.serialize(a, 1, .{ .background = .{ .items = background.items } });
            var candidate = try base.fork(self.allocator);
            defer candidate.deinit();
            try candidate.appendInput(rendered);
            if (try provider.requestBytes(a, candidate.history()) > self.limits.request_bytes - reserve) break;
            selected = rendered;
        }
        if (selected) |rendered| try self.conversations.appendCoreInput(rendered);
    }

    fn receive(self: *Kernel, a: Allocator, letter: Mail.Letter) !void {
        if (try self.conversations.handled(letter)) {
            try self.mailbox.markRead(a, letter.id);
            return;
        }
        const audience: Input.Audience = if (self.isSelf(letter) or letter.from.len == 0) .internal else .external;
        if (try self.conversations.acceptExisting(letter, audience)) return;
        const thread = try self.mailbox.thread(a, letter.thread_id, 32);
        var background: std.ArrayList(Input.Background) = .empty;
        if (thread.handover) |handover| {
            try background.append(a, .{ .handover = try self.source(a, handover, self.limits.handover_bytes) });
        }
        for (thread.letters) |past| {
            if (std.mem.eql(u8, past.id, letter.id) or past.purpose == .handover or past.purpose == .core_handover) continue;
            try background.append(a, .{ .history = try self.source(a, past, 512) });
        }
        _ = try self.conversations.accept(letter, audience, background.items);
    }

    fn dispatch(self: *Kernel) !void {
        while (try self.conversations.nextReady(self.max_parallel)) |work| {
            self.workers.concurrent(self.io, execute, .{ self, work }) catch |err| {
                self.conversations.fail(work, "Worker could not start.") catch {};
                self.conversations.endWorker(work.conversation.session_id);
                return err;
            };
        }
    }

    fn execute(self: *Kernel, work: Work) std.Io.Cancelable!void {
        const session_id = work.conversation.session_id;
        defer self.conversations.endWorker(session_id);
        self.respond(work) catch |err| {
            self.conversations.fail(work, @errorName(err)) catch |failure|
                std.log.err("could not record session failure: {s}", .{@errorName(failure)});
            if (err == error.Canceled) return error.Canceled;
            std.log.err("session {d} stopped: {s}", .{ session_id, @errorName(err) });
        };
    }

    const RuntimeRound = struct {
        kernel: *Kernel,
        work: Work,
        plans: std.ArrayList(Conversations.ForkPlan) = .empty,
        committed: bool = false,

        fn deinit(self: *RuntimeRound) void {
            if (!self.committed) self.kernel.conversations.abandonForks(self.plans.items);
            self.plans.deinit(self.kernel.allocator);
        }

        fn invoke(context: *anyopaque, a: Allocator, name: []const u8, arguments: []const u8) anyerror!?Content {
            const self: *RuntimeRound = @ptrCast(@alignCast(context));
            if (!std.mem.eql(u8, name, "fork_session")) return null;
            const request = std.json.parseFromSliceLeaky(Conversations.ForkRequest, a, arguments, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.InvalidToolArguments,
            };
            if (self.plans.items.len != 0 and (request.mode == .handoff or self.plans.items[0].request.mode == .handoff))
                return try runtimeError(a, "invalid_fork_batch", "A handoff must be the only fork in its round.");
            try self.plans.ensureUnusedCapacity(self.kernel.allocator, 1);
            const plan = self.kernel.conversations.prepareFork(self.work, request) catch |err| switch (err) {
                error.Canceled, error.OutOfMemory => return err,
                else => return try runtimeError(a, "fork_unavailable", @errorName(err)),
            };
            self.plans.appendAssumeCapacity(plan);
            return try Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{
                .result = .{ .session_id = plan.child.session_id },
            }, .{}));
        }
    };

    fn respond(self: *Kernel, work: Work) !void {
        const session = work.conversation;
        const origin = work.delivery.letter;
        if (!work.delivery.supplied) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const record = try self.source(a, origin, @intCast(@min(4096, self.limits.request_bytes / 8)));
            const observation: Input.Observation = switch (work.delivery.kind) {
                .input => .{ .input = .{ .letter = record, .background = work.delivery.background } },
                .assignment => |task| .{ .assignment = .{ .task = task, .origin = record.origin } },
            };
            try self.conversations.appendInput(session, try Input.serialize(a, session.session_id, observation));
            work.delivery.supplied = true;
        }
        while (true) {
            try self.io.checkCancel();
            if (work.delivery.tracks_mail and try self.withdrawn(origin)) {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const a = arena.allocator();
                try self.conversations.appendInput(session, try Input.serialize(a, session.session_id, .{ .source_update = .{ .mail_id = origin.id, .state = .withdrawn } }));
                const saved = try self.saveForRelease(work);
                return self.conversations.finish(work, null, saved);
            }
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var view = try self.requestContext(a, session, work.delivery);
            defer view.deinit();
            var runtime: RuntimeRound = .{ .kernel = self, .work = work };
            defer runtime.deinit();
            const round = try self.engine.turn(a, session.session_id, view.history(), .{ .context = &runtime, .invoke = RuntimeRound.invoke }, session.role == .core);
            const committed = try self.conversations.commitRound(work, round.output, round.replies, runtime.plans.items);
            runtime.committed = true;
            if (committed.handed_off or committed.waiting) return;
            if (round.replies.len != 0) continue;
            if (work.delivery.tracks_mail and try self.withdrawn(origin)) continue;
            if (round.text) |text| if (work.delivery.audience == .external) {
                _ = try self.mailbox.send(a, .{
                    .to = origin.from,
                    .subject = try replySubject(a, origin.subject),
                    .body = text,
                    .in_reply_to = origin.message_id,
                    .references = try replyReferences(a, origin),
                });
                try self.mailbox.markAnswered(a, origin.id);
            };
            if (work.delivery.tracks_mail) try self.mailbox.markRead(a, origin.id);
            const saved = try self.saveForRelease(work);
            return self.conversations.finish(work, round.text, saved);
        }
    }

    fn requestContext(self: *Kernel, a: Allocator, session: *Conversation, delivery: *Conversations.Delivery) !Context {
        const origin = delivery.letter;
        const correspondence = session.role == .branch and delivery.tracks_mail;
        var provider = self.engine.provider;
        provider.tool_scope = if (session.role == .core) .coordination else .all;
        var view = try self.conversations.snapshot(session);
        errdefer view.deinit();
        const current = try Input.serializeSnapshot(a, try self.conversations.runtimeSnapshot(session));
        try view.appendInput(current);
        if (try provider.requestBytes(a, view.history()) <= self.limits.request_bytes) return view;
        const summary = try Compaction.summarize(provider, a, view.history(), try self.conversations.runtimeSnapshot(session), self.limits.compaction_bytes, self.limits.handover_bytes);
        const rendered = try Input.serialize(a, session.session_id, .{ .handover = .{ .summary = summary, .thread_id = origin.thread_id } });
        var candidate = try view.withHandover(self.allocator, rendered, 0);
        errdefer candidate.deinit();
        var request = try candidate.fork(self.allocator);
        errdefer request.deinit();
        try request.appendInput(current);
        if (try provider.requestBytes(a, request.history()) > self.limits.request_bytes) return error.ContextBudgetExhausted;
        _ = try self.mailbox.saveInternal(a, .{
            .subject = if (correspondence) try replySubject(a, origin.subject) else if (session.role == .core) "Core handover" else try std.fmt.allocPrint(a, "Session {d} handover", .{session.session_id}),
            .body = summary,
            .in_reply_to = if (correspondence) origin.message_id else null,
            .references = if (correspondence) try replyReferences(a, origin) else &.{},
            .purpose = if (session.role == .core) .core_handover else .handover,
        }, .archive);
        try self.conversations.replaceContext(session, candidate);
        view.deinit();
        return request;
    }

    /// Save a correspondence handover without moving its source mail.
    /// Internal subtasks do not replace the correspondence handover.
    fn saveForRelease(self: *Kernel, work: Work) !bool {
        if (work.conversation.role == .core or !work.delivery.tracks_mail) return true;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var view = try self.conversations.snapshot(work.conversation);
        defer view.deinit();
        const summary = Compaction.summarize(self.engine.provider, a, view.history(), try self.conversations.runtimeSnapshot(work.conversation), self.limits.compaction_bytes, self.limits.handover_bytes) catch |err| {
            if (err == error.Canceled) return err;
            std.log.warn("session {d} retained; handover unavailable: {s}", .{ work.conversation.session_id, @errorName(err) });
            return false;
        };
        _ = self.mailbox.saveInternal(a, .{
            .subject = try replySubject(a, work.delivery.letter.subject),
            .body = summary,
            .in_reply_to = work.delivery.letter.message_id,
            .references = try replyReferences(a, work.delivery.letter),
            .purpose = .handover,
        }, .archive) catch |err| {
            if (err == error.Canceled) return err;
            std.log.warn("session {d} retained; handover storage unavailable: {s}", .{ work.conversation.session_id, @errorName(err) });
            return false;
        };
        return true;
    }

    fn source(self: *Kernel, a: Allocator, letter: Mail.Letter, limit: usize) !Input.MailRecord {
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
        return .{
            .excerpt = letter.body[0..end],
            .excerpt_bytes = end,
            .origin = .{
                .subject = letter.subject,
                .observed_at_unix_ms = std.Io.Clock.real.now(self.io).toMilliseconds(),
                .mail_id = letter.id,
                .thread_id = letter.thread_id,
                .message_id = letter.message_id,
                .in_reply_to = letter.in_reply_to,
                .references = letter.references,
                .purpose = letter.purpose,
                .from = letter.from,
                .to = letter.to,
                .body_file = path,
                .body_bytes = letter.body.len,
            },
        };
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

fn runtimeError(a: Allocator, code: []const u8, message: []const u8) !Content {
    return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .@"error" = .{ .code = code, .message = message } }, .{}));
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
