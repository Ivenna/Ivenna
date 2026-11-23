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

/// The adapter resolves correspondent IDs to native addresses and submits the
/// message. Failures of required service access propagate to the caller.
/// The caller owns the returned reference, allocated with the supplied allocator.
pub const Sender = struct {
    context: *anyopaque,
    submit: *const fn (*anyopaque, std.mem.Allocator, Message) anyerror!SendResult,

    pub fn send(self: Sender, a: std.mem.Allocator, message: Message) !SendResult {
        return self.submit(self.context, a, message);
    }
};

/// A named outbound route. A host that delivers over more than one service
/// registers one channel per service; the sender resolves its own addresses.
pub const Channel = struct {
    name: []const u8,
    sender: Sender,
};

/// The channels a kernel can deliver through, in preference order. The first
/// channel is the default for a message that names none.
pub const Roster = struct {
    channels: []const Channel,

    /// Returns the channel a name selects, or the default channel when name is
    /// null. A name that no channel carries resolves to null, as does the
    /// default channel of a roster without channels.
    pub fn resolve(self: Roster, name: ?[]const u8) ?Channel {
        if (name) |wanted| {
            for (self.channels) |channel| {
                if (std.mem.eql(u8, channel.name, wanted)) return channel;
            }
            return null;
        }
        return if (self.channels.len == 0) null else self.channels[0];
    }
};

test "a roster resolves a channel name and otherwise selects the default" {
    const Stub = struct {
        fn submit(_: *anyopaque, _: std.mem.Allocator, _: Message) anyerror!SendResult {
            return .{ .submitted = .{ .reference = "" } };
        }
    };
    const channels = [_]Channel{
        .{ .name = "email", .sender = .{ .context = undefined, .submit = Stub.submit } },
        .{ .name = "qq", .sender = .{ .context = undefined, .submit = Stub.submit } },
    };
    const roster: Roster = .{ .channels = &channels };
    try std.testing.expectEqualStrings("email", roster.resolve(null).?.name);
    try std.testing.expectEqualStrings("qq", roster.resolve("qq").?.name);
    try std.testing.expect(roster.resolve("fax") == null);
    const bare: Roster = .{ .channels = &.{} };
    try std.testing.expect(bare.resolve(null) == null);
}
