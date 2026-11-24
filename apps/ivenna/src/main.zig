const std = @import("std");
const state = @import("instance_state");
const contracts = @import("agent_contracts");
const cli = @import("cli.zig");
const serve = @import("serve.zig");
const subscription = @import("subscription.zig");

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const command = cli.parse(args[1..]) catch |err| return failure(init.io, err);
    switch (command) {
        .serve => try serve.run(init),
        .help => |help| try std.Io.File.stdout().writeStreamingAll(init.io, help),
        .receive => |options| receive(init.io, options) catch |err| return failure(init.io, err),
        .subscription => |request| runSubscription(init, request) catch |err| return failure(init.io, err),
    }
    return 0;
}

fn runSubscription(init: std.process.Init, request: @FieldType(cli.Command, "subscription")) !void {
    const a = init.arena.allocator();
    const directory = init.environ_map.get("DATA_DIR") orelse "";
    if (directory.len == 0) {
        std.log.err("set DATA_DIR to the instance's data directory", .{});
        return error.MissingDataDirectory;
    }
    const path = try std.fs.path.join(a, &.{ directory, state.filename });
    var store = try state.subscriptions.Store.open(a, path);
    defer store.close();
    switch (request.action) {
        .inspect => try writeJson(init.io, try store.inspect(a, request.id)),
        .publish => try writeJson(init.io, try subscription.publish(a, init.io, &store, request.id)),
        .checkpoint => {
            try subscription.checkpoint(a, init.io, &store, request.id);
            try writeJson(init.io, "accepted");
        },
    }
}

fn receive(io: std.Io, options: cli.Receive) !void {
    const linux = std.os.linux;
    const stdin = std.Io.File.stdin();
    const flags = linux.fcntl(stdin.handle, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return error.InvalidReceiveInput;
    const mode: linux.O = @bitCast(@as(u32, @intCast(flags)));
    if (mode.ACCMODE != .RDONLY or !mode.NONBLOCK or (try stdin.stat(io)).kind != .named_pipe)
        return error.InvalidReceiveInput;
    var message: [contracts.Channels.max_bytes]u8 = undefined;
    switch (options) {
        .once => |wait_ms| try receiveOne(io, stdin.handle, &message, wait_ms),
        .follow => try followMessages(io, stdin.handle, &message),
    }
}

fn receiveOne(io: std.Io, fd: std.posix.fd_t, message: []u8, wait_ms: u32) !void {
    const posix = std.posix;
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(wait_ms));
    var input = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    while (true) {
        const text = readMessage(fd, message) catch |err| switch (err) {
            error.WouldBlock => {
                if (wait_ms == 0) return writeJson(io, .{ .status = "empty" });
                if (!try poll(io, &input, deadline)) return writeJson(io, .{ .status = "timeout" });
                if (input[0].revents & (posix.POLL.IN | posix.POLL.HUP) == 0)
                    return error.InvalidReceiveInput;
                continue;
            },
            else => return err,
        };
        if (text) |value| return writeJson(io, .{ .status = "message", .text = value });
        return writeJson(io, .{ .status = "closed" });
    }
}

fn followMessages(io: std.Io, fd: std.posix.fd_t, message: []u8) !void {
    const posix = std.posix;
    var descriptors = [_]posix.pollfd{
        .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 },
        // Watch the output for closure without waiting on writability.
        .{ .fd = std.Io.File.stdout().handle, .events = 0, .revents = 0 },
    };
    while (true) {
        _ = try poll(io, &descriptors, null);
        if (descriptors[1].revents != 0) return;
        if (descriptors[0].revents & (posix.POLL.IN | posix.POLL.HUP) == 0)
            return error.InvalidReceiveInput;
        const text = (readMessage(fd, message) catch |err| switch (err) {
            error.WouldBlock => continue,
            else => return err,
        }) orelse return;
        writeJson(io, .{ .status = "message", .text = text }) catch |err| switch (err) {
            error.BrokenPipe => return,
            else => return err,
        };
    }
}

fn readMessage(fd: std.posix.fd_t, buffer: []u8) !?[]const u8 {
    const size = try std.posix.read(fd, buffer);
    if (size == 0) return null;
    const text = buffer[0..size];
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidMessage;
    return text;
}

fn poll(io: std.Io, descriptors: []std.posix.pollfd, deadline: ?std.Io.Timestamp) !bool {
    const posix = std.posix;
    while (true) {
        const timeout: ?posix.timespec = if (deadline) |end| for_wait: {
            const remaining = std.Io.Clock.awake.now(io).durationTo(end).toNanoseconds();
            if (remaining <= 0) return false;
            break :for_wait .{
                .sec = @intCast(@divTrunc(remaining, std.time.ns_per_s)),
                .nsec = @intCast(@rem(remaining, std.time.ns_per_s)),
            };
        } else null;
        const ready = posix.ppoll(descriptors, if (timeout) |*value| value else null, null) catch |err| switch (err) {
            error.SignalInterrupt => continue,
            else => return err,
        };
        return ready != 0;
    }
}

fn failure(io: std.Io, err: anyerror) !u8 {
    const reason: []const u8 = switch (err) {
        error.InvalidArguments => "invalid_request",
        error.SubscriptionWithdrawn => "withdrawn",
        error.CursorConflict => "cursor_conflict",
        error.StateStoreBusy => "busy",
        error.StateStoreFull => "storage_full",
        error.InvalidReceiveArguments, error.MissingDataDirectory, error.StateStorageFailed => return 1,
        error.InvalidReceiveInput => {
            std.log.err("run receive inside a host command in messages mode with its stdin inherited", .{});
            return 1;
        },
        error.InvalidMessage => {
            std.log.err("the input message contains invalid UTF-8", .{});
            return 1;
        },
        else => {
            std.log.err("{s}", .{@errorName(err)});
            return 1;
        },
    };
    try writeJson(io, reason);
    return 1;
}

fn writeJson(io: std.Io, value: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    stdout.interface.print("{f}\n", .{std.json.fmt(value, .{})}) catch |err| return stdout.err orelse err;
    stdout.interface.flush() catch |err| return stdout.err orelse err;
}
