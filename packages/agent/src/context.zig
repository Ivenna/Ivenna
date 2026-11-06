const std = @import("std");
const Input = @import("input.zig");
const Entry = @import("history.zig").Entry;
const Model = @import("agent_contracts").Model;
const Content = @import("content").Content;
const Allocator = std.mem.Allocator;

/// Owned working history and the model-message view derived from it. Registry
/// synchronizes mutation; current requests never become retained records.
pub const Context = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,
    messages: []const Model.Item,

    pub fn init(allocator: Allocator, system_text: []const u8) !Context {
        return restore(allocator, &.{}, system_text);
    }

    pub fn restore(allocator: Allocator, entries: []const Entry, system_text: []const u8) !Context {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const owned = try a.alloc(Entry, entries.len);
        var messages: std.ArrayList(Model.Item) = .empty;
        try messages.append(a, .{ .message = .{ .role = .system, .text = try a.dupe(u8, system_text) } });
        for (entries, owned) |entry, *copy| switch (entry) {
            .record => |record| {
                copy.* = .{ .record = .{
                    .session_id = record.session_id,
                    .events = try cloneEvents(a, record.events),
                    .handover = if (record.handover) |handover| .{ .summary = try a.dupe(u8, handover.summary) } else null,
                } };
                try messages.append(a, .{ .message = .{ .role = .user, .text = try Input.renderRecord(a, copy.record) } });
            },
            .exchange => |items| {
                const batch = try a.alloc(Model.Item, items.len);
                for (items, batch) |item, *cloned| cloned.* = try cloneItem(a, item);
                copy.* = .{ .exchange = batch };
                try messages.appendSlice(a, batch);
            },
        };
        return .{ .allocator = allocator, .arena = arena, .entries = owned, .messages = try messages.toOwnedSlice(a) };
    }

    pub fn deinit(self: *Context) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn history(self: *const Context) []const Model.Item {
        return self.messages;
    }

    pub fn records(self: *const Context) []const Entry {
        return self.entries;
    }

    /// Source values and the derived view become independently owned.
    pub fn fork(self: *const Context, allocator: Allocator) !Context {
        return restore(allocator, self.entries, self.messages[0].message.text);
    }

    pub fn appendRecord(self: *Context, record: Input.Record) !void {
        try self.append(.{ .record = record });
    }

    /// Retain one complete exchange, preserving the adapter's opaque output.
    pub fn appendBatch(self: *Context, output: []const Model.Item, replies: []const Model.Item) !void {
        if (output.len == 0) return;
        const batch = try self.allocator.alloc(Model.Item, output.len + replies.len);
        defer self.allocator.free(batch);
        @memcpy(batch[0..output.len], output);
        @memcpy(batch[output.len..], replies);
        try self.append(.{ .exchange = batch });
    }

    /// The temporary request and returned slice belong to a.
    pub fn request(self: *const Context, a: Allocator, current: Input.Request) ![]const Model.Item {
        const messages = try a.alloc(Model.Item, self.messages.len + 1);
        @memcpy(messages[0..self.messages.len], self.messages);
        messages[self.messages.len] = .{ .message = .{ .role = .user, .text = try Input.renderRequest(a, current) } };
        return messages;
    }

    pub fn withHandover(self: *const Context, allocator: Allocator, session_id: u64, handover: Input.Handover) !Context {
        return restore(allocator, &.{.{ .record = .{ .session_id = session_id, .handover = handover } }}, self.messages[0].message.text);
    }

    fn append(self: *Context, entry: Entry) !void {
        const entries = try self.allocator.alloc(Entry, self.entries.len + 1);
        defer self.allocator.free(entries);
        @memcpy(entries[0..self.entries.len], self.entries);
        entries[self.entries.len] = entry;
        const next = try restore(self.allocator, entries, self.messages[0].message.text);
        self.arena.deinit();
        self.* = next;
    }
};

fn cloneEvents(a: Allocator, events: []const Input.Event) ![]const Input.Event {
    const owned = try a.alloc(Input.Event, events.len);
    for (events, owned) |event, *copy| copy.* = switch (event) {
        .startup => |startup| .{ .startup = startup },
        .input => |input| blk: {
            const from = try a.alloc([]const u8, input.from.len);
            for (input.from, from) |id, *cloned| cloned.* = try a.dupe(u8, id);
            break :blk .{ .input = .{ .from = from, .text = try a.dupe(u8, input.text), .observed_at_unix_ms = input.observed_at_unix_ms } };
        },
        .assignment => |assignment| .{ .assignment = .{ .task = try a.dupe(u8, assignment.task), .from_session = assignment.from_session } },
        .report => |report| .{ .report = .{ .from_session = report.from_session, .text = try a.dupe(u8, report.text) } },
    };
    return owned;
}

fn cloneItem(a: Allocator, item: Model.Item) !Model.Item {
    return switch (item) {
        .message => |message| .{ .message = .{ .role = message.role, .text = try a.dupe(u8, message.text) } },
        .continuation => |bytes| .{ .continuation = try a.dupe(u8, bytes) },
        .tool_result => |result| blk: {
            const parts = try a.alloc(Content.Part, result.content.parts.len);
            for (result.content.parts, parts) |part, *copy| copy.* = switch (part) {
                .text => |text| .{ .text = try a.dupe(u8, text) },
                .image => |image| .{ .image = switch (image) {
                    .url => |url| .{ .url = try a.dupe(u8, url) },
                    .data => |data| .{ .data = .{ .format = data.format, .bytes = try a.dupe(u8, data.bytes) } },
                } },
            };
            break :blk .{ .tool_result = .{ .call_id = try a.dupe(u8, result.call_id), .content = .{ .parts = parts } } };
        },
    };
}
