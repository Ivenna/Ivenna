const std = @import("std");
const yaml = @import("yaml");
const contracts = @import("agent_contracts");
const Allocator = std.mem.Allocator;
const IncomingMessage = contracts.Communication.IncomingMessage;
const Feed = @import("instance_state").feeds.Feed;
const Time = @import("time.zig");

pub const Role = enum { core, activity };

pub const Assignment = struct {
    task: []const u8,
};

pub const ActivityMessage = struct {
    text: []const u8,
    observed_at_unix_ms: i64,

    pub fn jsonStringify(self: ActivityMessage, writer: anytype) !void {
        try writer.write(.{ .text = self.text, .observed_at = Time.Instant{ .unix_ms = self.observed_at_unix_ms } });
    }
};

pub const ActivityReport = struct {
    from_focus: []const u8,
    messages: []const ActivityMessage,
    ended_at_unix_ms: ?i64,

    pub fn jsonStringify(self: ActivityReport, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("from_focus");
        try writer.write(self.from_focus);
        if (self.messages.len != 0) {
            try writer.objectField("messages");
            try writer.write(self.messages);
        }
        if (self.ended_at_unix_ms) |at| {
            try writer.objectField("ended_at");
            try writer.write(Time.Instant{ .unix_ms = at });
        }
        try writer.endObject();
    }
};

pub const Handover = struct {
    focus_id: []const u8,
    observed_at_unix_ms: i64,
    summary: []const u8,
    state: State,

    pub fn jsonStringify(self: Handover, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("focus_id");
        try writer.write(self.focus_id);
        try writer.objectField("observed_at");
        try writer.write(Time.Instant{ .unix_ms = self.observed_at_unix_ms });
        try writer.objectField("summary");
        try writer.write(self.summary);
        if (!self.state.isEmpty()) {
            try writer.objectField("state");
            try writer.write(self.state);
        }
        try writer.endObject();
    }
};

pub const Startup = struct {
    observed_at_unix_ms: i64,

    pub fn jsonStringify(self: Startup, writer: anytype) !void {
        try writer.write(.{ .observed_at = Time.Instant{ .unix_ms = self.observed_at_unix_ms } });
    }
};

pub const FocusMessage = struct {
    from_focus: []const u8,
    observed_at_unix_ms: i64,
    text: []const u8,

    pub fn jsonStringify(self: FocusMessage, writer: anytype) !void {
        try writer.write(.{ .from_focus = self.from_focus, .observed_at = Time.Instant{ .unix_ms = self.observed_at_unix_ms }, .text = self.text });
    }
};

pub const FocusInterrupted = struct {
    focus_id: []const u8,
    observed_at_unix_ms: i64,
    reason: []const u8,

    pub fn jsonStringify(self: FocusInterrupted, writer: anytype) !void {
        try writer.write(.{ .focus_id = self.focus_id, .observed_at = Time.Instant{ .unix_ms = self.observed_at_unix_ms }, .reason = self.reason });
    }
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

    pub fn jsonStringify(self: Callback, writer: anytype) !void {
        try writer.write(.{ .callback_id = self.callback_id, .source = self.source, .observed_at = Time.Instant{ .unix_ms = self.observed_at_unix_ms }, .text = self.text });
    }
};

pub const SubscriptionReport = struct {
    subscription_id: []const u8,
    text: []const u8,
    observed_at_unix_ms: i64,
    source_time_unix_ms: ?i64,

    pub fn jsonStringify(self: SubscriptionReport, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("subscription_id");
        try writer.write(self.subscription_id);
        try writer.objectField("observed_at");
        try writer.write(Time.Instant{ .unix_ms = self.observed_at_unix_ms });
        if (self.source_time_unix_ms) |time| {
            try writer.objectField("source_time");
            try writer.write(Time.Instant{ .unix_ms = time });
        }
        try writer.objectField("text");
        try writer.write(self.text);
        try writer.endObject();
    }
};

/// Identity and observation time for an inference, with destinations for ordinary turns.
pub const Current = struct {
    focus_id: []const u8,
    role: Role,
    observed_at_unix_ms: i64,
    focuses: []const []const u8 = &.{},
    correspondents: []const []const u8 = &.{},
    feeds: []const Feed = &.{},

    fn write(self: Current, writer: anytype, include_destinations: bool) !void {
        try writer.beginObject();
        try writer.objectField("focus_id");
        try writer.write(self.focus_id);
        try writer.objectField("role");
        try writer.write(self.role);
        try writer.objectField("observed_at");
        try writer.write(Time.Instant{ .unix_ms = self.observed_at_unix_ms });
        if (include_destinations) {
            try writer.objectField("focuses");
            try writer.write(self.focuses);
            try writer.objectField("correspondents");
            try writer.write(self.correspondents);
            try writer.objectField("feeds");
            try writer.write(self.feeds);
        }
        try writer.endObject();
    }
};

/// Focus identity, time, and runtime references sampled together for compaction.
pub const Snapshot = struct {
    current: Current,
    state: State,
};

/// The sampled focus's pending callbacks and active subscriptions. The core
/// also sees the existing activities.
pub const State = struct {
    activities: []const []const u8,
    callbacks: []const PendingCallback,
    subscriptions: []const []const u8,

    pub fn isEmpty(self: State) bool {
        return self.activities.len == 0 and self.callbacks.len == 0 and self.subscriptions.len == 0;
    }

    pub fn jsonStringify(self: State, writer: anytype) !void {
        try writer.beginObject();
        if (self.activities.len != 0) {
            try writer.objectField("activities");
            try writer.write(self.activities);
        }
        if (self.callbacks.len != 0) {
            try writer.objectField("callbacks");
            try writer.write(self.callbacks);
        }
        if (self.subscriptions.len != 0) {
            try writer.objectField("subscriptions");
            try writer.write(self.subscriptions);
        }
        try writer.endObject();
    }
};

pub fn cloneState(a: Allocator, state: State) !State {
    return .{
        .activities = try cloneIds(a, state.activities),
        .callbacks = try cloneCallbacks(a, state.callbacks),
        .subscriptions = try cloneIds(a, state.subscriptions),
    };
}

fn cloneCallbacks(a: Allocator, values: []const PendingCallback) ![]const PendingCallback {
    const owned = try a.dupe(PendingCallback, values);
    for (owned) |*callback| {
        callback.callback_id = try a.dupe(u8, callback.callback_id);
        callback.source = switch (callback.source) {
            .wakeup => .wakeup,
            .host => |host| .{ .host = .{ .command_id = try a.dupe(u8, host.command_id) } },
        };
    }
    return owned;
}

fn cloneIds(a: Allocator, values: []const []const u8) ![]const []const u8 {
    const owned = try a.alloc([]const u8, values.len);
    for (values, owned) |value, *id| id.* = try a.dupe(u8, value);
    return owned;
}

pub const Event = union(enum) {
    startup: Startup,
    input: IncomingMessage,
    assignment: Assignment,
    activity: ActivityReport,
    focus_message: FocusMessage,
    focus_interrupted: FocusInterrupted,
    callback: Callback,
    subscription: SubscriptionReport,

    pub fn jsonStringify(self: Event, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField(@tagName(self));
        switch (self) {
            .input => |message| try writer.write(.{ .from = message.from, .text = message.text, .observed_at = Time.Instant{ .unix_ms = message.observed_at_unix_ms } }),
            inline else => |payload| try writer.write(payload),
        }
        try writer.endObject();
    }
};

/// Copy retained observations without passing them through model presentation.
pub fn cloneEvents(a: Allocator, events: []const Event) ![]const Event {
    const owned = try a.alloc(Event, events.len);
    for (events, owned) |event, *copy| copy.* = try cloneEvent(a, event);
    return owned;
}

pub fn cloneEvent(a: Allocator, event: Event) !Event {
    return switch (event) {
        .startup => |startup| .{ .startup = startup },
        .input => |input| blk: {
            const from = try a.alloc([]const u8, input.from.len);
            for (input.from, from) |id, *copy| copy.* = try a.dupe(u8, id);
            break :blk .{ .input = .{ .from = from, .text = try a.dupe(u8, input.text), .observed_at_unix_ms = input.observed_at_unix_ms } };
        },
        .assignment => |assignment| .{ .assignment = .{ .task = try a.dupe(u8, assignment.task) } },
        .activity => |report| blk: {
            const messages = try a.alloc(ActivityMessage, report.messages.len);
            for (report.messages, messages) |message, *copy| copy.* = .{ .text = try a.dupe(u8, message.text), .observed_at_unix_ms = message.observed_at_unix_ms };
            break :blk .{ .activity = .{ .from_focus = try a.dupe(u8, report.from_focus), .messages = messages, .ended_at_unix_ms = report.ended_at_unix_ms } };
        },
        .focus_message => |message| .{ .focus_message = .{ .from_focus = try a.dupe(u8, message.from_focus), .observed_at_unix_ms = message.observed_at_unix_ms, .text = try a.dupe(u8, message.text) } },
        .focus_interrupted => |failure| .{ .focus_interrupted = .{
            .focus_id = try a.dupe(u8, failure.focus_id),
            .observed_at_unix_ms = failure.observed_at_unix_ms,
            .reason = try a.dupe(u8, failure.reason),
        } },
        .subscription => |report| .{ .subscription = .{
            .subscription_id = try a.dupe(u8, report.subscription_id),
            .text = try a.dupe(u8, report.text),
            .observed_at_unix_ms = report.observed_at_unix_ms,
            .source_time_unix_ms = report.source_time_unix_ms,
        } },
        .callback => |callback| .{ .callback = .{
            .callback_id = try a.dupe(u8, callback.callback_id),
            .source = switch (callback.source) {
                .wakeup => .wakeup,
                .host => |host| .{ .host = .{ .command_id = try a.dupe(u8, host.command_id) } },
            },
            .observed_at_unix_ms = callback.observed_at_unix_ms,
            .text = try a.dupe(u8, callback.text),
        } },
    };
}

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

/// Observations and handovers retained in working history.
pub const Record = union(enum) {
    events: EventGroup,
    handover: Handover,
};

/// Identity and time with new observations or a compaction request.
pub const Turn = struct {
    current: Current,
    purpose: union(enum) {
        work: []const Event,
        summarize: struct { instructions: []const u8, state: State },
    },

    pub fn jsonStringify(self: Turn, writer: anytype) !void {
        try writer.beginObject();
        try writer.objectField("current");
        try self.current.write(writer, self.purpose == .work);
        switch (self.purpose) {
            .work => |events| {
                if (events.len != 0) {
                    try writer.objectField("events");
                    try writer.write(events);
                }
            },
            .summarize => |summary| {
                try writer.objectField("summarize");
                try writer.beginObject();
                try writer.objectField("instructions");
                try writer.write(summary.instructions);
                if (!summary.state.isEmpty()) {
                    try writer.objectField("state");
                    try writer.write(summary.state);
                }
                try writer.endObject();
            },
        }
        try writer.endObject();
    }
};

/// Render the model-facing record as YAML. Returned bytes belong to arena.
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

test "activity grouping retains each source's message order, times, and silent endings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const grouped = try coalesceActivityReports(arena.allocator(), &.{
        .{ .activity = .{ .from_focus = "practice-2", .messages = &.{.{ .text = "first", .observed_at_unix_ms = 10 }}, .ended_at_unix_ms = null } },
        .{ .input = .{ .from = &.{"operator"}, .text = "Continue.", .observed_at_unix_ms = 11 } },
        .{ .activity = .{ .from_focus = "research-3", .messages = &.{}, .ended_at_unix_ms = 12 } },
        .{ .activity = .{ .from_focus = "practice-2", .messages = &.{.{ .text = "second", .observed_at_unix_ms = 13 }}, .ended_at_unix_ms = null } },
        .{ .activity = .{ .from_focus = "practice-2", .messages = &.{}, .ended_at_unix_ms = 14 } },
    });
    const expected: []const Event = &.{
        .{ .activity = .{ .from_focus = "practice-2", .messages = &.{
            .{ .text = "first", .observed_at_unix_ms = 10 },
            .{ .text = "second", .observed_at_unix_ms = 13 },
        }, .ended_at_unix_ms = 14 } },
        .{ .input = .{ .from = &.{"operator"}, .text = "Continue.", .observed_at_unix_ms = 11 } },
        .{ .activity = .{ .from_focus = "research-3", .messages = &.{}, .ended_at_unix_ms = 12 } },
    };
    try std.testing.expectEqualDeep(expected, grouped);
}
