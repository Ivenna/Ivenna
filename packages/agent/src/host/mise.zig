const std = @import("std");
const process = @import("process.zig");
const toml = @import("toml");
const Catalog = @import("catalog.zig").Catalog;

const Allocator = std.mem.Allocator;

/// Resolves deployment configuration before a command is started. The returned
/// environment belongs to the caller and never enters a tool reply.
pub fn prepareEnvironment(a: Allocator, io: std.Io, directory: []const u8, base: *const std.process.Environ.Map, deadline: std.Io.Clock.Timestamp) !std.process.Environ.Map {
    const remaining_ms = deadline.durationFromNow(io).raw.toMilliseconds();
    if (remaining_ms <= 0) return error.Timeout;
    const preparation_ms: u32 = @intCast(@min(30_000, remaining_ms));
    const result = process.capture(a, io, &.{ "mise", "-C", directory, "exec", "--", "/usr/bin/env", "-0" }, directory, base, preparation_ms, 1024 * 1024) catch |err| switch (err) {
        error.Canceled, error.OutOfMemory => return err,
        error.Timeout => {
            if (deadline.durationFromNow(io).raw.toMilliseconds() <= 0) return error.Timeout;
            std.log.err("mise environment preparation timed out", .{});
            return error.EnvironmentUnavailable;
        },
        else => {
            std.log.err("mise environment preparation failed: {s}", .{@errorName(err)});
            return error.EnvironmentUnavailable;
        },
    };
    if (!result.term.success()) {
        std.log.err("mise environment preparation failed ({f}): {s}", .{ result.term, result.stderr });
        return error.EnvironmentUnavailable;
    }
    if (result.stderr.len != 0) std.log.warn("mise environment preparation: {s}", .{result.stderr});

    // Resolved variable values may contain credentials. Never log this output.
    // A complete snapshot also preserves declarations that unset inherited
    // variables, which an overlay of newly set values would lose.
    var environment: std.process.Environ.Map = .init(a);
    errdefer environment.deinit();
    var entries = std.mem.splitScalar(u8, result.stdout, 0);
    while (entries.next()) |entry| {
        if (entry.len == 0) continue;
        const separator = std.mem.indexOfScalar(u8, entry, '=') orelse {
            std.log.err("mise returned an invalid environment entry", .{});
            return error.EnvironmentUnavailable;
        };
        const key = entry[0..separator];
        if (!std.process.Environ.Map.validateKeyForPut(key)) {
            std.log.err("mise returned an invalid environment key", .{});
            return error.EnvironmentUnavailable;
        }
        try environment.put(key, entry[separator + 1 ..]);
    }
    return environment;
}

/// Projects configuration metadata into discovery data. Strings remain in the
/// caller's arena until Host serializes the result.
pub fn readCatalog(a: std.mem.Allocator, io: std.Io, directory: []const u8) !Catalog {
    const file = try std.fs.path.join(a, &.{ directory, "mise.toml" });
    const source = try std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(1024 * 1024));
    var info: toml.ErrorInfo = .{};
    const root = toml.parseSlice(a, source, &info) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            std.log.warn("invalid host configuration at {d}:{d}", .{ info.line, info.col });
            return error.InvalidRecommendedToolsConfig;
        },
    };
    const metadata = try tableField(root, "_");
    const application = try tableField(metadata, "ivenna");
    const entries = try tableField(application, "recommended_tools");
    const Tool = @import("catalog.zig").Tool;
    const tools = try a.alloc(Tool, entries.count());
    for (entries.keys(), entries.values(), tools) |name, entry, *tool| {
        const fields = switch (entry) {
            .table => |table| table,
            else => return error.InvalidRecommendedToolsConfig,
        };
        tool.* = .{
            .name = name,
            .command = try stringField(fields, "command"),
            .description = try stringField(fields, "description"),
            .help = try stringField(fields, "help"),
        };
    }
    return .{ .tools = tools };
}

fn tableField(table: *const toml.Table, name: []const u8) !*toml.Table {
    const value = table.get(name) orelse return error.InvalidRecommendedToolsConfig;
    return switch (value) {
        .table => |found| found,
        else => error.InvalidRecommendedToolsConfig,
    };
}

fn stringField(table: *const toml.Table, name: []const u8) ![]const u8 {
    const value = table.get(name) orelse return error.InvalidRecommendedToolsConfig;
    return switch (value) {
        .string => |found| found,
        else => error.InvalidRecommendedToolsConfig,
    };
}
