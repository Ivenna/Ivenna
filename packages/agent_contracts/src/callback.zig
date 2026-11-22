const std = @import("std");
const Allocator = std.mem.Allocator;

/// A callback's originating capability. Host identifiers belong to the runtime
/// that started the command; retained sources do not restore control handles.
pub const Source = union(enum) {
    wakeup,
    host: struct { command_id: []const u8 },
    subscription: struct { subscription_id: u64 },
};

/// Internal delivery identity and the complete model-facing association.
/// The reference belongs to the allocator supplied to Registrar.open.
pub const Registration = struct { id: u64, reference: []const u8 };

/// Register one future observation for the invoking session. The registrar is
/// borrowed for the tool call; success confirms durable registration.
pub const Registrar = struct {
    context: *anyopaque,
    register: *const fn (*anyopaque, Allocator, []const u8, Source) anyerror!Registration,

    pub fn open(self: Registrar, a: Allocator, name: []const u8, source: Source) !Registration {
        return self.register(self.context, a, name, source);
    }
};

/// The callback identity binds observations to their registering session.
/// A subscription reuses its callback identity for each report.
pub const Message = struct { id: u64, text: []const u8 };
pub const Observation = struct { id: u64, text: []const u8, observed_at_unix_ms: i64 };

/// Durable callback delivery. Repeating a one-shot publication preserves
/// the first result. Subscription reports use distinct deliveries.
/// Returned success confirms storage, not model admission or task completion.
pub const Publisher = struct {
    context: *anyopaque,
    publish: *const fn (*anyopaque, Allocator, Message) anyerror!void,

    pub fn send(self: Publisher, a: Allocator, message: Message) !void {
        return self.publish(self.context, a, message);
    }
};
