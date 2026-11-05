const std = @import("std");
const Context = @import("context.zig").Context;
const Compaction = @import("compaction.zig");
const Engine = @import("engine.zig").Engine;
const Content = @import("content.zig").Content;
const Input = @import("input.zig");
const Sessions = @import("sessions.zig");
const WorkInput = @import("work.zig");
const EmailTransport = @import("email_transport.zig").EmailTransport;
const MailState = @import("mail_state.zig").MailState;
const MailSources = @import("mail_sources.zig").MailSources;
const Allocator = std.mem.Allocator;
const Session = Sessions.Session;
const Work = Sessions.Work;

/// Coordinate sessions, model/tool rounds, email, and internal state within
/// worker scopes. Core coordination has an independent execution lane.
pub const Kernel = struct {
    allocator: Allocator,
    io: std.Io,
    engine: *Engine,
    email: *EmailTransport,
    state: *MailState,
    sources: *MailSources,
    limits: Limits,
    poll_interval_ms: u32,
    max_parallel: usize,
    sessions: Sessions.Registry,

    pub const Limits = struct {
        request_bytes: u64 = 65536,
        compaction_bytes: u64 = 131072,
        handover_bytes: usize = 8192,
    };

    pub fn init(allocator: Allocator, io: std.Io, engine: *Engine, email: *EmailTransport, state: *MailState, sources: *MailSources, limits: Limits, poll_interval_ms: u32, max_parallel: usize, max_contexts: usize) !Kernel {
        return .{
            .allocator = allocator,
            .io = io,
            .engine = engine,
            .email = email,
            .state = state,
            .sources = sources,
            .limits = limits,
            .poll_interval_ms = poll_interval_ms,
            .max_parallel = max_parallel,
            .sessions = try Sessions.Registry.init(allocator, io, max_contexts),
        };
    }

    pub fn deinit(self: *Kernel) void {
        self.sessions.deinit();
        self.* = undefined;
    }

    const TaskResult = union(enum) { intake: anyerror!void, work: anyerror!void };
    const Tasks = std.Io.Select(TaskResult);

    pub fn run(self: *Kernel) !void {
        var results: [1]TaskResult = undefined;
        var tasks = Tasks.init(self.io, &results);
        defer tasks.cancelDiscard();
        try tasks.concurrent(.intake, receiveLoop, .{ self, &tasks });
        while (true) switch (try tasks.await()) {
            .intake => |result| return result,
            .work => |result| {
                try result;
                try self.dispatch(&tasks);
            },
        };
    }

    fn receiveLoop(self: *Kernel, tasks: *Tasks) !void {
        try self.recollect();
        while (true) {
            try self.io.checkCancel();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const pending = try self.state.pending(a, try self.sessions.intakeLimit());
            var waiting: std.ArrayList(WorkInput.Incoming) = .empty;
            for (pending) |candidate| {
                const received = try self.email.receive(a, candidate.receipt, @intCast(@min(4096, self.limits.request_bytes / 8)));
                try waiting.append(a, .{
                    .input = received.input,
                    .reply = received.reply,
                    .source_state = .{
                        .receipt = candidate.receipt,
                        .input_key = candidate.input_key,
                        .route = received.route,
                        .state_key = try std.fmt.allocPrint(a, "conversation/{s}", .{received.route}),
                    },
                });
            }
            try self.sessions.reconcile(waiting.items);
            for (waiting.items) |incoming| try self.receive(a, incoming);
            try self.sources.sweep(try self.sessions.receiptsInUse(a));
            try self.dispatch(tasks);
            try self.io.sleep(.fromMilliseconds(self.poll_interval_ms), .awake);
        }
    }

    fn recollect(self: *Kernel) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        if (try self.state.loadHandover(a, "core", self.limits.handover_bytes)) |record| {
            try self.sessions.appendCoreInput(try Input.serialize(a, 1, .{ .background = .{ .items = &.{.{ .handover = record }} } }));
        }
        var background: std.ArrayList(Input.Background) = .empty;
        var base = try self.sessions.snapshotCore();
        defer base.deinit();
        var provider = self.engine.provider;
        provider.tool_scope = .coordination;
        const reserve = @min(4096, self.limits.request_bytes / 4);
        var selected: ?[]const u8 = null;
        for (try self.email.recent(a, 32)) |material| {
            try background.append(a, .{ .evidence = material });
            const rendered = try Input.serialize(a, 1, .{ .background = .{ .items = background.items } });
            var candidate = try base.fork(self.allocator);
            defer candidate.deinit();
            try candidate.appendInput(rendered);
            if (try provider.requestBytes(a, candidate.history()) > self.limits.request_bytes - reserve) break;
            selected = rendered;
        }
        if (selected) |rendered| try self.sessions.appendCoreInput(rendered);
    }

    fn receive(self: *Kernel, a: Allocator, incoming: WorkInput.Incoming) !void {
        var prepared = incoming;
        if (incoming.source_state) |source| {
            if (try self.sessions.handled(source.input_key)) return;
            if (try self.sessions.acceptExisting(incoming)) return;
            var context: std.ArrayList(Input.Background) = .empty;
            try context.appendSlice(a, incoming.input.context);
            if (source.state_key) |key| {
                if (try self.state.loadHandover(a, key, self.limits.handover_bytes)) |handover|
                    try context.append(a, .{ .handover = handover });
            }
            for (try self.email.history(a, source.receipt)) |material|
                try context.append(a, .{ .evidence = material });
            prepared.input.context = context.items;
        }
        _ = try self.sessions.accept(prepared);
    }

    fn dispatch(self: *Kernel, tasks: *Tasks) !void {
        while (try self.sessions.nextReady(self.max_parallel)) |work| {
            tasks.concurrent(.work, execute, .{ self, work }) catch |err| {
                self.sessions.endWorker(work.session.session_id);
                return err;
            };
        }
    }

    fn execute(self: *Kernel, work: Work) !void {
        const session_id = work.session.session_id;
        defer self.sessions.endWorker(session_id);
        self.respond(work) catch |err| {
            if (err == error.Canceled) return error.Canceled;
            std.log.err("session {d} stopped: {s}", .{ session_id, @errorName(err) });
            return err;
        };
    }

    const RuntimeRound = struct {
        kernel: *Kernel,
        work: Work,
        plans: std.ArrayList(Sessions.ForkPlan) = .empty,
        committed: bool = false,

        fn deinit(self: *RuntimeRound) void {
            if (!self.committed) self.kernel.sessions.abandonForks(self.plans.items);
            self.plans.deinit(self.kernel.allocator);
        }

        fn invoke(context: *anyopaque, a: Allocator, name: []const u8, arguments: []const u8) anyerror!?Content {
            const self: *RuntimeRound = @ptrCast(@alignCast(context));
            if (!std.mem.eql(u8, name, "fork_session")) return null;
            const request = std.json.parseFromSliceLeaky(Sessions.ForkRequest, a, arguments, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.InvalidToolArguments,
            };
            if (self.plans.items.len != 0 and (request.mode == .handoff or self.plans.items[0].request.mode == .handoff))
                return try runtimeError(a, "invalid_fork_batch", "A handoff must be the only fork in its round.");
            try self.plans.ensureUnusedCapacity(self.kernel.allocator, 1);
            const plan = self.kernel.sessions.prepareFork(self.work, request) catch |err| switch (err) {
                error.InvalidForkArguments, error.CoreRequiresHandoff, error.AttentionCapacityUnavailable => return try runtimeError(a, "fork_unavailable", @errorName(err)),
                else => return err,
            };
            self.plans.appendAssumeCapacity(plan);
            return try Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{
                .result = .{ .session_id = plan.child.session_id },
            }, .{}));
        }
    };

    fn respond(self: *Kernel, work: Work) !void {
        const session = work.session;
        if (!work.delivery.supplied) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            const observation: Input.Observation = switch (work.delivery.input) {
                .input => |input| .{ .input = input },
                .assignment => |assignment| .{ .assignment = assignment },
            };
            try self.sessions.appendInput(session, try Input.serialize(a, session.session_id, observation));
            work.delivery.supplied = true;
        }
        while (true) {
            try self.io.checkCancel();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var view = try self.requestContext(a, session, work.delivery);
            defer view.deinit();
            var runtime: RuntimeRound = .{ .kernel = self, .work = work };
            defer runtime.deinit();
            const round = try self.engine.turn(a, session.session_id, view.history(), .{ .context = &runtime, .invoke = RuntimeRound.invoke }, session.role == .core);
            const committed = try self.sessions.commitRound(work, round.output, round.replies, runtime.plans.items);
            runtime.committed = true;
            if (committed != .continuing) return;
            if (round.replies.len != 0) continue;
            return self.finishResult(work, round.text);
        }
    }

    fn finishResult(self: *Kernel, work: Work, text: ?[]const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        if (work.delivery.reply) |target| if (text) |answer|
            try self.email.reply(a, target.receipt, answer);
        if (work.delivery.source_state) |source|
            try self.state.complete(a, source.receipt);
        try self.saveForRelease(work);
        return self.sessions.finish(work, text);
    }

    fn requestContext(self: *Kernel, a: Allocator, session: *Session, delivery: *WorkInput.Delivery) !Context {
        var provider = self.engine.provider;
        provider.tool_scope = if (session.role == .core) .coordination else .all;
        var view = try self.sessions.snapshot(session);
        errdefer view.deinit();
        const current = try Input.serializeSnapshot(a, try self.sessions.runtimeSnapshot(session));
        try view.appendInput(current);
        if (try provider.requestBytes(a, view.history()) <= self.limits.request_bytes) return view;
        const summary = try Compaction.summarize(provider, a, view.history(), try self.sessions.runtimeSnapshot(session), self.limits.compaction_bytes, self.limits.handover_bytes);
        const rendered = try Input.serialize(a, session.session_id, .{ .handover = .{ .summary = summary } });
        var candidate = try view.withHandover(self.allocator, rendered);
        errdefer candidate.deinit();
        var request = try candidate.fork(self.allocator);
        errdefer request.deinit();
        try request.appendInput(current);
        if (try provider.requestBytes(a, request.history()) > self.limits.request_bytes) return error.ContextBudgetExhausted;
        const key: ?[]const u8 = if (session.role == .core)
            "core"
        else if (delivery.source_state) |source|
            source.state_key
        else
            null;
        if (key) |state_key| try self.state.saveHandover(a, state_key, summary);
        try self.sessions.replaceContext(session, candidate);
        view.deinit();
        return request;
    }

    /// Persist continuity only when work has an assigned state key. A result's
    /// reply destination does not determine its state-storage policy.
    fn saveForRelease(self: *Kernel, work: Work) !void {
        if (work.session.role == .core) return;
        const source = work.delivery.source_state orelse return;
        const key = source.state_key orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var view = try self.sessions.snapshot(work.session);
        defer view.deinit();
        const summary = try Compaction.summarize(self.engine.provider, a, view.history(), try self.sessions.runtimeSnapshot(work.session), self.limits.compaction_bytes, self.limits.handover_bytes);
        try self.state.saveHandover(a, key, summary);
    }
};

fn runtimeError(a: Allocator, code: []const u8, message: []const u8) !Content {
    return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .@"error" = .{ .code = code, .message = message } }, .{}));
}
