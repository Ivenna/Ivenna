const std = @import("std");
const Mail = @import("mail.zig");
const MailSources = @import("mail_sources.zig").MailSources;
const Input = @import("input.zig");
const Work = @import("work.zig");
const Allocator = std.mem.Allocator;

/// Exchange communication with the outside world. MailState independently owns
/// ingestion progress and continuity records, using the same mail service.
pub const EmailTransport = struct {
    io: std.Io,
    mailbox: *Mail.Mailbox,
    sources: *MailSources,

    pub const Received = struct {
        input: Input.Input,
        route: []const u8,
        reply: ?Work.ReplyTarget,
    };

    pub fn init(io: std.Io, mailbox: *Mail.Mailbox, sources: *MailSources) EmailTransport {
        return .{ .io = io, .mailbox = mailbox, .sources = sources };
    }

    pub fn receive(self: *EmailTransport, a: Allocator, receipt: []const u8, limit: usize) !Received {
        const letter = try self.sources.lookup(a, receipt);
        const material = try self.project(a, letter, limit);
        const audience = try describe(a, replyAddresses(letter));
        return .{
            .input = .{ .content = material.content, .source = material.source },
            .route = try reference(a, "route", &.{ self.mailbox.session_url, self.mailbox.account_id, letter.thread_id }),
            .reply = if (self.isSelf(letter) or audience.len == 0) null else .{ .receipt = receipt, .audience = audience },
        };
    }

    pub fn recent(self: *EmailTransport, a: Allocator, limit: usize) ![]const Input.Evidence {
        var result: std.ArrayList(Input.Evidence) = .empty;
        for (try self.mailbox.recent(a, limit)) |letter|
            try result.append(a, try self.project(a, letter, 512));
        return result.toOwnedSlice(a);
    }

    pub fn history(self: *EmailTransport, a: Allocator, receipt: []const u8) ![]const Input.Evidence {
        const origin = try self.sources.lookup(a, receipt);
        const thread = try self.mailbox.thread(a, origin.thread_id, 32);
        var result: std.ArrayList(Input.Evidence) = .empty;
        for (thread.letters) |letter| {
            if (std.mem.eql(u8, letter.id, origin.id)) continue;
            try result.append(a, try self.project(a, letter, 512));
        }
        return result.toOwnedSlice(a);
    }

    pub fn reply(self: *EmailTransport, a: Allocator, receipt: []const u8, text: []const u8) !void {
        const origin = try self.sources.lookup(a, receipt);
        const submission = try self.mailbox.send(a, .{
            .to = replyAddresses(origin),
            .subject = try replySubject(a, origin.subject),
            .body = text,
            .in_reply_to = origin.message_id,
            .references = try replyReferences(a, origin),
        });
        if (submission.sent_copy == .unconfirmed)
            std.log.warn("mail {s} accepted for submission; sent-copy update unconfirmed", .{submission.mail_id});
    }

    fn project(self: *EmailTransport, a: Allocator, letter: Mail.Letter, limit: usize) !Input.Evidence {
        const text = if (letter.subject.len == 0)
            letter.body
        else
            try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ letter.subject, letter.body });
        const files = try self.sources.capture(a, letter, text);
        const authors = try describe(a, letter.from);
        return .{
            .content = if (text.len <= limit)
                .{ .text = text }
            else
                .{ .excerpt = .{ .text = excerpt(text, limit), .full = .{ .file = files.body.file, .byte_length = files.body.byte_length } } },
            .source = .{
                .reference = try self.sourceReference(a, letter),
                .description = if (authors.len == 0) null else try std.mem.join(a, ", ", authors),
                .observed_at_unix_ms = std.Io.Clock.real.now(self.io).toMilliseconds(),
                .details = .{ .file = files.details.file, .byte_length = files.details.byte_length },
            },
        };
    }

    fn sourceReference(self: *EmailTransport, a: Allocator, letter: Mail.Letter) ![]const u8 {
        if (letter.message_id) |id|
            return reference(a, "source", &.{ "message", std.mem.trim(u8, id, " \t\r\n<>") });
        return reference(a, "source", &.{ "native", self.mailbox.session_url, self.mailbox.account_id, letter.id });
    }

    fn isSelf(self: *EmailTransport, letter: Mail.Letter) bool {
        return letter.from.len == 1 and std.ascii.eqlIgnoreCase(letter.from[0].email, self.mailbox.address);
    }
};

fn replyAddresses(letter: Mail.Letter) []const Mail.Address {
    return if (letter.reply_to.len == 0) letter.from else letter.reply_to;
}

fn describe(a: Allocator, addresses: []const Mail.Address) ![]const []const u8 {
    const descriptions = try a.alloc([]const u8, addresses.len);
    for (addresses, descriptions) |address, *description|
        description.* = if (address.name) |name|
            try std.fmt.allocPrint(a, "{s} <{s}>", .{ name, address.email })
        else
            address.email;
    return descriptions;
}

fn reference(a: Allocator, domain: []const u8, components: []const []const u8) ![]const u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    for (components) |component| {
        hash.update(&.{0});
        hash.update(component);
    }
    const digest = std.fmt.bytesToHex(hash.finalResult(), .lower);
    return std.fmt.allocPrint(a, "{s}-{s}", .{ domain, digest });
}

fn excerpt(bytes: []const u8, limit: usize) []const u8 {
    var end = @min(limit, bytes.len);
    while (end > 0 and end < bytes.len and (bytes[end] & 0xc0) == 0x80) end -= 1;
    return bytes[0..end];
}

fn replySubject(a: Allocator, subject: []const u8) ![]const u8 {
    if (subject.len >= 3 and std.ascii.eqlIgnoreCase(subject[0..3], "re:")) return subject;
    return std.fmt.allocPrint(a, "Re: {s}", .{subject});
}

fn replyReferences(a: Allocator, letter: Mail.Letter) ![]const []const u8 {
    const retained = @min(letter.references.len, 31);
    const refs = try a.alloc([]const u8, retained + @as(usize, @intFromBool(letter.message_id != null)));
    @memcpy(refs[0..retained], letter.references[letter.references.len - retained ..]);
    if (letter.message_id) |id| refs[retained] = id;
    return refs;
}
