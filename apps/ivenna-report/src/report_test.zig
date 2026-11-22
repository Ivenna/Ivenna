const std = @import("std");
const subscriptions = @import("subscriptions");
const testing = std.testing;

const Listener = struct {
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    reference: []const u8,

    fn request(self: Listener, action: []const u8, input: ?[]const u8, success: bool) !std.json.Value {
        const io = testing.io;
        var child = try std.process.spawn(io, .{
            .argv = &.{ @import("reporter").executable, action, self.reference },
            .environ_map = self.env,
            .stdin = .pipe,
            .stdout = .pipe,
        });
        defer child.kill(io);
        if (input) |bytes| try child.stdin.?.writeStreamingAll(io, bytes);
        child.stdin.?.close(io);
        child.stdin = null;

        var buffer: [256]u8 = undefined;
        var output = child.stdout.?.readerStreaming(io, &buffer);
        const bytes = try output.interface.allocRemaining(self.allocator, .unlimited);
        const term = try child.wait(io);
        try testing.expect(term == .exited);
        try testing.expectEqual(success, term.exited == 0);
        return std.json.parseFromSliceLeaky(std.json.Value, self.allocator, bytes, .{});
    }

    fn expectReply(self: Listener, action: []const u8, input: anytype, success: bool, expected: []const u8) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, input, .{});
        const reply = try self.request(action, bytes, success);
        try testing.expectEqualStrings(expected, reply.string);
    }
};

test "the reporter accepts observations while the kernel is stopped and rejects them after withdrawal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(testing.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, subscriptions.filename });
    var env = std.process.Environ.Map.init(a);
    try env.put("DATA_DIR", dir);
    const listener: Listener = .{
        .allocator = a,
        .env = &env,
        .reference = blk: {
            var owner = try subscriptions.Store.open(a, path);
            defer owner.close();
            break :blk (try owner.create(a, "research-2", "news", .next_input, "test listener")).subscription_id;
        },
    };
    const first_cursor: [40 * 1024]u8 = @splat('1');
    const next_cursor: [40 * 1024]u8 = @splat('2');
    const report = .{ .key = "item-1", .text = "first", .cursor = .{ .to = &first_cursor } };
    // A JSON array must not reserve the same key as the string "item-1".
    const array_key = [_]u16{ 'i', 't', 'e', 'm', '-', '1' };
    try listener.expectReply("publish", .{ .key = array_key, .text = "wrong type" }, false, "invalid_request");
    try listener.expectReply("publish", report, true, "accepted");
    try listener.expectReply("publish", .{ .key = "item-2", .text = "second" }, true, "accepted");
    try listener.expectReply("publish", report, true, "duplicate");
    try listener.expectReply("checkpoint", .{ .to = "2" }, false, "cursor_conflict");
    try listener.expectReply("checkpoint", .{ .from = &first_cursor, .to = &next_cursor }, true, "accepted");
    const details = (try listener.request("inspect", null, true)).object;
    try testing.expectEqualStrings(listener.reference, details.get("subscription_id").?.string);
    try testing.expectEqualStrings("research-2", details.get("focus_id").?.string);
    try testing.expectEqualStrings(&next_cursor, details.get("cursor").?.string);

    var owner = try subscriptions.Store.openExisting(a, path);
    defer owner.close();
    try testing.expect(try owner.withdraw(listener.reference));
    try listener.expectReply("publish", report, false, "withdrawn");
    try testing.expect((try listener.request("inspect", null, true)) == .null);
}
