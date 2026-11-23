const std = @import("std");
const FileUri = @import("agent_contracts").FileUri;
const Allocator = std.mem.Allocator;

pub const Locator = union(enum) {
    file: []const u8,
    web: []const u8,
    snapshot: u64,
};

/// Parse a complete resource URI. Only the local filesystem consumes decoded path bytes.
pub fn parse(a: Allocator, reference: []const u8) !Locator {
    for (reference, 0..) |byte, index| {
        if (byte <= ' ' or byte == 0x7f) return error.InvalidUri;
        if (byte == '%' and (reference.len - index < 3 or
            !std.ascii.isHex(reference[index + 1]) or !std.ascii.isHex(reference[index + 2]))) return error.InvalidUri;
    }
    const uri = std.Uri.parse(reference) catch return error.InvalidUri;

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
    return .{ .file = try FileUri.toPath(a, uri) };
}

test "local file URIs round trip filesystem bytes and keep traversal order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = "/work/a b#%20?\xff";
    const uri = try FileUri.fromPath(a, path, .file);
    try std.testing.expectEqualStrings("file:///work/a%20b%23%2520%3F%FF", uri);
    try std.testing.expectEqualStrings(path, (try parse(a, uri)).file);
    try std.testing.expectEqualStrings("file:///", try FileUri.fromPath(a, "/", .directory));
    try std.testing.expectEqualStrings("file:///a%2520/", try FileUri.fromPath(a, "/a%20//", .directory));
    try std.testing.expectEqualStrings("/work/link/../file", (try parse(a, "file:///work/link/../file")).file);
    try std.testing.expectEqualStrings("/tmp/a", (try parse(a, "FILE://LOCALHOST/tmp/a")).file);
    const web = "https://example.com/a%2Fb?q=x%20y#fragment";
    try std.testing.expectEqualStrings(web, (try parse(a, web)).web);
    try std.testing.expectError(error.InvalidWebUrl, parse(a, "https:///missing-host"));
    try std.testing.expectError(error.InvalidWebUrl, parse(a, "https://user@example.com/a"));
    try std.testing.expectError(error.InvalidFileUri, parse(a, "file://remote/tmp/a"));
    try std.testing.expectError(error.InvalidFileUri, parse(a, "file:///a%00b"));
    try std.testing.expectError(error.InvalidUri, parse(a, "file:///a%2"));
    try std.testing.expectError(error.InvalidUri, parse(a, "/work/doc.md"));
    for ([_][]const u8{ "file:doc.md", "file:%2Fwork/doc.md" }) |relative_file|
        try std.testing.expectError(error.InvalidFileUri, parse(a, relative_file));
    try std.testing.expectError(error.UnsupportedScheme, parse(a, "other:x"));
}

pub fn snapshotUri(a: Allocator, id: u64) ![]const u8 {
    return a.print("ivenna:fetch/{x:0>16}", .{id});
}

test "snapshot URIs identify a fetch independently of its reading window" {
    const a = std.testing.allocator;
    const reference = try snapshotUri(a, 0xf01a);
    defer a.free(reference);
    try std.testing.expectEqual(0xf01a, (try parse(a, reference)).snapshot);
    for ([_][]const u8{ "ivenna:fetch/0", "ivenna:fetch/0123456789abcdef#2", "ivenna://host/fetch/0123456789abcdef", "ivenna:fetch/+000000000000001" }) |invalid|
        try std.testing.expectError(error.InvalidSnapshotUri, parse(a, invalid));
}
