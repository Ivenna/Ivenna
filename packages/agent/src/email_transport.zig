const std = @import("std");
const Mail = @import("mail.zig");
const MailSources = @import("mail_sources.zig").MailSources;
const Input = @import("input.zig");
const Communication = @import("communication.zig");
const Allocator = std.mem.Allocator;

/// Exchange messages with the outside world. MailState owns input consumption
/// and handovers in the same mail service.
pub const EmailTransport = struct {
    io: std.Io,
    mailbox: *Mail.Mailbox,
    sources: *MailSources,

    pub fn init(io: std.Io, mailbox: *Mail.Mailbox, sources: *MailSources) EmailTransport {
        return .{ .io = io, .mailbox = mailbox, .sources = sources };
    }

    pub fn receive(self: *EmailTransport, a: Allocator, receipt: []const u8, limit: usize) !Input.Input {
        const letter = try self.sources.lookup(a, receipt);
        const material = try self.project(a, letter, limit);
        return .{
            .content = material.content,
            .source = material.source,
            .contacts = material.contacts,
        };
    }

    pub fn recent(self: *EmailTransport, a: Allocator, limit: usize) ![]const Input.Evidence {
        var result: std.ArrayList(Input.Evidence) = .empty;
        for (try self.mailbox.recent(a, limit)) |letter|
            try result.append(a, try self.project(a, letter, 512));
        return result.toOwnedSlice(a);
    }

    pub fn send(self: *EmailTransport, a: Allocator, message: Communication.Message) !Communication.Submission {
        const recipients = try a.alloc(Mail.Address, message.recipients.len);
        for (message.recipients, recipients) |id, *recipient| {
            const path = try self.contactPath(a, id);
            const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .unlimited) catch |err| switch (err) {
                error.FileNotFound => return error.InvalidContactReference,
                else => return err,
            };
            recipient.* = try std.json.parseFromSliceLeaky(Mail.Address, a, bytes, .{});
        }
        const submission = try self.mailbox.send(a, .{
            .to = recipients,
            .subject = "Ivenna",
            .body = message.text,
        });
        if (submission.sent_copy == .unconfirmed)
            std.log.warn("mail {s} accepted for submission; sent-copy update unconfirmed", .{submission.mail_id});
        return .{ .reference = try reference(a, "submission", &.{ self.mailbox.session_url, self.mailbox.account_id, submission.mail_id }) };
    }

    fn project(self: *EmailTransport, a: Allocator, letter: Mail.Letter, limit: usize) !Input.Evidence {
        const text = if (letter.subject.len == 0)
            letter.body
        else
            try std.fmt.allocPrint(a, "{s}\n\n{s}", .{ letter.subject, letter.body });
        const files = try self.sources.capture(a, letter, text);
        const authors = try describe(a, letter.from);
        const addresses = replyAddresses(letter);
        const contacts = try a.alloc(Communication.Contact, addresses.len);
        for (addresses, contacts) |address, *contact| contact.* = try self.rememberContact(a, address);
        return .{
            .contacts = contacts,
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

    fn rememberContact(self: *EmailTransport, a: Allocator, address: Mail.Address) !Communication.Contact {
        const id = try reference(a, "contact", &.{address.email});
        const path = try self.contactPath(a, id);
        _ = try std.Io.Dir.cwd().createDirPathStatus(self.io, std.fs.path.dirname(path).?, .fromMode(0o700));
        var file = try std.Io.Dir.cwd().createFileAtomic(self.io, path, .{ .permissions = .fromMode(0o600) });
        defer file.deinit(self.io);
        try file.file.writeStreamingAll(self.io, try std.json.Stringify.valueAlloc(a, address, .{}));
        file.link(self.io) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        return .{ .reference = id, .description = contactDescription(address) };
    }

    fn contactPath(self: *EmailTransport, a: Allocator, id: []const u8) ![]const u8 {
        const prefix = "contact-";
        if (id.len != prefix.len + 64 or !std.mem.startsWith(u8, id, prefix)) return error.InvalidContactReference;
        for (id[prefix.len..]) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidContactReference;
        return std.fs.path.join(a, &.{ self.sources.data_directory, "contacts", try std.fmt.allocPrint(a, "{s}.json", .{id}) });
    }
};

fn replyAddresses(letter: Mail.Letter) []const Mail.Address {
    return if (letter.reply_to.len == 0) letter.from else letter.reply_to;
}

fn describe(a: Allocator, addresses: []const Mail.Address) ![]const []const u8 {
    const descriptions = try a.alloc([]const u8, addresses.len);
    for (addresses, descriptions) |address, *description|
        description.* = contactDescription(address);
    return descriptions;
}

fn contactDescription(address: Mail.Address) []const u8 {
    if (address.name) |name|
        if (name.len != 0) return name;
    return "Correspondent";
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
