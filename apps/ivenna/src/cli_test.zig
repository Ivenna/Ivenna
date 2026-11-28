const std = @import("std");
const agent = @import("agent");
const state = @import("instance_state");
const contracts = @import("agent_contracts");
const channel_ipc = @import("channel_ipc.zig");
const Config = @import("config.zig").Config;
const Registry = @import("channels.zig").Registry;
const testing = std.testing;
const executable = @import("app_options").executable;

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

test "help exposes the session commands and retired commands fail before configuration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const receive = try runWithoutConfig(a, &.{ executable, "channel", "receive", "--help" });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, receive.term);
    try testing.expect(std.mem.indexOf(u8, receive.stdout, "ivenna channel receive CHANNEL_ID") != null);
    const listen = try runWithoutConfig(a, &.{ executable, "subscription", "listen", "--help" });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, listen.term);
    try testing.expect(std.mem.indexOf(u8, listen.stdout, "ivenna subscription listen SUBSCRIPTION_ID") != null);

    for ([_][]const []const u8{
        &.{ executable, "receive", "events-1" },
        &.{ executable, "channel", "receive", "events-1", "--timeout", "100" },
        &.{ executable, "subscription", "publish", "news-1" },
    }) |argv| {
        const result = try runWithoutConfig(a, argv);
        try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expect(std.mem.indexOf(u8, result.stderr, "DATA_DIR") == null);
    }
}

test "a subscription listener streams writes without the kernel and stops after withdrawal" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var fixture = try SubscriptionFixture.init(a, temporary.dir);
    const owner = &fixture.store;
    defer owner.close();
    const id = (try owner.create(a, "research-2", "-release watch", "test listener")).subscription_id;
    try testing.expectEqualDeep(@as([]const []const u8, &.{id}), try owner.subscriptionsWithoutListeners(a, "research-2", 1));
    var child = try fixture.listen(id, .inherit);
    defer child.kill(io);
    const input = child.stdin.?;
    var buffer: [256]u8 = undefined;
    var output = child.stdout.?.readerStreaming(io, &buffer);
    const reader = &output.interface;

    try testing.expectEqualStrings("ready", (try readJsonLine(a, reader)).string);
    try testing.expectEqual(0, (try owner.subscriptionsWithoutListeners(a, "research-2", 1)).len);

    for ([_][]const u8{
        "{\"key\":\"item-17\",\"text\":\"New release\",\"cursor\":{\"to\":\"17\"}}\n",
        "{\"key\":[105,116,101,109,45,49,55],\"text\":\"New release\"}\n",
    }) |line| {
        try input.writeStreamingAll(io, line);
        try testing.expectEqualStrings("invalid_request", (try readJsonLine(a, reader)).string);
    }

    const report = "{\"key\":\"item-17\",\"text\":\"New release\",\"source_time_unix_ms\":123}\n";
    try input.writeStreamingAll(io, report);
    try testing.expectEqualStrings("accepted", (try readJsonLine(a, reader)).string);
    try input.writeStreamingAll(io, report);
    try testing.expectEqualStrings("accepted", (try readJsonLine(a, reader)).string);

    try testing.expect(try owner.withdraw(id));
    try input.writeStreamingAll(io, report);
    try testing.expectEqualStrings("withdrawn", (try readJsonLine(a, reader)).string);
    try testing.expectEqual(null, try readOutputLine(reader));
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, try child.wait(io));

    const through = try owner.latestSequence("research-2");
    const pending = try owner.pending(a, "research-2", 0, through, 2);
    try testing.expectEqual(1, pending.len);
    try testing.expectEqualStrings(id, pending[0].reference);
    try testing.expectEqualStrings("New release", pending[0].text);
    try testing.expectEqual(@as(?i64, 123), pending[0].source_time_unix_ms);
}

test "a subscription listener accepts a final report at EOF without a newline" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var fixture = try SubscriptionFixture.init(a, temporary.dir);
    const owner = &fixture.store;
    defer owner.close();
    const id = (try owner.create(a, "research-2", "-release watch", "test listener")).subscription_id;
    var child = try fixture.listen(id, .inherit);
    defer child.kill(io);
    const input = child.stdin.?;
    var buffer: [256]u8 = undefined;
    var output = child.stdout.?.readerStreaming(io, &buffer);
    const reader = &output.interface;

    try testing.expectEqualStrings("ready", (try readJsonLine(a, reader)).string);
    try input.writeStreamingAll(io, "{\"key\":\"item-18\",\"text\":\"Final line\"}");
    // EOF delivers the buffered final line; the listener must reply before exiting.
    input.close(io);
    child.stdin = null;
    try testing.expectEqualStrings("accepted", (try readJsonLine(a, reader)).string);
    try testing.expectEqual(null, try readOutputLine(reader));
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));

    const through = try owner.latestSequence("research-2");
    const pending = try owner.pending(a, "research-2", 0, through, 2);
    try testing.expectEqual(1, pending.len);
    try testing.expectEqualStrings("Final line", pending[0].text);
}

test "a subscription listener rejects an oversized line with invalid_request" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var fixture = try SubscriptionFixture.init(a, temporary.dir);
    const owner = &fixture.store;
    defer owner.close();
    const id = (try owner.create(a, "research-2", "-release watch", "test listener")).subscription_id;
    var child = try fixture.listen(id, .inherit);
    defer child.kill(io);
    const input = child.stdin.?;
    var buffer: [256]u8 = undefined;
    var output = child.stdout.?.readerStreaming(io, &buffer);
    const reader = &output.interface;
    try testing.expectEqualStrings("ready", (try readJsonLine(a, reader)).string);

    var oversize: [65_538]u8 = @splat('x');
    try input.writeStreamingAll(io, &oversize);
    try testing.expectEqualStrings("invalid_request", (try readJsonLine(a, reader)).string);
    try testing.expectEqual(null, try readOutputLine(reader));
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, try child.wait(io));
}

test "an unknown subscription reports withdrawn before ready" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var fixture = try SubscriptionFixture.init(a, temporary.dir);
    defer fixture.store.close();
    const result = try std.process.run(a, testing.io, .{
        .argv = &.{ executable, "subscription", "listen", "missing-1" },
        .environ_map = &fixture.env,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    });
    try testing.expectEqualStrings("\"withdrawn\"\n", result.stdout);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
}

test "losing an accepted subscription receipt leaves the report stored" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var fixture = try SubscriptionFixture.init(a, temporary.dir);
    defer fixture.store.close();
    const focus = "research-2";
    const id = (try fixture.store.create(a, focus, "release", "test listener")).subscription_id;

    var child = try fixture.listen(id, .pipe);
    defer child.kill(io);
    var buffer: [256]u8 = undefined;
    var output = child.stdout.?.readerStreaming(io, &buffer);
    try testing.expectEqualStrings("ready", (try readJsonLine(a, &output.interface)).string);
    child.stdout.?.close(io);
    child.stdout = null;
    try child.stdin.?.writeStreamingAll(io, "{\"key\":\"item-19\",\"text\":\"New release\"}\n");

    var diagnostics = child.stderr.?.readerStreaming(io, &buffer);
    const diagnostic = (try readOutputLine(&diagnostics.interface)) orelse return error.MissingOutputLine;
    try testing.expect(std.mem.indexOf(u8, diagnostic, "the report was accepted") != null);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, try child.wait(io));

    const through = try fixture.store.latestSequence(focus);
    const pending = try fixture.store.pending(a, focus, 0, through, 2);
    try testing.expectEqual(1, pending.len);
    try testing.expectEqualStrings("New release", pending[0].text);
}

test "channel receive requires the instance data directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const missing_data_dir = try runWithoutConfig(a, &.{ executable, "channel", "receive", "events-1" });
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, missing_data_dir.term);
    try testing.expectEqualStrings("", missing_data_dir.stdout);
    try testing.expect(std.mem.indexOf(u8, missing_data_dir.stderr, "DATA_DIR") != null);
}

test "a channel delivers one message per read and tracks the receiver session" {
    const io = testing.io;
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
    const id = "events-1";
    try channels.reserve(id);
    try expectSendOutcome(channels, id, "before activation", .unknown_channel);
    {
        const reserved = try channel_ipc.connect(io, directory, id);
        defer reserved.close(io);
        try expectReceiveReply(reserved, .unknown_channel);
    }
    channels.activate(id);
    try testing.expectEqual(@as(?bool, false), try channels.hasReceiver(id));
    try expectSendOutcome(channels, id, "before any receiver", .no_receiver);

    const oversize: [contracts.Channels.max_message_bytes + 1]u8 = @splat('x');
    const maximum = oversize[0..contracts.Channels.max_message_bytes];
    try expectSendOutcome(channels, id, &oversize, .too_long);
    {
        const receiver = try channel_ipc.connect(io, directory, id);
        defer receiver.close(io);
        try expectReceiveReply(receiver, .waiting);
        try testing.expectEqual(@as(?bool, true), try channels.hasReceiver(id));
        try expectSendOutcome(channels, id, maximum, .accepted);
        try expectReceiveReply(receiver, .{ .message = maximum });
        try testing.expectEqual(@as(?bool, true), try channels.hasReceiver(id));
        try expectSendOutcome(channels, id, "no pending read", .would_block);
    }
    try testing.expectEqual(@as(?bool, false), try channels.hasReceiver(id));
    try expectSendOutcome(channels, id, "no connection", .no_receiver);

    const replacement = try channel_ipc.connect(io, directory, id);
    defer replacement.close(io);
    try expectReceiveReply(replacement, .waiting);
    try expectSendOutcome(channels, id, "for the next receiver", .accepted);
    try expectReceiveReply(replacement, .{ .message = "for the next receiver" });
}

test "channel receive flushes successive matches and exits when its channel closes" {
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
    channels.activate(receiver.id);
    const waiting = try channel_ipc.connect(io, directory, receiver.id);
    defer waiting.close(io);
    try expectReceiveReply(waiting, .waiting);
    try expectSendOutcome(channels, receiver.id, "queued before close", .accepted);
    try expectSendOutcome(channels, receiver.id, "before the next request", .would_block);

    var child = try receiver.spawn(&.{ executable, "channel", "receive", receiver.id });
    defer child.kill(io);
    var buffer: [256]u8 = undefined;
    var output = child.stdout.?.readerStreaming(io, &buffer);

    const first = "前半段\x00\n\"\\second half";
    try expectSendOutcome(channels, receiver.id, first, .accepted);
    try expectChannelMessage(a, &output.interface, first);
    try expectSendOutcome(channels, receiver.id, "matched before closing", .accepted);
    channels.close(receiver.id);
    var descriptors = [_]std.posix.pollfd{.{ .fd = waiting.socket.handle, .events = 0, .revents = 0 }};
    try testing.expect(try std.posix.poll(&descriptors, 5000) != 0);
    try testing.expect(descriptors[0].revents & std.posix.POLL.HUP != 0);
    try channel_ipc.requestNext(waiting);
    try expectReceiveReply(waiting, .{ .message = "queued before close" });
    try expectReceiveReply(waiting, .closed);
    try expectChannelMessage(a, &output.interface, "matched before closing");
    try testing.expectEqual(null, try readOutputLine(&output.interface));
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));

    const unknown = try receiver.run(a);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, unknown.term);
    try testing.expectEqualStrings("", unknown.stdout);
    try testing.expect(std.mem.indexOf(u8, unknown.stderr, "CHANNEL_ID") != null);
    try expectSendOutcome(channels, receiver.id, "late", .unknown_channel);
}

test "channel receive exits when a shell pipeline takes one message" {
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
        \\    "$1" channel receive "$2" || printf '%s\n' 'receive failed' >&2
        \\} | {
        \\    IFS= read -r message && printf '%s\n' "$message"
        \\}
    ;
    var child = try receiver.spawn(&.{ "/bin/sh", "-c", script, "receive-test", executable, receiver.id });
    defer child.kill(io);
    var buffer: [256]u8 = undefined;
    var output = child.stdout.?.readerStreaming(io, &buffer);
    try expectSendOutcome(channels, receiver.id, "接收\n第二行", .accepted);
    try expectChannelMessage(a, &output.interface, "接收\n第二行");

    // The source stays open while the pipeline and its follower finish.
    try testing.expectEqual(null, try readOutputLine(&output.interface));
    var diagnostics = child.stderr.?.readerStreaming(io, &buffer);
    try testing.expectEqual(null, try readOutputLine(&diagnostics.interface));
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
}

test "channel receive exits successfully when its output pipe closes during a matched write" {
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
            .argv = &.{ executable, "channel", "receive", receiver.id },
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
    try testing.expectEqual(null, try readOutputLine(&diagnostics.interface));
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
}

fn expectSendOutcome(channels: contracts.Channels, id: []const u8, message: []const u8, expected: contracts.Channels.SendOutcome) !void {
    const io = testing.io;
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(5));
    while (true) {
        const outcome = try channels.trySend(id, message);
        const retrying = outcome != expected and (outcome == .would_block or (outcome == .no_receiver and expected == .accepted));
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

fn expectChannelMessage(a: std.mem.Allocator, reader: *std.Io.Reader, expected: []const u8) !void {
    try expectMessage(try readJsonLine(a, reader), expected);
}

fn readJsonLine(a: std.mem.Allocator, reader: *std.Io.Reader) !std.json.Value {
    const line = (try readOutputLine(reader)) orelse return error.MissingOutputLine;
    return std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
}

fn readOutputLine(reader: *std.Io.Reader) !?[]u8 {
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
            return error.OutputTimedOut;
        },
    }
}

fn expectMessage(result: std.json.Value, message: []const u8) !void {
    try testing.expectEqual(1, result.object.count());
    try testing.expectEqualStrings(message, result.object.get("text").?.string);
}

const SubscriptionFixture = struct {
    store: state.subscriptions.Store,
    env: std.process.Environ.Map,

    fn init(a: std.mem.Allocator, directory: std.Io.Dir) !SubscriptionFixture {
        const path = try directory.realPathFileAlloc(testing.io, ".", a);
        const database = try std.fs.path.join(a, &.{ path, state.filename });
        var env = std.process.Environ.Map.init(a);
        try env.put("DATA_DIR", path);
        return .{ .store = try state.subscriptions.Store.initialize(a, testing.io, database, null), .env = env };
    }

    fn listen(self: *const SubscriptionFixture, id: []const u8, stderr: std.process.SpawnOptions.StdIo) !std.process.Child {
        return std.process.spawn(testing.io, .{
            .argv = &.{ executable, "subscription", "listen", id },
            .environ_map = &self.env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = stderr,
        });
    }
};

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

    fn run(self: *const Receiver, a: std.mem.Allocator) !std.process.RunResult {
        return std.process.run(a, testing.io, .{
            .argv = &.{ executable, "channel", "receive", self.id },
            .environ_map = &self.env,
            .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
        });
    }
};
