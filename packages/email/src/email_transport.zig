const std = @import("std");
const Mail = @import("mail.zig");
const Communication = @import("agent_contracts").Communication;
const Allocator = std.mem.Allocator;

/// Project incoming observations and submit explicit messages.
pub const EmailTransport = struct {
    mailbox: *Mail.Mailbox,

    pub fn init(mailbox: *Mail.Mailbox) EmailTransport {
        return .{ .mailbox = mailbox };
    }

    pub fn receive(self: *EmailTransport, a: Allocator, letter: Mail.Letter) !Communication.IncomingMessage {
        return .{
            .from = try self.participantIds(a, letter.from),
            .text = if (letter.subject.len == 0) letter.body else try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ letter.subject, letter.body }),
            .observed_at_unix_ms = std.Io.Clock.real.now(self.mailbox.jmap.io()).toMilliseconds(),
        };
    }

    pub fn send(self: *EmailTransport, a: Allocator, message: Communication.Message) !Communication.SendResult {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        const recipients = try scratch.alloc(Mail.Address, message.recipients.len);
        for (message.recipients, recipients) |id, *recipient| {
            const address = self.mailbox.addressing.address(scratch, id) catch |err| switch (err) {
                error.InvalidRecipientId => return .invalid_recipient,
                else => return err,
            };
            recipient.* = .{ .email = address };
        }
        const mail_id = self.mailbox.createDraft(scratch, .{
            .to = recipients,
            .subject = "Ivenna",
            .body = message.text,
        }) catch |err| switch (err) {
            error.MailMutationUnconfirmed => return .not_submitted,
            else => return err,
        };
        self.mailbox.submitDraft(scratch, mail_id) catch |err| switch (err) {
            error.MailMutationUnconfirmed => if (!try self.mailbox.submissionConfirmed(scratch, mail_id)) return .submission_unknown,
            else => return err,
        };
        return .{ .submitted = .{ .reference = try submissionReference(a, self.mailbox.*, mail_id) } };
    }

    fn participantIds(self: *EmailTransport, a: Allocator, addresses: []const Mail.Address) ![]const []const u8 {
        const result = try a.alloc([]const u8, addresses.len);
        for (addresses, result) |address, *id|
            id.* = self.mailbox.addressing.id(address.email).?;
        return result;
    }
};

fn submissionReference(a: Allocator, mailbox: Mail.Mailbox, mail_id: []const u8) ![]const u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("submission");
    for ([_][]const u8{ mailbox.session_url, mailbox.account_id, mail_id }) |component| {
        hash.update(&.{0});
        hash.update(component);
    }
    const digest = std.fmt.bytesToHex(hash.finalResult(), .lower);
    return std.fmt.allocPrint(a, "submission-{s}", .{digest});
}

test "an unconfirmed submission is checked for the same draft without resending" {
    const Fixture = @import("test_jmap.zig").Fixture;
    const Case = struct {
        submission_error: ?[]const u8 = null,
        result: []const u8,
        method_error: bool = false,
        outcome: std.meta.Tag(Communication.SendResult) = .submission_unknown,
    };
    for ([_]Case{
        .{ .result = "{\"ids\":[\"submission\"]}", .outcome = .submitted },
        .{ .submission_error = "{\"type\":\"serverUnavailable\"}", .result = "{\"ids\":[]}" },
        .{ .result = "{\"type\":\"forbidden\"}", .method_error = true },
    }) |case| {
        var fixture = try Fixture.init(&.{
            .{ .method = "Email/set", .result = "{\"created\":{\"letter\":{\"id\":\"draft\"}}}" },
            .{ .method = "EmailSubmission/set", .result = case.submission_error, .method_error = case.submission_error != null },
            .{ .method = "EmailSubmission/query", .result = case.result, .method_error = case.method_error, .properties = &.{
                .{ .path = &.{ "filter", "emailIds" }, .json = "[\"draft\"]" },
                .{ .path = &.{ "filter", "identityIds" }, .json = "[\"identity\"]" },
            } },
        });
        defer fixture.deinit();
        var mailbox = try fixture.start();
        var transport = EmailTransport.init(&mailbox);
        const outcome = try transport.send(fixture.arena.allocator(), .{ .recipients = &.{"operator"}, .text = "hello" });
        try std.testing.expectEqual(case.outcome, std.meta.activeTag(outcome));
        try fixture.finish();
    }
}

test "an interrupted draft create has no submission to reconcile" {
    const Fixture = @import("test_jmap.zig").Fixture;
    var fixture = try Fixture.init(&.{.{ .method = "Email/set", .result = null }});
    defer fixture.deinit();
    var mailbox = try fixture.start();
    var transport = EmailTransport.init(&mailbox);
    const outcome = try transport.send(fixture.arena.allocator(), .{ .recipients = &.{"operator"}, .text = "hello" });
    try std.testing.expect(outcome == .not_submitted);
    try fixture.finish();
}
