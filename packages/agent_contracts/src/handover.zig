const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Handover = struct {
    summary: []const u8,
};

/// Store complete handovers for continued understanding across starts.
/// Execution owns their size limits. Returned values belong to the supplied
/// allocator.
pub const HandoverStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        load: *const fn (*anyopaque, Allocator, []const u8) anyerror!?Handover,
        save: *const fn (*anyopaque, Allocator, []const u8, []const u8) anyerror!void,
    };

    pub fn load(self: HandoverStore, a: Allocator, key: []const u8) !?Handover {
        return self.vtable.load(self.context, a, key);
    }

    pub fn save(self: HandoverStore, a: Allocator, key: []const u8, summary: []const u8) !void {
        return self.vtable.save(self.context, a, key, summary);
    }
};
