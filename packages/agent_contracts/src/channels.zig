const Allocator = @import("std").mem.Allocator;

/// Named channels hand text to waiting local receivers. The implementation
/// owns channel lifetimes and copies references it keeps.
pub const Channels = struct {
    pub const max_bytes = 4096;

    pub const Outcome = enum {
        accepted,
        /// This attempt made no handoff and stored no message.
        not_ready,
        unknown_channel,
        too_long,
    };

    context: *anyopaque,
    send: *const fn (*anyopaque, []const u8, []const u8) anyerror!Outcome,
    open: *const fn (context: *anyopaque, channel_id: []const u8, focus_id: []const u8) anyerror!void,
    close: *const fn (context: *anyopaque, channel_id: []const u8) anyerror!bool,
    sample: *const fn (*anyopaque, Allocator, ?[]const u8) anyerror![]const []const u8,

    pub fn submit(self: Channels, channel_id: []const u8, text: []const u8) !Outcome {
        return self.send(self.context, channel_id, text);
    }
};
