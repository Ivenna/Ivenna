const std = @import("std");
const yaml = @import("yaml");
const contracts = @import("agent_contracts");
const Allocator = std.mem.Allocator;
const IncomingMessage = contracts.Communication.IncomingMessage;

pub const Role = union(enum) {
    core: void,
    branch: struct { parent_session_id: u64 },

    pub fn parentSessionId(self: Role) ?u64 {
        return switch (self) {
            .core => null,
            .branch => |branch| branch.parent_session_id,
        };
    }
};

pub const Assignment = struct {
    task: []const u8,
    from_session: u64,
};

pub const Report = struct {
    from_session: u64,
    text: []const u8,
};

pub const Handover = struct {
    session_id: u64,
    summary: []const u8,
};

pub const Startup = struct {
    observed_at_unix_ms: i64,
};

pub const SessionMessage = struct {
    from_session: u64,
    observed_at_unix_ms: i64,
    text: []const u8,
};

pub const CallbackSource = enum { host, wakeup };

pub const PendingCallback = struct {
    id: u64,
    session_id: u64,
    source: CallbackSource,
};

pub const Callback = struct {
    id: u64,
    source: CallbackSource,
    observed_at_unix_ms: i64,
    text: []const u8,
};

pub const SessionCreated = struct {
    session_id: u64,
    parent_session_id: u64,
    task: []const u8,
};

pub const SessionInfo = struct {
    session_id: u64,
    role: Role,
    status: enum { running, ready, dormant },
    queued_inputs: usize,
    pending_callbacks: usize,
    last_active_unix_ms: i64,
};

/// A complete projection of program state, not the model's working memory.
pub const State = struct {
    session: struct {
        role: Role,
        child_sessions: usize = 0,
        callbacks: []const PendingCallback,
    },
    runtime: struct {
        observed_at_unix_ms: i64,
        registered_sessions: usize,
        running_sessions: usize,
        queued_inputs: usize,
        sessions: []const SessionInfo,
    },
};

/// Runtime facts sampled for one inference; never retained or inherited.
pub const Current = struct {
    session_id: u64,
    state: State,
};

pub const Event = union(enum) {
    startup: Startup,
    input: IncomingMessage,
    assignment: Assignment,
    report: Report,
    session_message: SessionMessage,
    callback: Callback,
    session_created: SessionCreated,
};

pub const EventGroup = struct {
    session_id: u64,
    items: []const Event,
};

/// Delivered observations or compacted understanding retained in history.
pub const Record = union(enum) {
    events: EventGroup,
    handover: Handover,
};

/// Each turn supplies current runtime facts alongside exactly one purpose.
/// Working understanding remains in the preceding LLM messages.
pub const Turn = struct {
    current: Current,
    purpose: union(enum) {
        work: struct { events: []const Event },
        summarize: struct { instructions: []const u8 },
    },
};

/// Render declared fields as YAML values. Returned bytes belong to arena.
pub fn renderRecord(arena: Allocator, record: Record) ![]const u8 {
    return render(arena, record);
}

pub fn renderTurn(arena: Allocator, turn: Turn) ![]const u8 {
    return render(arena, turn);
}

fn render(arena: Allocator, value: anytype) ![]const u8 {
    const bytes = try std.json.Stringify.valueAlloc(arena, value, .{});
    const document = try yaml.parse(arena, bytes, .{});
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();
    try yaml.emit(&output.writer, document, .{});
    return output.toOwnedSlice();
}
