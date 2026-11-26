const std = @import("std");
const IncomingMessage = @import("communication.zig").IncomingMessage;
const Callback = @import("callback.zig");
const Allocator = std.mem.Allocator;

/// Incoming messages and opaque receipts for durable admission.
/// Returned values belong to the supplied allocator. The adapter owns native
/// delivery records.
pub const Inbox = struct {
    context: *anyopaque,
    vtable: *const VTable,

    /// An arrival with an optional opaque transport receipt.
    pub const Incoming = struct {
        content: union(enum) { message: IncomingMessage, callback: Callback.Observation },
        receipt: ?[]const u8 = null,
    };

    /// Independent eligible-prefix limits. Zero disables that input stream.
    pub const Poll = struct { messages: usize, callbacks: usize };

    pub const VTable = struct {
        poll: *const fn (*anyopaque, Allocator, Poll) anyerror![]const Incoming,
        acknowledge: *const fn (*anyopaque, Allocator, []const u8) anyerror!void,
    };

    pub fn poll(self: Inbox, a: Allocator, request: Poll) ![]const Incoming {
        return self.vtable.poll(self.context, a, request);
    }

    /// Call after storage has confirmed the complete observation and checkpoint.
    /// Acknowledgement releases the transport copy; task execution can continue.
    /// The kernel can repeat acknowledgement when a poll still offers the
    /// same receipt. A successful repeat has the same effect as the first.
    pub fn acknowledge(self: Inbox, a: Allocator, receipt: []const u8) !void {
        return self.vtable.acknowledge(self.context, a, receipt);
    }
};
