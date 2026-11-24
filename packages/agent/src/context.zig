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

    pub const CompactionScope = enum { keep_latest_tool_round, keep_recent_rounds, all_history };
    const recent_completed_rounds = 2;

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
        return buildRequest(a, self.messages.items, .{ .current = current, .purpose = .{ .work = events } });
    }

    /// The ordinary turn with only the history eligible for summarization.
    pub fn retainedRequest(self: *const Context, a: Allocator, current: Input.Current, events: []const Input.Event) ![]const Model.Item {
        return buildRequest(a, self.summaryItems(.keep_latest_tool_round), .{ .current = current, .purpose = .{ .work = events } });
    }

    /// Assemble a request with the pending tool round and observations admitted after it.
    pub fn latestRequest(self: *const Context, a: Allocator, current: Input.Current) ![]const Model.Item {
        const pending = self.compactionBoundary(.keep_latest_tool_round);
        return buildRequest(a, self.messages.items[pending.message_index..], .{ .current = current, .purpose = .{ .work = &.{} } });
    }

    /// Completed exchanges and observations before the pending continuation
    /// that can be retained in addition to it.
    pub fn additionalRecentItems(self: *const Context) []const Model.Item {
        const pending = self.compactionBoundary(.keep_latest_tool_round);
        const recent = self.recentRounds(pending);
        return self.messages.items[recent.message_index..pending.message_index];
    }

    pub fn hasToolRoundToKeep(self: *const Context) bool {
        return self.latestToolRound() != null;
    }

    pub fn hasHistoryForCompaction(self: *const Context, compaction_scope: CompactionScope) bool {
        return self.summaryEntryCount(compaction_scope) != 0;
    }

    pub fn canCompact(self: *const Context, compaction_scope: CompactionScope) bool {
        return switch (self.summaryEntryCount(compaction_scope)) {
            0 => false,
            1 => switch (self.entries.items[0]) {
                .record => |record| record != .handover,
                .exchange => true,
            },
            else => true,
        };
    }

    const HistoryBoundary = struct { entry_index: usize, message_index: usize };

    /// An observation can be checkpointed before the next inference receives
    /// it. Preserve that observation with a tool round still awaiting inference.
    fn latestToolRound(self: *const Context) ?HistoryBoundary {
        var entry_index = self.entries.items.len;
        var message_index = self.messages.items.len;
        while (entry_index != 0) {
            entry_index -= 1;
            switch (self.entries.items[entry_index]) {
                .record => |record| {
                    if (record != .events) return null;
                    message_index -= 1;
                },
                .exchange => |exchange| {
                    for (exchange) |item| {
                        if (item == .tool_result) return .{ .entry_index = entry_index, .message_index = message_index - exchange.len };
                    }
                    return null;
                },
            }
        }
        return null;
    }

    fn compactionBoundary(self: *const Context, compaction_scope: CompactionScope) HistoryBoundary {
        const end: HistoryBoundary = .{ .entry_index = self.entries.items.len, .message_index = self.messages.items.len };
        return switch (compaction_scope) {
            .keep_latest_tool_round => self.latestToolRound() orelse end,
            .keep_recent_rounds => self.recentRounds(self.latestToolRound() orelse end),
            .all_history => end,
        };
    }

    /// Extend the protected suffix over recent exchanges and their preceding
    /// observations, up to the most recent handover.
    fn recentRounds(self: *const Context, start: HistoryBoundary) HistoryBoundary {
        var retained = start;
        var cursor = start;
        var completed: usize = 0;
        while (cursor.entry_index != 0) {
            cursor.entry_index -= 1;
            switch (self.entries.items[cursor.entry_index]) {
                .record => |record| {
                    if (record != .events) break;
                    cursor.message_index -= 1;
                },
                .exchange => |exchange| {
                    if (completed == recent_completed_rounds) break;
                    completed += 1;
                    cursor.message_index -= exchange.len;
                },
            }
            if (completed != 0) retained = cursor;
        }
        return retained;
    }

    fn summaryEntryCount(self: *const Context, compaction_scope: CompactionScope) usize {
        return self.compactionBoundary(compaction_scope).entry_index;
    }

    fn summaryItems(self: *const Context, compaction_scope: CompactionScope) []const Model.Item {
        const boundary = self.compactionBoundary(compaction_scope);
        return self.messages.items[0..boundary.message_index];
    }

    /// Assemble the summary request from selected history and sampled state.
    pub fn summaryRequest(self: *const Context, a: Allocator, snapshot: Input.Snapshot, instructions: []const u8, compaction_scope: CompactionScope) ![]Model.Item {
        return buildRequest(a, self.summaryItems(compaction_scope), .{
            .current = snapshot.current,
            .purpose = .{ .summarize = .{ .instructions = instructions, .state = snapshot.state } },
        });
    }

    /// Replace media in the summary request while keeping the source descriptions.
    /// Return true when a request item changed. The retained history stays intact.
    pub fn replaceSummaryMedia(a: Allocator, messages: []Model.Item) !bool {
        var replaced = false;
        for (messages) |*item| {
            if (item.* != .tool_result) continue;
            var copy: ?[]Content.Part = null;
            for (item.tool_result.content.parts, 0..) |part, index| {
                const note = switch (part) {
                    .text => continue,
                    .image => "[Image omitted from this summary input.]",
                    .file => "[File omitted from this summary input.]",
                };
                if (copy == null) copy = try a.dupe(Content.Part, item.tool_result.content.parts);
                copy.?[index] = .{ .text = note };
            }
            if (copy) |parts| {
                item.tool_result.content.parts = parts;
                replaced = true;
            }
        }
        return replaced;
    }

    fn buildRequest(a: Allocator, history: []const Model.Item, turn: Input.Turn) ![]Model.Item {
        const prefix_len = history.len;
        const messages = try a.alloc(Model.Item, prefix_len + 2);
        messages[0] = .{ .message = .{ .role = .system, .text = @embedFile("system.md") } };
        @memcpy(messages[1 .. prefix_len + 1], history);
        messages[prefix_len + 1] = .{ .message = .{ .role = .user, .text = try Input.renderTurn(a, turn) } };
        return messages;
    }

    pub fn withHandover(self: *const Context, allocator: Allocator, handover: Input.Handover, compaction_scope: CompactionScope) !Context {
        const scope: Scope = .{ .session_id = self.scope.session_id, .epoch = try std.math.add(u64, self.scope.epoch, 1) };
        var replacement = try restore(allocator, scope, self.focus_id, &.{.{ .record = .{ .handover = handover } }});
        errdefer replacement.deinit();
        const count = self.summaryEntryCount(compaction_scope);
        for (self.entries.items[count..]) |entry| try replacement.append(entry);
        return replacement;
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
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var original = try Context.init(std.testing.allocator, .{ .session_id = 1, .epoch = 0 }, "core-1");
    defer original.deinit();
    try original.appendRecord(.{ .events = .{ .focus_id = "core-1", .items = &.{.{ .input = .{ .from = &.{"operator"}, .text = "Keep working on our plan.", .observed_at_unix_ms = 100 } }} } });
    var activity_id = "practice-2".*;
    var command_id = "inspect-7".*;
    var subscription_id = "releases-4".*;
    var feed_id = "public-3".*;
    var correspondent_id = "reviewer+notes".*;
    const handover: Input.Handover = .{
        .focus_id = "core-1",
        .observed_at_unix_ms = 900,
        .summary = "A command is still awaiting observation.",
        .state = .{
            .activities = &.{&activity_id},
            .callbacks = &.{.{ .callback_id = "inspect-3", .source = .{ .host = .{ .command_id = &command_id } } }},
            .subscriptions = &.{&subscription_id},
            .feeds = &.{&feed_id},
            .correspondents = &.{&correspondent_id},
        },
    };
    const current: Input.Current = .{ .focus_id = handover.focus_id, .role = .core, .observed_at_unix_ms = 900 };
    const summary = try original.summaryRequest(a, .{ .current = current, .state = handover.state }, "Summarize.", .keep_latest_tool_round);
    var replacement = try original.withHandover(std.testing.allocator, handover, .keep_latest_tool_round);
    defer replacement.deinit();
    @memset(&activity_id, 0);
    @memset(&command_id, 0);
    @memset(&subscription_id, 0);
    @memset(&feed_id, 0);
    @memset(&correspondent_id, 0);

    try std.testing.expectEqual(@as(usize, 1), original.records().len);
    try std.testing.expectEqualStrings("Keep working on our plan.", original.records()[0].record.events.items[0].input.text);
    try std.testing.expectEqual(@as(usize, 1), replacement.records().len);
    const retained = replacement.records()[0].record.handover;
    try std.testing.expectEqual(handover.observed_at_unix_ms, retained.observed_at_unix_ms);
    try std.testing.expectEqualStrings(handover.summary, retained.summary);
    const expected_state: Input.State = .{
        .activities = &.{"practice-2"},
        .callbacks = &.{.{ .callback_id = "inspect-3", .source = .{ .host = .{ .command_id = "inspect-7" } } }},
        .subscriptions = &.{"releases-4"},
        .feeds = &.{"public-3"},
        .correspondents = &.{"reviewer+notes"},
    };
    try std.testing.expectEqualDeep(expected_state, retained.state);
    const next = try replacement.request(a, current, &.{});
    for ([_][]const u8{ summary[summary.len - 1].message.text, next[1].message.text }) |rendered| {
        try std.testing.expect(std.mem.indexOf(u8, rendered, "public-3") != null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "reviewer+notes") != null);
    }
}

test "compaction summarizes older entries and carries forward the complete latest tool round" {
    const testing = std.testing;
    var scratch: std.heap.ArenaAllocator = .init(testing.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var original = try Context.init(testing.allocator, .{ .session_id = 1, .epoch = 0 }, "core-1");
    defer original.deinit();
    const current: Input.Current = .{ .focus_id = "core-1", .role = .core, .observed_at_unix_ms = 1000 };
    const state: Input.State = .{ .activities = &.{}, .callbacks = &.{}, .subscriptions = &.{} };
    const image_url = "https://example.test/old.png";
    const earlier: []const Model.Item = &.{
        .{ .continuation = "older call" },
        .{ .tool_result = .{ .call_id = "older", .content = .{ .parts = &.{
            .{ .text = "file:///old-image-url.txt" },
            .{ .image = .{ .url = image_url } },
            .{ .file = .{ .bytes = "PDF bytes" } },
        } } } },
    };
    const latest: []const Model.Item = &.{
        .{ .continuation = "latest call" },
        .{ .tool_result = .{ .call_id = "latest", .content = .{ .parts = &.{
            .{ .image = .{ .data = .{ .format = .png, .bytes = "PNG bytes" } } },
        } } } },
    };
    try original.appendBatch(earlier[0..1], earlier[1..]);
    try original.appendBatch(latest[0..1], latest[1..]);

    const snapshot: Input.Snapshot = .{ .current = current, .state = state };
    const summary = try original.summaryRequest(a, snapshot, "Summarize.", .keep_latest_tool_round);
    try testing.expectEqualDeep(earlier, summary[1 .. summary.len - 1]);
    try testing.expect(try Context.replaceSummaryMedia(a, summary));
    try testing.expectEqualDeep(earlier[0], summary[1]);
    const projected_reply = summary[2].tool_result;
    try testing.expectEqualStrings(earlier[1].tool_result.call_id, projected_reply.call_id);
    const parts = projected_reply.content.parts;
    try testing.expectEqualDeep(earlier[1].tool_result.content.parts[0], parts[0]);
    try testing.expect(parts[1] == .text and std.mem.indexOf(u8, parts[1].text, image_url) == null);
    try testing.expect(parts[2] == .text);
    try testing.expectEqualDeep(earlier, original.records()[0].exchange);

    const handover: Input.Handover = .{
        .focus_id = current.focus_id,
        .observed_at_unix_ms = current.observed_at_unix_ms,
        .summary = "Earlier work.",
        .state = state,
    };
    var replacement = try original.withHandover(testing.allocator, handover, .keep_latest_tool_round);
    defer replacement.deinit();
    const next = try replacement.request(a, current, &.{});
    try testing.expectEqualDeep(latest, next[2 .. next.len - 1]);
}

test "compaction retains checkpointed observations following a tool round that still needs inference" {
    const testing = std.testing;
    const current: Input.Current = .{ .focus_id = "core-1", .role = .core, .observed_at_unix_ms = 1000 };
    const scope: Scope = .{ .session_id = 1, .epoch = 0 };
    const earlier: Input.Event = .{ .input = .{ .from = &.{"operator"}, .text = "Earlier report.", .observed_at_unix_ms = 10 } };
    const arrival: Input.Event = .{ .input = .{ .from = &.{"operator"}, .text = "Recent report.", .observed_at_unix_ms = 20 } };
    const subsequent: Input.Event = .{ .input = .{ .from = &.{"operator"}, .text = "Another recent report.", .observed_at_unix_ms = 30 } };
    const entries: []const Entry = &.{
        .{ .record = .{ .events = .{ .focus_id = current.focus_id, .items = &.{earlier} } } },
        .{ .exchange = &.{
            .{ .continuation = "Tool call" },
            .{ .tool_result = .{ .call_id = "read", .content = .{ .parts = &.{.{ .text = "Tool result" }} } } },
        } },
        .{ .record = .{ .events = .{ .focus_id = current.focus_id, .items = &.{arrival} } } },
        .{ .record = .{ .events = .{ .focus_id = current.focus_id, .items = &.{subsequent} } } },
    };
    var restored = try Context.restore(testing.allocator, scope, current.focus_id, entries);
    defer restored.deinit();
    const state: Input.State = .{ .activities = &.{}, .callbacks = &.{}, .subscriptions = &.{} };
    const handover: Input.Handover = .{ .focus_id = current.focus_id, .observed_at_unix_ms = current.observed_at_unix_ms, .summary = "Previous work.", .state = state };

    var replacement = try restored.withHandover(testing.allocator, handover, .keep_latest_tool_round);
    defer replacement.deinit();
    try testing.expectEqualDeep(entries[1..], replacement.records()[1..]);
    try restored.appendBatch(&.{.{ .continuation = "Assistant response" }}, &.{});
    var after_response = try restored.withHandover(testing.allocator, handover, .keep_latest_tool_round);
    defer after_response.deinit();
    try testing.expect(after_response.records()[1..].len == 0);
}

test "recent retention carries complete exchanges and their observations across a handover" {
    const testing = std.testing;
    const current: Input.Current = .{ .focus_id = "core-1", .role = .core, .observed_at_unix_ms = 1000 };
    const scope: Scope = .{ .session_id = 1, .epoch = 0 };
    const state: Input.State = .{ .activities = &.{}, .callbacks = &.{}, .subscriptions = &.{} };
    const handover: Input.Handover = .{ .focus_id = current.focus_id, .observed_at_unix_ms = 900, .summary = "Earlier work.", .state = state };
    const evidence: Input.Event = .{ .input = .{ .from = &.{"operator"}, .text = "Keep this evidence.", .observed_at_unix_ms = 910 } };
    const arrival: Input.Event = .{ .input = .{ .from = &.{"operator"}, .text = "New observation.", .observed_at_unix_ms = 950 } };
    const entries: []const Entry = &.{
        .{ .record = .{ .handover = handover } },
        .{ .exchange = &.{.{ .continuation = "Older exchange" }} },
        .{ .record = .{ .events = .{ .focus_id = current.focus_id, .items = &.{evidence} } } },
        .{ .exchange = &.{
            .{ .continuation = "Completed tool call" },
            .{ .tool_result = .{ .call_id = "earlier", .content = .{ .parts = &.{.{ .text = "Completed result" }} } } },
        } },
        .{ .exchange = &.{.{ .continuation = "Later completed exchange" }} },
        .{ .exchange = &.{
            .{ .continuation = "Pending tool call" },
            .{ .tool_result = .{ .call_id = "latest", .content = .{ .parts = &.{.{ .text = "Pending result" }} } } },
        } },
        .{ .record = .{ .events = .{ .focus_id = current.focus_id, .items = &.{arrival} } } },
    };
    var original = try Context.restore(testing.allocator, scope, current.focus_id, entries);
    defer original.deinit();

    var replacement = try original.withHandover(testing.allocator, handover, .keep_recent_rounds);
    defer replacement.deinit();
    try testing.expectEqualDeep(entries[2..], replacement.records()[1..]);
}
