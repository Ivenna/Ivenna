const std = @import("std");
const Input = @import("input.zig");
const Entry = @import("history.zig").Entry;
const Scope = @import("history.zig").Scope;
const Model = @import("agent_contracts").Model;
const Content = @import("content").Content;
const Allocator = std.mem.Allocator;

/// Owned working history and the model-message view derived from it. Registry
/// synchronizes mutation; current context and summary requests are temporary.
pub const Context = struct {
    /// Only a newly admitted group is presented as this turn's observations.
    /// Older groups remain in the LLM conversation, even after empty output.
    pub const Delivery = enum { none, latest };

    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    /// This session's current history segment.
    scope: Scope,
    entries: std.ArrayList(Entry) = .empty,
    messages: std.ArrayList(Model.Item) = .empty,

    pub fn init(allocator: Allocator, scope: Scope, system_text: []const u8) !Context {
        return restore(allocator, scope, &.{}, system_text);
    }

    pub fn restore(allocator: Allocator, scope: Scope, entries: []const Entry, system_text: []const u8) !Context {
        var self: Context = .{ .allocator = allocator, .arena = .init(allocator), .scope = scope };
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

    /// Return an independently owned snapshot of this session's retained history.
    pub fn clone(self: *const Context, allocator: Allocator) !Context {
        return restore(allocator, self.scope, self.entries.items, self.messages.items[0].message.text);
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

    /// The slice and rendered request belong to a; retained message payloads
    /// borrow self.
    pub fn request(self: *const Context, a: Allocator, current: Input.Current, delivery: Delivery) ![]const Model.Item {
        const events = switch (delivery) {
            .none => &.{},
            .latest => self.entries.items[self.entries.items.len - 1].record.events.items,
        };
        return self.buildRequest(a, self.messages.items.len - @intFromBool(delivery == .latest), .{
            .current = current,
            .purpose = .{ .work = .{ .events = events } },
        });
    }

    /// Assemble an admission candidate without changing retained history.
    /// As with request, retained message payloads borrow self.
    pub fn requestWithEvents(self: *const Context, a: Allocator, events: []const Input.Event, current: Input.Current) ![]const Model.Item {
        return self.buildRequest(a, self.messages.items.len, .{
            .current = current,
            .purpose = .{ .work = .{ .events = events } },
        });
    }

    /// Summarization reads retained history without admitting pending events.
    pub fn summaryRequest(self: *const Context, a: Allocator, current: Input.Current, instructions: []const u8) ![]const Model.Item {
        return self.buildRequest(a, self.messages.items.len, .{
            .current = current,
            .purpose = .{ .summarize = .{ .instructions = instructions } },
        });
    }

    fn buildRequest(self: *const Context, a: Allocator, prefix_len: usize, turn: Input.Turn) ![]const Model.Item {
        const messages = try a.alloc(Model.Item, prefix_len + 1);
        @memcpy(messages[0..prefix_len], self.messages.items[0..prefix_len]);
        messages[prefix_len] = .{ .message = .{ .role = .user, .text = try Input.renderTurn(a, turn) } };
        return messages;
    }

    pub fn withHandover(self: *const Context, allocator: Allocator, summary: []const u8) !Context {
        const scope: Scope = .{ .session_id = self.scope.session_id, .epoch = try std.math.add(u64, self.scope.epoch, 1) };
        const record: Input.Record = .{ .handover = .{ .session_id = scope.session_id, .summary = summary } };
        return restore(allocator, scope, &.{.{ .record = record }}, self.messages.items[0].message.text);
    }

    fn append(self: *Context, entry: Entry) !void {
        const a = self.arena.allocator();
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        switch (entry) {
            .record => |record| {
                try self.messages.ensureUnusedCapacity(self.allocator, 1);
                const copy: Input.Record = switch (record) {
                    .events => |group| .{ .events = .{ .session_id = group.session_id, .items = try cloneEvents(a, group.items) } },
                    .handover => |handover| .{ .handover = .{ .session_id = handover.session_id, .summary = try a.dupe(u8, handover.summary) } },
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
        .assignment => |assignment| .{ .assignment = .{ .task = try a.dupe(u8, assignment.task) } },
        .report => |report| .{ .report = .{ .from_session = report.from_session, .text = try a.dupe(u8, report.text) } },
        .session_message => |message| .{ .session_message = .{
            .from_session = message.from_session,
            .observed_at_unix_ms = message.observed_at_unix_ms,
            .text = try a.dupe(u8, message.text),
        } },
        .callback => |callback| .{ .callback = .{
            .id = callback.id,
            .source = callback.source,
            .observed_at_unix_ms = callback.observed_at_unix_ms,
            .text = try a.dupe(u8, callback.text),
        } },
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
