const std = @import("std");
const contracts = @import("agent_contracts");
const Mailbox = @import("mail.zig").Mailbox;
const Checkpoint = @import("mail.zig").Checkpoint;
const Allocator = std.mem.Allocator;
const Store = contracts.HistoryStore;

/// Store grouped immutable records and publish the retained-session checkpoint.
/// The agent owns record encodings and identity; native locators stay in memory.
pub const History = struct {
    allocator: Allocator,
    mailbox: *Mailbox,
    /// Highest revision in the prepared format observed or confirmed by this run.
    last_revision: ?u64 = null,
    confirmed_id: ?[]const u8 = null,

    pub fn init(allocator: Allocator, mailbox: *Mailbox) History {
        return .{ .allocator = allocator, .mailbox = mailbox };
    }

    pub fn deinit(self: *History) void {
        if (self.confirmed_id) |id| self.allocator.free(id);
        self.* = undefined;
    }

    pub fn port(self: *History) contracts.HistoryStore {
        return .{ .context = self, .vtable = &.{ .load = load, .allocateGroup = allocateGroup, .query = query, .read = read, .create = create, .save = save, .maintain = maintain } };
    }

    fn load(context: *anyopaque, a: Allocator) !?[]const u8 {
        const self: *History = @ptrCast(@alignCast(context));
        const candidates = try self.mailbox.historyCheckpoints(a);
        var last_revision: u64 = 0;
        var latest: ?Checkpoint = null;
        for (candidates) |candidate| {
            if (candidate.state != .legacy) last_revision = @max(last_revision, candidate.revision);
            if (candidate.state == .prepared) continue;
            if (latest == null or newer(candidate, latest.?)) latest = candidate;
        }
        const document: ?[]const u8 = if (latest) |head| blk: {
            for (candidates) |candidate| {
                if (candidate.state == head.state and candidate.revision == head.revision and
                    !std.mem.eql(u8, candidate.id, head.id)) return error.AmbiguousHistoryRevision;
            }
            break :blk try self.mailbox.historyCheckpoint(a, head.id);
        } else null;
        // Only this run's freshly published message can authorize maintenance.
        if (self.confirmed_id) |id| self.allocator.free(id);
        self.confirmed_id = null;
        self.last_revision = last_revision;
        return document;
    }

    fn newer(candidate: Checkpoint, previous: Checkpoint) bool {
        if (candidate.state != previous.state) return candidate.state == .published;
        return candidate.revision > previous.revision;
    }

    fn allocateGroup(context: *anyopaque, a: Allocator) ![]const u8 {
        const self: *History = @ptrCast(@alignCast(context));
        return self.mailbox.allocateHistoryGroup(a);
    }

    fn query(context: *anyopaque, a: Allocator, groups: []const []const u8) ![]const contracts.HistoryStore.Reference {
        const self: *History = @ptrCast(@alignCast(context));
        return self.mailbox.queryHistory(a, groups);
    }

    fn read(context: *anyopaque, a: Allocator, references: []const contracts.HistoryStore.Reference) ![]const []const u8 {
        const self: *History = @ptrCast(@alignCast(context));
        return self.mailbox.readHistory(a, references);
    }

    fn create(context: *anyopaque, a: Allocator, records: []const contracts.HistoryStore.Record) !void {
        const self: *History = @ptrCast(@alignCast(context));
        return self.mailbox.createHistoryRecords(a, records);
    }

    fn maintain(context: *anyopaque, a: Allocator, retention: contracts.HistoryStore.Retention) !void {
        const self: *History = @ptrCast(@alignCast(context));
        return self.mailbox.maintainHistory(a, retention, self.confirmed_id orelse return error.HistoryNotPublished);
    }

    fn save(context: *anyopaque, checkpoint: []const u8) !void {
        const self: *History = @ptrCast(@alignCast(context));
        const prior = self.last_revision orelse return error.HistoryNotLoaded;
        const revision = std.math.add(u64, prior, 1) catch return error.HistoryRevisionExhausted;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const id = try self.mailbox.prepareCheckpoint(a, checkpoint, revision);
        const owned_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned_id);
        try self.mailbox.publishCheckpoint(a, id);
        if (self.confirmed_id) |previous| self.allocator.free(previous);
        self.confirmed_id = owned_id;
        self.last_revision = revision;
    }
};

test "unconfirmed publication checks the keyword on the prepared email" {
    const Fixture = @import("test_jmap.zig").Fixture;
    const fields = ",\"mailboxIds\":{\"history\":true},\"from\":[{\"email\":\"ivenna@example.com\"}],\"to\":[{\"email\":\"ivenna@example.com\"}]," ++
        "\"header:X-Ivenna-History-Kind:asText\":\"checkpoint\",\"header:X-Ivenna-History-Revision:asText\":\"1\"}]}";
    const prepared = "{\"list\":[{\"id\":\"saved\",\"keywords\":{\"ivenna-state\":true,\"ivenna-prepared\":true}" ++ fields;
    const published = "{\"list\":[{\"id\":\"saved\",\"keywords\":{\"ivenna-state\":true,\"ivenna-prepared\":true,\"ivenna-current\":true}" ++ fields;
    for ([_]bool{ false, true }) |marked| {
        var fixture = try Fixture.init(&.{
            .{ .method = "Email/query", .result = "{\"ids\":[]}" },
            .{ .method = "Email/set", .result = "{\"created\":{\"checkpoint\":{\"id\":\"saved\"}}}" },
            .{ .method = "Email/set", .result = "{}", .properties = &.{.{ .path = &.{ "update", "saved" }, .json = "{\"keywords/ivenna-current\":true}" }} },
            .{ .method = "Email/get", .result = if (marked) published else prepared, .properties = &.{
                .{ .path = &.{"ids"}, .json = "[\"saved\"]" },
                .{ .path = &.{"fetchTextBodyValues"}, .json = "false" },
            } },
        });
        defer fixture.deinit();
        var mailbox = try fixture.start();
        var history = History.init(std.testing.allocator, &mailbox);
        defer history.deinit();
        const port = history.port();
        _ = try port.load(fixture.arena.allocator());
        const saved = port.save("selected");
        if (marked) try saved else try std.testing.expectError(error.MailMutationUnconfirmed, saved);
        try fixture.finish();
    }
}

test "restart advances past prepared revisions across pages and prefers published checkpoints" {
    const Fixture = @import("test_jmap.zig").Fixture;
    const fields = ",\"mailboxIds\":{\"history\":true},\"from\":[{\"email\":\"ivenna@example.com\"}],\"to\":[{\"email\":\"ivenna@example.com\"}]," ++
        "\"header:X-Ivenna-History-Kind:asText\":\"checkpoint\",\"header:X-Ivenna-History-Revision:asText\":";
    const saved = "{\"id\":\"saved\",\"keywords\":{\"ivenna-state\":true,\"ivenna-prepared\":true,\"ivenna-current\":true}" ++ fields ++ "\"3\"";
    const prepared = "{\"id\":\"pending\",\"keywords\":{\"ivenna-state\":true,\"ivenna-prepared\":true}" ++ fields ++ "\"4\"}";
    const legacy = "{\"id\":\"old\",\"keywords\":{\"ivenna-state\":true,\"ivenna-current\":true}" ++ fields ++ "\"18446744073709551615\"}";
    var fixture = try Fixture.init(&.{
        .{ .method = "Email/query", .result = "{\"ids\":[\"old\",\"saved\"]}" },
        .{ .method = "Email/get", .result = "{\"list\":[" ++ legacy ++ "," ++ saved ++ "}]}" },
        // A retired ID before the anchor does not shift the start of this page.
        .{ .method = "Email/query", .result = "{\"ids\":[\"pending\"]}", .properties = &.{
            .{ .path = &.{"anchor"}, .json = "\"saved\"" },
            .{ .path = &.{"anchorOffset"}, .json = "1" },
        } },
        .{ .method = "Email/get", .result = "{\"list\":[" ++ prepared ++ "]}" },
        .{ .method = "Email/query", .result = "{\"ids\":[]}", .properties = &.{.{ .path = &.{"anchor"}, .json = "\"pending\"" }} },
        .{ .method = "Email/get", .result = "{\"list\":[" ++ saved ++ ",\"textBody\":[{\"partId\":\"text\",\"type\":\"text/plain\"}],\"bodyValues\":{\"text\":{\"value\":\"selected\"}}}]}", .properties = &.{
            .{ .path = &.{"ids"}, .json = "[\"saved\"]" },
        } },
        .{ .method = "Email/set", .result = "{\"created\":{\"checkpoint\":{\"id\":\"new\"}}}", .properties = &.{
            .{ .path = &.{ "create", "checkpoint", "header:X-Ivenna-History-Revision:asText" }, .json = "\"5\"" },
            .{ .path = &.{ "create", "checkpoint", "keywords" }, .json = "{\"$seen\":true,\"ivenna-state\":true,\"ivenna-prepared\":true}" },
        } },
        .{ .method = "Email/set", .result = "{\"updated\":{\"new\":null}}", .properties = &.{.{
            .path = &.{ "update", "new" },
            .json = "{\"keywords/ivenna-current\":true}",
        }} },
    });
    defer fixture.deinit();
    var mailbox = try fixture.start();
    var history = History.init(std.testing.allocator, &mailbox);
    defer history.deinit();
    const port = history.port();
    const a = fixture.arena.allocator();
    try std.testing.expectEqualStrings("selected", (try port.load(a)).?);
    try std.testing.expectError(error.HistoryNotPublished, port.maintain(a, .{ .records = &.{} }));
    try port.save("new");
    try fixture.finish();
}

test "an unconfirmed preparation sends no publication" {
    const Fixture = @import("test_jmap.zig").Fixture;
    var fixture = try Fixture.init(&.{
        .{ .method = "Email/query", .result = "{\"ids\":[]}" },
        .{ .method = "Email/set", .result = null },
    });
    defer fixture.deinit();
    var mailbox = try fixture.start();
    var history = History.init(std.testing.allocator, &mailbox);
    defer history.deinit();
    const port = history.port();
    _ = try port.load(fixture.arena.allocator());
    try std.testing.expectError(error.MailMutationUnconfirmed, port.save("unconfirmed"));
    try fixture.finish();
}

test "a checkpoint rejected for size sends no publication" {
    const Fixture = @import("test_jmap.zig").Fixture;
    var fixture = try Fixture.init(&.{
        .{ .method = "Email/query", .result = "{\"ids\":[]}" },
    });
    defer fixture.deinit();
    var mailbox = try fixture.start();
    var history = History.init(std.testing.allocator, &mailbox);
    defer history.deinit();
    const port = history.port();
    _ = try port.load(fixture.arena.allocator());
    fixture.jmap.max_request = 1;
    try std.testing.expectError(error.HistoryCheckpointTooLarge, port.save("rejected"));
    try fixture.finish();
}

test "history requires every immutable record in an unconfirmed batch" {
    const Fixture = @import("test_jmap.zig").Fixture;
    const group: [32]u8 = @splat('1');
    // SHA-256 of "first" and "second", as supplied by the history writer.
    const first_key = "a7937b64b8caa58f03721bb6bacf5c78cb235febe0e70b1b84cd99541461a08e".*;
    const second_key = "16367aacb67a4a017c8da8ab95682ccb390863780f7114dda0a0e0c55644c7c4".*;
    const common = "\"size\":450,\"mailboxIds\":{\"history\":true},\"keywords\":{\"ivenna-state\":true,\"ivenna-history-" ++ group ++ "\":true}," ++
        "\"from\":[{\"email\":\"ivenna@example.com\"}],\"to\":[{\"email\":\"ivenna@example.com\"}]," ++
        "\"header:X-Ivenna-History-Kind:asText\":\"record\",\"header:X-Ivenna-History-Key:asText\":\"";
    const first = "{\"id\":\"first\"," ++ common ++ first_key ++ "\"}";
    const second = "{\"id\":\"second\"," ++ common ++ second_key ++ "\",\"header:X-Ivenna-History-Previous:asText\":\"" ++ first_key ++ "\"}";
    for ([_]bool{ false, true }) |complete| {
        var fixture = try Fixture.init(&.{
            .{ .method = "Email/set", .result = null },
            .{ .method = "Email/query", .result = if (complete) "{\"ids\":[\"first\",\"second\"]}" else "{\"ids\":[\"first\"]}" },
            .{ .method = "Email/get", .result = if (complete) "{\"list\":[" ++ first ++ "," ++ second ++ "]}" else "{\"list\":[" ++ first ++ "]}" },
            .{ .method = "Email/query", .result = "{\"ids\":[]}" },
        });
        defer fixture.deinit();
        var mailbox = try fixture.start();
        var history = History.init(std.testing.allocator, &mailbox);
        defer history.deinit();
        const port = history.port();
        const a = fixture.arena.allocator();
        const outcome = port.create(a, &.{
            .{ .group = &group, .key = first_key, .body = "first" },
            .{ .group = &group, .key = second_key, .previous = first_key, .body = "second" },
        });
        if (complete) try outcome else try std.testing.expectError(error.MailMutationUnconfirmed, outcome);
        try fixture.finish();
    }
}
