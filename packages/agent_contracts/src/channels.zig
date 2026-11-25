/// The transport hands text to waiting local receivers by channel ID.
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

    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        trySend: *const fn (*anyopaque, []const u8, []const u8) anyerror!SendOutcome,
        /// Reserve an entry for a channel ID without exposing it to sends or
        /// reads.
        open: *const fn (context: *anyopaque, channel_id: []const u8) anyerror!void,
        /// Expose a reserved entry once its registration is in the checkpoint.
        activate: *const fn (context: *anyopaque, channel_id: []const u8) anyerror!void,
        close: *const fn (context: *anyopaque, channel_id: []const u8) bool,
    };

    pub fn trySend(self: Channels, channel_id: []const u8, text: []const u8) !SendOutcome {
        return self.vtable.trySend(self.context, channel_id, text);
    }

    pub fn open(self: Channels, channel_id: []const u8) !void {
        return self.vtable.open(self.context, channel_id);
    }

    pub fn activate(self: Channels, channel_id: []const u8) !void {
        return self.vtable.activate(self.context, channel_id);
    }

    pub fn close(self: Channels, channel_id: []const u8) bool {
        return self.vtable.close(self.context, channel_id);
    }
};
