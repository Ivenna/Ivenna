const std = @import("std");
const Allocator = std.mem.Allocator;

/// Maps readable IDs to addresses in the configured mailbox's domain.
pub const Addressing = struct {
    domain: []const u8,

    /// Borrows the domain from a dot-atom address with an ASCII hostname domain.
    pub fn init(self_address: []const u8) !Addressing {
        const separator = std.mem.indexOfScalar(u8, self_address, '@') orelse return error.InvalidMailAddress;
        const local = self_address[0..separator];
        const domain = self_address[separator + 1 ..];
        if (!validId(local) or !validDomain(domain)) return error.InvalidMailAddress;
        return .{ .domain = domain };
    }

    /// Borrows the local part of a same-domain address, preserving its case.
    pub fn id(self: Addressing, full_address: []const u8) ?[]const u8 {
        const separator = std.mem.indexOfScalar(u8, full_address, '@') orelse return null;
        const local = full_address[0..separator];
        if (!validId(local) or !std.ascii.eqlIgnoreCase(full_address[separator + 1 ..], self.domain)) return null;
        return local;
    }

    /// Allocates a native address for an ID in this domain.
    pub fn address(self: Addressing, a: Allocator, recipient_id: []const u8) ![]const u8 {
        if (!validId(recipient_id)) return error.InvalidRecipientId;
        return std.fmt.allocPrint(a, "{s}@{s}", .{ recipient_id, self.domain });
    }

    /// IDs use ASCII dot-atom local parts without quoting or escaping.
    pub fn validId(value: []const u8) bool {
        var atom_start = true;
        for (value) |character| switch (character) {
            '.' => {
                if (atom_start) return false;
                atom_start = true;
            },
            'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~' => atom_start = false,
            else => return false,
        };
        return !atom_start;
    }
};

fn validDomain(domain: []const u8) bool {
    var labels = std.mem.splitScalar(u8, domain, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or !std.ascii.isAlphanumeric(label[0]) or !std.ascii.isAlphanumeric(label[label.len - 1])) return false;
        for (label) |character| {
            if (!std.ascii.isAlphanumeric(character) and character != '-') return false;
        }
    }
    return true;
}
