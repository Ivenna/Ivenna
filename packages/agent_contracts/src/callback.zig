const std = @import("std");
const Allocator = std.mem.Allocator;

/// The callback identity binds one terminal observation to its registering
/// session. Destinations and source kinds belong to execution, not producers.
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

/// Available only during the current tool invocation. A capability may retain
/// the returned ID, but must not retain this registration context.
pub const Registrar = struct {
    context: *anyopaque,
    register: *const fn (*anyopaque) anyerror!u64,

    pub fn open(self: Registrar) !u64 {
        return self.register(self.context);
    }
};
