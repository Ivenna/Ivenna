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

pub const Evidence = struct {
    content: Content,
    contacts: []const Communication.Contact = &.{},
    source: ?Source = null,
};

pub const Input = struct {
    content: Content,
    contacts: []const Communication.Contact = &.{},
    source: ?Source = null,
    context: []const Background = &.{},
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

pub const Background = union(enum) {
    evidence: Evidence,
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

/// Current state for one model request.
pub const Snapshot = struct {
    session_id: u64,
    state: State,
};

pub const Observation = union(enum) {
    input: Input,
    assignment: Assignment,
    report: Report,
    handover: Handover,
    background: struct {
        items: []const Background,
    },
    runtime: State,
    context_compaction: struct {
        instructions: []const u8,
        state: State,
    },
};

pub const Frame = struct {
    session_id: u64,
    observation: Observation,
};

/// The typed observation determines the complete YAML shape. Source text is
/// serialized as a value; callers cannot merge arbitrary envelope fields.
/// Returned bytes belong to arena.
pub fn serialize(arena: Allocator, session_id: u64, observation: Observation) ![]const u8 {
    const frame: Frame = .{ .session_id = session_id, .observation = observation };
    const bytes = try std.json.Stringify.valueAlloc(arena, frame, .{});
    const document = try yaml.parse(arena, bytes, .{});
    var output = std.Io.Writer.Allocating.init(arena);
    defer output.deinit();
    try yaml.emit(&output.writer, document, .{});
    return output.toOwnedSlice();
}

pub fn serializeSnapshot(arena: Allocator, snapshot: Snapshot) ![]const u8 {
    return serialize(arena, snapshot.session_id, .{ .runtime = snapshot.state });
}
