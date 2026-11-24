const std = @import("std");
const Mail = @import("mail.zig");
const Communication = @import("agent_contracts").Communication;
const Allocator = std.mem.Allocator;

/// Project incoming observations and submit explicit messages.
pub const EmailTransport = struct {
    mailbox: *Mail.Mailbox,
    recipients: std.StringArrayHashMapUnmanaged([]const u8),

    /// Index the configured addresses once in the integration's discovery arena.
    /// The entries borrow the configuration strings.
    pub fn init(a: Allocator, mailbox: *Mail.Mailbox, addresses: []const []const u8) !EmailTransport {
        var recipients: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
        errdefer recipients.deinit(a);
        for (addresses) |address| {
            const id = mailbox.addressing.id(address) orelse return error.InvalidCorrespondentAddress;
            const entry = try recipients.getOrPut(a, id);
            if (entry.found_existing) return error.DuplicateCorrespondentId;
            entry.value_ptr.* = address;
        }
        return .{ .mailbox = mailbox, .recipients = recipients };
    }

    pub fn receive(self: *EmailTransport, a: Allocator, letter: Mail.Letter) !Communication.IncomingMessage {
        return .{
            .from = try self.participantIds(a, letter.from),
            .text = if (letter.subject.len == 0) letter.body else try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ letter.subject, letter.body }),
            .observed_at_unix_ms = std.Io.Clock.real.now(self.mailbox.jmap.io()).toMilliseconds(),
        };
    }

    pub fn send(self: *EmailTransport, a: Allocator, message: Communication.Message) !Communication.SendResult {
        const recipient = self.recipients.get(message.recipient) orelse return .invalid_recipient;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const scratch = arena.allocator();
        const mail_id = self.mailbox.createDraft(scratch, .{
            .recipient = recipient,
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
        var transport = try EmailTransport.init(fixture.arena.allocator(), &mailbox, &.{"Operator@EXAMPLE.COM"});
        const outcome = try transport.send(fixture.arena.allocator(), .{ .recipient = "Operator", .text = "hello" });
        try std.testing.expectEqual(case.outcome, std.meta.activeTag(outcome));
        try fixture.finish();
    }
}

test "an interrupted draft create has no submission to reconcile" {
    const Fixture = @import("test_jmap.zig").Fixture;
    var fixture = try Fixture.init(&.{.{ .method = "Email/set", .result = null }});
    defer fixture.deinit();
    var mailbox = try fixture.start();
    var transport = try EmailTransport.init(fixture.arena.allocator(), &mailbox, &.{"operator@example.com"});
    const outcome = try transport.send(fixture.arena.allocator(), .{ .recipient = "operator", .text = "hello" });
    try std.testing.expect(outcome == .not_submitted);
    try fixture.finish();
}

test "registered correspondent IDs each submit to their single configured address" {
    const Fixture = @import("test_jmap.zig").Fixture;
    var fixture = try Fixture.init(&.{
        .{ .method = "Email/set", .result = "{\"created\":{\"letter\":{\"id\":\"draft-1\"}}}", .properties = &.{
            .{ .path = &.{ "create", "letter", "to" }, .json = "[{\"email\":\"Reviewer+Ops@EXAMPLE.COM\"}]" },
        } },
        .{ .method = "EmailSubmission/set", .result = "{\"created\":{\"submission\":{\"id\":\"submitted-1\"}}}" },
        .{ .method = "Email/set", .result = "{\"created\":{\"letter\":{\"id\":\"draft-2\"}}}", .properties = &.{
            .{ .path = &.{ "create", "letter", "to" }, .json = "[{\"email\":\"operator@example.com\"}]" },
        } },
        .{ .method = "EmailSubmission/set", .result = "{\"created\":{\"submission\":{\"id\":\"submitted-2\"}}}" },
    });
    defer fixture.deinit();
    var mailbox = try fixture.start();
    const a = fixture.arena.allocator();
    var transport = try EmailTransport.init(a, &mailbox, &.{ "operator@example.com", "Reviewer+Ops@EXAMPLE.COM" });
    const review = try transport.send(a, .{ .recipient = "Reviewer+Ops", .text = "Review complete" });
    try std.testing.expect(review == .submitted);
    const operator = try transport.send(a, .{ .recipient = "operator", .text = "Deployment complete" });
    try std.testing.expect(operator == .submitted);
    try fixture.finish();
}

test "correspondent registration requires distinct IDs in the configured domain" {
    const a = std.testing.allocator;
    var jmap = @import("jmap.zig").Jmap.init(a, std.testing.io, "test");
    defer jmap.deinit();
    const address = "ivenna@example.com";
    var mailbox: Mail.Mailbox = .{
        .jmap = &jmap,
        .session_url = "",
        .address = address,
        .addressing = try @import("addressing.zig").Addressing.init(address),
    };
    try std.testing.expectError(error.InvalidCorrespondentAddress, EmailTransport.init(a, &mailbox, &.{ "reviewer@example.com", "operator@other.example" }));
    try std.testing.expectError(error.DuplicateCorrespondentId, EmailTransport.init(a, &mailbox, &.{ "operator@example.com", "operator@EXAMPLE.COM" }));
}

test "unregistered recipient IDs never create drafts" {
    const Fixture = @import("test_jmap.zig").Fixture;
    var fixture = try Fixture.init(&.{});
    defer fixture.deinit();
    var mailbox = try fixture.start();
    const a = fixture.arena.allocator();
    var empty = try EmailTransport.init(a, &mailbox, &.{});
    const denied = try empty.send(a, .{ .recipient = "operator", .text = "hello" });
    try std.testing.expect(denied == .invalid_recipient);
    var transport = try EmailTransport.init(a, &mailbox, &.{ "operator@example.com", "Reviewer+Ops@EXAMPLE.COM" });
    for ([_][]const u8{ "admin", "Operator", "Reviewer" }) |id| {
        const outcome = try transport.send(a, .{ .recipient = id, .text = "hello" });
        try std.testing.expect(outcome == .invalid_recipient);
    }
    try fixture.finish();
}
