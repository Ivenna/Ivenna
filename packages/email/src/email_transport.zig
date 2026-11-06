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
            .observed_at_unix_ms = std.Io.Clock.real.now(self.mailbox.client.io).toMilliseconds(),
        };
    }

    pub fn send(self: *EmailTransport, a: Allocator, message: Communication.Message) !Communication.Submission {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        const recipients = try scratch.alloc(Mail.Address, message.recipients.len);
        for (message.recipients, recipients) |id, *recipient|
            recipient.* = .{ .email = try self.mailbox.addressing.address(scratch, id) };
        const submission = try self.mailbox.send(scratch, .{
            .to = recipients,
            .subject = "Ivenna",
            .body = message.text,
        });
        if (submission.sent_copy == .unconfirmed)
            std.log.warn("mail {s} accepted for submission; sent-copy update unconfirmed", .{submission.mail_id});
        return .{ .reference = try submissionReference(a, self.mailbox.*, submission.mail_id) };
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
