const Allocator = @import("std").mem.Allocator;

/// Named channels hand text to waiting local receivers. The implementation
/// owns pending receive requests and copies registration data it keeps.
pub const Channels = struct {
    pub const max_message_bytes = 4096;

    pub const SendOutcome = enum {
        /// The complete message was handed to a pending receive operation.
        accepted,
        /// This attempt made no handoff and stored no message.
        would_block,
        unknown_channel,
        too_long,
    };

    pub const Registration = struct {
        channel_id: []const u8,
        description: ?[]const u8,
    };

    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        trySend: *const fn (*anyopaque, []const u8, []const u8) anyerror!SendOutcome,
        open: *const fn (context: *anyopaque, channel_id: []const u8, opening_focus_id: []const u8, description: ?[]const u8) anyerror!void,
        close: *const fn (context: *anyopaque, channel_id: []const u8) anyerror!bool,
        sample: *const fn (*anyopaque, Allocator, ?[]const u8) anyerror![]const Registration,
    };

    pub fn trySend(self: Channels, channel_id: []const u8, text: []const u8) !SendOutcome {
        return self.vtable.trySend(self.context, channel_id, text);
    }

    /// A restored registration may predate description storage.
    pub fn open(self: Channels, channel_id: []const u8, opening_focus_id: []const u8, description: ?[]const u8) !void {
        return self.vtable.open(self.context, channel_id, opening_focus_id, description);
    }

    pub fn close(self: Channels, channel_id: []const u8) !bool {
        return self.vtable.close(self.context, channel_id);
    }

    /// Sample all open channels or those opened by a particular focus. The
    /// supplied arena owns the returned slice and strings.
    pub fn sample(self: Channels, arena: Allocator, opening_focus_id: ?[]const u8) ![]const Registration {
        return self.vtable.sample(self.context, arena, opening_focus_id);
    }
};
