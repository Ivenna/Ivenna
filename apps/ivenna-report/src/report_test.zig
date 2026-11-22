const std = @import("std");
const subscriptions = @import("subscriptions");
const testing = std.testing;
const executable = @import("reporter").executable;

const Listener = struct {
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    reference: []const u8,

    fn request(self: Listener, action: []const u8, input: ?[]const u8, success: bool) !std.json.Value {
        const io = testing.io;
        var child = try std.process.spawn(io, .{
            .argv = &.{ executable, action, self.reference },
            .environ_map = self.env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = if (success) .inherit else .ignore,
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

fn runWithoutConfig(a: std.mem.Allocator, argv: []const []const u8) !std.process.RunResult {
    const env = std.process.Environ.Map.init(a);
    return std.process.run(a, testing.io, .{ .argv = argv, .environ_map = &env });
}

test "listeners can read the protocol and diagnose a mistyped command before configuring a catalog" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const help = try runWithoutConfig(a, &.{ executable, "--help" });
    const inspect_usage = "ivenna-report inspect SUBSCRIPTION_ID";
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, help.term);
    try testing.expect(std.mem.indexOf(u8, help.stdout, inspect_usage) != null);
    try testing.expect(std.mem.indexOf(u8, help.stdout, "\"cursor_conflict\"") != null);

    const publish = try runWithoutConfig(a, &.{ executable, "publish", "-h" });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, publish.term);
    try testing.expect(std.mem.indexOf(u8, publish.stdout, "\"key\"") != null);
    try testing.expect(std.mem.indexOf(u8, publish.stdout, inspect_usage) == null);

    const typo = try runWithoutConfig(a, &.{ executable, "publsh", "news-1" });
    try testing.expect(typo.term == .exited and typo.term.exited != 0);
    const receipt = try std.json.parseFromSliceLeaky(std.json.Value, a, typo.stdout, .{});
    try testing.expectEqualStrings("invalid_request", receipt.string);
    try testing.expect(std.mem.indexOf(u8, typo.stderr, "publsh") != null);
}

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
            break :blk (try owner.create(a, "research-2", "-release feed", "test listener")).subscription_id;
        },
    };
    const report = .{ .key = "item-1", .text = "first", .cursor = .{ .to = "1" } };
    // A JSON array must not reserve the same key as the string "item-1".
    const array_key = [_]u16{ 'i', 't', 'e', 'm', '-', '1' };
    try listener.expectReply("publish", .{ .key = array_key, .text = "wrong type" }, false, "invalid_request");
    try listener.expectReply("publish", report, true, "accepted");
    try listener.expectReply("publish", report, true, "duplicate");
    try listener.expectReply("checkpoint", .{ .to = "2" }, false, "cursor_conflict");
    try listener.expectReply("checkpoint", .{ .from = "1", .to = "2" }, true, "accepted");
    const details = (try listener.request("inspect", null, true)).object;
    try testing.expectEqualStrings(listener.reference, details.get("subscription_id").?.string);
    try testing.expectEqualStrings("research-2", details.get("focus_id").?.string);
    try testing.expectEqualStrings("test listener", details.get("listener").?.string);
    try testing.expectEqualStrings("2", details.get("cursor").?.string);

    var owner = try subscriptions.Store.openExisting(a, path);
    defer owner.close();
    try testing.expect(try owner.withdraw(listener.reference));
    try listener.expectReply("publish", report, false, "withdrawn");
    try testing.expect((try listener.request("inspect", null, true)) == .null);
}
