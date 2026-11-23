const std = @import("std");
const Allocator = std.mem.Allocator;

/// Accounted, observable content omission for one request. Byte counts are
/// encoded-request deltas measured by the caller's `measure` function, never
/// raw part lengths: the same part can cost different bytes per adapter.
pub const Omissions = struct {
    truncated_text_bytes: u64 = 0,
    dropped_files: u32 = 0,
    dropped_file_bytes: u64 = 0,
    dropped_images: u32 = 0,
    dropped_image_bytes: u64 = 0,
    dropped_entries: u32 = 0,
    dropped_entry_bytes: u64 = 0,
    measured_before: u64 = 0,
    measured_after: u64 = 0,
    budget: u64 = 0,

    pub const Kind = enum { truncated_text, files, images, entries };

    pub fn any(self: Omissions) bool {
        return self.truncated_text_bytes != 0 or self.dropped_files != 0 or
            self.dropped_images != 0 or self.dropped_entries != 0;
    }

    pub fn record(self: *Omissions, kind: Kind, bytes: u64, count: u32) void {
        switch (kind) {
            .truncated_text => self.truncated_text_bytes += bytes,
            .files => {
                self.dropped_files += count;
                self.dropped_file_bytes += bytes;
            },
            .images => {
                self.dropped_images += count;
                self.dropped_image_bytes += bytes;
            },
            .entries => {
                self.dropped_entries += count;
                self.dropped_entry_bytes += bytes;
            },
        }
    }

    /// One user-visible note describing what was omitted and where it still
    /// lives. Null when nothing was omitted, so callers add nothing.
    pub fn render(self: Omissions, a: Allocator) !?[]const u8 {
        if (!self.any()) return null;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        try out.appendSlice(a, try std.fmt.allocPrint(a, "Context note: this request was reduced to fit the {d}-byte budget ({d} bytes measured before, {d} after). " ++
            "Omitted content is still in the retained history; nothing was destroyed.", .{ self.budget, self.measured_before, self.measured_after }));
        if (self.truncated_text_bytes != 0)
            try out.appendSlice(a, try std.fmt.allocPrint(a, " Tool output text truncated: {d} bytes.", .{self.truncated_text_bytes}));
        if (self.dropped_files != 0)
            try out.appendSlice(a, try std.fmt.allocPrint(a, " Files omitted: {d} ({d} bytes).", .{ self.dropped_files, self.dropped_file_bytes }));
        if (self.dropped_images != 0)
            try out.appendSlice(a, try std.fmt.allocPrint(a, " Images omitted: {d} ({d} bytes).", .{ self.dropped_images, self.dropped_image_bytes }));
        if (self.dropped_entries != 0)
            try out.appendSlice(a, try std.fmt.allocPrint(a, " Earlier history items omitted: {d} ({d} bytes).", .{ self.dropped_entries, self.dropped_entry_bytes }));
        return try out.toOwnedSlice(a);
    }
};

test "empty omissions render nothing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), try (Omissions{}).render(arena.allocator()));
}

test "omissions render counts and bytes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var o: Omissions = .{ .budget = 1000, .measured_before = 4000, .measured_after = 900 };
    o.record(.truncated_text, 100, 1);
    o.record(.images, 3000, 2);
    try std.testing.expect(o.any());
    const text = (try o.render(arena.allocator())).?;
    try std.testing.expect(std.mem.indexOf(u8, text, "budget") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Images omitted: 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "4000") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "still in the retained history") != null);
}
