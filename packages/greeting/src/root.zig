//! Greeting output.

const std = @import("std");

/// Write a UTF-8 greeting. The caller owns and flushes the writer.
pub fn write(writer: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    try writer.print("Hello, {s}!\n", .{name});
}

test "writes a UTF-8 greeting through a caller-owned writer" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try write(&writer, "Zoë");

    try std.testing.expectEqualStrings("Hello, Zoë!\n", writer.buffered());
}
