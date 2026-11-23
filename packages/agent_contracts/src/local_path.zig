const std = @import("std");
const Allocator = std.mem.Allocator;
const JsonString = @import("json_string.zig");

/// A filesystem path supplied as a JSON string. OS calls use the decoded bytes.
pub const Argument = struct {
    bytes: []const u8,

    pub fn jsonParse(a: Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!Argument {
        const text = try JsonString.jsonParse(a, source, options);
        return .{ .bytes = fromReference(a, text.bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.UnexpectedToken,
        } };
    }
};

/// Project an absolute host path into a single textual reference.
pub fn reference(a: Allocator, path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (std.unicode.utf8ValidateSlice(path)) return path;
    return fileUri(a, path, .file);
}

/// Directories end in a slash so relative URI references resolve to children.
pub fn fileUri(a: Allocator, path: []const u8, kind: enum { file, directory }) ![]const u8 {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
    const directory = kind == .directory;
    const component: std.Uri.Component = .{ .raw = if (directory) std.mem.trimEnd(u8, path, "/") else path };
    return a.print("file://{f}{s}", .{ std.fmt.alt(component, .formatPath), if (directory) "/" else "" });
}

/// Filesystem operations also accept literal relative paths.
pub fn fromReference(a: Allocator, text: []const u8) ![]const u8 {
    if (std.ascii.startsWithIgnoreCase(text, "file://")) return fromFileUri(a, try parseUri(text));
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidPath;
    return text;
}

/// std.Uri parses components but permits malformed escapes and unescaped whitespace.
pub fn parseUri(text: []const u8) !std.Uri {
    for (text, 0..) |byte, index| {
        if (byte <= ' ' or byte == 0x7f) return error.InvalidUri;
        if (byte == '%' and (text.len - index < 3 or
            !std.ascii.isHex(text[index + 1]) or !std.ascii.isHex(text[index + 2]))) return error.InvalidUri;
    }
    return std.Uri.parse(text) catch error.InvalidUri;
}

/// Preserve traversal order so the filesystem can resolve symbolic links and '..'.
pub fn fromFileUri(a: Allocator, uri: std.Uri) ![]const u8 {
    if (uri.user != null or uri.password != null or
        uri.port != null or uri.query != null or uri.fragment != null) return error.InvalidFileUri;
    if (uri.host) |host| {
        if (!std.ascii.eqlIgnoreCase(try host.toRawMaybeAlloc(a), "localhost")) return error.InvalidFileUri;
    }
    switch (uri.path) {
        inline else => |bytes| if (!std.mem.startsWith(u8, bytes, "/")) return error.InvalidFileUri,
    }
    const path = try uri.path.toRawMaybeAlloc(a);
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidFileUri;
    return path;
}
