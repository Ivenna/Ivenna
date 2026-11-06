const std = @import("std");
const Allocator = std.mem.Allocator;

/// Immutable history records and the manifest identifying retained contexts.
/// The agent owns encoding, content identity, and active-source sharing. Storage
/// owns opaque locators. Batch results preserve input order and belong to a.
/// Creation is all-or-error, but failures may leave unreferenced stored objects.
/// The caller confirms every source before publishing a manifest and serializes writes.
pub const HistoryStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        load: *const fn (*anyopaque, Allocator) anyerror!?[]const u8,
        read: *const fn (*anyopaque, Allocator, []const []const u8) anyerror![]const []const u8,
        create: *const fn (*anyopaque, Allocator, []const []const u8) anyerror![]const []const u8,
        save: *const fn (*anyopaque, []const u8) anyerror!void,
    };

    pub fn load(self: HistoryStore, a: Allocator) !?[]const u8 {
        return self.vtable.load(self.context, a);
    }

    pub fn read(self: HistoryStore, a: Allocator, locators: []const []const u8) ![]const []const u8 {
        return self.vtable.read(self.context, a, locators);
    }

    pub fn create(self: HistoryStore, a: Allocator, records: []const []const u8) ![]const []const u8 {
        return self.vtable.create(self.context, a, records);
    }

    pub fn save(self: HistoryStore, document: []const u8) !void {
        return self.vtable.save(self.context, document);
    }
};
