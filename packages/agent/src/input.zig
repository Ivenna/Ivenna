const std = @import("std");
const yaml = @import("yaml");
const Communication = @import("communication.zig");
const Allocator = std.mem.Allocator;

pub const Role = enum { core, branch };

pub const Resource = struct {
    file: []const u8,
    byte_length: usize,
};

pub const Content = union(enum) {
    text: []const u8,
    excerpt: struct {
        text: []const u8,
        full: Resource,
    },
};

pub const Source = struct {
    reference: []const u8,
    description: ?[]const u8 = null,
    observed_at_unix_ms: ?i64 = null,
    details: ?Resource = null,
};

pub const Material = struct {
    content: Content,
    contacts: []const Communication.Contact = &.{},
    source: ?Source = null,
};

pub const Handover = struct {
    summary: []const u8,
    source: ?Resource = null,
};

pub const Assignment = struct {
    task: []const u8,
    from_session: u64,
    source_refs: []const []const u8 = &.{},
};

pub const Report = struct {
    from_session: u64,
    text: []const u8,
};

pub const ContextItem = union(enum) {
    evidence: Material,
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
    input: Material,
    assignment: Assignment,
    report: Report,
};

/// A retained event group and any supporting material in a session's history.
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
