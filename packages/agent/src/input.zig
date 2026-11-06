const std = @import("std");
const yaml = @import("yaml");
const contracts = @import("agent_contracts");
const Allocator = std.mem.Allocator;
const IncomingMessage = contracts.Communication.IncomingMessage;
const SentMessage = contracts.Communication.SentMessage;
const Handover = contracts.Handover;

pub const Role = enum { core, branch };

pub const Assignment = struct {
    task: []const u8,
    from_session: u64,
};

pub const Report = struct {
    from_session: u64,
    text: []const u8,
};

pub const ContextItem = union(enum) {
    received: IncomingMessage,
    sent: SentMessage,
    handover: Handover,
};

pub const Response = union(enum) {
    report: struct { session_id: u64 },
    internal: struct {},
    summary: struct {},
};

pub const State = struct {
    session: struct {
        role: Role,
        parent_generation: ?u64 = null,
        parent_session_id: ?u64 = null,
        active_children: usize = 0,
    },
    runtime: struct {
        active_sessions: usize,
        running_sessions: usize,
        queued_inputs: usize,
    },
    response: Response = .{ .internal = .{} },
};

/// Current session state supplied by the registry.
pub const Snapshot = struct {
    session_id: u64,
    state: State,
};

pub const Event = union(enum) {
    input: IncomingMessage,
    assignment: Assignment,
    report: Report,
};

/// A retained event group and supporting context in a session's history.
pub const Record = struct {
    session_id: u64,
    events: []const Event = &.{},
    context: []const ContextItem = &.{},
};

/// Temporary current-state message appended for one inference.
pub const Request = struct {
    session_id: u64,
    state: State,
    instructions: ?[]const u8 = null,
};

/// Render declared fields as YAML values. Returned bytes belong to arena.
pub fn renderRecord(arena: Allocator, record: Record) ![]const u8 {
    return render(arena, record);
}

pub fn renderRequest(arena: Allocator, request: Request) ![]const u8 {
    return render(arena, request);
}

fn render(arena: Allocator, value: anytype) ![]const u8 {
    const bytes = try std.json.Stringify.valueAlloc(arena, value, .{});
    const document = try yaml.parse(arena, bytes, .{});
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();
    try yaml.emit(&output.writer, document, .{});
    return output.toOwnedSlice();
}
