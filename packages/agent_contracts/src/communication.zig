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

/// The channels a kernel can deliver through. A message that names no channel
/// is delivered through the channel `default_name` selects; the order of
/// `channels` never chooses it.
pub const Roster = struct {
    channels: []const Channel,
    /// The name of the channel for a message that names none. A host declares
    /// it; when it is absent, a message has to name its channel.
    default_name: ?[]const u8 = null,

    /// What a channel name selects. A name that no channel carries and a
    /// message that names none where the roster declares no default are
    /// different failures, so a caller can tell one from the other.
    pub const Resolution = union(enum) {
        channel: Channel,
        unknown_channel: void,
        no_default_channel: void,
    };

    pub fn resolve(self: Roster, name: ?[]const u8) Resolution {
        const wanted = name orelse self.default_name orelse return .no_default_channel;
        for (self.channels) |channel| {
            if (std.mem.eql(u8, channel.name, wanted)) return .{ .channel = channel };
        }
        return .unknown_channel;
    }
};

const StubSubmitter = struct {
    fn submit(_: *anyopaque, _: std.mem.Allocator, _: Message) anyerror!SendResult {
        return .{ .submitted = .{ .reference = "" } };
    }
};

const stub_sender: Sender = .{ .context = undefined, .submit = StubSubmitter.submit };

test "a roster resolves a declared default only when the message names none" {
    const channels = [_]Channel{
        .{ .name = "email", .sender = stub_sender },
        .{ .name = "qq", .sender = stub_sender },
    };
    const roster: Roster = .{ .channels = &channels, .default_name = "email" };
    try std.testing.expectEqualStrings("email", roster.resolve(null).channel.name);
    try std.testing.expectEqualStrings("email", roster.resolve("email").channel.name);
    try std.testing.expectEqualStrings("qq", roster.resolve("qq").channel.name);
    try std.testing.expectEqual(
        Roster.Resolution.unknown_channel,
        std.meta.activeTag(roster.resolve("fax")),
    );
}

test "a roster without a declared default refuses a message that names none" {
    const channels = [_]Channel{
        .{ .name = "email", .sender = stub_sender },
        .{ .name = "qq", .sender = stub_sender },
    };
    const roster: Roster = .{ .channels = &channels };
    try std.testing.expectEqual(
        Roster.Resolution.no_default_channel,
        std.meta.activeTag(roster.resolve(null)),
    );
    try std.testing.expectEqualStrings("qq", roster.resolve("qq").channel.name);
    const bare: Roster = .{ .channels = &.{} };
    try std.testing.expectEqual(
        Roster.Resolution.no_default_channel,
        std.meta.activeTag(bare.resolve(null)),
    );
}

test "the declared default does not follow the order of the channels" {
    const reversed = [_]Channel{
        .{ .name = "qq", .sender = stub_sender },
        .{ .name = "email", .sender = stub_sender },
    };
    const roster: Roster = .{ .channels = &reversed, .default_name = "email" };
    try std.testing.expectEqualStrings("email", roster.resolve(null).channel.name);
}
