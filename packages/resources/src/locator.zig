const std = @import("std");
const content = @import("content");
const LocalPath = @import("agent_contracts").LocalPath;
const Allocator = std.mem.Allocator;

pub const Locator = union(enum) {
    file: []const u8,
    web: []const u8,
    snapshot: u64,
};

/// An absolute host path is literal. Percent escapes apply only to URIs.
pub fn parse(a: Allocator, reference: []const u8) !Locator {
    if (std.mem.startsWith(u8, reference, "/")) return .{ .file = try LocalPath.fromReference(a, reference) };
    const uri = try LocalPath.parseUri(reference);
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        if (uri.host == null or uri.user != null or uri.password != null) return error.InvalidWebUrl;
        return .{ .web = reference };
    }
    if (std.ascii.eqlIgnoreCase(uri.scheme, "ivenna")) {
        const hex = std.mem.cutPrefix(u8, reference[uri.scheme.len + 1 ..], "fetch/") orelse return error.InvalidSnapshotUri;
        if (hex.len != 16) return error.InvalidSnapshotUri;
        var bytes: [8]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, hex) catch return error.InvalidSnapshotUri;
        return .{ .snapshot = std.mem.readInt(u64, &bytes, .big) };
    }
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "file")) return error.UnsupportedScheme;
    return .{ .file = try LocalPath.fromFileUri(a, uri) };
}

/// A shell can write one URL followed by its usual line ending.
pub fn imageUrlFromText(a: Allocator, text: []const u8) ![]const u8 {
    const url = content.withoutLineEnding(text);
    if (!std.unicode.utf8ValidateSlice(url)) return error.UnsupportedImage;
    if (std.ascii.startsWithIgnoreCase(url, "data:image/")) {
        const comma = std.mem.indexOfScalar(u8, url, ',') orelse return error.UnsupportedImage;
        if (comma <= "data:image/".len or comma + 1 == url.len) return error.UnsupportedImage;
        for (url) |ch| if (ch <= ' ' or ch == 0x7f) return error.UnsupportedImage;
    } else {
        const location = parse(a, url) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.UnsupportedImage,
        };
        if (location != .web) return error.UnsupportedImage;
    }
    return url;
}

test "local file URIs round trip filesystem bytes and keep traversal order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = "/work/a b#%20?\xff";
    const uri = try LocalPath.reference(a, path);
    try std.testing.expectEqualStrings("file:///work/a%20b%23%2520%3F%FF", uri);
    try std.testing.expectEqualStrings(path, (try parse(a, uri)).file);
    try std.testing.expectEqualStrings(path, try LocalPath.fromReference(a, uri));
    try std.testing.expectEqualStrings("file:///", try LocalPath.fileUri(a, "/", .directory));
    try std.testing.expectEqualStrings("file:///a%2520/", try LocalPath.fileUri(a, "/a%20//", .directory));
    try std.testing.expectEqualStrings("/work/link/../file", (try parse(a, "file:///work/link/../file")).file);
    try std.testing.expectEqualStrings("/tmp/a", (try parse(a, "FILE://%6cOCALHOST/tmp/a")).file);
    const web = "https://example.com/a%2Fb?q=x%20y#fragment";
    try std.testing.expectEqualStrings(web, (try parse(a, web)).web);
    try std.testing.expectError(error.InvalidWebUrl, parse(a, "https:///missing-host"));
    try std.testing.expectError(error.InvalidWebUrl, parse(a, "https://user@example.com/a"));
    try std.testing.expectError(error.InvalidFileUri, parse(a, "file://remote/tmp/a"));
    try std.testing.expectError(error.InvalidFileUri, parse(a, "file:///a%00b"));
    try std.testing.expectError(error.InvalidUri, parse(a, "file:///a%2"));
    const literal = "/work/链接/../a b#%20?%\nline";
    try std.testing.expectEqualStrings(literal, try LocalPath.reference(a, literal));
    try std.testing.expectEqualStrings(literal, (try parse(a, literal)).file);
    try std.testing.expectEqualStrings("reports/q%2F", try LocalPath.fromReference(a, "reports/q%2F"));
    try std.testing.expectError(error.InvalidPath, parse(a, "/work/\x00file"));
    try std.testing.expectError(error.InvalidUri, parse(a, "work/doc.md"));
    for ([_][]const u8{ "file:doc.md", "file:%2Fwork/doc.md" }) |relative_file|
        try std.testing.expectError(error.InvalidFileUri, parse(a, relative_file));
    try std.testing.expectError(error.UnsupportedScheme, parse(a, "other:x"));
    try std.testing.expectError(error.InvalidSnapshotUri, parse(a, "ivenna:fetch/invalid"));
}

pub fn snapshotUri(a: Allocator, id: u64) ![]const u8 {
    return a.print("ivenna:fetch/{x:0>16}", .{id});
}
