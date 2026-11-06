const std = @import("std");

pub const Contact = struct {
    reference: []const u8,
    description: ?[]const u8 = null,
};

pub const Message = struct {
    recipients: []const []const u8,
    text: []const u8,
};

pub const Submission = struct {
    reference: []const u8,
};

/// Explicit external submission. Contact resolution and native addressing
/// belong to the adapter. A submission reference does not prove delivery.
/// Returned submission values belong to the supplied allocator.
pub const Sender = struct {
    context: *anyopaque,
    submit: *const fn (*anyopaque, std.mem.Allocator, Message) anyerror!Submission,

    pub fn send(self: Sender, a: std.mem.Allocator, message: Message) !Submission {
        return self.submit(self.context, a, message);
    }
};
