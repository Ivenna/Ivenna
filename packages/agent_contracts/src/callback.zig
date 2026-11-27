const std = @import("std");
const Allocator = std.mem.Allocator;

/// Internal delivery identity and the complete model-facing association.
/// The reference belongs to the allocator supplied to Registrar.open.
pub const Registration = struct { id: u64, reference: []const u8 };

/// Register a command completion for the invoking session. The registrar is
/// borrowed for the tool call and success confirms durable registration.
pub const Registrar = struct {
    context: *anyopaque,
    register: *const fn (*anyopaque, Allocator, []const u8, []const u8) anyerror!Registration,

    pub fn open(self: Registrar, a: Allocator, name: []const u8, command_id: []const u8) !Registration {
        return self.register(self.context, a, name, command_id);
    }
};

/// The callback identity binds one future observation to its registering
/// session. Destinations belong to execution, not the transport.
pub const Message = struct { id: u64, text: []const u8 };

/// The inbox adapter supplies a decoded observation with a positive ID.
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
