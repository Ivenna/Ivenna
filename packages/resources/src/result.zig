const std = @import("std");
const content = @import("content");
const Content = content.Content;
const Allocator = std.mem.Allocator;

pub fn success(a: Allocator, value: anytype) !Content {
    return Content.fromText(a, try encode(a, value));
}

pub fn attachment(a: Allocator, source: anytype, part: Content.Part) !Content {
    return Content.fromParts(a, &.{ .{ .text = try encode(a, source) }, part });
}

pub fn imageUrl(a: Allocator, uri: []const u8, url: []const u8) !Content {
    return attachment(a, .{ .uri = uri, .kind = "image_url" }, .{ .image = .{ .url = url } });
}

pub fn unavailable(a: Allocator, uri: []const u8, omitted: content.Unavailable) !Content {
    return success(a, .{ .uri = uri, .kind = "file", .content = .{ .unavailable = omitted } });
}

fn encode(a: Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{ .result = value }, .{ .emit_null_optional_fields = false });
}

pub fn failure(a: Allocator, code: []const u8, message: []const u8) !Content {
    return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .@"error" = .{ .code = code, .message = message } }, .{}));
}
