const std = @import("std");

pub const Command = union(enum) {
    serve,
    receive: []const u8,
    listen: []const u8,
    help: []const u8,
};

pub fn parse(args: []const []const u8) !Command {
    if (args.len == 0) return .{ .help = overview };
    if (isHelp(args[0])) return help(args[1..], overview);
    if (equal(args[0], "serve")) {
        if (args.len == 1) return .serve;
        if (isHelp(args[1])) return help(args[2..], serve_help);
        return unexpected(args[1]);
    }
    if (equal(args[0], "channel")) return parseSession(args[1..], .channel);
    if (equal(args[0], "subscription")) return parseSession(args[1..], .subscription);
    return invalid("unknown command \"{f}\". See 'ivenna --help'.", .{std.zig.fmtString(args[0])});
}

const SessionKind = enum { channel, subscription };

fn parseSession(args: []const []const u8, kind: SessionKind) error{InvalidArguments}!Command {
    const command: struct { verb: []const u8, id_label: []const u8, usage: []const u8 } = switch (kind) {
        .channel => .{ .verb = "receive", .id_label = "CHANNEL_ID", .usage = @embedFile("help/receive.txt") },
        .subscription => .{ .verb = "listen", .id_label = "SUBSCRIPTION_ID", .usage = @embedFile("help/listen.txt") },
    };
    if (args.len == 0) return .{ .help = command.usage };
    if (isHelp(args[0])) return help(args[1..], command.usage);
    if (!equal(args[0], command.verb)) {
        return invalid("unknown {t} command \"{f}\". See 'ivenna {t} --help'.", .{ kind, std.zig.fmtString(args[0]), kind });
    }
    if (args.len < 2 or args[1].len == 0) {
        return invalid("missing {s}. See 'ivenna {t} {s} --help'.", .{ command.id_label, kind, command.verb });
    }
    if (isHelp(args[1])) return help(args[2..], command.usage);
    if (args.len > 2) return unexpected(args[2]);
    return switch (kind) {
        .channel => .{ .receive = args[1] },
        .subscription => .{ .listen = args[1] },
    };
}

pub fn writeJson(io: std.Io, value: anytype) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    stdout.interface.print("{f}\n", .{std.json.fmt(value, .{})}) catch |err| return stdout.err orelse err;
    stdout.interface.flush() catch |err| return stdout.err orelse err;
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
    \\  serve                                Run the kernel.
    \\  channel receive CHANNEL_ID           Read channel messages.
    \\  subscription listen SUBSCRIPTION_ID  Send reports to a subscription.
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
