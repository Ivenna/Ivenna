const std = @import("std");
const Allocator = std.mem.Allocator;

/// Grouped immutable records and the checkpoint identifying retained histories.
/// The agent owns encoding, record keys, ordering, committed chains, and
/// retention selection.
/// Storage owns opaque group IDs and native record locators. Returned data
/// belongs to a. The caller serializes writes and confirms records before
/// publishing a checkpoint; errors do not imply that no native write occurred.
pub const HistoryStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    /// Lowercase hexadecimal SHA-256 of the agent's encoded record body.
    pub const Key = [64]u8;

    pub const Record = struct {
        group: []const u8,
        key: Key,
        previous: ?Key = null,
        body: []const u8,
    };

    pub const Reference = struct {
        group: []const u8,
        key: Key,
        previous: ?Key,
        /// Opaque to execution; only the adapter interprets its contents.
        locator: []const u8,
    };

    pub const RecordId = struct {
        group: []const u8,
        key: Key,
    };

    /// The confirmed checkpoint's complete record selection. Unselected material
    /// can be retired. Storage owns native placement; disposal after retirement
    /// belongs to the storage service and its deployment policy.
    pub const Retention = struct {
        records: []const RecordId,
    };

    pub const VTable = struct {
        load: *const fn (*anyopaque, Allocator) anyerror!?[]const u8,
        allocateGroup: *const fn (*anyopaque, Allocator) anyerror![]const u8,
        query: *const fn (*anyopaque, Allocator, []const []const u8) anyerror![]const Reference,
        read: *const fn (*anyopaque, Allocator, []const Reference) anyerror![]const []const u8,
        create: *const fn (*anyopaque, Allocator, []const Record) anyerror!void,
        save: *const fn (*anyopaque, []const u8) anyerror!void,
        maintain: *const fn (*anyopaque, Allocator, Retention) anyerror!void,
    };

    pub fn load(self: HistoryStore, a: Allocator) !?[]const u8 {
        return self.vtable.load(self.context, a);
    }

    /// Allocate a fresh opaque group. Allocation alone commits no history.
    pub fn allocateGroup(self: HistoryStore, a: Allocator) ![]const u8 {
        return self.vtable.allocateGroup(self.context, a);
    }

    /// Discover decoded record metadata confined to the requested groups, in
    /// any order. Keys follow the Key contract; locators remain adapter-owned.
    /// Results can include uncommitted records and repeated logical keys.
    pub fn query(self: HistoryStore, a: Allocator, groups: []const []const u8) ![]const Reference {
        return self.vtable.query(self.context, a, groups);
    }

    /// Return one complete body per reference in input order, including repeats,
    /// or return an error. Stored group, key, and predecessor must match the
    /// reference; the agent verifies body hashes.
    pub fn read(self: HistoryStore, a: Allocator, references: []const Reference) ![]const []const u8 {
        return self.vtable.read(self.context, a, references);
    }

    /// Confirm every requested create or return an error. A partial or
    /// unconfirmed operation may leave records outside committed paths.
    pub fn create(self: HistoryStore, a: Allocator, records: []const Record) !void {
        return self.vtable.create(self.context, a, records);
    }

    /// Publish the complete checkpoint. An error can follow publication.
    pub fn save(self: HistoryStore, document: []const u8) !void {
        return self.vtable.save(self.context, document);
    }

    /// Reconcile storage against a confirmed checkpoint's complete selection.
    /// The caller serializes maintenance with record creation and publication.
    pub fn maintain(self: HistoryStore, a: Allocator, retention: Retention) !void {
        return self.vtable.maintain(self.context, a, retention);
    }
};
