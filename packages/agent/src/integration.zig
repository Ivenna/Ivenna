const std = @import("std");
const Input = @import("input.zig");
const Work = @import("work.zig");
const Allocator = std.mem.Allocator;

/// External observations and their opaque consumption receipts. Returned values
/// belong to the supplied allocator. The adapter owns native delivery records.
pub const Inbox = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const Incoming = Work.Incoming;

    pub const VTable = struct {
        poll: *const fn (*anyopaque, Allocator, usize, usize) anyerror![]const Incoming,
        recent: *const fn (*anyopaque, Allocator, usize) anyerror![]const Input.Material,
        complete: *const fn (*anyopaque, Allocator, []const u8) anyerror!void,
        releaseUnused: *const fn (*anyopaque, []const []const u8) anyerror!void,
    };

    pub fn poll(self: Inbox, a: Allocator, limit: usize, excerpt_bytes: usize) ![]const Incoming {
        return self.vtable.poll(self.context, a, limit, excerpt_bytes);
    }

    pub fn recent(self: Inbox, a: Allocator, limit: usize) ![]const Input.Material {
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

/// Durable handovers reconstruct understanding after startup. This contract
/// does not persist execution checkpoints or restore work-session identities.
/// Loaded values belong to the supplied allocator.
pub const HandoverStore = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        load: *const fn (*anyopaque, Allocator, []const u8, usize) anyerror!?Input.Handover,
        save: *const fn (*anyopaque, Allocator, []const u8, []const u8) anyerror!void,
    };

    pub fn load(self: HandoverStore, a: Allocator, key: []const u8, limit: usize) !?Input.Handover {
        return self.vtable.load(self.context, a, key, limit);
    }

    pub fn save(self: HandoverStore, a: Allocator, key: []const u8, summary: []const u8) !void {
        return self.vtable.save(self.context, a, key, summary);
    }
};
