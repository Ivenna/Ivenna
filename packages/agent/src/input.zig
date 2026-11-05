const std = @import("std");
const yaml = @import("yaml");
const Mail = @import("mail.zig");
const Allocator = std.mem.Allocator;

pub const Role = enum { core, branch };
pub const Audience = enum { external, internal };

pub const MailOrigin = struct {
    mail_id: []const u8,
    thread_id: []const u8,
    message_id: ?[]const u8 = null,
    in_reply_to: ?[]const u8 = null,
    references: []const []const u8 = &.{},
    purpose: ?Mail.Purpose = null,
    from: []const Mail.Address,
    to: []const Mail.Address,
    subject: []const u8,
    observed_at_unix_ms: i64,
    body_file: []const u8,
    body_bytes: usize,
};

pub const MailRecord = struct {
    origin: MailOrigin,
    excerpt: []const u8,
    excerpt_bytes: usize,
};

/// Historical mail carries evidence, without another frame's session identity
/// or the authority of a current assignment or runtime observation.
pub const Background = union(enum) {
    history: MailRecord,
    handover: MailRecord,
};

pub const ReportOutcome = union(enum) {
    completed: []const u8,
    failed: []const u8,
};

pub const State = struct {
    conversation: struct {
        role: Role,
        parent_generation: ?u64 = null,
        parent_session_id: ?u64 = null,
        active_children: usize = 0,
        thread_id: []const u8,
    },
    runtime: struct {
        active_sessions: usize,
        running_sessions: usize,
        active_conversations: usize,
        queued_turns: usize,
    },
    response: struct {
        audience: Audience = .internal,
        source_mail_id: ?[]const u8 = null,
    } = .{},
};

/// Current state for one model request. Strings borrow the active delivery or
/// session and must be rendered while their owner remains live.
pub const Snapshot = struct {
    session_id: u64,
    state: State,
};

pub const Observation = union(enum) {
    input: struct {
        letter: MailRecord,
        background: []const Background = &.{},
    },
    assignment: struct {
        task: []const u8,
        origin: MailOrigin,
    },
    report: struct {
        from_session: u64,
        outcome: ReportOutcome,
    },
    handover: struct {
        summary: []const u8,
        thread_id: []const u8,
    },
    background: struct {
        items: []const Background,
    },
    runtime: State,
    source_update: struct {
        mail_id: []const u8,
        state: enum { withdrawn },
    },
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

/// Runtime state is request-local and does not accumulate in working history.
pub fn serializeSnapshot(arena: Allocator, snapshot: Snapshot) ![]const u8 {
    return serialize(arena, snapshot.session_id, .{ .runtime = snapshot.state });
}
