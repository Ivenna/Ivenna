const std = @import("std");
const content = @import("content");
const locator = @import("locator.zig");
const LocalFile = content.LocalFile;
const LocalPath = @import("agent_contracts").LocalPath;
const result = @import("result.zig");
const windows = @import("window.zig");
const Window = windows.Window;
const View = windows.View;
const Allocator = std.mem.Allocator;
const Content = content.Content;

pub fn read(io: std.Io, a: Allocator, path: []const u8, view: View) !Content {
    return readPath(io, a, path, view) catch |err| {
        switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            error.InvalidRange => return result.failure(a, "invalid_range", "Use the previous result's next_offset as view.offset to continue, or omit view to start again. Text offsets must fall on a UTF-8 character boundary."),
            error.UnsupportedImage => return result.failure(a, "unsupported_view", "The image view needs a recognized image or a file containing an image URL."),
            error.DirectoryView => return result.failure(a, "unsupported_view", "Omit view or select a window to list a directory."),
            error.FileMetadata => return result.failure(a, "unsupported_view", "Metadata is available when listing a directory."),
            else => {},
        }
        const uri = try LocalPath.fileUri(a, path, .file);
        const message = switch (err) {
            error.FileNotFound, error.NotDir => return result.failure(a, "not_found", try a.print("No file or directory exists at {s}.", .{uri})),
            error.AccessDenied, error.PermissionDenied => try a.print("Permission to read {s} was denied.", .{uri}),
            error.SymLinkLoop => try a.print("Could not follow the chain of symbolic links at {s}.", .{uri}),
            error.NotRegularFile => try a.print("{s} does not identify a regular file or directory.", .{uri}),
            error.StreamTooLong => try a.print("The content read from {s} exceeds the size limit for this view.", .{uri}),
            else => blk: {
                std.log.debug("could not read {s} ({s})", .{ uri, @errorName(err) });
                break :blk try a.print("Could not read {s}.", .{uri});
            },
        };
        return result.failure(a, "not_readable", message);
    };
}

fn readPath(io: std.Io, a: Allocator, path: []const u8, view: View) !Content {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    switch (stat.kind) {
        .directory => {
            const window: Window = switch (view) {
                .window => |window| window,
                .image, .file => return error.DirectoryView,
            };
            const uri = try LocalPath.fileUri(a, path, .directory);
            var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
            defer dir.close(io);
            return list(io, a, dir, path, uri, window);
        },
        .file => {
            const uri = try LocalPath.fileUri(a, path, .file);
            const source = try LocalFile.open(io, path);
            defer source.file.close(io);
            return switch (view) {
                .window => |window| readFile(io, a, source.file, source.size, uri, window),
                .image => openImage(io, a, source, uri),
                .file => openFile(io, a, source, uri),
            };
        },
        else => return error.NotRegularFile,
    }
}

fn openFile(io: std.Io, a: Allocator, source: LocalFile, uri: []const u8) !Content {
    if (source.size > content.file_size_limit)
        return result.unavailable(a, uri, .{ .byte_length = source.size, .reason = .file_too_large });
    const bytes = try source.readAll(io, a, content.file_size_limit);
    return result.attachment(a, .{ .uri = uri, .kind = "file", .byte_length = bytes.len }, .{ .file = bytes });
}

fn openImage(io: std.Io, a: Allocator, source: LocalFile, uri: []const u8) !Content {
    var header: [32]u8 = undefined;
    const count = try source.file.readPositionalAll(io, &header, 0);
    const prefix = header[0..count];
    if (content.detectFormat(prefix) != null) {
        if (source.size > content.image_size_limit)
            return result.unavailable(a, uri, .{ .byte_length = source.size, .reason = .image_too_large });
        const bytes = try source.readAll(io, a, content.image_size_limit);
        const format = content.detectFormat(bytes) orelse return error.UnsupportedImage;
        const image: content.Image = .{ .format = format, .bytes = bytes };
        return result.attachment(a, .{
            .uri = uri,
            .kind = "image",
            .format = format,
            .byte_length = bytes.len,
        }, .{ .image = .{ .data = image } });
    }
    if (!(std.ascii.startsWithIgnoreCase(prefix, "http://") or std.ascii.startsWithIgnoreCase(prefix, "https://") or
        std.ascii.startsWithIgnoreCase(prefix, "data:image/"))) return error.UnsupportedImage;
    if (source.size > content.reference_size_limit)
        return result.unavailable(a, uri, .{ .byte_length = source.size, .reason = .reference_too_large });
    const bytes = try source.readAll(io, a, content.reference_size_limit);
    return result.imageUrl(a, uri, try locator.imageUrlFromText(a, bytes));
}

const MediaView = enum { file, image };

fn mediaPreview(a: Allocator, uri: []const u8, length: u64, view: MediaView) !Content {
    switch (view) {
        .file => if (length > content.file_size_limit) return result.unavailable(a, uri, .{ .byte_length = length, .reason = .file_too_large }),
        .image => if (length > content.image_size_limit) return result.unavailable(a, uri, .{ .byte_length = length, .reason = .image_too_large }),
    }
    return result.success(a, .{ .uri = uri, .kind = "file", .byte_length = length, .view = view });
}

fn readFile(io: std.Io, a: Allocator, file: std.Io.File, length: u64, uri: []const u8, window: Window) !Content {
    if (window.metadata) return error.FileMetadata;
    const offset = window.offset;
    var header: [32]u8 = undefined;
    const size = try file.readPositionalAll(io, &header, 0);
    const prefix = header[0..size];
    if (content.requiresCompleteSource(prefix, size == length)) {
        const view: MediaView = if (content.detectFormat(prefix) != null) .image else .file;
        return mediaPreview(a, uri, length, view);
    }
    const budget = window.textBytes();
    // Up to three preceding bytes distinguish a split UTF-8 character from
    // binary data and EOF from a range beyond EOF. One trailing byte detects continuation.
    const before: usize = @intCast(@min(3, offset));
    const start = offset - before;
    var storage: [windows.text_byte_limit + 4]u8 = undefined;
    // POSIX rejects a read whose end exceeds its signed file-offset range.
    const capacity = @min(before + @max(4, budget) + 1, std.math.maxInt(i64) -| start);
    const buffer = storage[0..@intCast(capacity)];
    const count = try file.readPositionalAll(io, buffer, start);
    if (count < before) return error.InvalidRange;
    const bytes = buffer[before..count];
    const end = windows.textLength(bytes, budget) orelse {
        if (insideCharacter(buffer[0..count], before)) return error.InvalidRange;
        return mediaPreview(a, uri, try file.length(io), .file);
    };
    const observed_end = start + count;
    const byte_length: ?u64 = if (count < buffer.len or observed_end == std.math.maxInt(i64))
        observed_end
    else
        null;
    const next = offset + end;
    return result.success(a, .{
        .uri = uri,
        .kind = "file",
        .content = bytes[0..end],
        .byte_length = byte_length,
        .offset = offset,
        .next_offset = if (end < bytes.len) @as(?u64, next) else null,
    });
}

fn insideCharacter(bytes: []const u8, offset: usize) bool {
    for (0..offset) |i| {
        const length = std.unicode.utf8ByteSequenceLength(bytes[i]) catch continue;
        if (i + length > offset and i + length <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i..][0..length]))
            return true;
    }
    return false;
}

const default_directory_entries = 20;
const directory_limit = 100;

const Name = struct {
    bytes: std.ArrayList(u8),
    kind: std.Io.File.Kind,

    fn largestFirst(_: void, left: Name, right: Name) std.math.Order {
        return std.mem.order(u8, right.bytes.items, left.bytes.items);
    }
};

fn list(io: std.Io, a: Allocator, dir: std.Io.Dir, path: []const u8, uri: []const u8, window: Window) !Content {
    const limit = @min(window.limit orelse default_directory_entries, directory_limit);
    // Keep only the smallest names through the requested window. The queue
    // grows as names are observed, even if the caller asks for a distant offset.
    const keep_count = window.offset +| limit;
    var names: std.PriorityQueue(Name, void, Name.largestFirst) = .empty;
    defer {
        for (names.items) |*name| name.bytes.deinit(a);
        names.deinit(a);
    }
    var total: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        total += 1;
        var bytes: std.ArrayList(u8) = .empty;
        if (names.count() == keep_count) {
            if (!std.mem.lessThan(u8, entry.name, names.items[0].bytes.items)) continue;
            bytes = names.pop().?.bytes;
            bytes.clearRetainingCapacity();
        }
        errdefer bytes.deinit(a);
        try bytes.appendSlice(a, entry.name);
        try names.push(a, .{ .bytes = bytes, .kind = entry.kind });
    }
    if (window.offset > total) return error.InvalidRange;
    std.mem.sort(Name, names.items, {}, struct {
        fn ascending(_: void, left: Name, right: Name) bool {
            return std.mem.lessThan(u8, left.bytes.items, right.bytes.items);
        }
    }.ascending);
    const Entry = struct {
        uri: []const u8,
        name: ?[]const u8,
        kind: ?enum { file, directory, symlink, other },
        metadata: ?struct { byte_length: ?u64, modified_ms: i64 },
    };
    var entries: std.ArrayList(Entry) = .empty;
    var uri_bytes: usize = 0;
    for (names.items[@intCast(window.offset)..]) |*name| {
        const child = name.bytes.items;
        const stat = if (window.metadata or name.kind == .unknown)
            dir.statFile(io, child, .{ .follow_symlinks = false }) catch |err| switch (err) {
                error.Canceled => return err,
                else => null,
            }
        else
            null;
        const kind = if (stat) |s| s.kind else name.kind;
        const child_path = try std.fs.path.join(a, &.{ path, child });
        const child_uri = try LocalPath.fileUri(a, child_path, if (kind == .directory) .directory else .file);
        if (entries.items.len > 0 and uri_bytes + child_uri.len > 32 * 1024) break;
        uri_bytes += child_uri.len;
        try entries.append(a, .{
            .uri = child_uri,
            .name = if (std.unicode.utf8ValidateSlice(child)) child else null,
            .kind = switch (kind) {
                .file => .file,
                .directory => .directory,
                .sym_link => .symlink,
                .unknown => null,
                else => .other,
            },
            .metadata = if (window.metadata and stat != null) .{
                .byte_length = if (stat.?.kind == .file) stat.?.size else null,
                .modified_ms = stat.?.mtime.toMilliseconds(),
            } else null,
        });
    }
    const next = window.offset + entries.items.len;
    return result.success(a, .{
        .uri = uri,
        .kind = "directory",
        .entries = entries.items,
        .offset = window.offset,
        .next_offset = if (next < total) @as(?u64, next) else null,
    });
}

const testing = std.testing;

fn readTemporary(a: Allocator, tmp: std.testing.TmpDir, name: []const u8, window: Window) !Content {
    return readTemporaryView(a, tmp, name, .{ .window = window });
}

fn readTemporaryView(a: Allocator, tmp: std.testing.TmpDir, name: []const u8, view: View) !Content {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(testing.io, &buffer);
    const path = try std.fs.path.join(a, &.{ buffer[0..length], name });
    return read(testing.io, a, path, view);
}

fn json(a: Allocator, reply: Content) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, reply.parts[0].text, .{});
}

test "file pages make progress at character boundaries and return local read failures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const prefix_len = windows.default_text_bytes - 2;
    var bytes: [prefix_len + "🐾c".len]u8 = @splat('a');
    @memcpy(bytes[prefix_len..], "🐾c");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a b", .data = &bytes });
    try tmp.dir.symLink(testing.io, "a b", "link", .{});

    const first = (try json(a, try readTemporary(a, tmp, "a b", .{}))).object.get("result").?.object;
    try testing.expectEqualStrings(bytes[0..prefix_len], first.get("content").?.string);
    try testing.expectEqual(@as(i64, @intCast(prefix_len)), first.get("next_offset").?.integer);
    try testing.expect(std.mem.endsWith(u8, first.get("uri").?.string, "/a%20b"));
    const next: Window = .{ .offset = @intCast(first.get("next_offset").?.integer), .limit = 1 };
    const reply = try readTemporary(a, tmp, "a b", next);
    const second = (try json(a, reply)).object.get("result").?.object;
    try testing.expectEqualStrings("🐾", second.get("content").?.string);
    try testing.expectEqual(@as(i64, @intCast(prefix_len)), second.get("offset").?.integer);
    try testing.expectEqual(@as(i64, @intCast(bytes.len - 1)), second.get("next_offset").?.integer);
    const eof = (try json(a, try readTemporary(a, tmp, "link", .{ .offset = bytes.len }))).object.get("result").?.object;
    try testing.expectEqualStrings("", eof.get("content").?.string);
    try testing.expect(eof.get("next_offset") == null);
    const invalid = try json(a, try readTemporary(a, tmp, "link", .{ .offset = prefix_len + 1 }));
    try testing.expectEqualStrings("invalid_range", invalid.object.get("error").?.object.get("code").?.string);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a b", .data = "" });
    const shorter = try json(a, try readTemporary(a, tmp, "a b", .{ .offset = std.math.maxInt(i64) }));
    try testing.expectEqualStrings("invalid_range", shorter.object.get("error").?.object.get("code").?.string);
    const empty = (try json(a, try readTemporary(a, tmp, "a b", .{}))).object.get("result").?.object;
    try testing.expectEqualStrings("", empty.get("content").?.string);
    try testing.expect(empty.get("next_offset") == null);

    // A nominal file size can be zero or larger than the readable text.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "nominal", .data = "hello world" });
    const file = try tmp.dir.openFile(testing.io, "nominal", .{});
    defer file.close(testing.io);
    for ([_]u64{ 0, 4096 }) |nominal_size| {
        const head = (try json(a, try readFile(testing.io, a, file, nominal_size, "file:///nominal", .{ .limit = 5 }))).object.get("result").?.object;
        try testing.expectEqualStrings("hello", head.get("content").?.string);
        try testing.expect(head.get("byte_length") == null);
        const rest = (try json(a, try readFile(testing.io, a, file, nominal_size, "file:///nominal", .{ .offset = @intCast(head.get("next_offset").?.integer), .limit = 6 }))).object.get("result").?.object;
        try testing.expectEqualStrings(" world", rest.get("content").?.string);
        try testing.expectEqual(11, rest.get("byte_length").?.integer);
        try testing.expect(rest.get("next_offset") == null);
        const attachment = try openFile(testing.io, a, .{ .file = file, .size = nominal_size }, "file:///nominal");
        try testing.expectEqualStrings("hello world", attachment.parts[1].file);
    }
    const source: LocalFile = .{ .file = file, .size = 0 };
    try testing.expectError(error.StreamTooLong, source.readAll(testing.io, a, "hello world".len - 1));

    const long_text: [windows.text_byte_limit + 1]u8 = @splat('x');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "long", .data = &long_text });
    const expanded = (try json(a, try readTemporary(a, tmp, "long", .{ .limit = long_text.len }))).object.get("result").?.object;
    try testing.expectEqual(windows.text_byte_limit, expanded.get("content").?.string.len);
    try testing.expectEqual(windows.text_byte_limit, expanded.get("next_offset").?.integer);

    const missing = try json(a, try readTemporary(a, tmp, "missing", .{}));
    try testing.expectEqualStrings("not_found", missing.object.get("error").?.object.get("code").?.string);
    try tmp.dir.symLink(testing.io, "loop", "loop", .{});
    const loop = try json(a, try readTemporary(a, tmp, "loop", .{}));
    try testing.expectEqualStrings("not_readable", loop.object.get("error").?.object.get("code").?.string);
}

test "previews identify media and only explicit views attach complete sources" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const image = "\x89PNG\r\n\x1a\nimage bytes";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "image", .data = image });
    const pdf = "%PDF-1.7\nall ASCII";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "document.png", .data = pdf });
    const tail = "\x80late bytes";
    var bytes: [windows.default_text_bytes + tail.len]u8 = @splat('a');
    @memcpy(bytes[windows.default_text_bytes..], tail);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "mixed", .data = &bytes });

    const first = (try json(a, try readTemporary(a, tmp, "mixed", .{}))).object.get("result").?.object;
    const next: Window = .{ .offset = @intCast(first.get("next_offset").?.integer), .limit = 1 };
    for ([_][]const u8{ "image", "document.png", "mixed" }, [_]Window{ .{}, .{ .limit = 1 }, next }, [_]View{ .image, .file, .file }) |name, window, view| {
        const preview = try readTemporary(a, tmp, name, window);
        try testing.expectEqual(1, preview.parts.len);
        const descriptor = (try json(a, preview)).object.get("result").?.object;
        try testing.expectEqualStrings(@tagName(view), descriptor.get("view").?.string);
        const source = try locator.parse(a, descriptor.get("uri").?.string);
        const attached = try read(testing.io, a, source.file, try View.parse(descriptor.get("view").?));
        try testing.expectEqual(2, attached.parts.len);
        switch (view) {
            .image => {
                try testing.expectEqual(.png, attached.parts[1].image.data.format);
                try testing.expectEqualSlices(u8, image, attached.parts[1].image.data.bytes);
            },
            .file => try testing.expectEqualSlices(u8, if (window.offset == 0) pdf else &bytes, attached.parts[1].file),
            .window => unreachable,
        }
    }
    for ([_][]const u8{ "document.png", "." }) |name| {
        const reply = try readTemporaryView(a, tmp, name, .image);
        try testing.expectEqual(1, reply.parts.len);
        const failure = (try json(a, reply)).object.get("error").?.object;
        try testing.expectEqualStrings("unsupported_view", failure.get("code").?.string);
    }

    const large = try tmp.dir.createFile(testing.io, "large", .{});
    defer large.close(testing.io);
    try large.setLength(testing.io, content.file_size_limit + 1);
    const oversized = try readTemporary(a, tmp, "large", .{});
    try testing.expectEqual(@as(usize, 1), oversized.parts.len);
    const diagnostic = (try json(a, oversized)).object.get("result").?.object.get("content").?.object.get("unavailable").?.object;
    try testing.expectEqualStrings("file_too_large", diagnostic.get("reason").?.string);

    const large_image = try tmp.dir.openFile(testing.io, "image", .{ .mode = .read_write });
    defer large_image.close(testing.io);
    try large_image.setLength(testing.io, content.image_size_limit + 1);
    const preview = try readTemporaryView(a, tmp, "image", .image);
    try testing.expectEqual(1, preview.parts.len);
    const unavailable = (try json(a, preview)).object.get("result").?.object.get("content").?.object.get("unavailable").?.object;
    try testing.expectEqualStrings("image_too_large", unavailable.get("reason").?.string);
}

test "explicit image reads pass a complete local URL source as a native reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const url = "data:image/png;base64,aGk=";
    const source = url ++ "\r\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "stdout", .data = source });
    const offset = "data:image/png;base64,".len;
    const preview = try readTemporary(a, tmp, "stdout", .{ .offset = offset });
    const description = (try json(a, preview)).object.get("result").?.object;
    try testing.expectEqualStrings(source[offset..], description.get("content").?.string);
    const image = try readTemporaryView(a, tmp, "stdout", .image);
    try testing.expectEqualStrings(url, image.parts[1].image.url);
    try testing.expect(std.mem.indexOf(u8, image.parts[0].text, url) == null);
    const attached = try readTemporaryView(a, tmp, "stdout", .file);
    try testing.expectEqualSlices(u8, source, attached.parts[1].file);

    const https = "https://example.org/file?q=a%2Fb";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "stdout", .data = https });
    const external = try readTemporaryView(a, tmp, "stdout", .image);
    try testing.expectEqualStrings(https, external.parts[1].image.url);
    for ([_][]const u8{ "ordinary text", "https://example.org/\nanother line", "%PDF-1.7" }) |invalid| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "stdout", .data = invalid });
        const reply = try readTemporaryView(a, tmp, "stdout", .image);
        try testing.expectEqual(1, reply.parts.len);
        try testing.expectEqualStrings("unsupported_view", (try json(a, reply)).object.get("error").?.object.get("code").?.string);
    }
    const long_url = try a.alloc(u8, content.reference_size_limit + 1);
    @memset(long_url, 'a');
    @memcpy(long_url[0.."https://example.org/".len], "https://example.org/");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "stdout", .data = long_url });
    const oversized = try readTemporaryView(a, tmp, "stdout", .image);
    try testing.expectEqual(1, oversized.parts.len);
    const omitted = (try json(a, oversized)).object.get("result").?.object.get("content").?.object.get("unavailable").?.object;
    try testing.expectEqualStrings("reference_too_large", omitted.get("reason").?.string);
}

test "directory windows select sorted entries and child URIs preserve arbitrary filename bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "z child", .default_dir);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b file", .data = "hi" });
    try tmp.dir.symLink(testing.io, "missing", "a link", .{});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "\x80after%", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "\xff", .data = "" });
    const first = (try json(a, try readTemporary(a, tmp, ".", .{ .limit = 4, .metadata = true }))).object.get("result").?.object;
    try testing.expect(std.mem.endsWith(u8, first.get("uri").?.string, "/"));
    const entries = first.get("entries").?.array.items;
    try testing.expectEqual(4, entries.len);
    const link = entries[0].object;
    try testing.expectEqualStrings("a link", link.get("name").?.string);
    try testing.expectEqualStrings("symlink", link.get("kind").?.string);
    try testing.expect(link.get("metadata").?.object.get("modified_ms").? == .integer);
    try testing.expectEqual(2, entries[1].object.get("metadata").?.object.get("byte_length").?.integer);
    try testing.expect(std.mem.endsWith(u8, entries[2].object.get("uri").?.string, "/z%20child/"));
    try testing.expect(entries[3].object.get("name") == null);
    try testing.expect(std.mem.endsWith(u8, entries[3].object.get("uri").?.string, "/%80after%25"));
    const source = try locator.parse(a, first.get("uri").?.string);
    const last_offset: Window = .{ .offset = @intCast(first.get("next_offset").?.integer) };
    const last = (try json(a, try read(testing.io, a, source.file, .{ .window = last_offset }))).object.get("result").?.object;
    try testing.expectEqual(@as(i64, @intCast(entries.len)), last.get("offset").?.integer);
    const children = last.get("entries").?.array.items;
    try testing.expectEqual(@as(usize, 1), children.len);
    const raw_name = children[0].object;
    try testing.expect(raw_name.get("name") == null);
    try testing.expect(std.mem.endsWith(u8, raw_name.get("uri").?.string, "/%FF"));
    try testing.expect(last.get("next_offset") == null);
    const eof = (try json(a, try read(testing.io, a, source.file, .{ .window = .{ .offset = last_offset.offset + children.len } }))).object.get("result").?.object;
    try testing.expectEqual(0, eof.get("entries").?.array.items.len);
    try testing.expect(eof.get("next_offset") == null);
    const beyond = try json(a, try read(testing.io, a, source.file, .{ .window = .{ .offset = std.math.maxInt(u64) } }));
    try testing.expectEqualStrings("invalid_range", beyond.object.get("error").?.object.get("code").?.string);

    for (0..directory_limit) |i| {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = try a.print("entry-{d}", .{i}), .data = "" });
    }
    const alias: [200]u8 = @splat('%');
    try tmp.dir.symLink(testing.io, ".", &alias, .{});
    const brief = (try json(a, try readTemporary(a, tmp, ".", .{}))).object.get("result").?.object.get("entries").?.array.items;
    try testing.expectEqual(default_directory_entries, brief.len);
    try testing.expect(!brief[0].object.contains("metadata"));
    const wide: Window = .{ .offset = 1, .limit = directory_limit + 1 };
    const capped = (try json(a, try readTemporary(a, tmp, ".", wide))).object.get("result").?.object.get("entries").?.array.items;
    try testing.expectEqual(directory_limit, capped.len);

    // The same request through a long path can return fewer entries.
    const short = (try json(a, try readTemporary(a, tmp, &alias, wide))).object.get("result").?.object;
    const received = short.get("entries").?.array.items.len;
    try testing.expect(received > 0 and received < capped.len);
    try testing.expectEqual(@as(i64, @intCast(wide.offset + received)), short.get("next_offset").?.integer);
}
