const std = @import("std");
const content = @import("content");
const Content = content.Content;
const Allocator = std.mem.Allocator;

pub fn success(a: Allocator, value: anytype) !Content {
    return Content.fromText(a, try encode(a, value));
}

pub fn imageUrl(a: Allocator, url: []const u8) !Content {
    const image: content.ImageContent = .{ .url = url };
    const text = try encode(a, .{ .uri = image.url, .kind = "image_url", .content = .{ .image = image.describe() } });
    return Content.fromParts(a, &.{ .{ .text = text }, .{ .image = image } });
}

pub fn fileMedia(a: Allocator, uri: []const u8, media: content.Media) !Content {
    return switch (media) {
        .image => |image| {
            const length = switch (image) {
                .data => |data| data.bytes.len,
                .url => |url| url.len,
            };
            return fileAttachment(a, uri, length, .image, image);
        },
        .file => |file| fileAttachment(a, uri, file.bytes.len, .file, file),
        .unavailable => |reason| success(a, .{ .uri = uri, .kind = "file", .content = .{ .unavailable = reason }, .byte_length = reason.byte_length }),
    };
}

fn fileAttachment(a: Allocator, uri: []const u8, length: u64, comptime tag: enum { image, file }, value: @FieldType(Content.Part, @tagName(tag))) !Content {
    const description = switch (tag) {
        .image => .{ .image = value.describe() },
        .file => .{ .file = value.describe() },
    };
    const text = try encode(a, .{ .uri = uri, .kind = "file", .content = description, .byte_length = length });
    return Content.fromParts(a, &.{ .{ .text = text }, @unionInit(Content.Part, @tagName(tag), value) });
}

fn encode(a: Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{ .result = value }, .{});
}

pub fn failure(a: Allocator, code: []const u8, message: []const u8) !Content {
    return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .@"error" = .{ .code = code, .message = message } }, .{}));
}
