const std = @import("std");
const yaml = @import("yaml");
const contracts = @import("agent_contracts");
const Allocator = std.mem.Allocator;
const IncomingMessage = contracts.Communication.IncomingMessage;

pub const Role = enum { core, branch };

pub const Assignment = struct {
    task: []const u8,
    from_session: u64,
};

pub const Report = struct {
    from_session: u64,
    text: []const u8,
};

pub const Handover = struct {
    summary: []const u8,
};

pub const Startup = struct {
    observed_at_unix_ms: i64,
};

pub const Response = union(enum) {
    report: struct { session_id: u64 },
    internal: struct {},
    summary: struct {},
};

pub const State = struct {
    session: struct {
        role: Role,
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
    startup: Startup,
    input: IncomingMessage,
    assignment: Assignment,
    report: Report,
};

/// An event group or compacted understanding retained in session history.
pub const Record = struct {
    session_id: u64,
    events: []const Event = &.{},
    handover: ?Handover = null,
};

/// Temporary current-state message appended for one inference.
pub const Request = struct {
    session_id: u64,
    state: State,
    instructions: ?[]const u8 = null,
};

/// Render declared fields as YAML values. Returned bytes belong to arena.
pub fn renderRecord(arena: Allocator, record: Record) ![]const u8 {
    return render(arena, record, .{ .emit_null_optional_fields = false });
}

pub fn renderRequest(arena: Allocator, request: Request) ![]const u8 {
    return render(arena, request, .{});
}

fn render(arena: Allocator, value: anytype, options: std.json.Stringify.Options) ![]const u8 {
    const bytes = try std.json.Stringify.valueAlloc(arena, value, options);
    const document = try yaml.parse(arena, bytes, .{});
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();
    try yaml.emit(&output.writer, document, .{});
    return output.toOwnedSlice();
}
