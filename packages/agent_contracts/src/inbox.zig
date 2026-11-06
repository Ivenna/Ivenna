const std = @import("std");
const Material = @import("material.zig").Material;
const Allocator = std.mem.Allocator;

/// External observations and their opaque consumption receipts. Returned values
/// belong to the supplied allocator. The adapter owns native delivery records.
pub const Inbox = struct {
    context: *anyopaque,
    vtable: *const VTable,

    /// An arrival with an optional opaque receipt for consumption bookkeeping.
    /// The receipt is independent of the material's source provenance.
    pub const Incoming = struct {
        input: Material,
        receipt: ?[]const u8 = null,
    };

    pub const VTable = struct {
        poll: *const fn (*anyopaque, Allocator, usize, usize) anyerror![]const Incoming,
        recent: *const fn (*anyopaque, Allocator, usize) anyerror![]const Material,
        complete: *const fn (*anyopaque, Allocator, []const u8) anyerror!void,
        releaseUnused: *const fn (*anyopaque, []const []const u8) anyerror!void,
    };

    pub fn poll(self: Inbox, a: Allocator, limit: usize, excerpt_bytes: usize) ![]const Incoming {
        return self.vtable.poll(self.context, a, limit, excerpt_bytes);
    }

    pub fn recent(self: Inbox, a: Allocator, limit: usize) ![]const Material {
        return self.vtable.recent(self.context, a, limit);
    }

    pub fn complete(self: Inbox, a: Allocator, receipt: []const u8) !void {
        return self.vtable.complete(self.context, a, receipt);
    }

    /// Release adapter handles outside the retained receipt snapshot. Source
    /// artifacts and stored correspondence keep their independent lifetimes.
    pub fn releaseUnused(self: Inbox, retained: []const []const u8) !void {
        return self.vtable.releaseUnused(self.context, retained);
    }
};
