const std = @import("std");
const Context = @import("context.zig").Context;
const Compaction = @import("compaction.zig");
const Engine = @import("engine.zig").Engine;
const Content = @import("content.zig").Content;
const Input = @import("input.zig");
const Sessions = @import("sessions.zig");
const WorkInput = @import("work.zig");
const Communication = @import("communication.zig");
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
    reception: std.atomic.Value(enum(u8) { starting, open, closed }) = .init(.starting),

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

    pub fn isReceiving(self: *const Kernel) bool {
        return self.reception.load(.acquire) == .open;
    }

    pub fn closeReception(self: *Kernel) void {
        self.reception.store(.closed, .release);
    }

    pub fn run(self: *Kernel) !void {
        var results: [1]TaskResult = undefined;
        var tasks = Tasks.init(self.io, &results);
        defer {
            self.closeReception();
            tasks.cancelDiscard();
        }
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
        if (self.reception.cmpxchgStrong(.starting, .open, .release, .monotonic) != null) return;
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
                    .input = received,
                    .receipt = candidate.receipt,
                });
            }
            try self.sessions.reconcile(waiting.items);
            for (waiting.items) |incoming| _ = try self.sessions.accept(incoming);
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
            try self.sessions.appendCoreContext(&.{.{ .handover = record }});
        }
        var context: std.ArrayList(Input.ContextItem) = .empty;
        var base = try self.sessions.snapshotCore();
        defer base.deinit();
        var provider = self.engine.provider;
        provider.tool_scope = .coordination;
        const snapshot = try self.sessions.runtimeSnapshot(self.sessions.core);
        const request: Input.Request = .{ .session_id = snapshot.session_id, .state = snapshot.state };
        const reserve = @min(4096, self.limits.request_bytes / 4);
        var selected: usize = 0;
        for (try self.email.recent(a, 32)) |material| {
            try context.append(a, .{ .evidence = material });
            var candidate = try base.fork(self.allocator);
            defer candidate.deinit();
            try candidate.appendRecord(.{ .session_id = snapshot.session_id, .context = context.items });
            if (try provider.requestBytes(a, try candidate.request(a, request)) > self.limits.request_bytes - reserve) break;
            selected = context.items.len;
        }
        if (selected != 0) try self.sessions.appendCoreContext(context.items[0..selected]);
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
        plan: ?Sessions.ForkPlan = null,
        committed: bool = false,

        fn deinit(self: *RuntimeRound) void {
            if (!self.committed) if (self.plan) |plan| self.kernel.sessions.abandonFork(plan);
        }

        fn invoke(context: *anyopaque, a: Allocator, name: []const u8, arguments: []const u8) anyerror!?Content {
            const self: *RuntimeRound = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, name, "send_message")) {
                const message = try parseArguments(Communication.Message, a, arguments);
                if (message.recipients.len == 0 or message.text.len == 0) return error.InvalidToolArguments;
                const submission = self.kernel.email.send(a, message) catch |err| switch (err) {
                    error.InvalidContactReference => return try runtimeError(a, "unknown_recipient", "The recipient reference is not available."),
                    else => return err,
                };
                return try runtimeResult(a, submission);
            }
            if (!std.mem.eql(u8, name, "fork_session")) return null;
            const request = try parseArguments(Sessions.ForkRequest, a, arguments);
            if (self.plan != null)
                return try runtimeError(a, "invalid_fork_batch", "Only one fork is allowed in a model round.");
            const plan = self.kernel.sessions.prepareFork(self.work, request) catch |err| switch (err) {
                error.InvalidForkArguments, error.AttentionCapacityUnavailable => return try runtimeError(a, "fork_unavailable", @errorName(err)),
                else => return err,
            };
            self.plan = plan;
            return try runtimeResult(a, .{ .session_id = plan.child.session_id });
        }
    };

    fn respond(self: *Kernel, work: Work) !void {
        const session = work.session;
        try self.beginActivation(work);
        while (true) {
            try self.io.checkCancel();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            var view = try self.requestContext(a, session);
            defer view.deinit();
            var runtime: RuntimeRound = .{ .kernel = self, .work = work };
            defer runtime.deinit();
            const round = try self.engine.turn(a, session.session_id, view.input, .{ .context = &runtime, .invoke = RuntimeRound.invoke }, session.role == .core);
            const committed = try self.sessions.commitRound(work, round.output, round.replies, runtime.plan);
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
        for (work.activation.deliveries.items) |delivery|
            for (delivery.receipts) |receipt|
                try self.state.complete(a, receipt);
        return self.sessions.finish(work, text);
    }

    const Selection = struct { count: usize, context: Context };

    /// Choose from the queue snapshot owned by this activation. Later arrivals
    /// stay queued; excluded deliveries return ahead of them when selected
    /// history is installed.
    fn selectActivation(self: *Kernel, a: Allocator, work: Work, history: *const Context, request: Input.Request) !?Selection {
        var provider = self.engine.provider;
        provider.tool_scope = if (work.session.role == .core) .coordination else .all;
        var selected = try history.fork(self.allocator);
        errdefer selected.deinit();
        var count: usize = 0;
        const deliveries = work.activation.deliveries.items;
        const events = try a.alloc(Input.Event, deliveries.len);
        for (deliveries, events) |delivery, *event| event.* = delivery.event;
        for (1..events.len + 1) |end| {
            var candidate = try history.fork(self.allocator);
            errdefer candidate.deinit();
            try candidate.appendRecord(.{ .session_id = work.session.session_id, .events = events[0..end] });
            var current = request;
            current.state.runtime.queued_inputs += events.len - end;
            const input = try candidate.request(a, current);
            if (try provider.requestBytes(a, input) > self.limits.request_bytes) {
                candidate.deinit();
                break;
            }
            selected.deinit();
            selected = candidate;
            count = end;
        }
        if (count == 0) {
            selected.deinit();
            return null;
        }
        return .{ .count = count, .context = selected };
    }

    fn beginActivation(self: *Kernel, work: Work) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var history = try self.sessions.snapshot(work.session);
        defer history.deinit();
        const snapshot = try self.sessions.runtimeSnapshot(work.session);
        var request: Input.Request = .{ .session_id = snapshot.session_id, .state = snapshot.state };
        var selection = try self.selectActivation(a, work, &history, request);
        var handover: ?[]const u8 = null;
        if (selection == null and history.history().len > 1) {
            handover = try Compaction.summarize(self.engine.provider, a, &history, request, self.limits.compaction_bytes, self.limits.handover_bytes);
            var compacted = try history.withHandover(self.allocator, work.session.session_id, .{ .summary = handover.? });
            defer compacted.deinit();
            request.state = (try self.sessions.runtimeSnapshot(work.session)).state;
            selection = try self.selectActivation(a, work, &compacted, request);
        }
        var selected = selection orelse return error.ContextBudgetExhausted;
        errdefer selected.context.deinit();
        if (handover) |summary| if (work.session.role == .core)
            try self.state.saveHandover(a, "core", summary);
        try self.sessions.beginActivation(work, selected.count, selected.context);
    }

    /// Owns the history snapshot borrowed by the request-arena input view.
    const RequestView = struct {
        context: Context,
        input: []const std.json.Value,

        fn deinit(self: *RequestView) void {
            self.context.deinit();
            self.* = undefined;
        }
    };

    fn requestContext(self: *Kernel, a: Allocator, session: *Session) !RequestView {
        var provider = self.engine.provider;
        provider.tool_scope = if (session.role == .core) .coordination else .all;
        var view = try self.sessions.snapshot(session);
        errdefer view.deinit();
        const snapshot = try self.sessions.runtimeSnapshot(session);
        const request: Input.Request = .{ .session_id = snapshot.session_id, .state = snapshot.state };
        const input = try view.request(a, request);
        if (try provider.requestBytes(a, input) <= self.limits.request_bytes) return .{ .context = view, .input = input };
        const summary = try Compaction.summarize(provider, a, &view, request, self.limits.compaction_bytes, self.limits.handover_bytes);
        var candidate = try view.withHandover(self.allocator, session.session_id, .{ .summary = summary });
        errdefer candidate.deinit();
        var replacement = try candidate.fork(self.allocator);
        errdefer replacement.deinit();
        var replacement_request = request;
        replacement_request.state = (try self.sessions.runtimeSnapshot(session)).state;
        const replacement_input = try replacement.request(a, replacement_request);
        if (try provider.requestBytes(a, replacement_input) > self.limits.request_bytes) return error.ContextBudgetExhausted;
        if (session.role == .core) try self.state.saveHandover(a, "core", summary);
        try self.sessions.replaceContext(session, candidate);
        view.deinit();
        return .{ .context = replacement, .input = replacement_input };
    }
};

fn parseArguments(comptime T: type, a: Allocator, arguments: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, arguments, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidToolArguments,
    };
}

fn runtimeResult(a: Allocator, value: anytype) !Content {
    return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .result = value }, .{}));
}

fn runtimeError(a: Allocator, code: []const u8, message: []const u8) !Content {
    return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .@"error" = .{ .code = code, .message = message } }, .{}));
}
