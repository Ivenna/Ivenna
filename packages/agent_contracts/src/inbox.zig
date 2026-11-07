const std = @import("std");
const IncomingMessage = @import("communication.zig").IncomingMessage;
const Allocator = std.mem.Allocator;

/// Incoming messages and opaque receipts for durable admission.
/// Returned values belong to the supplied allocator. The adapter owns native
/// delivery records.
pub const Inbox = struct {
    context: *anyopaque,
    vtable: *const VTable,

    /// An arrival with an optional opaque transport receipt.
    pub const Incoming = struct {
        input: IncomingMessage,
        receipt: ?[]const u8 = null,
    };

    pub const VTable = struct {
        poll: *const fn (*anyopaque, Allocator, usize) anyerror![]const Incoming,
        acknowledge: *const fn (*anyopaque, Allocator, []const u8) anyerror!void,
    };

    pub fn poll(self: Inbox, a: Allocator, limit: usize) ![]const Incoming {
        return self.vtable.poll(self.context, a, limit);
    }

    /// Call after storage has confirmed the complete observation and checkpoint.
    /// Acknowledgement releases the transport copy; task execution can continue.
    pub fn acknowledge(self: Inbox, a: Allocator, receipt: []const u8) !void {
        return self.vtable.acknowledge(self.context, a, receipt);
    }
};
