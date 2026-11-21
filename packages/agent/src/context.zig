const std = @import("std");
const Input = @import("input.zig");
const Entry = @import("history.zig").Entry;
const Scope = @import("history.zig").Scope;
const Model = @import("agent_contracts").Model;
const Content = @import("content").Content;
const Allocator = std.mem.Allocator;

/// Owned working history and its model-message view. Registry synchronizes
/// mutation; request assembly remains read-only.
pub const Context = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    scope: Scope,
    focus_id: []const u8,
    entries: std.ArrayList(Entry) = .empty,
    messages: std.ArrayList(Model.Item) = .empty,

    pub fn init(allocator: Allocator, scope: Scope, focus_id: []const u8) !Context {
        return restore(allocator, scope, focus_id, &.{});
    }

    pub fn restore(allocator: Allocator, scope: Scope, focus_id: []const u8, entries: []const Entry) !Context {
        var self: Context = .{ .allocator = allocator, .arena = .init(allocator), .scope = scope, .focus_id = undefined };
        errdefer self.deinit();
        self.focus_id = try self.arena.allocator().dupe(u8, focus_id);
        try self.entries.ensureTotalCapacity(allocator, entries.len);
        for (entries) |entry| try self.append(entry);
        return self;
    }

    pub fn deinit(self: *Context) void {
        self.entries.deinit(self.allocator);
        self.messages.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn records(self: *const Context) []const Entry {
        return self.entries.items;
    }

    pub fn clone(self: *const Context, allocator: Allocator) !Context {
        return restore(allocator, self.scope, self.focus_id, self.entries.items);
    }

    pub fn appendRecord(self: *Context, record: Input.Record) !void {
        try self.append(.{ .record = record });
    }

    /// Preserve the complete native exchange, including replies when model
    /// output is empty.
    pub fn appendBatch(self: *Context, output: []const Model.Item, replies: []const Model.Item) !void {
        if (output.len == 0 and replies.len == 0) return;
        const batch = try self.allocator.alloc(Model.Item, output.len + replies.len);
        defer self.allocator.free(batch);
        @memcpy(batch[0..output.len], output);
        @memcpy(batch[output.len..], replies);
        try self.append(.{ .exchange = batch });
    }

    /// Present new observations once alongside the retained history. The
    /// request borrows self through inference and owns its rendered turn in a.
    pub fn request(self: *const Context, a: Allocator, current: Input.Current, events: []const Input.Event) ![]const Model.Item {
        return self.buildRequest(a, .{ .current = current, .purpose = .{ .work = events } });
    }

    /// Assemble a summary request from retained history and sampled state;
    /// pending events stay outside.
    pub fn summaryRequest(self: *const Context, a: Allocator, snapshot: Input.Snapshot, instructions: []const u8) ![]const Model.Item {
        return self.buildRequest(a, .{
            .current = snapshot.current,
            .purpose = .{ .summarize = .{ .instructions = instructions, .state = snapshot.state } },
        });
    }

    fn buildRequest(self: *const Context, a: Allocator, turn: Input.Turn) ![]Model.Item {
        const prefix_len = self.messages.items.len;
        const messages = try a.alloc(Model.Item, prefix_len + 2);
        messages[0] = .{ .message = .{ .role = .system, .text = @embedFile("system.md") } };
        @memcpy(messages[1 .. prefix_len + 1], self.messages.items);
        messages[prefix_len + 1] = .{ .message = .{ .role = .user, .text = try Input.renderTurn(a, turn) } };
        return messages;
    }

    pub fn withHandover(self: *const Context, allocator: Allocator, handover: Input.Handover) !Context {
        const scope: Scope = .{ .session_id = self.scope.session_id, .epoch = try std.math.add(u64, self.scope.epoch, 1) };
        return restore(allocator, scope, self.focus_id, &.{.{ .record = .{ .handover = handover } }});
    }

    fn append(self: *Context, entry: Entry) !void {
        const a = self.arena.allocator();
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        switch (entry) {
            .record => |record| {
                try self.messages.ensureUnusedCapacity(self.allocator, 1);
                const copy: Input.Record = switch (record) {
                    .events => |group| .{ .events = .{ .focus_id = try a.dupe(u8, group.focus_id), .items = try Input.cloneEvents(a, group.items) } },
                    .handover => |handover| .{ .handover = .{
                        .focus_id = try a.dupe(u8, handover.focus_id),
                        .observed_at_unix_ms = handover.observed_at_unix_ms,
                        .summary = try a.dupe(u8, handover.summary),
                        .state = try Input.cloneState(a, handover.state),
                    } },
                };
                const text = try Input.renderRecord(a, copy);
                self.entries.appendAssumeCapacity(.{ .record = copy });
                self.messages.appendAssumeCapacity(.{ .message = .{ .role = .user, .text = text } });
            },
            .exchange => |exchange| {
                try self.messages.ensureUnusedCapacity(self.allocator, exchange.len);
                const batch = try a.alloc(Model.Item, exchange.len);
                for (exchange, batch) |item, *item_copy| item_copy.* = try cloneItem(a, item);
                self.entries.appendAssumeCapacity(.{ .exchange = batch });
                self.messages.appendSliceAssumeCapacity(batch);
            },
        }
    }
};

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
                .file => |file| .{ .file = .{
                    .bytes = try a.dupe(u8, file.bytes),
                    .reference = if (file.reference) |reference| try a.dupe(u8, reference) else null,
                } },
            };
            break :blk .{ .tool_result = .{ .call_id = try a.dupe(u8, result.call_id), .content = .{ .parts = parts } } };
        },
    };
}

test "candidate requests leave history intact and latest observations appear once" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var context = try Context.init(std.testing.allocator, .{ .session_id = 1, .epoch = 0 }, "core-1");
    defer context.deinit();
    try context.appendRecord(.{ .events = .{ .focus_id = "core-1", .items = &.{.{ .startup = .{ .observed_at_unix_ms = 0 } }} } });
    const current: Input.Current = .{ .focus_id = "core-1", .role = .core, .observed_at_unix_ms = 1000 };
    const before = try context.request(a, current, &.{});
    const events: []const Input.Event = &.{.{ .input = .{ .from = &.{"operator"}, .text = "Remember our plan.", .observed_at_unix_ms = 900 } }};

    const candidate = try context.request(a, current, events);
    try std.testing.expectEqual(@as(usize, 1), context.records().len);
    try std.testing.expectEqualDeep(before, try context.request(a, current, &.{}));
    try std.testing.expectEqual(before.len, candidate.len);
    try std.testing.expectEqualDeep(before[0 .. before.len - 1], candidate[0 .. candidate.len - 1]);
    try std.testing.expectEqual(1, std.mem.count(u8, candidate[candidate.len - 1].message.text, events[0].input.text));

    try context.appendRecord(.{ .events = .{ .focus_id = "core-1", .items = events } });
    const later = try context.request(a, current, &.{});
    try std.testing.expectEqual(1, std.mem.count(u8, later[later.len - 2].message.text, events[0].input.text));
    try std.testing.expectEqualDeep(before[before.len - 1], later[later.len - 1]);
    try std.testing.expectEqual(@as(usize, 2), context.records().len);
}

test "encoded native exchanges restore independently of their source buffers" {
    const restored = blk: {
        var source = try Context.init(std.testing.allocator, .{ .session_id = 2, .epoch = 0 }, "practice-2");
        defer source.deinit();
        var continuation = [_]u8{ 0, 255, '"', '\\', '\n' };
        var result_text = "observed".*;
        var image_bytes = [_]u8{ 137, 'P', 'N', 'G', 0, 255 };
        var file_bytes = [_]u8{ '%', 'P', 'D', 'F', 0, 255 };
        var file_reference = [_]u8{ 0, 255, '"', '\\', '\n' };
        try source.appendBatch(&.{.{ .continuation = &continuation }}, &.{.{ .tool_result = .{
            .call_id = "inspect-1",
            .content = .{ .parts = &.{
                .{ .text = &result_text },
                .{ .image = .{ .data = .{ .format = .png, .bytes = &image_bytes } } },
                .{ .file = .{ .bytes = &file_bytes, .reference = &file_reference } },
            } },
        } }});
        @memset(&continuation, 0);
        @memset(&result_text, 0);
        @memset(&image_bytes, 0);
        @memset(&file_bytes, 0);
        @memset(&file_reference, 0);

        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const codec = @import("record_codec.zig");
        const encoded = try codec.encode(arena.allocator(), source.records());
        const entries = try codec.decode([]const Entry, arena.allocator(), encoded);
        break :blk try Context.restore(std.testing.allocator, source.scope, source.focus_id, entries);
    };
    var context = restored;
    defer context.deinit();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const request = try context.request(arena.allocator(), .{ .focus_id = "practice-2", .role = .activity, .observed_at_unix_ms = 1000 }, &.{});
    try std.testing.expectEqual(@as(usize, 4), request.len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, '"', '\\', '\n' }, request[1].continuation);
    const reply = request[2].tool_result;
    try std.testing.expectEqualStrings("inspect-1", reply.call_id);
    try std.testing.expectEqualStrings("observed", reply.content.parts[0].text);
    try std.testing.expectEqual(.png, reply.content.parts[1].image.data.format);
    try std.testing.expectEqualSlices(u8, &.{ 137, 'P', 'N', 'G', 0, 255 }, reply.content.parts[1].image.data.bytes);
    const file = reply.content.parts[2].file;
    try std.testing.expectEqualSlices(u8, &.{ '%', 'P', 'D', 'F', 0, 255 }, file.bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, '"', '\\', '\n' }, file.reference.?);
}

test "candidate handover retains sampled references and leaves earlier history available" {
    var original = try Context.init(std.testing.allocator, .{ .session_id = 1, .epoch = 0 }, "core-1");
    defer original.deinit();
    try original.appendRecord(.{ .events = .{ .focus_id = "core-1", .items = &.{.{ .input = .{ .from = &.{"operator"}, .text = "Keep working on our plan.", .observed_at_unix_ms = 100 } }} } });
    var activity_id = "practice-2".*;
    var command_id = "inspect-7".*;
    const handover: Input.Handover = .{
        .focus_id = "core-1",
        .observed_at_unix_ms = 900,
        .summary = "A command is still awaiting observation.",
        .state = .{
            .activities = &.{&activity_id},
            .callbacks = &.{.{ .callback_id = "inspect-3", .source = .{ .host = .{ .command_id = &command_id } } }},
        },
    };
    var replacement = try original.withHandover(std.testing.allocator, handover);
    defer replacement.deinit();
    @memset(&activity_id, 0);
    @memset(&command_id, 0);

    try std.testing.expectEqual(@as(usize, 1), original.records().len);
    try std.testing.expectEqualStrings("Keep working on our plan.", original.records()[0].record.events.items[0].input.text);
    try std.testing.expectEqual(@as(usize, 1), replacement.records().len);
    const retained = replacement.records()[0].record.handover;
    try std.testing.expectEqual(handover.observed_at_unix_ms, retained.observed_at_unix_ms);
    try std.testing.expectEqualStrings(handover.summary, retained.summary);
    const expected_state: Input.State = .{
        .activities = &.{"practice-2"},
        .callbacks = &.{.{ .callback_id = "inspect-3", .source = .{ .host = .{ .command_id = "inspect-7" } } }},
    };
    try std.testing.expectEqualDeep(expected_state, retained.state);
}
