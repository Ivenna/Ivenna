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

test "command help and argument errors work without instance or service settings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const receive = try runWithoutConfig(a, &.{ executable, "receive", "--help" });
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, receive.term);
    try testing.expect(std.mem.indexOf(u8, receive.stdout, "ivenna receive [--wait MS]") != null);
    try testing.expect(std.mem.indexOf(u8, receive.stdout, "ivenna receive --follow") != null);

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

test "receive validates its arguments before reading standard input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const invalid_options = [_][]const []const u8{
        &.{"command-1"},
        &.{"--wait"},
        &.{ "--wait", "4294967296" },
        &.{ "--wait", "1.5" },
        &.{ "--follow", "--wait", "1" },
        &.{ "--wait", "1", "--follow" },
    };
    for (invalid_options) |options| {
        const argv = try std.mem.concat(a, []const u8, &.{ &.{ executable, "receive" }, options });
        const result = try runWithoutConfig(a, argv);
        try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
        try testing.expectEqualStrings("", result.stdout);
        try testing.expect(result.stderr.len != 0);
    }
    const invalid_input = try runWithoutConfig(a, &.{ executable, "receive" });
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, invalid_input.term);
    try testing.expectEqualStrings("", invalid_input.stdout);
    try testing.expect(std.mem.indexOf(u8, invalid_input.stderr, "messages mode") != null);
}

test "receive preserves one whole packet and drains before reporting closure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pipe = try MessagePipe.init();
    defer pipe.deinit();

    const first = "前半段\x00\n\"\\second half";
    const second: [4096]u8 = @splat('s');
    try pipe.write(first);
    const first_result = try pipe.receive(a, &.{});
    try testing.expectEqualStrings("message", first_result.object.get("status").?.string);
    try testing.expectEqualStrings(first, first_result.object.get("text").?.string);

    try pipe.write(&second);
    pipe.closeWriter();
    const second_result = try pipe.receive(a, &.{});
    try testing.expectEqualStrings("message", second_result.object.get("status").?.string);
    try testing.expectEqualStrings(&second, second_result.object.get("text").?.string);
    try expectReceiveStatus(try pipe.receive(a, &.{ "--wait", "4294967295" }), "closed");
}

test "receive returns empty, times out, and wakes on a packet or closure" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pipe = try MessagePipe.init();
    defer pipe.deinit();

    try expectReceiveStatus(try pipe.receive(a, &.{}), "empty");
    try expectReceiveStatus(try pipe.receive(a, &.{ "--wait", "0" }), "empty");
    try expectReceiveStatus(try pipe.receive(a, &.{ "--wait", "10" }), "timeout");
    {
        var child = try pipe.spawn(a, &.{ "--wait", "5000" });
        defer child.kill(io);
        try io.sleep(.fromMilliseconds(30), .awake);
        try pipe.write("while waiting");
        const result = try readJson(a, &child, true);
        try testing.expectEqualStrings("message", result.object.get("status").?.string);
        try testing.expectEqualStrings("while waiting", result.object.get("text").?.string);
    }
    var child = try pipe.spawn(a, &.{ "--wait", "5000" });
    defer child.kill(io);
    try io.sleep(.fromMilliseconds(30), .awake);
    pipe.closeWriter();
    try expectReceiveStatus(try readJson(a, &child, true), "closed");
}

test "receive rejects a packet containing invalid UTF-8" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pipe = try MessagePipe.init();
    defer pipe.deinit();
    try pipe.write("\xff");
    var child = try pipe.spawn(a, &.{});
    defer child.kill(io);
    var buffer: [128]u8 = undefined;
    var output = child.stdout.?.readerStreaming(io, &buffer);
    try testing.expectEqualStrings("", try output.interface.allocRemaining(a, .limited(128)));
    var diagnostics = child.stderr.?.readerStreaming(io, &buffer);
    const stderr = try diagnostics.interface.allocRemaining(a, .limited(128));
    try testing.expect(std.mem.indexOf(u8, stderr, "UTF-8") != null);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, try child.wait(io));
}

test "receive follow flushes delayed messages and drains before closing" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pipe = try MessagePipe.init();
    defer pipe.deinit();
    var child = try pipe.spawn(a, &.{"--follow"});
    defer child.kill(io);
    var buffer: [256]u8 = undefined;
    var output = child.stdout.?.readerStreaming(io, &buffer);

    try pipe.write("first message\ncontinued");
    try expectFollowMessage(a, &output.interface, "first message\ncontinued");
    try pipe.write("later 消息");
    try expectFollowMessage(a, &output.interface, "later 消息");
    try pipe.write("before closing");
    pipe.closeWriter();
    try expectFollowMessage(a, &output.interface, "before closing");
    try testing.expectEqual(null, try readFollowLine(&output.interface));
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
}

test "receive follow exits when a shell pipeline takes one message" {
    const io = testing.io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pipe = try MessagePipe.init();
    defer pipe.deinit();
    const script =
        \\{
        \\    "$1" receive --follow || printf '%s\n' 'receive failed' >&2
        \\} | {
        \\    IFS= read -r message && printf '%s\n' "$message"
        \\}
    ;
    var child = try pipe.spawnCommand(a, &.{ "/bin/sh", "-c", script, "receive-test", executable });
    defer {
        pipe.closeWriter();
        child.kill(io);
    }
    var buffer: [256]u8 = undefined;
    var output = child.stdout.?.readerStreaming(io, &buffer);
    try pipe.write("接收\n第二行");
    try expectFollowMessage(a, &output.interface, "接收\n第二行");

    // The source stays open while the pipeline and its follower finish.
    try testing.expectEqual(null, try readFollowLine(&output.interface));
    var diagnostics = child.stderr.?.readerStreaming(io, &buffer);
    try testing.expectEqual(null, try readFollowLine(&diagnostics.interface));
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
}

fn expectFollowMessage(a: std.mem.Allocator, reader: *std.Io.Reader, expected: []const u8) !void {
    const line = (try readFollowLine(reader)) orelse return error.MissingMessage;
    const result = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
    try testing.expectEqualStrings("message", result.object.get("status").?.string);
    try testing.expectEqualStrings(expected, result.object.get("text").?.string);
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

const MessagePipe = struct {
    input: std.Io.File,
    output: ?std.os.linux.fd_t,

    fn init() !MessagePipe {
        const linux = std.os.linux;
        var fds: [2]linux.fd_t = undefined;
        const rc = linux.pipe2(&fds, .{ .DIRECT = true, .NONBLOCK = true, .CLOEXEC = true });
        if (linux.errno(rc) != .SUCCESS) return error.PipeSetupFailed;
        errdefer _ = linux.close(fds[0]);
        errdefer _ = linux.close(fds[1]);
        if (linux.fcntl(fds[1], linux.F.SETPIPE_SZ, std.heap.pageSize()) != std.heap.pageSize())
            return error.PipeSetupFailed;
        return .{
            .input = .{ .handle = fds[0], .flags = .{ .nonblocking = true } },
            .output = fds[1],
        };
    }

    fn deinit(self: *MessagePipe) void {
        self.closeWriter();
        self.input.close(testing.io);
    }

    fn closeWriter(self: *MessagePipe) void {
        if (self.output) |fd| _ = std.os.linux.close(fd);
        self.output = null;
    }

    fn write(self: MessagePipe, message: []const u8) !void {
        const size = std.os.linux.write(self.output.?, message.ptr, message.len);
        try testing.expectEqual(message.len, size);
    }

    fn spawn(self: MessagePipe, a: std.mem.Allocator, options: []const []const u8) !std.process.Child {
        const argv = try std.mem.concat(a, []const u8, &.{ &.{ executable, "receive" }, options });
        return self.spawnCommand(a, argv);
    }

    fn spawnCommand(self: MessagePipe, a: std.mem.Allocator, argv: []const []const u8) !std.process.Child {
        const env = std.process.Environ.Map.init(a);
        return std.process.spawn(testing.io, .{
            .argv = argv,
            .environ_map = &env,
            .stdin = .{ .file = self.input },
            .stdout = .pipe,
            .stderr = .pipe,
        });
    }

    fn receive(self: MessagePipe, a: std.mem.Allocator, options: []const []const u8) !std.json.Value {
        var child = try self.spawn(a, options);
        defer child.kill(testing.io);
        return readJson(a, &child, true);
    }
};
