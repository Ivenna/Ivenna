const std = @import("std");
const IncomingMessage = @import("communication.zig").IncomingMessage;
const HistoryItem = @import("communication.zig").HistoryItem;
const Allocator = std.mem.Allocator;

/// Incoming messages, recent communication, and opaque consumption receipts.
/// Returned values belong to the supplied allocator. The adapter owns native
/// delivery records.
pub const Inbox = struct {
    context: *anyopaque,
    vtable: *const VTable,

    /// An arrival with an optional opaque receipt for consumption bookkeeping.
    pub const Incoming = struct {
        input: IncomingMessage,
        receipt: ?[]const u8 = null,
    };

    pub const VTable = struct {
        poll: *const fn (*anyopaque, Allocator, usize) anyerror![]const Incoming,
        recent: *const fn (*anyopaque, Allocator, usize) anyerror![]const HistoryItem,
        complete: *const fn (*anyopaque, Allocator, []const u8) anyerror!void,
    };

    pub fn poll(self: Inbox, a: Allocator, limit: usize) ![]const Incoming {
        return self.vtable.poll(self.context, a, limit);
    }

    pub fn recent(self: Inbox, a: Allocator, limit: usize) ![]const HistoryItem {
        return self.vtable.recent(self.context, a, limit);
    }

    pub fn complete(self: Inbox, a: Allocator, receipt: []const u8) !void {
        return self.vtable.complete(self.context, a, receipt);
    }
};
