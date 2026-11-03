const std = @import("std");
const catalog = @import("catalog.zig");
const mise = @import("mise.zig");

const Allocator = std.mem.Allocator;

/// Provides configured tool descriptions through the host's discovery contract.
pub const RecommendedTools = struct {
    io: std.Io,
    directory: []const u8,

    pub const Catalog = catalog.Catalog;
    pub const Tool = catalog.Tool;

    pub const ReadOutcome = union(enum) { catalog: Catalog, unavailable };

    pub fn read(self: RecommendedTools, a: Allocator) !ReadOutcome {
        const configured = mise.readCatalog(a, self.io, self.directory) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => return err,
            else => {
                std.log.warn("could not read recommendation catalog: {s}", .{@errorName(err)});
                return .unavailable;
            },
        };
        return .{ .catalog = configured };
    }
};
