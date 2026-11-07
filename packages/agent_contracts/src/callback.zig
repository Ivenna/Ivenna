const std = @import("std");
const Allocator = std.mem.Allocator;

/// The callback identity binds one scheduled observation to its registering
/// session. Destinations belong to execution, not the transport.
pub const Message = struct { id: u64, text: []const u8 };
pub const Observation = struct { id: u64, text: []const u8, observed_at_unix_ms: i64 };

/// Durable callback delivery. Repeated publication preserves the first result.
/// Returned success confirms storage, not model admission or task completion.
pub const Publisher = struct {
    context: *anyopaque,
    publish: *const fn (*anyopaque, Allocator, Message) anyerror!void,

    pub fn send(self: Publisher, a: Allocator, message: Message) !void {
        return self.publish(self.context, a, message);
    }
};
