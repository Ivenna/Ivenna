const std = @import("std");
const Input = @import("input.zig");
const Entry = @import("history.zig").Entry;
const Scope = @import("history.zig").Scope;
const Model = @import("agent_contracts").Model;
const Content = @import("content").Content;
const Omissions = @import("omissions.zig").Omissions;
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

    /// One request plus the accounted omissions applied to it.
    pub const Fitted = struct { items: []const Model.Item, omissions: Omissions };
    pub const FitResult = union(enum) { fitted: Fitted, over_budget: Omissions };

    /// Assemble a work request, omitting retained content in priority order
    /// (tool output text, files, images, then oldest history items) until it
    /// fits `budget`. The current turn is never reduced. Every omission is
    /// counted and surfaced in one context note; nothing disappears silently.
    pub fn requestFitted(self: *const Context, a: Allocator, current: Input.Current, events: []const Input.Event, budget: u64, measure: anytype) !FitResult {
        return self.fitTurn(a, .{ .current = current, .purpose = .{ .work = events } }, budget, measure);
    }

    /// Same omission policy for a summary request; compaction reuses it so the
    /// reduction rules live in one place.
    pub fn summaryRequestFitted(self: *const Context, a: Allocator, snapshot: Input.Snapshot, instructions: []const u8, budget: u64, measure: anytype) !FitResult {
        return self.fitTurn(a, .{ .current = snapshot.current, .purpose = .{ .summarize = .{ .instructions = instructions, .state = snapshot.state } } }, budget, measure);
    }

    const Drop = enum { truncate_text, drop_files, drop_images, drop_entries };

    fn fitTurn(self: *const Context, a: Allocator, turn: Input.Turn, budget: u64, measure: anytype) !FitResult {
        const turn_text = try Input.renderTurn(a, turn);
        var prefix: std.ArrayList(Model.Item) = .empty;
        defer prefix.deinit(a);
        try prefix.appendSlice(a, self.messages.items);
        var omissions: Omissions = .{ .budget = budget };
        var phase: Drop = .truncate_text;
        var summary = false;
        var previous: u64 = 0;
        var pending: ?Omissions.Kind = null;
        var pending_count: u32 = 0;
        while (true) {
            const items = try assemble(a, prefix.items, turn_text, omissions, summary);
            const measured = try measure.measure(a, items);
            if (omissions.measured_before == 0) omissions.measured_before = measured;
            if (pending) |kind| {
                omissions.record(kind, if (previous > measured) previous - measured else 0, pending_count);
                pending = null;
                previous = measured;
                continue;
            }
            if (measured <= budget) {
                if (!summary and omissions.any()) {
                    summary = true;
                    continue;
                }
                omissions.measured_after = measured;
                return .{ .fitted = .{ .items = items, .omissions = omissions } };
            }
            previous = measured;
            if (try dropOne(a, &prefix, &phase, &pending_count)) |kind| {
                pending = kind;
                continue;
            }
            omissions.measured_after = measured;
            return .{ .over_budget = omissions };
        }
    }

    fn assemble(a: Allocator, prefix: []const Model.Item, turn_text: []const u8, omissions: Omissions, summary: bool) ![]const Model.Item {
        const text = if (summary) blk: {
            const note = (try omissions.render(a)) orelse break :blk turn_text;
            break :blk try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ note, turn_text });
        } else turn_text;
        const items = try a.alloc(Model.Item, prefix.len + 2);
        items[0] = .{ .message = .{ .role = .system, .text = @embedFile("system.md") } };
        @memcpy(items[1 .. prefix.len + 1], prefix);
        items[prefix.len + 1] = .{ .message = .{ .role = .user, .text = text } };
        return items;
    }

    /// Apply one omission step. Parts are copied into `a` before mutation so
    /// the retained history is never touched.
    fn dropOne(a: Allocator, prefix: *std.ArrayList(Model.Item), phase: *Drop, count: *u32) !?Omissions.Kind {
        while (true) {
            switch (phase.*) {
                .truncate_text => {
                    if (try truncateLargestText(a, prefix.items)) {
                        count.* = 1;
                        return .truncated_text;
                    }
                    phase.* = .drop_files;
                },
                .drop_files => {
                    if (try replaceFirstPart(a, prefix.items, .file)) {
                        count.* = 1;
                        return .files;
                    }
                    phase.* = .drop_images;
                },
                .drop_images => {
                    if (try replaceFirstPart(a, prefix.items, .image)) {
                        count.* = 1;
                        return .images;
                    }
                    phase.* = .drop_entries;
                },
                .drop_entries => {
                    if (prefix.items.len == 0) return null;
                    _ = prefix.orderedRemove(0);
                    count.* = 1;
                    return .entries;
                },
            }
        }
    }

    fn truncateLargestText(a: Allocator, items: []Model.Item) !bool {
        var best_item: ?usize = null;
        var best_part: usize = 0;
        // A truncated part ends up far below this, so it is never re-selected.
        var best_len: usize = 2048;
        for (items, 0..) |item, i| {
            if (item != .tool_result) continue;
            for (item.tool_result.content.parts, 0..) |part, p| {
                if (part != .text) continue;
                if (part.text.len > best_len) {
                    best_len = part.text.len;
                    best_item = i;
                    best_part = p;
                }
            }
        }
        const i = best_item orelse return false;
        const copied = try a.dupe(Content.Part, items[i].tool_result.content.parts);
        items[i].tool_result.content.parts = copied;
        const text = copied[best_part].text;
        // Keep a quarter from each end: the result must be clearly smaller than
        // the selection threshold or the same part would be chosen forever.
        const keep = @max(512, text.len / 4);
        var head_len = keep / 2;
        while (head_len > 0 and (text[head_len] & 0xC0) == 0x80) head_len -= 1;
        var tail_start = text.len - (keep - head_len);
        while (tail_start < text.len and (text[tail_start] & 0xC0) == 0x80) tail_start += 1;
        const omitted = text.len - head_len - (text.len - tail_start);
        copied[best_part] = .{ .text = try std.fmt.allocPrint(a, "{s}…[truncated {d} bytes]…{s}", .{ text[0..head_len], omitted, text[tail_start..] }) };
        return true;
    }

    const PartKind = enum { file, image };

    fn replaceFirstPart(a: Allocator, items: []Model.Item, kind: PartKind) !bool {
        for (items, 0..) |item, i| {
            if (item != .tool_result) continue;
            const copied = try a.dupe(Content.Part, item.tool_result.content.parts);
            items[i].tool_result.content.parts = copied;
            for (copied, 0..) |part, p| {
                switch (kind) {
                    .file => {
                        if (part != .file) continue;
                        const reference = if (part.file.reference) |r| r else "none";
                        copied[p] = .{ .text = try std.fmt.allocPrint(a, "[file omitted: {d} bytes, reference {s}]", .{ part.file.bytes.len, reference }) };
                        return true;
                    },
                    .image => {
                        if (part != .image) continue;
                        copied[p] = .{ .text = switch (part.image) {
                            .url => |url| try std.fmt.allocPrint(a, "[image omitted: {s}]", .{url}),
                            .data => |data| try std.fmt.allocPrint(a, "[image omitted: {d} bytes, format {s}]", .{ data.bytes.len, @tagName(data.format) }),
                        } };
                        return true;
                    },
                }
            }
        }
        return false;
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
    var subscription_id = "releases-4".*;
    const handover: Input.Handover = .{
        .focus_id = "core-1",
        .observed_at_unix_ms = 900,
        .summary = "A command is still awaiting observation.",
        .state = .{
            .activities = &.{&activity_id},
            .callbacks = &.{.{ .callback_id = "inspect-3", .source = .{ .host = .{ .command_id = &command_id } } }},
            .subscriptions = &.{&subscription_id},
        },
    };
    var replacement = try original.withHandover(std.testing.allocator, handover);
    defer replacement.deinit();
    @memset(&activity_id, 0);
    @memset(&command_id, 0);
    @memset(&subscription_id, 0);

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
    };
    try std.testing.expectEqualDeep(expected_state, retained.state);
}

const TestMeasure = struct {
    fn measure(_: *const TestMeasure, _: Allocator, items: []const Model.Item) !u64 {
        var total: u64 = 0;
        for (items) |item| switch (item) {
            .message => |message| total += message.text.len,
            .continuation => |bytes| total += bytes.len,
            .tool_result => |result| for (result.content.parts) |part| {
                total += switch (part) {
                    .text => |text| text.len,
                    .image => |image| switch (image) {
                        .url => |url| 1 + url.len,
                        .data => |data| 1 + data.bytes.len,
                    },
                    .file => |file| 1 + file.bytes.len,
                };
            },
        };
        return total;
    }
};

const KindCounts = struct { images: usize = 0, files: usize = 0 };

fn partKindCounts(items: []const Model.Item) KindCounts {
    var counts: KindCounts = .{};
    for (items) |item| {
        if (item != .tool_result) continue;
        for (item.tool_result.content.parts) |part| switch (part) {
            .image => counts.images += 1,
            .file => counts.files += 1,
            else => {},
        };
    }
    return counts;
}

test "fitTurn omits retained content by priority and never touches the current turn" {
    const testing = std.testing;
    var context = try Context.init(testing.allocator, .{ .session_id = 3, .epoch = 0 }, "core-1");
    defer context.deinit();
    const big_text = try testing.allocator.alloc(u8, 4000);
    defer testing.allocator.free(big_text);
    @memset(big_text, 'a');
    const image_bytes = try testing.allocator.alloc(u8, 2000);
    defer testing.allocator.free(image_bytes);
    @memset(image_bytes, 7);
    const file_bytes = try testing.allocator.alloc(u8, 1000);
    defer testing.allocator.free(file_bytes);
    @memset(file_bytes, 9);
    try context.appendBatch(&.{.{ .message = .{ .role = .user, .text = "ask" } }}, &.{.{ .tool_result = .{
        .call_id = "call-1",
        .content = .{ .parts = &.{
            .{ .text = big_text },
            .{ .image = .{ .data = .{ .format = .png, .bytes = image_bytes } } },
            .{ .file = .{ .bytes = file_bytes, .reference = "ref-1" } },
        } },
    } }});

    const current: Input.Current = .{ .focus_id = "core-1", .role = .core, .observed_at_unix_ms = 5 };
    const events: []const Input.Event = &.{.{ .input = .{ .from = &.{"operator"}, .text = "keep this", .observed_at_unix_ms = 4 } }};
    const records_before = context.records().len;
    var req_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer req_arena.deinit();

    // Budget below the current size: policy must drop retained media instead
    // of handing back an oversized request. The deficit here is small enough
    // that truncating the text part alone covers it, so the earlier media must
    // survive: priority order means "do not over-drop", not just "drop".
    const full = try context.request(req_arena.allocator(), current, events);
    const full_bytes = try TestMeasure.measure(&.{}, req_arena.allocator(), full);
    const budget = full_bytes - 2500;

    const result = try context.requestFitted(req_arena.allocator(), current, events, budget, &TestMeasure{});
    const fitted = switch (result) {
        .fitted => |value| value,
        .over_budget => return error.TestUnexpectedResult,
    };
    try testing.expect(fitted.omissions.any());
    try testing.expect(fitted.omissions.measured_after <= budget);
    const counts = partKindCounts(fitted.items);
    try testing.expect(fitted.omissions.truncated_text_bytes > 0);
    try testing.expect(counts.images <= 1);
    try testing.expectEqual(records_before, context.records().len);
    const kept = partKindCounts(context.messages.items);
    try testing.expectEqual(@as(usize, 1), kept.images);
    try testing.expectEqual(@as(usize, 1), kept.files);
}

test "fitTurn escalates from text to file to image when the deficit is large" {
    const testing = std.testing;
    var context = try Context.init(testing.allocator, .{ .session_id = 5, .epoch = 0 }, "core-1");
    defer context.deinit();
    const big_text = try testing.allocator.alloc(u8, 4000);
    defer testing.allocator.free(big_text);
    @memset(big_text, 'a');
    const image_bytes = try testing.allocator.alloc(u8, 2000);
    defer testing.allocator.free(image_bytes);
    @memset(image_bytes, 7);
    const file_bytes = try testing.allocator.alloc(u8, 1000);
    defer testing.allocator.free(file_bytes);
    @memset(file_bytes, 9);
    try context.appendBatch(&.{.{ .message = .{ .role = .user, .text = "ask" } }}, &.{.{ .tool_result = .{
        .call_id = "call-1",
        .content = .{ .parts = &.{
            .{ .text = big_text },
            .{ .image = .{ .data = .{ .format = .png, .bytes = image_bytes } } },
            .{ .file = .{ .bytes = file_bytes, .reference = "ref-1" } },
        } },
    } }});

    const current: Input.Current = .{ .focus_id = "core-1", .role = .core, .observed_at_unix_ms = 5 };
    const events: []const Input.Event = &.{.{ .input = .{ .from = &.{"operator"}, .text = "keep this", .observed_at_unix_ms = 4 } }};
    var req_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer req_arena.deinit();

    // A deficit beyond what text truncation and file removal can save forces
    // the image out as well, in that order.
    const full = try context.request(req_arena.allocator(), current, events);
    const full_bytes = try TestMeasure.measure(&.{}, req_arena.allocator(), full);
    const budget = full_bytes - 4500;

    const result = try context.requestFitted(req_arena.allocator(), current, events, budget, &TestMeasure{});
    const fitted = switch (result) {
        .fitted => |value| value,
        .over_budget => return error.TestUnexpectedResult,
    };
    try testing.expect(fitted.omissions.truncated_text_bytes > 0);
    try testing.expectEqual(@as(u32, 1), fitted.omissions.dropped_files);
    try testing.expectEqual(@as(u32, 1), fitted.omissions.dropped_images);
    try testing.expect(fitted.omissions.measured_after <= budget);
    const counts = partKindCounts(fitted.items);
    try testing.expectEqual(@as(usize, 0), counts.images);
    try testing.expectEqual(@as(usize, 0), counts.files);
    // The retained history is untouched: only the request view changes.
    const kept = partKindCounts(context.messages.items);
    try testing.expectEqual(@as(usize, 1), kept.images);
    try testing.expectEqual(@as(usize, 1), kept.files);
}

test "fitTurn reports over_budget with measured bytes when nothing may be dropped" {
    const testing = std.testing;
    var context = try Context.init(testing.allocator, .{ .session_id = 4, .epoch = 0 }, "core-1");
    defer context.deinit();
    const huge = try testing.allocator.alloc(u8, 2000);
    defer testing.allocator.free(huge);
    @memset(huge, 'x');
    const current: Input.Current = .{ .focus_id = "core-1", .role = .core, .observed_at_unix_ms = 5 };
    const events: []const Input.Event = &.{.{ .input = .{ .from = &.{"operator"}, .text = huge, .observed_at_unix_ms = 4 } }};
    var req_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer req_arena.deinit();
    const result = try context.requestFitted(req_arena.allocator(), current, events, 100, &TestMeasure{});
    switch (result) {
        .fitted => return error.TestUnexpectedResult,
        .over_budget => |omissions| {
            try testing.expectEqual(@as(u64, 100), omissions.budget);
            try testing.expect(omissions.measured_after > 100);
        },
    }
}
