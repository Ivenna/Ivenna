const Allocator = @import("std").mem.Allocator;

/// Named channels route text to live host commands. The host owns the channel
/// lifetimes and pending input, and copies references it keeps.
pub const Channels = struct {
    pub const max_bytes = 4096;

    pub const Outcome = enum {
        accepted,
        full,
        closed,
        unknown_channel,
        too_long,
        busy,
    };

    pub const OpenOutcome = enum {
        opened,
        unknown_command,
        not_enabled,
        closed,
        already_open,
    };

    context: *anyopaque,
    send: *const fn (*anyopaque, []const u8, []const u8) anyerror!Outcome,
    open: *const fn (context: *anyopaque, command_id: []const u8, channel_id: []const u8, focus_id: []const u8) anyerror!OpenOutcome,
    close: *const fn (context: *anyopaque, channel_id: []const u8) anyerror!bool,
    sample: *const fn (*anyopaque, Allocator, ?[]const u8) anyerror![]const []const u8,

    pub fn submit(self: Channels, channel_id: []const u8, text: []const u8) !Outcome {
        return self.send(self.context, channel_id, text);
    }
};
