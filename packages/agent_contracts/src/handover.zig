const std = @import("std");
const Resource = @import("material.zig").Resource;
const Allocator = std.mem.Allocator;

pub const Handover = struct {
    summary: []const u8,
    source: ?Resource = null,
};

/// Durable handovers reconstruct understanding after startup. This contract
/// does not persist execution checkpoints or restore work-session identities.
/// Loaded values belong to the supplied allocator.
pub const HandoverStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        load: *const fn (*anyopaque, Allocator, []const u8, usize) anyerror!?Handover,
        save: *const fn (*anyopaque, Allocator, []const u8, []const u8) anyerror!void,
    };

    pub fn load(self: HandoverStore, a: Allocator, key: []const u8, limit: usize) !?Handover {
        return self.vtable.load(self.context, a, key, limit);
    }

    pub fn save(self: HandoverStore, a: Allocator, key: []const u8, summary: []const u8) !void {
        return self.vtable.save(self.context, a, key, summary);
    }
};
