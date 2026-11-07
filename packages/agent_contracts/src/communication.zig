const std = @import("std");

/// An observed message and the participants it came from.
pub const IncomingMessage = struct {
    from: []const []const u8,
    text: []const u8,
    /// Time this message was observed, in Unix milliseconds.
    observed_at_unix_ms: i64,
};

pub const Message = struct {
    recipients: []const []const u8,
    text: []const u8,
};

pub const Submission = struct {
    reference: []const u8,
};

/// A defined sending outcome. Infrastructure failures use the error channel.
pub const SendResult = union(enum) {
    submitted: Submission,
    invalid_recipient: void,
};

/// Explicit message submission. Participant ID resolution and native addressing
/// belong to the adapter. A submission reference does not prove delivery.
/// Unsupported recipient IDs return invalid_recipient without submitting.
/// Returned submission values belong to the supplied allocator.
pub const Sender = struct {
    context: *anyopaque,
    submit: *const fn (*anyopaque, std.mem.Allocator, Message) anyerror!SendResult,

    pub fn send(self: Sender, a: std.mem.Allocator, message: Message) !SendResult {
        return self.submit(self.context, a, message);
    }
};
