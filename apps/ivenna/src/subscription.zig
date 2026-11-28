const std = @import("std");
const state = @import("instance_state");
const subscriptions = state.subscriptions;
const cli = @import("cli.zig");
const Allocator = std.mem.Allocator;

const max_line_bytes = 65_536;
const Receipt = enum { ready, accepted, invalid_request, withdrawn, busy, storage_full };

pub fn run(init: std.process.Init, id: []const u8) u8 {
    runSession(init, id) catch |err| {
        if (errorReceipt(err)) |receipt| {
            // writeReceipt owns the diagnostic if stdout cannot take the terminal reply.
            writeReceipt(init.io, receipt) catch {};
        } else switch (err) {
            error.MissingDataDirectory, error.StateStorageFailed, error.ReceiptWriteFailed => {},
            error.IncompatibleStateSchema => std.log.err("this listener requires the instance database schema for its build. Check DATA_DIR and use the same build as the kernel. After updating, start 'ivenna serve' before connecting listeners", .{}),
            else => std.log.err("{s}", .{@errorName(err)}),
        }
        return 1;
    };
    return 0;
}

fn runSession(init: std.process.Init, id: []const u8) !void {
    const a = init.arena.allocator();
    const directory = init.environ_map.get("DATA_DIR") orelse "";
    if (directory.len == 0) {
        std.log.err("set DATA_DIR to the instance's data directory", .{});
        return error.MissingDataDirectory;
    }
    const path = try std.fs.path.join(a, &.{ directory, state.filename });
    var listener = try subscriptions.Listener.open(a, init.io, path, id);
    defer listener.close();
    try listen(init.gpa, init.io, &listener);
}

fn listen(a: Allocator, io: std.Io, listener: *subscriptions.Listener) !void {
    try writeReceipt(io, .ready);

    var buffer: [max_line_bytes + 1]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(io, &buffer);
    while (true) {
        const line = input.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.InvalidArguments,
            error.ReadFailed => return input.err orelse err,
        } orelse return;

        var frame = std.heap.ArenaAllocator.init(a);
        defer frame.deinit();
        const receipt: Receipt = if (publishLine(frame.allocator(), io, listener, line)) .accepted else |err| switch (err) {
            error.SubscriptionWithdrawn => return err,
            else => errorReceipt(err) orelse return err,
        };
        try writeReceipt(io, receipt);
    }
}

fn publishLine(a: Allocator, io: std.Io, listener: *subscriptions.Listener, line: []const u8) !void {
    const report = std.json.parseFromSliceLeaky(Report, a, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidArguments,
    };
    try listener.publish(report.value(), std.Io.Clock.real.now(io).toMilliseconds());
}

fn errorReceipt(err: anyerror) ?Receipt {
    return switch (err) {
        error.InvalidArguments => .invalid_request,
        error.SubscriptionWithdrawn => .withdrawn,
        error.StateStoreBusy => .busy,
        error.StateStoreFull => .storage_full,
        else => null,
    };
}

fn writeReceipt(io: std.Io, receipt: Receipt) error{ReceiptWriteFailed}!void {
    cli.writeJson(io, @tagName(receipt)) catch |err| {
        if (receipt == .accepted) {
            std.log.err("the report was accepted. Its receipt could not be written ({s}). Retry with its original key to confirm", .{@errorName(err)});
        } else {
            std.log.err("could not write subscription reply '{t}' ({s})", .{ receipt, @errorName(err) });
        }
        return error.ReceiptWriteFailed;
    };
}

const Report = struct {
    key: Scalar([]const u8),
    text: Scalar([]const u8),
    source_time_unix_ms: ?Scalar(i64) = null,

    fn value(self: Report) subscriptions.NewReport {
        return .{
            .key = self.key.value,
            .text = self.text.value,
            .source_time_unix_ms = if (self.source_time_unix_ms) |time| time.value else null,
        };
    }
};

// Require JSON strings for text and JSON numbers for timestamps.
fn Scalar(comptime T: type) type {
    return struct {
        value: T,

        pub fn jsonParse(a: Allocator, json: *std.json.Scanner, options: std.json.ParseOptions) !@This() {
            const expected: std.json.TokenType = if (T == []const u8) .string else .number;
            if (try json.peekNextTokenType() != expected) return error.UnexpectedToken;
            return .{ .value = try std.json.innerParse(T, a, json, options) };
        }
    };
}
