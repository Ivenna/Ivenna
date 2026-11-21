const std = @import("std");
const contracts = @import("agent_contracts");
const Allocator = std.mem.Allocator;
const Inbox = contracts.Inbox;
const IncomingMessage = contracts.Communication.IncomingMessage;

/// Directory-backed inbox: one JSON document per file, arrival order by file
/// name. A writer publishes atomically (write `*.tmp`, then rename), so a
/// partially written document is never visible as a candidate. The receipt is
/// the file name; acknowledgement moves the file into `.acked/`.
pub const Spool = struct {
    io: std.Io,
    dir: std.Io.Dir,
    owned: bool,
    /// Upper bound for one document. Oversized files are reported and skipped.
    max_message_bytes: usize = 1 << 20,

    const acked_dir = ".acked";

    /// Create the directory (if missing), open it, and prepare `.acked/`.
    /// The directory is owned by the returned value.
    pub fn openPath(io: std.Io, path: []const u8) !Spool {
        _ = try std.Io.Dir.cwd().createDirPathStatus(io, path, .fromMode(0o700));
        const dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
        errdefer dir.close(io);
        var spool: Spool = .{ .io = io, .dir = dir, .owned = true };
        try spool.ensureAcked();
        return spool;
    }

    /// Borrow a directory opened by the caller. The caller keeps ownership.
    pub fn init(io: std.Io, dir: std.Io.Dir) !Spool {
        var spool: Spool = .{ .io = io, .dir = dir, .owned = false };
        try spool.ensureAcked();
        return spool;
    }

    pub fn deinit(self: *Spool) void {
        if (self.owned) self.dir.close(self.io);
        self.* = undefined;
    }

    pub fn inbox(self: *Spool) Inbox {
        return .{ .context = self, .vtable = &vtable };
    }

    fn ensureAcked(self: *Spool) !void {
        _ = try self.dir.createDirPathStatus(self.io, acked_dir, .fromMode(0o700));
    }

    const vtable: Inbox.VTable = .{ .poll = poll, .acknowledge = acknowledge };

    fn fromContext(context: *anyopaque) *Spool {
        return @ptrCast(@alignCast(context));
    }

    /// Wire format. `from` is required and non-empty; the remaining fields are
    /// optional so a producer can omit what it does not know.
    const Wire = struct {
        from: []const []const u8,
        text: []const u8 = "",
        observed_at_unix_ms: ?i64 = null,
    };

    fn poll(context: *anyopaque, a: Allocator, request: Inbox.Poll) ![]const Inbox.Incoming {
        const self = fromContext(context);
        if (request.messages == 0) return &.{};
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(a);
        var entries = self.dir.iterate();
        while (try entries.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            try names.append(a, try a.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, lessThanName);
        const limit = @min(names.items.len, request.messages);
        var incoming: std.ArrayList(Inbox.Incoming) = .empty;
        defer incoming.deinit(a);
        for (names.items) |name| {
            if (incoming.items.len == limit) break;
            const bytes = self.dir.readFileAlloc(self.io, name, a, .limited(self.max_message_bytes)) catch |err| {
                std.log.warn("spool: cannot read {s}: {s}", .{ name, @errorName(err) });
                continue;
            };
            defer a.free(bytes);
            const message = decode(self.io, a, bytes) catch |err| {
                std.log.warn("spool: skipping {s}: {s}", .{ name, @errorName(err) });
                continue;
            };
            try incoming.append(a, .{ .content = .{ .message = message }, .receipt = name });
        }
        return try incoming.toOwnedSlice(a);
    }

    fn acknowledge(context: *anyopaque, a: Allocator, receipt: []const u8) !void {
        const self = fromContext(context);
        if (receipt.len == 0) return;
        if (std.mem.indexOfAny(u8, receipt, "/\\") != null or std.mem.startsWith(u8, receipt, "."))
            return error.InvalidReceipt;
        const destination = try std.fmt.allocPrint(a, "{s}/{s}", .{ acked_dir, receipt });
        std.Io.Dir.rename(self.dir, receipt, self.dir, destination, self.io) catch |err| switch (err) {
            // Already acknowledged, or vanished: acknowledgement is idempotent.
            error.FileNotFound => return,
            else => return err,
        };
    }

    fn decode(io: std.Io, a: Allocator, bytes: []const u8) !IncomingMessage {
        const wire = try std.json.parseFromSliceLeaky(Wire, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        if (wire.from.len == 0) return error.MissingFrom;
        return .{
            .from = wire.from,
            .text = wire.text,
            .observed_at_unix_ms = wire.observed_at_unix_ms orelse std.Io.Clock.real.now(io).toMilliseconds(),
        };
    }
};

fn lessThanName(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn writeDocument(dir: std.Io.Dir, io: std.Io, name: []const u8, body: []const u8) !void {
    const file = try dir.createFile(io, name, .{ .read = true });
    defer file.close(io);
    try file.writeStreamingAll(io, body);
}

test "returns documents in name order with receipts" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeDocument(tmp.dir, io, "0002.json", "{\"from\":[\"operator\"],\"text\":\"second\"}");
    try writeDocument(tmp.dir, io, "0001.json", "{\"from\":[\"operator\"],\"text\":\"first\",\"observed_at_unix_ms\":5}");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spool = try Spool.init(io, tmp.dir);
    const items = try spool.inbox().poll(a, .{ .messages = 10, .callbacks = 0 });
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("first", items[0].content.message.text);
    try std.testing.expectEqual(@as(i64, 5), items[0].content.message.observed_at_unix_ms);
    try std.testing.expectEqualStrings("operator", items[0].content.message.from[0]);
    try std.testing.expectEqualStrings("0001.json", items[0].receipt.?);
    try std.testing.expectEqualStrings("second", items[1].content.message.text);
    try std.testing.expect(items[1].content.message.observed_at_unix_ms > 0);
}

test "acknowledgement retires a document exactly once" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeDocument(tmp.dir, io, "a.json", "{\"from\":[\"operator\"],\"text\":\"hello\"}");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spool = try Spool.init(io, tmp.dir);
    const items = try spool.inbox().poll(a, .{ .messages = 10, .callbacks = 0 });
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try spool.inbox().acknowledge(a, items[0].receipt.?);
    try spool.inbox().acknowledge(a, items[0].receipt.?);
    const after = try spool.inbox().poll(a, .{ .messages = 10, .callbacks = 0 });
    try std.testing.expectEqual(@as(usize, 0), after.len);
    const acked = try tmp.dir.readFileAlloc(io, ".acked/a.json", a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, acked, "hello") != null);
}

test "skips malformed and temporary documents without blocking later ones" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeDocument(tmp.dir, io, "0001.json", "{not json");
    try writeDocument(tmp.dir, io, "0002.json.tmp", "{\"from\":[\"x\"],\"text\":\"tmp\"}");
    try writeDocument(tmp.dir, io, "0003.json", "{\"text\":\"no sender\"}");
    try writeDocument(tmp.dir, io, "0004.json", "{\"from\":[\"operator\"],\"text\":\"good\"}");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spool = try Spool.init(io, tmp.dir);
    const items = try spool.inbox().poll(a, .{ .messages = 10, .callbacks = 0 });
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("good", items[0].content.message.text);
}

test "respects the message budget" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeDocument(tmp.dir, io, "1.json", "{\"from\":[\"a\"],\"text\":\"1\"}");
    try writeDocument(tmp.dir, io, "2.json", "{\"from\":[\"a\"],\"text\":\"2\"}");
    try writeDocument(tmp.dir, io, "3.json", "{\"from\":[\"a\"],\"text\":\"3\"}");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spool = try Spool.init(io, tmp.dir);
    const items = try spool.inbox().poll(a, .{ .messages = 2, .callbacks = 0 });
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("1", items[0].content.message.text);
    try std.testing.expectEqualStrings("2", items[1].content.message.text);
    const off = try spool.inbox().poll(a, .{ .messages = 0, .callbacks = 10 });
    try std.testing.expectEqual(@as(usize, 0), off.len);
}
