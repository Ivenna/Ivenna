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

    pub fn init(allocator: Allocator, mailbox: *Mailbox) History {
        return .{ .allocator = allocator, .mailbox = mailbox };
    }

    pub fn deinit(self: *History) void {
        self.* = undefined;
    }

    pub fn port(self: *History) contracts.HistoryStore {
        return .{ .context = self, .vtable = &.{ .load = load, .allocateGroup = allocateGroup, .query = query, .read = read, .create = create, .save = save, .maintain = maintain } };
    }

    fn load(context: *anyopaque, a: Allocator) !?[]const u8 {
        const self: *History = @ptrCast(@alignCast(context));
        const checkpoint = try self.currentCheckpoint(a);
        self.confirmed_revision = if (checkpoint) |head| head.revision else 0;
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

    fn save(context: *anyopaque, checkpoint: []const u8) !void {
        const self: *History = @ptrCast(@alignCast(context));
        const confirmed = self.confirmed_revision orelse return error.HistoryNotLoaded;
        const revision = std.math.add(u64, confirmed, 1) catch return error.HistoryRevisionExhausted;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        self.mailbox.createCheckpoint(a, checkpoint, revision) catch |err| {
            if (err != error.MailMutationUnconfirmed) return err;
            // Confirm the unique current head and full body used at restart.
            const stored = (try self.currentCheckpoint(a)) orelse return err;
            if (stored.revision < revision) return err;
            if (stored.revision != revision or !std.mem.eql(u8, stored.document, checkpoint)) return error.InvalidHistory;
        };
        self.confirmed_revision = revision;
    }
};

test "a lost checkpoint acknowledgement requires the published document to match" {
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
        const port = history.port();
        _ = try port.load(fixture.arena.allocator());
        const saved = port.save(document);
        if (std.mem.eql(u8, document, "selected")) {
            try saved;
        } else {
            try std.testing.expectError(error.InvalidHistory, saved);
        }
        try fixture.finish();
    }
}

test "a checkpoint rejected for size sends no publication" {
    const Fixture = @import("test_jmap.zig").Fixture;
    var fixture = try Fixture.init(&.{
        .{ .method = "Email/query", .result = "{\"ids\":[]}" },
    });
    defer fixture.deinit();
    var mailbox = try fixture.start();
    var history = History.init(std.testing.allocator, &mailbox);
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
