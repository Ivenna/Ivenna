const std = @import("std");
const Allocator = std.mem.Allocator;

/// Immutable history records and the manifest identifying retained contexts.
/// The agent owns encoding and record keys. It confirms records before publishing
/// a manifest, and serializes writes. Loaded text belongs to the allocator.
pub const HistoryStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        load: *const fn (*anyopaque, Allocator) anyerror!?[]const u8,
        read: *const fn (*anyopaque, Allocator, []const u8) anyerror![]const u8,
        put: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
        save: *const fn (*anyopaque, []const u8) anyerror!void,
    };

    pub fn load(self: HistoryStore, a: Allocator) !?[]const u8 {
        return self.vtable.load(self.context, a);
    }

    pub fn read(self: HistoryStore, a: Allocator, key: []const u8) ![]const u8 {
        return self.vtable.read(self.context, a, key);
    }

    pub fn put(self: HistoryStore, key: []const u8, record: []const u8) !void {
        return self.vtable.put(self.context, key, record);
    }

    pub fn save(self: HistoryStore, document: []const u8) !void {
        return self.vtable.save(self.context, document);
    }
};
