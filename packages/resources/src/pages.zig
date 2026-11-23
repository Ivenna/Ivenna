const std = @import("std");
const Content = @import("content").Content;
const result = @import("result.zig");
const locator = @import("locator.zig");
const windows = @import("window.zig");
const Allocator = std.mem.Allocator;
const Window = windows.Window;

const Page = @import("web.zig").Page;

const snapshot_limit = 256;

const Snapshot = struct {
    id: u64,
    bytes: []const u8,
    uri_end: usize,
    title_end: usize,
    title_truncated: bool,

    // Called under the cache lock. The serialized result belongs to the turn
    // and either focus can keep it after this snapshot is evicted.
    fn render(self: Snapshot, a: Allocator, window: Window, include_source: bool) !Content {
        const uri = try locator.snapshotUri(a, self.id);
        const source = self.bytes[self.title_end..];
        if (window.offset > source.len or (window.offset < source.len and source[@intCast(window.offset)] & 0xc0 == 0x80)) {
            return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .@"error" = .{
                .code = "invalid_range",
                .message = "Pass error.uri as location to reuse this snapshot. Omit view to start at byte zero, or set view.offset to a UTF-8 character boundary in the Markdown.",
                .uri = uri,
            } }, .{}));
        }
        const title = self.bytes[self.uri_end..self.title_end];
        const text = windows.utf8Prefix(source[@intCast(window.offset)..], window.textBytes());
        const next = window.offset + text.len;
        return result.success(a, .{
            .uri = uri,
            .source_uri = if (include_source) @as(?[]const u8, self.bytes[0..self.uri_end]) else null,
            .kind = "webpage",
            .title = if (include_source and title.len > 0) @as(?[]const u8, title) else null,
            .title_truncated = if (include_source and self.title_truncated) @as(?bool, true) else null,
            .content = text,
            .byte_length = source.len,
            .offset = window.offset,
            .next_offset = if (next < source.len) @as(?u64, next) else null,
        });
    }
};

pub const Cache = struct {
    mutex: std.Io.Mutex = .init,
    snapshots: std.ArrayList(Snapshot) = .empty,
    retained_bytes: usize = 0,
    byte_limit: usize = 32 * 1024 * 1024,

    pub fn deinit(self: *Cache, a: Allocator) void {
        for (self.snapshots.items) |snapshot| a.free(snapshot.bytes);
        self.snapshots.deinit(a);
    }

    pub fn open(self: *Cache, io: std.Io, storage: Allocator, turn: Allocator, source_uri: []const u8, page: Page, window: Window) !Content {
        const title = windows.utf8Prefix(page.title, 1024);
        const size = source_uri.len + title.len + page.markdown.len;
        if (size > self.byte_limit)
            return result.failure(turn, "page_too_large", "This page is too large to retain for reading.");
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.snapshots.ensureTotalCapacity(storage, @min(snapshot_limit, self.snapshots.items.len + 1));
        const bytes = try std.mem.concat(storage, u8, &.{ source_uri, title, page.markdown });
        var id: u64 = undefined;
        while (true) {
            io.random(std.mem.asBytes(&id));
            if (self.find(id) == null) break;
        }

        var removed: usize = 0;
        while (self.snapshots.items.len - removed >= snapshot_limit or self.retained_bytes > self.byte_limit - bytes.len) : (removed += 1) {
            const oldest = self.snapshots.items[removed];
            self.retained_bytes -= oldest.bytes.len;
            storage.free(oldest.bytes);
        }
        self.snapshots.replaceRangeAssumeCapacity(0, removed, &.{});
        const snapshot: Snapshot = .{
            .id = id,
            .bytes = bytes,
            .uri_end = source_uri.len,
            .title_end = source_uri.len + title.len,
            .title_truncated = title.len < page.title.len,
        };
        self.snapshots.appendAssumeCapacity(snapshot);
        self.retained_bytes += bytes.len;
        return snapshot.render(turn, window, true);
    }

    pub fn read(self: *Cache, io: std.Io, turn: Allocator, id: u64, window: Window) !?Content {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const snapshot = self.find(id) orelse return null;
        return try snapshot.render(turn, window, window.offset == 0);
    }

    fn find(self: *const Cache, id: u64) ?Snapshot {
        for (self.snapshots.items) |snapshot| if (snapshot.id == id) return snapshot;
        return null;
    }
};

test "a new fetch of the same URL preserves the previous version until eviction" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const url = "https://example.org/update";
    var cache: Cache = .{ .byte_limit = 2 * (url.len + "旧A".len) };
    defer cache.deinit(t.allocator);
    const first = try cache.open(t.io, t.allocator, a, url, .{ .title = "", .markdown = "旧A" }, .{ .offset = "旧".len });
    const fields = (try std.json.parseFromSliceLeaky(std.json.Value, a, first.parts[0].text, .{})).object.get("result").?.object;
    try t.expectEqualStrings(url, fields.get("source_uri").?.string);
    const id = (try locator.parse(a, fields.get("uri").?.string)).snapshot;

    const oversized = try cache.open(t.io, t.allocator, a, url, .{ .title = "This title and its source URL exceed the budget", .markdown = "" }, .{});
    const failure = (try std.json.parseFromSliceLeaky(std.json.Value, a, oversized.parts[0].text, .{})).object.get("error").?.object;
    try t.expectEqualStrings("page_too_large", failure.get("code").?.string);
    _ = try cache.open(t.io, t.allocator, a, url, .{ .title = "", .markdown = "新" }, .{});
    const old = (try cache.read(t.io, a, id, .{ .limit = 1 })).?;
    const latest = try cache.open(t.io, t.allocator, a, url, .{ .title = "", .markdown = "新" }, .{});
    try t.expect(try cache.read(t.io, a, id, .{}) == null);
    const retained = (try std.json.parseFromSliceLeaky(std.json.Value, a, old.parts[0].text, .{})).object.get("result").?.object;
    try t.expectEqualStrings("旧", retained.get("content").?.string);

    // With room for all the bytes, empty documents still occupy snapshot slots.
    cache.byte_limit = std.math.maxInt(usize);
    const latest_fields = (try std.json.parseFromSliceLeaky(std.json.Value, a, latest.parts[0].text, .{})).object.get("result").?.object;
    const latest_id = (try locator.parse(a, latest_fields.get("uri").?.string)).snapshot;
    for (0..snapshot_limit) |_| _ = try cache.open(t.io, t.allocator, a, url, .{ .title = "Empty", .markdown = "" }, .{});
    try t.expect(try cache.read(t.io, a, latest_id, .{}) == null);
}
