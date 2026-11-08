const std = @import("std");
const yaml = @import("yaml");
const contracts = @import("agent_contracts");
const Allocator = std.mem.Allocator;
const IncomingMessage = contracts.Communication.IncomingMessage;

pub const Role = enum { core, activity };

pub const Assignment = struct {
    task: []const u8,
};

pub const ActivityMessage = struct {
    text: []const u8,
    observed_at_unix_ms: i64,
};

pub const ActivityReport = struct {
    from_focus: []const u8,
    messages: []const ActivityMessage,
    ended_at_unix_ms: ?i64,
};

pub const Handover = struct {
    focus_id: []const u8,
    summary: []const u8,
};

pub const Startup = struct {
    observed_at_unix_ms: i64,
};

pub const FocusMessage = struct {
    from_focus: []const u8,
    observed_at_unix_ms: i64,
    text: []const u8,
};

pub const PendingCallback = struct {
    callback_id: []const u8,
    source: contracts.Callback.Source,
};

pub const Callback = struct {
    callback_id: []const u8,
    source: contracts.Callback.Source,
    observed_at_unix_ms: i64,
    text: []const u8,
};

pub const FocusInfo = struct {
    focus_id: []const u8,
    role: Role,
    status: enum { running, waiting_for_tools, ready, dormant },
    queued_inputs: usize,
    pending_callbacks: usize,
};

/// Current focus and the circumstances visible for one inference; never retained.
pub const Current = struct {
    focus_id: []const u8,
    role: Role,
    observed_at_unix_ms: i64,
    callbacks: []const PendingCallback,
    focuses: []const FocusInfo,
};

pub const Event = union(enum) {
    startup: Startup,
    input: IncomingMessage,
    assignment: Assignment,
    activity: ActivityReport,
    focus_message: FocusMessage,
    callback: Callback,
};

/// Group selected activity observations by their first appearance. Returned
/// arrays belong to arena; text and other event payloads borrow events.
pub fn coalesceActivityReports(arena: Allocator, events: []const Event) ![]const Event {
    const Group = struct {
        position: usize,
        from_focus: []const u8,
        messages: std.ArrayList(ActivityMessage) = .empty,
        ended_at_unix_ms: ?i64 = null,
    };
    var groups: std.ArrayList(Group) = .empty;
    var positions: std.StringHashMapUnmanaged(usize) = .empty;
    var result: std.ArrayList(Event) = .empty;
    try result.ensureTotalCapacity(arena, events.len);
    for (events) |event| switch (event) {
        .activity => |report| {
            if (report.messages.len == 0 and report.ended_at_unix_ms == null) continue;
            const entry = try positions.getOrPut(arena, report.from_focus);
            const index = if (entry.found_existing) entry.value_ptr.* else new: {
                const index = groups.items.len;
                try groups.append(arena, .{ .position = result.items.len, .from_focus = report.from_focus });
                entry.value_ptr.* = index;
                result.appendAssumeCapacity(.{ .activity = report });
                break :new index;
            };
            const group = &groups.items[index];
            try group.messages.appendSlice(arena, report.messages);
            if (report.ended_at_unix_ms) |at| group.ended_at_unix_ms = at;
        },
        else => result.appendAssumeCapacity(event),
    };
    for (groups.items) |*group| result.items[group.position] = .{ .activity = .{
        .from_focus = group.from_focus,
        .messages = try group.messages.toOwnedSlice(arena),
        .ended_at_unix_ms = group.ended_at_unix_ms,
    } };
    return result.toOwnedSlice(arena);
}

pub const EventGroup = struct {
    focus_id: []const u8,
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
