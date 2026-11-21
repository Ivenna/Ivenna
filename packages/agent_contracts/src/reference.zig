const std = @import("std");

pub const max_name_characters = 32;

/// Issue a named reference in the owning execution domain. Success confirms
/// durable allocation; the returned reference belongs to a.
pub const Issuer = struct {
    context: *anyopaque,
    issue: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]const u8,

    pub fn create(self: Issuer, a: std.mem.Allocator, name: []const u8) ![]const u8 {
        return self.issue(self.context, a, name);
    }
};

/// A name supplies a recognition cue. Execution allocates the suffix; the
/// resource owner controls lifetime. Association uses the complete reference.
pub fn create(a: std.mem.Allocator, name: []const u8, serial: u64) ![]const u8 {
    if (!validName(name) or serial == 0) return error.InvalidReference;
    return std.fmt.allocPrint(a, "{s}-{d}", .{ name, serial });
}

pub fn validName(name: []const u8) bool {
    const length = std.unicode.utf8CountCodepoints(name) catch return false;
    if (length > max_name_characters or std.mem.trim(u8, name, " \t\r\n").len == 0) return false;
    for (name) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

/// Inspect a generated reference when checking persisted identity consistency.
/// A numeric suffix alone never establishes that a reference addresses an object.
pub fn sequence(reference: []const u8) ?u64 {
    const separator = std.mem.lastIndexOfScalar(u8, reference, '-') orelse return null;
    if (!validName(reference[0..separator])) return null;
    const digits = reference[separator + 1 ..];
    if (digits.len == 0 or digits[0] == '0') return null;
    for (digits) |byte| if (byte < '0' or byte > '9') return null;
    return std.fmt.parseInt(u64, digits, 10) catch null;
}
