const std = @import("std");
const contracts = @import("agent_contracts");
const Mailbox = @import("mail.zig").Mailbox;
const StateRecord = @import("mail.zig").StateRecord;
const Allocator = std.mem.Allocator;

/// Store grouped immutable records and publish the retained-session checkpoint.
/// The agent owns record encodings and identity; native locators stay in memory.
pub const History = struct {
    allocator: Allocator,
    mailbox: *Mailbox,
    /// Revision eligible for maintenance. Zero means the store was empty on load.
    confirmed_revision: ?u64 = null,
    /// Highest revision observed or attempted by this process. An unconfirmed
    /// write can still complete, so later saves advance beyond it.
    highest_revision: ?u64 = null,

    pub fn init(allocator: Allocator, mailbox: *Mailbox) History {
        return .{ .allocator = allocator, .mailbox = mailbox };
    }

    pub fn deinit(self: *History) void {
        self.* = undefined;
    }

    pub fn port(self: *History) contracts.HistoryStore {
        return .{ .context = self, .vtable = &.{ .load = load, .allocateGroup = allocateGroup, .query = query, .read = read, .create = create, .save = save, .fits = fits, .maintain = maintain } };
    }

    fn load(context: *anyopaque, a: Allocator) !?[]const u8 {
        const self: *History = @ptrCast(@alignCast(context));
        self.confirmed_revision = null;
        const checkpoint = try self.currentCheckpoint(a);
        const revision = if (checkpoint) |head| head.revision else 0;
        self.confirmed_revision = revision;
        self.highest_revision = @max(self.highest_revision orelse 0, revision);
        return if (checkpoint) |head| head.document else null;
    }

    const Checkpoint = struct { revision: u64, document: []const u8 };

    fn currentCheckpoint(self: *History, a: Allocator) !?Checkpoint {
        const records = try self.mailbox.historyHeads(a);
        var latest: ?StateRecord = null;
        for (records) |record| {
            if (latest == null or record.revision > latest.?.revision) {
                latest = record;
            }
        }
        if (latest) |selected| for (records) |record| {
            if (record.revision == selected.revision and !std.mem.eql(u8, record.id, selected.id))
                return error.AmbiguousHistoryRevision;
        };
        const head = latest orelse return null;
        return .{ .revision = head.revision, .document = try self.mailbox.historyCheckpoint(a, head.id) };
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
        return self.mailbox.maintainHistory(a, retention, self.confirmed_revision orelse return error.HistoryNotLoaded);
    }

    /// Answer for the revision save would publish next. Nothing is sent, so
    /// the answer only describes the size the server would accept right now.
    fn fits(context: *anyopaque, a: Allocator, checkpoint: []const u8) !bool {
        const self: *History = @ptrCast(@alignCast(context));
        if (self.highest_revision == null) _ = try load(context, a);
        const revision = std.math.add(u64, self.highest_revision.?, 1) catch return error.HistoryRevisionExhausted;
        return self.mailbox.checkpointFits(a, checkpoint, revision);
    }

    fn save(context: *anyopaque, checkpoint: []const u8) !void {
        const self: *History = @ptrCast(@alignCast(context));
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        if (self.highest_revision == null) _ = try load(context, a);
        const revision = std.math.add(u64, self.highest_revision.?, 1) catch return error.HistoryRevisionExhausted;
        self.mailbox.createCheckpoint(a, checkpoint, revision) catch |err| {
            if (err == error.HistoryCheckpointTooLarge) return err;
            self.highest_revision = revision;
            self.confirmed_revision = null;
            if (err != error.MailMutationUnconfirmed) return err;
            // A matching revision alone cannot confirm the selection.
            // Use the same unique current head and full body as restart.
            const stored = (try self.currentCheckpoint(a)) orelse return err;
            self.highest_revision = @max(revision, stored.revision);
            if (stored.revision < revision) return err;
            if (stored.revision != revision or !std.mem.eql(u8, stored.document, checkpoint)) return error.InvalidHistory;
        };
        self.highest_revision = revision;
        self.confirmed_revision = revision;
    }
};

test "a lost checkpoint acknowledgement requires the same published revision and document" {
    const Fixture = @import("test_jmap.zig").Fixture;
    const checkpoint =
        \\{"list":[{"id":"saved","mailboxIds":{"history":true},"keywords":{"ivenna-state":true,"ivenna-current":true},
        \\"from":[{"email":"ivenna@example.com"}],"to":[{"email":"ivenna@example.com"}],
        \\"header:X-Ivenna-History-Kind:asText":"checkpoint","header:X-Ivenna-History-Revision:asText":"1",
        \\"textBody":[{"partId":"text","type":"text/plain"}],"bodyValues":{"text":{"value":"selected"}}}]}
    ;
    for ([_][]const u8{ "selected", "different" }) |document| {
        var fixture = try Fixture.init(&.{
            .{ .method = "Email/query", .result = "{\"ids\":[]}" },
            .{ .method = "Email/set", .result = null },
            .{ .method = "Email/query", .result = "{\"ids\":[\"saved\"]}" },
            .{ .method = "Email/get", .result = checkpoint },
            .{ .method = "Email/query", .result = "{\"ids\":[]}" },
            .{ .method = "Email/get", .result = checkpoint, .properties = &.{.{ .path = &.{"fetchTextBodyValues"}, .json = "true" }} },
        });
        defer fixture.deinit();
        var mailbox = try fixture.start();
        var history = History.init(std.testing.allocator, &mailbox);
        const saved = history.port().save(document);
        if (std.mem.eql(u8, document, "selected")) {
            try saved;
        } else {
            try std.testing.expectError(error.InvalidHistory, saved);
            try std.testing.expectError(error.HistoryNotLoaded, history.port().maintain(fixture.arena.allocator(), .{ .records = &.{} }));
        }
        try fixture.finish();
    }
}

test "a later save advances past a checkpoint whose create could still complete" {
    const Fixture = @import("test_jmap.zig").Fixture;
    var fixture = try Fixture.init(&.{
        .{ .method = "Email/query", .result = "{\"ids\":[]}" },
        .{ .method = "Email/set", .result = null, .properties = &.{.{ .path = &.{ "create", "checkpoint", "header:X-Ivenna-History-Revision:asText" }, .json = "\"1\"" }} },
        .{ .method = "Email/query", .result = "{\"ids\":[]}" },
        .{ .method = "Email/set", .result = "{\"created\":{\"checkpoint\":{\"id\":\"new\"}}}", .properties = &.{.{ .path = &.{ "create", "checkpoint", "header:X-Ivenna-History-Revision:asText" }, .json = "\"2\"" }} },
    });
    defer fixture.deinit();
    var mailbox = try fixture.start();
    var history = History.init(std.testing.allocator, &mailbox);
    try std.testing.expectError(error.MailMutationUnconfirmed, history.port().save("first"));
    try history.port().save("second");
    try fixture.finish();
}

test "a checkpoint rejected before sending leaves the confirmed revision intact" {
    const Fixture = @import("test_jmap.zig").Fixture;
    var fixture = try Fixture.init(&.{
        .{ .method = "Email/query", .result = "{\"ids\":[]}" },
        .{ .method = "Email/set", .result = "{\"created\":{\"checkpoint\":{\"id\":\"first\"}}}", .properties = &.{.{ .path = &.{ "create", "checkpoint", "header:X-Ivenna-History-Revision:asText" }, .json = "\"1\"" }} },
        .{ .method = "Email/set", .result = "{\"created\":{\"checkpoint\":{\"id\":\"second\"}}}", .properties = &.{.{ .path = &.{ "create", "checkpoint", "header:X-Ivenna-History-Revision:asText" }, .json = "\"2\"" }} },
    });
    defer fixture.deinit();
    var mailbox = try fixture.start();
    var history = History.init(std.testing.allocator, &mailbox);
    try history.port().save("first");
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    try std.testing.expect(try history.port().fits(scratch.allocator(), "accepted"));
    const limit = fixture.jmap.max_request;
    fixture.jmap.max_request = 1;
    try std.testing.expect(!try history.port().fits(scratch.allocator(), "rejected"));
    try std.testing.expectError(error.HistoryCheckpointTooLarge, history.port().save("rejected"));
    try std.testing.expectEqual(@as(?u64, 1), history.confirmed_revision);
    fixture.jmap.max_request = limit;
    try history.port().save("second");
    try fixture.finish();
}

test "history requires every immutable record in an unconfirmed batch" {
    const Fixture = @import("test_jmap.zig").Fixture;
    const group: [32]u8 = @splat('1');
    // SHA-256 of "first" and "second", as supplied by the history writer.
    const first_key = "a7937b64b8caa58f03721bb6bacf5c78cb235febe0e70b1b84cd99541461a08e".*;
    const second_key = "16367aacb67a4a017c8da8ab95682ccb390863780f7114dda0a0e0c55644c7c4".*;
    const common = "\"mailboxIds\":{\"history\":true},\"keywords\":{\"ivenna-state\":true,\"ivenna-history-" ++ group ++ "\":true}," ++
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
        const outcome = history.port().create(fixture.arena.allocator(), &.{
            .{ .group = &group, .key = first_key, .body = "first" },
            .{ .group = &group, .key = second_key, .previous = first_key, .body = "second" },
        });
        if (complete) try outcome else try std.testing.expectError(error.MailMutationUnconfirmed, outcome);
        try fixture.finish();
    }
}
