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
        reserve: *const fn (context: *anyopaque, channel_id: []const u8) anyerror!void,
        activate: *const fn (context: *anyopaque, channel_id: []const u8) void,
        close: *const fn (context: *anyopaque, channel_id: []const u8) void,
    };

    pub fn trySend(self: Channels, channel_id: []const u8, text: []const u8) !SendOutcome {
        return self.vtable.trySend(self.context, channel_id, text);
    }

    /// Reserve a fresh channel ID without exposing it to sends or reads. On
    /// success the caller must activate or close the reservation. On error the
    /// transport is unchanged.
    pub fn reserve(self: Channels, channel_id: []const u8) !void {
        return self.vtable.reserve(self.context, channel_id);
    }

    /// Expose the caller's reservation after its registration is confirmed in
    /// the checkpoint. A successful reservation guarantees this can complete.
    pub fn activate(self: Channels, channel_id: []const u8) void {
        self.vtable.activate(self.context, channel_id);
    }

    /// Cancel the caller's reservation or close an active channel and its readers.
    pub fn close(self: Channels, channel_id: []const u8) void {
        self.vtable.close(self.context, channel_id);
    }
};
