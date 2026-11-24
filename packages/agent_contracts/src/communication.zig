const std = @import("std");

/// An observed message and the participants it came from.
pub const IncomingMessage = struct {
    from: []const []const u8,
    text: []const u8,
    /// Time this message was observed, in Unix milliseconds.
    observed_at_unix_ms: i64,
};

pub const Message = struct {
    recipient: []const u8,
    text: []const u8,
};

pub const Submission = struct {
    /// Confirms that the sending service accepted the message for delivery.
    reference: []const u8,
};

pub const SendResult = union(enum) {
    submitted: Submission,
    /// The adapter found an unsupported correspondent ID before submission.
    invalid_recipient: void,
    /// Preparation stopped before the adapter attempted submission.
    not_submitted: void,
    /// The adapter attempted submission and the service may have accepted it.
    submission_unknown: void,
};

/// The adapter resolves the recipient to a native address and submits the
/// message. Failures of required service access propagate to the caller.
/// The caller owns the returned reference, allocated with the supplied allocator.
pub const Sender = struct {
    context: *anyopaque,
    submit: *const fn (*anyopaque, std.mem.Allocator, Message) anyerror!SendResult,
    /// The IDs accepted for outgoing correspondence, borrowed for the sender's lifetime.
    registered_correspondents: []const []const u8,

    pub fn send(self: Sender, a: std.mem.Allocator, message: Message) !SendResult {
        return self.submit(self.context, a, message);
    }
};
