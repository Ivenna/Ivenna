const std = @import("std");

pub const Command = enum { inspect, publish, checkpoint };

pub const Request = struct {
    command: Command,
    reference: []const u8,
};

/// A null request means the requested help was printed.
pub fn read(init: std.process.Init) !?Request {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return invalid("missing command. See 'ivenna-report --help'.", .{});
    if (isHelp(args[1])) {
        if (args.len > 2) return unexpected(args[2]);
        try std.Io.File.stdout().writeStreamingAll(init.io, full_help);
        return null;
    }
    const command = std.meta.stringToEnum(Command, args[1]) orelse
        return invalid("unknown command \"{f}\". See 'ivenna-report --help'.", .{std.zig.fmtString(args[1])});
    if (args.len < 3) return invalid("missing SUBSCRIPTION_ID for '{t}'. See 'ivenna-report {t} --help'.", .{ command, command });
    if (args.len > 3) return unexpected(args[3]);
    if (isHelp(args[2])) {
        try std.Io.File.stdout().writeStreamingAll(init.io, switch (command) {
            .inspect => inspect ++ "\n" ++ environment,
            .publish => publish ++ "\n" ++ writes ++ "\n" ++ environment,
            .checkpoint => checkpoint ++ "\n" ++ writes ++ "\n" ++ environment,
        });
        return null;
    }
    return .{ .command = command, .reference = args[2] };
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

fn unexpected(arg: []const u8) error{InvalidArguments} {
    return invalid("unexpected argument \"{f}\". See 'ivenna-report --help'.", .{std.zig.fmtString(arg)});
}

fn invalid(comptime format: []const u8, args: anytype) error{InvalidArguments} {
    std.log.err(format, args);
    return error.InvalidArguments;
}

const inspect = @embedFile("help/inspect.txt");
const publish = @embedFile("help/publish.txt");
const checkpoint = @embedFile("help/checkpoint.txt");
const writes = @embedFile("help/writes.txt");

const full_help = overview ++ "\n" ++ environment ++ "\n" ++ inspect ++ "\n" ++ publish ++ "\n" ++ checkpoint ++ "\n" ++ writes;

const overview =
    \\Usage: ivenna-report COMMAND SUBSCRIPTION_ID
    \\       ivenna-report [COMMAND] (-h | --help)
    \\
    \\Use inspect to read a subscription, publish to report an observation, or
    \\checkpoint to save a position after skipping an item.
    \\
;

const environment =
    \\Use the complete ID returned by subscribe in place of releases-1.
    \\Ivenna's host commands inherit IVENNA_REPORT (the path to this executable)
    \\and DATA_DIR (the kernel's data directory). In another shell, export DATA_DIR
    \\and set IVENNA_REPORT for the examples. A relative DATA_DIR resolves from
    \\the reporter's current directory.
    \\
;
