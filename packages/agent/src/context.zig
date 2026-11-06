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
    entries: std.ArrayList(Entry) = .empty,
    messages: std.ArrayList(Model.Item) = .empty,

    pub fn init(allocator: Allocator, system_text: []const u8) !Context {
        return restore(allocator, &.{}, system_text);
    }

    pub fn restore(allocator: Allocator, entries: []const Entry, system_text: []const u8) !Context {
        var self: Context = .{ .allocator = allocator, .arena = .init(allocator) };
        errdefer self.deinit();
        const a = self.arena.allocator();
        try self.entries.ensureTotalCapacity(allocator, entries.len);
        try self.messages.append(allocator, .{ .message = .{ .role = .system, .text = try a.dupe(u8, system_text) } });
        for (entries) |entry| try self.append(entry);
        return self;
    }

    pub fn deinit(self: *Context) void {
        self.entries.deinit(self.allocator);
        self.messages.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn history(self: *const Context) []const Model.Item {
        return self.messages.items;
    }

    pub fn records(self: *const Context) []const Entry {
        return self.entries.items;
    }

    /// Source values and the derived view become independently owned.
    pub fn fork(self: *const Context, allocator: Allocator) !Context {
        return restore(allocator, self.entries.items, self.messages.items[0].message.text);
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
        return self.buildRequest(a, null, current);
    }

    /// Measure an admission candidate without cloning or retaining its history.
    pub fn requestWithRecord(self: *const Context, a: Allocator, record: Input.Record, current: Input.Request) ![]const Model.Item {
        return self.buildRequest(a, record, current);
    }

    fn buildRequest(self: *const Context, a: Allocator, record: ?Input.Record, current: Input.Request) ![]const Model.Item {
        const history_len = self.messages.items.len;
        const messages = try a.alloc(Model.Item, history_len + @as(usize, if (record != null) 2 else 1));
        @memcpy(messages[0..history_len], self.messages.items);
        if (record) |value| messages[history_len] = .{ .message = .{ .role = .user, .text = try Input.renderRecord(a, value) } };
        messages[messages.len - 1] = .{ .message = .{ .role = .user, .text = try Input.renderRequest(a, current) } };
        return messages;
    }

    pub fn withHandover(self: *const Context, allocator: Allocator, session_id: u64, handover: Input.Handover) !Context {
        return restore(allocator, &.{.{ .record = .{ .session_id = session_id, .handover = handover } }}, self.messages.items[0].message.text);
    }

    fn append(self: *Context, entry: Entry) !void {
        const a = self.arena.allocator();
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        switch (entry) {
            .record => |record| {
                try self.messages.ensureUnusedCapacity(self.allocator, 1);
                const copy: Input.Record = .{
                    .session_id = record.session_id,
                    .events = try cloneEvents(a, record.events),
                    .handover = if (record.handover) |handover| .{ .summary = try a.dupe(u8, handover.summary) } else null,
                };
                const text = try Input.renderRecord(a, copy);
                self.entries.appendAssumeCapacity(.{ .record = copy });
                self.messages.appendAssumeCapacity(.{ .message = .{ .role = .user, .text = text } });
            },
            .exchange => |items| {
                try self.messages.ensureUnusedCapacity(self.allocator, items.len);
                const batch = try a.alloc(Model.Item, items.len);
                for (items, batch) |item, *copy| copy.* = try cloneItem(a, item);
                self.entries.appendAssumeCapacity(.{ .exchange = batch });
                self.messages.appendSliceAssumeCapacity(batch);
            },
        }
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
