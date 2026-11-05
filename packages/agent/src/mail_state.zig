const std = @import("std");
const Mail = @import("mail.zig");
const MailSources = @import("mail_sources.zig").MailSources;
const Input = @import("input.zig");
const Allocator = std.mem.Allocator;

/// Mailbox work control and independently keyed continuity records. The current
/// deployment controls the same physical letters used for boundary delivery.
pub const MailState = struct {
    io: std.Io,
    mailbox: *Mail.Mailbox,
    sources: *MailSources,

    pub const Pending = struct {
        receipt: []const u8,
        priority: bool,
    };

    pub fn init(io: std.Io, mailbox: *Mail.Mailbox, sources: *MailSources) MailState {
        return .{ .io = io, .mailbox = mailbox, .sources = sources };
    }

    pub fn pending(self: *MailState, a: Allocator, limit: usize) ![]const Pending {
        var result: std.ArrayList(Pending) = .empty;
        for (try self.mailbox.unread(a, limit)) |letter| {
            const receipt = try self.sources.receiptId(a, letter.id);
            try self.sources.retain(receipt, letter);
            try result.append(a, .{ .receipt = receipt, .priority = letter.flagged });
        }
        return result.toOwnedSlice(a);
    }

    pub fn withdrawn(self: *MailState, a: Allocator, receipt: []const u8) !bool {
        const origin = try self.sources.lookup(a, receipt);
        const current = self.mailbox.read(a, origin.id) catch |err| switch (err) {
            error.MailNotFound => return true,
            else => return err,
        };
        return !current.in_inbox;
    }

    pub fn complete(self: *MailState, a: Allocator, receipt: []const u8, answered: bool) !void {
        const origin = try self.sources.lookup(a, receipt);
        if (answered) try self.mailbox.markAnswered(a, origin.id) else try self.mailbox.markRead(a, origin.id);
    }

    pub fn loadHandover(self: *MailState, a: Allocator, key: []const u8, limit: usize) !?Input.Handover {
        const letter = try self.mailbox.latestState(a, key) orelse return null;
        const files = try self.sources.capture(a, letter, letter.body);
        return .{
            .summary = excerpt(letter.body, limit),
            .source = .{ .file = files.body.file, .byte_length = files.body.byte_length },
        };
    }

    pub fn saveHandover(self: *MailState, a: Allocator, key: []const u8, summary: []const u8) !void {
        _ = try self.mailbox.saveState(a, key, summary);
    }
};

fn excerpt(bytes: []const u8, limit: usize) []const u8 {
    var end = @min(limit, bytes.len);
    while (end > 0 and end < bytes.len and (bytes[end] & 0xc0) == 0x80) end -= 1;
    return bytes[0..end];
}
