const std = @import("std");
const zdt = @import("zdt");

/// One absolute instant at the model boundary; execution keeps Unix milliseconds.
pub const Instant = struct {
    unix_ms: i64,

    pub fn jsonStringify(self: Instant, writer: anytype) !void {
        const text = format(self.unix_ms);
        try writer.write(&text);
    }
};

pub fn parse(text: []const u8) error{InvalidTimestamp}!Instant {
    const date = zdt.Datetime.fromISO8601(text) catch return error.InvalidTimestamp;
    if (!date.isAware()) return error.InvalidTimestamp;
    return .{ .unix_ms = @intCast(date.toUnix(.millisecond)) };
}

pub fn format(unix_ms: i64) [24]u8 {
    const date = zdt.Datetime.fromUnix(unix_ms, .millisecond, .{ .tz = &zdt.Timezone.UTC }) catch unreachable;
    var text: [24]u8 = undefined;
    _ = std.fmt.bufPrint(&text, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        @as(u16, @intCast(date.year)),
        date.month,
        date.day,
        date.hour,
        date.minute,
        date.second,
        date.nanosecond / std.time.ns_per_ms,
    }) catch unreachable;
    return text;
}
