const std = @import("std");
const state = @import("instance_state");
const testing = std.testing;
const executable = @import("app_options").executable;

const Listener = struct {
    allocator: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    reference: []const u8,

    fn request(self: Listener, action: []const u8, input: ?[]const u8, success: bool) !std.json.Value {
        return runJson(self.allocator, self.env, &.{ executable, "subscription", action, self.reference }, input, success);
    }

    fn expectReply(self: Listener, action: []const u8, input: anytype, success: bool, expected: []const u8) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, input, .{});
        const reply = try self.request(action, bytes, success);
        try testing.expectEqualStrings(expected, reply.string);
    }
};

fn runJson(a: std.mem.Allocator, env: *const std.process.Environ.Map, argv: []const []const u8, input: ?[]const u8, success: bool) !std.json.Value {
    const io = testing.io;
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = env,
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
    const bytes = try output.interface.allocRemaining(a, .unlimited);
    try testing.expectEqual(std.process.Child.Term{ .exited = if (success) 0 else 1 }, try child.wait(io));
    return std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{});
}

fn runWithoutConfig(a: std.mem.Allocator, argv: []const []const u8) !std.process.RunResult {
    const env = std.process.Environ.Map.init(a);
    return std.process.run(a, testing.io, .{ .argv = argv, .environ_map = &env });
}

test "command help and argument errors work without instance or service settings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const help = try runWithoutConfig(a, &.{ executable, "--help" });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, help.term);
    for ([_][]const u8{ "serve", "feed", "subscription" }) |name|
        try testing.expect(std.mem.indexOf(u8, help.stdout, name) != null);

    const feed = try runWithoutConfig(a, &.{ executable, "feed", "read", "--help" });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, feed.term);
    try testing.expect(std.mem.indexOf(u8, feed.stdout, "--after") != null);

    const publish = try runWithoutConfig(a, &.{ executable, "subscription", "publish", "-h" });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, publish.term);
    try testing.expect(std.mem.indexOf(u8, publish.stdout, "\"key\"") != null);
    try testing.expect(std.mem.indexOf(u8, publish.stdout, "\"cursor_conflict\"") != null);

    const typo = try runWithoutConfig(a, &.{ executable, "subscription", "publsh", "news-1" });
    try testing.expect(typo.term == .exited and typo.term.exited != 0);
    const receipt = try std.json.parseFromSliceLeaky(std.json.Value, a, typo.stdout, .{});
    try testing.expectEqualStrings("invalid_request", receipt.string);
    try testing.expect(std.mem.indexOf(u8, typo.stderr, "publsh") != null);
}

test "the subscription command accepts observations while the kernel is stopped and rejects them after withdrawal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(testing.io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, state.filename });
    try state.initialize(a, path);
    var env = std.process.Environ.Map.init(a);
    try env.put("DATA_DIR", dir);
    const listener: Listener = .{
        .allocator = a,
        .env = &env,
        .reference = blk: {
            var owner = try state.subscriptions.Store.open(a, path);
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

    var owner = try state.subscriptions.Store.open(a, path);
    defer owner.close();
    try testing.expect(try owner.withdraw(listener.reference));
    try listener.expectReply("publish", report, false, "withdrawn");
    try testing.expect((try listener.request("inspect", null, true)) == .null);
}

test "the feed command resumes offline and distinguishes a closed feed from an unknown one" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const dir = try temporary.dir.realPathFileAlloc(io, ".", a);
    const path = try std.fs.path.join(a, &.{ dir, state.filename });
    var env = std.process.Environ.Map.init(a);
    try env.put("DATA_DIR", dir);

    const missing = try std.process.run(a, io, .{ .argv = &.{ executable, "feed", "read", "ivenna:/feed/releases-1" }, .environ_map = &env });
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, missing.term);
    try testing.expectError(error.FileNotFound, temporary.dir.access(io, state.filename, .{}));

    try state.initialize(a, path);
    const source = closed: {
        var writer = try state.feeds.Store.open(a, io, path, 2);
        defer writer.close();
        const first_feed = try writer.create(a, "发布", "Release updates");
        const other_feed = try writer.create(a, "发布", "Other work");
        const after = try writer.publish(first_feed, "core-1", "Already processed", 100);
        _ = try writer.publish(other_feed, "core-1", "Other update", 101);
        const next = try writer.publish(first_feed, "activity-2", "First line\x00\n第二行", 102);
        _ = try writer.publish(first_feed, "activity-2", "Later update", 103);
        _ = try writer.closeChannel(first_feed);
        break :closed .{ .id = first_feed, .after = after, .next = next };
    };

    const after = try std.fmt.allocPrint(a, "{d}", .{source.after});
    const page = (try runJson(a, &env, &.{ executable, "feed", "read", source.id, "--after", after, "--limit", "1" }, null, true)).object;
    try testing.expectEqualStrings(source.id, page.get("channel_id").?.string);
    try testing.expectEqualStrings("Release updates", page.get("description").?.string);
    try testing.expect(page.get("closed").?.bool);
    try testing.expect(page.get("has_more").?.bool);
    try testing.expectEqual(@as(i64, @intCast(source.next)), page.get("next_after").?.integer);
    const messages = page.get("messages").?.array.items;
    try testing.expectEqual(1, messages.len);
    try testing.expectEqualStrings("First line\x00\n第二行", messages[0].object.get("text").?.string);

    const unknown = try runJson(a, &env, &.{ executable, "feed", "read", "ivenna:/feed/missing-1" }, null, false);
    try testing.expectEqualStrings("unknown_channel", unknown.string);
    const invalid = try runJson(a, &env, &.{ executable, "feed", "read", "ivenna:/focus/core-1" }, null, false);
    try testing.expectEqualStrings("invalid_request", invalid.string);
}
