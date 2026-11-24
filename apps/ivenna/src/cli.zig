const std = @import("std");

const default_feed_after: u63 = 0;
const default_feed_limit = 100;
const max_feed_limit = 1000;

pub const Command = union(enum) {
    serve,
    feed: Feed,
    subscription: Subscription,
    help: []const u8,
};

const Feed = struct {
    feed_id: []const u8,
    after: u63,
    limit: u32,
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
    if (equal(args[0], "feed")) return parseFeed(args[1..]);
    if (equal(args[0], "subscription")) return parseSubscription(args[1..]);
    return invalid("unknown command \"{f}\". See 'ivenna --help'.", .{std.zig.fmtString(args[0])});
}

fn parseFeed(args: []const []const u8) !Command {
    if (args.len == 0) return .{ .help = feed_help };
    if (isHelp(args[0])) return help(args[1..], feed_help);
    const rest = args[1..];
    if (!equal(args[0], "read"))
        return invalid("unknown feed command \"{f}\". See 'ivenna feed --help'.", .{std.zig.fmtString(args[0])});
    if (rest.len == 0) return invalid("missing FEED_ID. See 'ivenna feed read --help'.", .{});
    const id = rest[0];
    if (isHelp(id)) return help(rest[1..], feed_help);
    var after: ?u63 = null;
    var limit: ?u32 = null;
    const options = rest[1..];
    var i: usize = 0;
    while (i < options.len) : (i += 2) {
        const option = options[i];
        if (equal(option, "--after") and after == null) {
            after = try decimal(u63, options[i..]);
        } else if (equal(option, "--limit") and limit == null) {
            const value = try decimal(u32, options[i..]);
            if (value == 0 or value > max_feed_limit)
                return invalid("--limit must be between 1 and {d}", .{max_feed_limit});
            limit = value;
        } else return unexpected(option);
    }
    return .{ .feed = .{
        .feed_id = id,
        .after = after orelse default_feed_after,
        .limit = limit orelse default_feed_limit,
    } };
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

fn decimal(comptime Int: type, args: []const []const u8) !Int {
    if (args.len < 2) return invalid("missing value for {s}", .{args[0]});
    const value = args[1];
    for (value) |byte| {
        if (!std.ascii.isDigit(byte)) return invalid("expected a decimal integer for {s}", .{args[0]});
    }
    return std.fmt.parseUnsigned(Int, value, 10) catch
        return invalid("decimal integer out of range for {s}", .{args[0]});
}

fn help(args: []const []const u8, usage: []const u8) !Command {
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
    \\  feed           Read a feed by ID.
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

const feed_help = std.fmt.comptimePrint(@embedFile("help/feed-read.txt"), .{
    default_feed_after,
    std.math.maxInt(@FieldType(Feed, "after")),
    default_feed_limit,
    max_feed_limit,
}) ++ "\n" ++ environment;

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
