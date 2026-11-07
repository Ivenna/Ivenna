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
    summary: []const u8,
};

pub const Startup = struct {
    observed_at_unix_ms: i64,
};

pub const State = struct {
    session: struct {
        role: Role,
        active_children: usize = 0,
    },
    runtime: struct {
        active_sessions: usize,
        running_sessions: usize,
        queued_inputs: usize,
    },
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
    content: union(enum) {
        events: []const Event,
        handover: Handover,
    },
};

pub const Operation = union(enum) {
    execute: void,
    summarize: struct { instructions: []const u8 },
};

/// Temporary state and operation supplied for one inference.
pub const Request = struct {
    session_id: u64,
    state: State,
    operation: Operation,
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
