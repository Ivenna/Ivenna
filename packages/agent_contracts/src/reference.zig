const std = @import("std");

/// A name supplies a recognition cue; the allocating capability owns uniqueness
/// and lifetime. Callers use the complete returned reference for association.
pub fn create(a: std.mem.Allocator, name: []const u8, serial: u64) ![]const u8 {
    if (!validName(name) or serial == 0) return error.InvalidReference;
    return std.fmt.allocPrint(a, "{s}-{d}", .{ name, serial });
}

pub fn validName(name: []const u8) bool {
    if (std.mem.trim(u8, name, " \t\r\n").len == 0 or !std.unicode.utf8ValidateSlice(name)) return false;
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
