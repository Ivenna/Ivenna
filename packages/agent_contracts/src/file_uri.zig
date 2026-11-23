const std = @import("std");

/// Encode host path bytes. A directory URI ends in a slash so a relative
/// reference resolves to a child of that directory.
pub fn fromPath(a: std.mem.Allocator, path: []const u8, kind: enum { file, directory }) ![]const u8 {
    if (!std.fs.path.isAbsolute(path)) return error.RelativePath;
    const directory = kind == .directory;
    const component: std.Uri.Component = .{ .raw = if (directory) std.mem.trimEnd(u8, path, "/") else path };
    return a.print("file://{f}{s}", .{ std.fmt.alt(component, .formatPath), if (directory) "/" else "" });
}

/// Extract a local path from a parsed URI with valid percent escapes.
/// Preserve traversal order so the filesystem can resolve symlinks and '..'.
pub fn toPath(arena: std.mem.Allocator, uri: std.Uri) ![]const u8 {
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "file") or uri.user != null or uri.password != null or
        uri.port != null or uri.query != null or uri.fragment != null) return error.InvalidFileUri;
    if (uri.host) |host| switch (host) {
        inline else => |bytes| if (!std.ascii.eqlIgnoreCase(bytes, "localhost")) return error.InvalidFileUri,
    };
    switch (uri.path) {
        inline else => |bytes| if (!std.mem.startsWith(u8, bytes, "/")) return error.InvalidFileUri,
    }
    const path = try uri.path.toRawMaybeAlloc(arena);
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidFileUri;
    return path;
}
