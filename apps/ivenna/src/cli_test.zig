const std = @import("std");
const agent = @import("agent");
const state = @import("instance_state");
const contracts = @import("agent_contracts");
const channel_ipc = @import("channel_ipc.zig");
const Config = @import("config.zig").Config;
const Registry = @import("channels.zig").Registry;
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
    return readJson(a, &child, success);
}

fn readJson(a: std.mem.Allocator, child: *std.process.Child, success: bool) !std.json.Value {
    const io = testing.io;
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

test "reasoning settings load defaults and provider-specific effort names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("DATA_DIR", "/unused");
    try env.put("LLM_API_KEY", "test-key");
    try env.put("MAIL_ADDRESS", "ivenna@example.test");
    try env.put("MAIL_AUTHORIZATION", "Bearer test-key");

    try testing.expectEqualDeep(agent.Engine.Reasoning{
        .core = "low",
        .activity = "max",
        .compaction = "max",
    }, (try Config.load(a, &env)).llm_reasoning);

    try env.put("LLM_CORE_REASONING_EFFORT", "provider-core");
    try env.put("LLM_ACTIVITY_REASONING_EFFORT", "provider-activity");
    try env.put("LLM_COMPACTION_REASONING_EFFORT", "provider-compaction");
    try testing.expectEqualDeep(agent.Engine.Reasoning{
        .core = "provider-core",
        .activity = "provider-activity",
        .compaction = "provider-compaction",
    }, (try Config.load(a, &env)).llm_reasoning);

    try env.put("LLM_COMPACTION_REASONING_EFFORT", "");
    try testing.expectError(error.MissingConfiguration, Config.load(a, &env));
}

test "history inline image budget loads defaults, custom values, zero, and rejects invalid values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("DATA_DIR", "/unused");
    try env.put("LLM_API_KEY", "test-key");
    try env.put("MAIL_ADDRESS", "ivenna@example.test");
    try env.put("MAIL_AUTHORIZATION", "Bearer test-key");

    try testing.expectEqual(@as(u64, 1024 * 1024), (try Config.load(a, &env)).context_limits.history_inline_image_bytes);
    try env.put("HISTORY_INLINE_IMAGE_BYTES", "33554432");
    try testing.expectEqual(@as(u64, 33554432), (try Config.load(a, &env)).context_limits.history_inline_image_bytes);
    try env.put("HISTORY_INLINE_IMAGE_BYTES", "0");
    try testing.expectEqual(@as(u64, 0), (try Config.load(a, &env)).context_limits.history_inline_image_bytes);
    try env.put("HISTORY_INLINE_IMAGE_BYTES", "-1");
    try testing.expectError(error.InvalidConfiguration, Config.load(a, &env));
    try env.put("HISTORY_INLINE_IMAGE_BYTES", "12x");
    try testing.expectError(error.InvalidConfiguration, Config.load(a, &env));
}

test "command help and argument errors work without instance or service settings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const receive = try runWithoutConfig(a, &.{ executable, "receive", "--help" });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, receive.term);
    try testing.expect(std.mem.indexOf(u8, receive.stdout, "ivenna receive CHANNEL_ID") != null);

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
            break :blk (try owner.create(a, "research-2", "-release watch", "test listener")).subscription_id;
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

test "receive reports invalid arguments before requiring instance configuration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const invalid_timeout = try runWithoutConfig(a, &.{ executable, "receive", "events-1", "--timeout", "0" });
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, invalid_timeout.term);
    try testing.expectEqualStrings("", invalid_timeout.stdout);
    try testing.expect(std.mem.indexOf(u8, invalid_timeout.stderr, "--timeout") != null);

    const missing_data_dir = try runWithoutConfig(a, &.{ executable, "receive", "events-1" });
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, missing_data_dir.term);
    try testing.expectEqualStrings("", missing_data_dir.stdout);
    try testing.expect(std.mem.indexOf(u8, missing_data_dir.stderr, "DATA_DIR") != null);
}

test "a channel matches one pending read and holds no message between receivers" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "target/child");
    try temporary.dir.symLink(io, "target/child", "link", .{ .is_directory = true });
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);
    const configured = try std.fs.path.join(a, &.{ root, "link", "..", "data" });
    const directory = try @import("serve.zig").prepareDataDirectory(io, configured, a);
    try testing.expectEqualStrings(try std.fs.path.join(a, &.{ root, "target", "data" }), directory);
    var registry = try Registry.listen(testing.allocator, io, directory);
    defer registry.deinit();
    var task = try io.concurrent(Registry.run, .{&registry});
    defer task.cancel(io) catch {};

    const channels = registry.port();
    const id = try contracts.Reference.create(a, "--工 作/path", 1);
    const receiver = try Receiver.init(a, configured, id);
    try channels.reserve(receiver.id);
    try expectSendOutcome(channels, receiver.id, "before activation", .unknown_channel);
    {
        const reserved = try channel_ipc.connect(io, directory, receiver.id, null);
        defer reserved.close(io);
        try expectReceiveReply(reserved, .unknown_channel);
    }
    channels.close(receiver.id);
    try channels.reserve(receiver.id);
    channels.activate(receiver.id);

    try expectSendOutcome(channels, receiver.id, "before any receiver", .would_block);

    const oversize: [contracts.Channels.max_message_bytes + 1]u8 = @splat('x');
    const maximum = oversize[0..contracts.Channels.max_message_bytes];
    try expectSendOutcome(channels, receiver.id, &oversize, .too_long);
    {
        var pending = try io.concurrent(Receiver.once, .{ &receiver, a, &.{} });
        defer _ = pending.cancel(io) catch {};
        try expectSendOutcome(channels, receiver.id, maximum, .accepted);
        try expectMessage(try pending.await(io), maximum);
    }

    try expectReceiveStatus(try receiver.once(a, &.{ "--timeout", "10" }), "timeout");
    try expectSendOutcome(channels, receiver.id, "after the wait expired", .would_block);
    {
        const canceled = try channel_ipc.connect(io, directory, receiver.id, null);
        defer canceled.close(io);
        try expectReceiveReply(canceled, .waiting);
    }
    try expectSendOutcome(channels, receiver.id, "after the waiting receiver disconnected", .would_block);

    const second = "前半段\x00\n\"\\second half";
    var replacement = try io.concurrent(Receiver.once, .{ &receiver, a, &.{ "--timeout", "5000" } });
    defer _ = replacement.cancel(io) catch {};
    try expectSendOutcome(channels, receiver.id, second, .accepted);
    try expectMessage(try replacement.await(io), second);
}

test "receive follow flushes successive matches and exits when its channel closes" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", a);
    var registry = try Registry.listen(testing.allocator, io, directory);
    defer registry.deinit();
    var task = try io.concurrent(Registry.run, .{&registry});
    defer task.cancel(io) catch {};

    const channels = registry.port();
    const receiver = try Receiver.init(a, directory, "events-1");
    try channels.reserve(receiver.id);
    channels.activate(receiver.id);
    const waiting = try channel_ipc.connect(io, directory, receiver.id, null);
    defer waiting.close(io);
    try expectReceiveReply(waiting, .waiting);
    try expectSendOutcome(channels, receiver.id, "queued before close", .accepted);
    try expectSendOutcome(channels, receiver.id, "before the next request", .would_block);

    var child = try receiver.spawn(&.{ executable, "receive", receiver.id, "--follow" });
    defer child.kill(io);
    var buffer: [256]u8 = undefined;
    var output = child.stdout.?.readerStreaming(io, &buffer);

    try expectSendOutcome(channels, receiver.id, "first message\ncontinued", .accepted);
    try expectFollowMessage(a, &output.interface, "first message\ncontinued");
    try expectSendOutcome(channels, receiver.id, "matched before closing", .accepted);
    channels.close(receiver.id);
    var descriptors = [_]std.posix.pollfd{.{ .fd = waiting.socket.handle, .events = 0, .revents = 0 }};
    try testing.expect(try std.posix.poll(&descriptors, 5000) != 0);
    try testing.expect(descriptors[0].revents & std.posix.POLL.HUP != 0);
    try channel_ipc.requestNext(waiting);
    try expectReceiveReply(waiting, .{ .message = "queued before close" });
    try expectReceiveReply(waiting, .closed);
    try expectFollowMessage(a, &output.interface, "matched before closing");
    try testing.expectEqual(null, try readFollowLine(&output.interface));
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));

    const unknown = try receiver.run(a, &.{});
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, unknown.term);
    try testing.expectEqualStrings("", unknown.stdout);
    try testing.expect(std.mem.indexOf(u8, unknown.stderr, "CHANNEL_ID") != null);
    try expectSendOutcome(channels, receiver.id, "late", .unknown_channel);
}

test "receive follow exits when a shell pipeline takes one message" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", a);
    var registry = try Registry.listen(testing.allocator, io, directory);
    defer registry.deinit();
    var task = try io.concurrent(Registry.run, .{&registry});
    defer task.cancel(io) catch {};

    const channels = registry.port();
    const receiver = try Receiver.init(a, directory, "events-1");
    try channels.reserve(receiver.id);
    channels.activate(receiver.id);
    const script =
        \\{
        \\    "$1" receive "$2" --follow || printf '%s\n' 'receive failed' >&2
        \\} | {
        \\    IFS= read -r message && printf '%s\n' "$message"
        \\}
    ;
    var child = try receiver.spawn(&.{ "/bin/sh", "-c", script, "receive-test", executable, receiver.id });
    defer child.kill(io);
    var buffer: [256]u8 = undefined;
    var output = child.stdout.?.readerStreaming(io, &buffer);
    try expectSendOutcome(channels, receiver.id, "接收\n第二行", .accepted);
    try expectFollowMessage(a, &output.interface, "接收\n第二行");

    // The source stays open while the pipeline and its follower finish.
    try testing.expectEqual(null, try readFollowLine(&output.interface));
    var diagnostics = child.stderr.?.readerStreaming(io, &buffer);
    try testing.expectEqual(null, try readFollowLine(&diagnostics.interface));
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
}

test "receive exits successfully when its output pipe closes during a matched write" {
    const io = testing.io;
    const linux = std.os.linux;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(io, ".", arena.allocator());
    var registry = try Registry.listen(testing.allocator, io, directory);
    defer registry.deinit();
    var task = try io.concurrent(Registry.run, .{&registry});
    defer task.cancel(io) catch {};

    const channels = registry.port();
    const receiver = try Receiver.init(arena.allocator(), directory, "events-1");
    try channels.reserve(receiver.id);
    channels.activate(receiver.id);

    var child = running: {
        // A one-page packet pipe holds only the first write, even on kernels
        // whose page size exceeds the length of the JSON-encoded message.
        const handles = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true, .DIRECT = true });
        const output: std.Io.File = .{ .handle = handles[0], .flags = .{ .nonblocking = false } };
        defer output.close(io);
        const writer: std.Io.File = .{ .handle = handles[1], .flags = .{ .nonblocking = false } };
        defer writer.close(io);
        try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(output.handle, linux.F.SETPIPE_SZ, std.heap.pageSize())));

        var process = try std.process.spawn(io, .{
            .argv = &.{ executable, "receive", receiver.id },
            .environ_map = &receiver.env,
            .stdin = .ignore,
            .stdout = .{ .file = writer },
            .stderr = .pipe,
        });
        errdefer process.kill(io);
        const message: [contracts.Channels.max_message_bytes]u8 = @splat(0);
        try expectSendOutcome(channels, receiver.id, &message, .accepted);

        var descriptors = [_]std.posix.pollfd{.{ .fd = output.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        try testing.expect(try std.posix.poll(&descriptors, 5000) != 0);
        try testing.expect(descriptors[0].revents & std.posix.POLL.IN != 0);
        break :running process;
    };
    defer child.kill(io);
    var buffer: [256]u8 = undefined;
    var diagnostics = child.stderr.?.readerStreaming(io, &buffer);
    try testing.expectEqual(null, try readFollowLine(&diagnostics.interface));
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
}

fn expectSendOutcome(channels: contracts.Channels, id: []const u8, message: []const u8, expected: contracts.Channels.SendOutcome) !void {
    const io = testing.io;
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(5));
    while (true) {
        const outcome = try channels.trySend(id, message);
        const retrying = outcome == .would_block and expected != .would_block;
        if (!retrying or std.Io.Clock.awake.now(io).compare(.gte, deadline))
            return testing.expectEqual(expected, outcome);
        try io.sleep(.fromMilliseconds(2), .awake);
    }
}

fn expectReceiveReply(connection: std.Io.net.Stream, expected: channel_ipc.Response) !void {
    var descriptors = [_]std.posix.pollfd{
        .{ .fd = connection.socket.handle, .events = std.posix.POLL.IN, .revents = 0 },
    };
    try testing.expect(try std.posix.poll(&descriptors, 5000) != 0);
    var buffer: [channel_ipc.response_buffer_size]u8 = undefined;
    try testing.expectEqualDeep(expected, try channel_ipc.readResponse(connection, &buffer));
}

fn expectFollowMessage(a: std.mem.Allocator, reader: *std.Io.Reader, expected: []const u8) !void {
    const line = (try readFollowLine(reader)) orelse return error.MissingMessage;
    const result = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
    try expectMessage(result, expected);
}

fn readFollowLine(reader: *std.Io.Reader) !?[]u8 {
    const io = testing.io;
    const Result = union(enum) { line: std.Io.Reader.DelimiterError![]u8, timeout: std.Io.Cancelable!void };
    var results: [2]Result = undefined;
    var pending = std.Io.Select(Result).init(io, &results);
    defer pending.cancelDiscard();
    try pending.concurrent(.line, std.Io.Reader.takeDelimiterInclusive, .{ reader, '\n' });
    try pending.concurrent(.timeout, std.Io.sleep, .{ io, .fromSeconds(5), .awake });
    switch (try pending.await()) {
        .line => |line| return line catch |err| switch (err) {
            error.EndOfStream => if (reader.bufferedLen() == 0) null else error.MissingLineBreak,
            else => |read_error| return read_error,
        },
        .timeout => |result| {
            try result;
            return error.FollowOutputTimedOut;
        },
    }
}

fn expectReceiveStatus(result: std.json.Value, expected: []const u8) !void {
    try testing.expectEqualStrings(expected, result.object.get("status").?.string);
}

fn expectMessage(result: std.json.Value, message: []const u8) !void {
    try expectReceiveStatus(result, "message");
    try testing.expectEqualStrings(message, result.object.get("text").?.string);
}

const Receiver = struct {
    env: std.process.Environ.Map,
    id: []const u8,

    fn init(a: std.mem.Allocator, directory: []const u8, id: []const u8) !Receiver {
        var env = std.process.Environ.Map.init(a);
        try env.put("DATA_DIR", directory);
        return .{ .env = env, .id = id };
    }

    fn spawn(self: *const Receiver, argv: []const []const u8) !std.process.Child {
        return std.process.spawn(testing.io, .{
            .argv = argv,
            .environ_map = &self.env,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
    }

    fn run(self: *const Receiver, a: std.mem.Allocator, options: []const []const u8) !std.process.RunResult {
        const argv = try std.mem.concat(a, []const u8, &.{ &.{ executable, "receive", self.id }, options });
        return std.process.run(a, testing.io, .{
            .argv = argv,
            .environ_map = &self.env,
            .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
        });
    }

    fn once(self: *const Receiver, a: std.mem.Allocator, options: []const []const u8) !std.json.Value {
        const result = try self.run(a, options);
        try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        return std.json.parseFromSliceLeaky(std.json.Value, a, result.stdout, .{});
    }
};
