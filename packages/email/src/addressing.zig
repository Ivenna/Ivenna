const std = @import("std");

/// Recognizes readable IDs in the configured mailbox's domain.
pub const Addressing = struct {
    local_part: []const u8,
    domain: []const u8,

    /// Borrows a dot-atom local part and ASCII hostname domain.
    pub fn init(self_address: []const u8) !Addressing {
        const separator = std.mem.indexOfScalar(u8, self_address, '@') orelse return error.InvalidMailAddress;
        const local = self_address[0..separator];
        const domain = self_address[separator + 1 ..];
        if (!validId(local) or !validDomain(domain)) return error.InvalidMailAddress;
        return .{ .local_part = local, .domain = domain };
    }

    /// Borrows the local part of a same-domain address, preserving its case.
    pub fn id(self: Addressing, full_address: []const u8) ?[]const u8 {
        const separator = std.mem.indexOfScalar(u8, full_address, '@') orelse return null;
        const local = full_address[0..separator];
        if (!validId(local) or !std.ascii.eqlIgnoreCase(full_address[separator + 1 ..], self.domain)) return null;
        return local;
    }

    pub fn isSelf(self: Addressing, full_address: []const u8) bool {
        const local = self.id(full_address) orelse return false;
        return std.mem.eql(u8, local, self.local_part);
    }

    /// IDs use ASCII dot-atom local parts without quoting or escaping.
    fn validId(value: []const u8) bool {
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

test "correspondent IDs preserve local case and stay in the configured domain" {
    const addressing = try Addressing.init("Ivenna@ivenna.test");
    try std.testing.expectEqualStrings("Alice.work+notes", addressing.id("Alice.work+notes@ivenna.test").?);
    try std.testing.expectEqualStrings("Alice.work+notes", addressing.id("Alice.work+notes@IVENNA.TEST").?);
    try std.testing.expect(addressing.isSelf("Ivenna@IVENNA.TEST"));
    try std.testing.expect(!addressing.isSelf("ivenna@ivenna.test"));

    try std.testing.expectEqual(null, addressing.id("Alice@elsewhere.test"));
    try std.testing.expectEqual(null, addressing.id("Alice..work@ivenna.test"));
}
