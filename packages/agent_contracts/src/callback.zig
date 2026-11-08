const std = @import("std");
const Allocator = std.mem.Allocator;

/// A callback's originating capability. Host identifiers belong to the runtime
/// that started the command; retained sources do not restore control handles.
pub const Source = union(enum) {
    wakeup,
    host: struct { command_id: u64 },
};

/// Register one future observation for the invoking session. The registrar is
/// borrowed for the tool call; success confirms durable registration.
pub const Registrar = struct {
    context: *anyopaque,
    register: *const fn (*anyopaque, Source) anyerror!u64,

    pub fn open(self: Registrar, source: Source) !u64 {
        return self.register(self.context, source);
    }
};

/// The callback identity binds one future observation to its registering
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
