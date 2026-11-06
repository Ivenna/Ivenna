const std = @import("std");
const Mail = @import("mail.zig");
const MailSources = @import("mail_sources.zig").MailSources;
const Input = @import("agent").Input;
const Allocator = std.mem.Allocator;

/// Track mail intake and store continuity handovers.
/// Read status, stars, and archiving do not control work.
pub const MailState = struct {
    mailbox: *Mail.Mailbox,
    sources: *MailSources,

    pub const Pending = struct {
        receipt: []const u8,
    };

    pub fn init(mailbox: *Mail.Mailbox, sources: *MailSources) MailState {
        return .{ .mailbox = mailbox, .sources = sources };
    }

    pub fn pending(self: *MailState, a: Allocator, limit: usize) ![]const Pending {
        var result: std.ArrayList(Pending) = .empty;
        for (try self.mailbox.pending(a, limit)) |letter| {
            const receipt = try self.sources.receiptId(a, letter.id);
            try self.sources.retain(receipt, letter);
            try result.append(a, .{ .receipt = receipt });
        }
        return result.toOwnedSlice(a);
    }

    pub fn complete(self: *MailState, a: Allocator, receipt: []const u8) !void {
        const origin = try self.sources.lookup(a, receipt);
        try self.mailbox.markHandled(a, origin.id);
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
        try self.mailbox.saveState(a, key, summary);
    }
};

fn excerpt(bytes: []const u8, limit: usize) []const u8 {
    var end = @min(limit, bytes.len);
    while (end > 0 and end < bytes.len and (bytes[end] & 0xc0) == 0x80) end -= 1;
    return bytes[0..end];
}
