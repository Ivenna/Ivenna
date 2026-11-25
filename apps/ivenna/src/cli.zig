const std = @import("std");

pub const Command = union(enum) {
    serve,
    receive: Receive,
    subscription: Subscription,
    help: []const u8,
};

pub const Receive = struct {
    id: []const u8,
    mode: union(enum) { once: ?u32, follow },
};

const Subscription = struct {
    action: enum { inspect, publish, checkpoint },
    id: []const u8,
};

pub fn parse(args: []const []const u8) !Command {
    if (args.len == 0) return .{ .help = overview };
    if (isHelp(args[0])) return help(args[1..], overview);
    if (equal(args[0], "serve")) {
        if (args.len == 1) return .serve;
        if (isHelp(args[1])) return help(args[2..], serve_help);
        return unexpected(args[1]);
    }
    if (equal(args[0], "receive")) return parseReceive(args[1..]) catch return error.InvalidReceiveArguments;
    if (equal(args[0], "subscription")) return parseSubscription(args[1..]);
    return invalid("unknown command \"{f}\". See 'ivenna --help'.", .{std.zig.fmtString(args[0])});
}

fn parseReceive(args: []const []const u8) error{InvalidArguments}!Command {
    if (args.len == 0 or args[0].len == 0)
        return invalid("missing CHANNEL_ID. See 'ivenna receive --help'.", .{});
    if (isHelp(args[0])) return help(args[1..], receive_help);
    const id = args[0];
    const options = args[1..];
    if (options.len == 0) return .{ .receive = .{ .id = id, .mode = .{ .once = null } } };
    if (equal(options[0], "--follow")) {
        if (options.len > 1) return unexpected(options[1]);
        return .{ .receive = .{ .id = id, .mode = .follow } };
    }
    if (!equal(options[0], "--timeout")) return unexpected(options[0]);
    const timeout_ms = try decimal(u32, options);
    if (timeout_ms == 0) return invalid("--timeout requires a positive duration in milliseconds", .{});
    if (options.len > 2) return unexpected(options[2]);
    return .{ .receive = .{ .id = id, .mode = .{ .once = timeout_ms } } };
}

pub fn writeJson(io: std.Io, value: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    stdout.interface.print("{f}\n", .{std.json.fmt(value, .{})}) catch |err| return stdout.err orelse err;
    stdout.interface.flush() catch |err| return stdout.err orelse err;
}

fn parseSubscription(args: []const []const u8) !Command {
    if (args.len == 0) return .{ .help = subscription_help };
    if (isHelp(args[0])) return help(args[1..], subscription_help);
    const action = std.meta.stringToEnum(@FieldType(Subscription, "action"), args[0]) orelse
        return invalid("unknown subscription command \"{f}\". See 'ivenna subscription --help'.", .{std.zig.fmtString(args[0])});
    if (args.len < 2)
        return invalid("missing SUBSCRIPTION_ID. See 'ivenna subscription {t} --help'.", .{action});
    if (args.len > 2) return unexpected(args[2]);
    if (isHelp(args[1])) return .{ .help = switch (action) {
        .inspect => inspect ++ "\n" ++ environment,
        .publish => publish ++ "\n" ++ writes ++ "\n" ++ environment,
        .checkpoint => checkpoint ++ "\n" ++ writes ++ "\n" ++ environment,
    } };
    return .{ .subscription = .{ .action = action, .id = args[1] } };
}

fn decimal(comptime Int: type, args: []const []const u8) error{InvalidArguments}!Int {
    if (args.len < 2) return invalid("missing value for {s}", .{args[0]});
    const value = args[1];
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return invalid("expected a decimal integer for {s}", .{args[0]});
    }
    return std.fmt.parseUnsigned(Int, value, 10) catch
        return invalid("decimal integer out of range for {s}", .{args[0]});
}

fn help(args: []const []const u8, usage: []const u8) error{InvalidArguments}!Command {
    if (args.len != 0) return unexpected(args[0]);
    return .{ .help = usage };
}

fn isHelp(arg: []const u8) bool {
    return equal(arg, "-h") or equal(arg, "--help");
}

fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

fn unexpected(arg: []const u8) error{InvalidArguments} {
    return invalid("unexpected argument \"{f}\"", .{std.zig.fmtString(arg)});
}

fn invalid(comptime format: []const u8, args: anytype) error{InvalidArguments} {
    std.log.err(format, args);
    return error.InvalidArguments;
}

const overview =
    \\ivenna COMMAND [ARGUMENTS]
    \\
    \\  serve          Run the kernel.
    \\  receive        Read messages from an open channel.
    \\  subscription   Report observations and save source positions.
    \\
    \\Run ivenna COMMAND --help for command usage.
    \\
;

const serve_help =
    \\ivenna serve
    \\
    \\Run the kernel with service settings from the environment. The current
    \\directory is the starting point for file browsing and host commands.
    \\See docs/running.md for configuration.
    \\
;

const environment =
    \\Set DATA_DIR to the directory containing the instance database. Relative
    \\paths resolve from the current directory. These commands work while the
    \\kernel is stopped. Ivenna host commands inherit absolute paths in DATA_DIR
    \\and IVENNA and can call the executable as "$IVENNA".
    \\
;

const receive_help = std.fmt.comptimePrint(@embedFile("help/receive.txt"), .{std.math.maxInt(u32)});

const inspect = @embedFile("help/inspect.txt");
const publish = @embedFile("help/publish.txt");
const checkpoint = @embedFile("help/checkpoint.txt");
const writes = @embedFile("help/writes.txt");
const subscription_help =
    \\ivenna subscription COMMAND SUBSCRIPTION_ID
    \\
    \\Use the subscription ID returned by Ivenna's subscribe tool.
    \\
    \\  inspect      Read the registration and saved cursor.
    \\  publish      Queue an observation and optionally save a cursor.
    \\  checkpoint   Save a cursor without queuing an observation.
    \\
    \\Run ivenna subscription COMMAND --help for examples and command results.
    \\
++ "\n" ++ environment;
