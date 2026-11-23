const std = @import("std");
const content = @import("content");
const FileUri = @import("agent_contracts").FileUri;
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
            error.UnsupportedImage => return result.failure(a, "unsupported_view", "This source cannot be opened as an image. Omit view to read a regular file or list a directory."),
            else => {},
        }
        const uri = try FileUri.fromPath(a, path, .file);
        const message = switch (err) {
            error.FileNotFound, error.NotDir => return result.failure(a, "not_found", try a.print("No file or directory exists at {s}.", .{uri})),
            error.AccessDenied, error.PermissionDenied => try a.print("Permission to read {s} was denied.", .{uri}),
            error.SymLinkLoop => try a.print("Could not follow the chain of symbolic links at {s}.", .{uri}),
            error.NotRegular => try a.print("{s} does not identify a regular file or directory.", .{uri}),
            error.IncompleteMedia => try a.print("Could not read the complete file at {s}.", .{uri}),
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
                .image => return error.UnsupportedImage,
            };
            const uri = try FileUri.fromPath(a, path, .directory);
            var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
            defer dir.close(io);
            return list(io, a, dir, path, uri, window);
        },
        .file => {
            const uri = try FileUri.fromPath(a, path, .file);
            // If another focus replaces this file with a FIFO before open,
            // the read must still return control without waiting for a writer.
            const file: std.Io.File = if (@import("builtin").os.tag == .linux) .{
                .handle = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOCTTY = true, .CLOEXEC = true }, 0),
                .flags = .{ .nonblocking = true },
            } else try std.Io.Dir.openFileAbsolute(io, path, .{ .allow_directory = false });
            defer file.close(io);
            const opened = try file.stat(io);
            if (opened.kind != .file) return error.NotRegular;
            return switch (view) {
                .window => |window| readFile(io, a, file, opened.size, uri, window),
                .image => {
                    const image = try content.readFileMedia(io, a, file, opened.size, .image) orelse return error.UnsupportedImage;
                    return result.fileMedia(a, uri, image);
                },
            };
        },
        else => return if (view == .image) error.UnsupportedImage else error.NotRegular,
    }
}

fn readFile(io: std.Io, a: Allocator, file: std.Io.File, length: u64, uri: []const u8, window: Window) !Content {
    const offset = window.offset;
    if (offset == 0) {
        if (try content.readFileMedia(io, a, file, length, .{ .detect = .{} })) |media|
            return result.fileMedia(a, uri, media);
    } else {
        // Reject a seek into recognized media without loading the whole file.
        var header: [32]u8 = undefined;
        const size = try file.readPositionalAll(io, &header, 0);
        if (content.requiresCompleteSource(header[0..size], size == length)) return error.InvalidRange;
    }
    const budget = window.count(windows.text_byte_limit);
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
        if (try content.readFileMedia(io, a, file, try file.length(io), .{ .detect = .{ .binary_observed = true } })) |media|
            return result.fileMedia(a, uri, media);
        return error.IncompleteMedia;
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

const directory_limit = 100;

const Name = struct {
    bytes: std.ArrayList(u8),
    kind: std.Io.File.Kind,

    fn largestFirst(_: void, left: Name, right: Name) std.math.Order {
        return std.mem.order(u8, right.bytes.items, left.bytes.items);
    }
};

fn list(io: std.Io, a: Allocator, dir: std.Io.Dir, path: []const u8, uri: []const u8, window: Window) !Content {
    const limit = window.count(directory_limit);
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
        byte_length: ?u64,
        modified_ms: ?i64,
    };
    var entries: std.ArrayList(Entry) = .empty;
    var uri_bytes: usize = 0;
    for (names.items[@intCast(window.offset)..]) |*name| {
        const child = name.bytes.items;
        const stat = dir.statFile(io, child, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.Canceled => return err,
            else => null,
        };
        const kind = if (stat) |s| s.kind else name.kind;
        const child_path = try std.fs.path.join(a, &.{ path, child });
        const child_uri = try FileUri.fromPath(a, child_path, if (kind == .directory) .directory else .file);
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
            .byte_length = if (stat != null and stat.?.kind == .file) stat.?.size else null,
            .modified_ms = if (stat) |s| s.mtime.toMilliseconds() else null,
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
    const prefix_len = windows.text_byte_limit - 2;
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
    try testing.expect(eof.get("next_offset").? == .null);
    const invalid = try json(a, try readTemporary(a, tmp, "link", .{ .offset = prefix_len + 1 }));
    try testing.expectEqualStrings("invalid_range", invalid.object.get("error").?.object.get("code").?.string);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a b", .data = "" });
    const shorter = try json(a, try readTemporary(a, tmp, "a b", .{ .offset = std.math.maxInt(i64) }));
    try testing.expectEqualStrings("invalid_range", shorter.object.get("error").?.object.get("code").?.string);
    const empty = (try json(a, try readTemporary(a, tmp, "a b", .{}))).object.get("result").?.object;
    try testing.expectEqualStrings("", empty.get("content").?.string);
    try testing.expect(empty.get("next_offset").? == .null);

    // A nominal file size can be zero or larger than the readable text.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "nominal", .data = "hello world" });
    const file = try tmp.dir.openFile(testing.io, "nominal", .{});
    defer file.close(testing.io);
    for ([_]u64{ 0, 4096 }) |nominal_size| {
        const head = (try json(a, try readFile(testing.io, a, file, nominal_size, "file:///nominal", .{ .limit = 5 }))).object.get("result").?.object;
        try testing.expectEqualStrings("hello", head.get("content").?.string);
        try testing.expect(head.get("byte_length").? == .null);
        const rest = (try json(a, try readFile(testing.io, a, file, nominal_size, "file:///nominal", .{ .offset = @intCast(head.get("next_offset").?.integer), .limit = 6 }))).object.get("result").?.object;
        try testing.expectEqualStrings(" world", rest.get("content").?.string);
        try testing.expectEqual(11, rest.get("byte_length").?.integer);
        try testing.expect(rest.get("next_offset").? == .null);
    }

    const missing = try json(a, try readTemporary(a, tmp, "missing", .{}));
    try testing.expectEqualStrings("not_found", missing.object.get("error").?.object.get("code").?.string);
    try tmp.dir.symLink(testing.io, "loop", "loop", .{});
    const loop = try json(a, try readTemporary(a, tmp, "loop", .{}));
    try testing.expectEqualStrings("not_readable", loop.object.get("error").?.object.get("code").?.string);
}

test "source signatures and late binary pages produce native complete content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const image = "\x89PNG\r\n\x1a\nimage bytes";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "image", .data = image });
    for ([_]View{ .{ .window = .{} }, .image }) |view| {
        const png = try readTemporaryView(a, tmp, "image", view);
        try testing.expectEqual(.png, png.parts[1].image.data.format);
        try testing.expectEqualSlices(u8, image, png.parts[1].image.data.bytes);
    }
    const pdf = "%PDF-1.7\nall ASCII";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "document.png", .data = pdf });
    const document = try readTemporary(a, tmp, "document.png", .{});
    try testing.expectEqualSlices(u8, pdf, document.parts[1].file.bytes);
    for ([_][]const u8{ "document.png", "." }) |name| {
        const reply = try readTemporaryView(a, tmp, name, .image);
        try testing.expectEqual(1, reply.parts.len);
        const failure = (try json(a, reply)).object.get("error").?.object;
        try testing.expectEqualStrings("unsupported_view", failure.get("code").?.string);
    }

    const tail = "\x80late bytes";
    var bytes: [windows.text_byte_limit + tail.len]u8 = @splat('a');
    @memcpy(bytes[windows.text_byte_limit..], tail);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "mixed", .data = &bytes });
    const first = (try json(a, try readTemporary(a, tmp, "mixed", .{}))).object.get("result").?.object;
    const next: Window = .{ .offset = @intCast(first.get("next_offset").?.integer) };
    const rest = try readTemporary(a, tmp, "mixed", next);
    try testing.expectEqualSlices(u8, &bytes, rest.parts[1].file.bytes);
    @memcpy(bytes[0..pdf.len], pdf);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "mixed", .data = &bytes });
    const replaced = try json(a, try readTemporary(a, tmp, "mixed", next));
    try testing.expectEqualStrings("invalid_range", replaced.object.get("error").?.object.get("code").?.string);

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

test "directory windows select sorted entries and child URIs preserve arbitrary filename bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(testing.io, "z child", .default_dir);
    for (0..97) |i| {
        var name: [16]u8 = undefined;
        try tmp.dir.writeFile(testing.io, .{ .sub_path = try std.fmt.bufPrint(&name, "f{d:0>3}", .{97 - i}), .data = "" });
    }
    try tmp.dir.symLink(testing.io, "missing", "f000", .{});
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "\x80after%", .data = "" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "\xff", .data = "" });
    const first = (try json(a, try readTemporary(a, tmp, ".", .{}))).object.get("result").?.object;
    try testing.expect(std.mem.endsWith(u8, first.get("uri").?.string, "/"));
    const entries = first.get("entries").?.array.items;
    try testing.expectEqual(directory_limit, entries.len);
    const link = entries[0].object;
    try testing.expectEqualStrings("f000", link.get("name").?.string);
    try testing.expectEqualStrings("symlink", link.get("kind").?.string);
    try testing.expect(link.get("modified_ms").? == .integer);
    try testing.expect(std.mem.endsWith(u8, entries[98].object.get("uri").?.string, "/z%20child/"));
    try testing.expect(entries[99].object.get("name").? == .null);
    try testing.expect(std.mem.endsWith(u8, entries[99].object.get("uri").?.string, "/%80after%25"));
    const source = try @import("locator.zig").parse(a, first.get("uri").?.string);
    const last_offset: Window = .{ .offset = @intCast(first.get("next_offset").?.integer) };
    const last = (try json(a, try read(testing.io, a, source.file, .{ .window = last_offset }))).object.get("result").?.object;
    try testing.expectEqual(100, last.get("offset").?.integer);
    const children = last.get("entries").?.array.items;
    try testing.expectEqual(@as(usize, 1), children.len);
    const raw_name = children[0].object;
    try testing.expect(raw_name.get("name").? == .null);
    try testing.expect(std.mem.endsWith(u8, raw_name.get("uri").?.string, "/%FF"));
    try testing.expect(last.get("next_offset").? == .null);
    const eof = (try json(a, try read(testing.io, a, source.file, .{ .window = .{ .offset = 101 } }))).object.get("result").?.object;
    try testing.expectEqual(0, eof.get("entries").?.array.items.len);
    try testing.expect(eof.get("next_offset").? == .null);
    const beyond = try json(a, try read(testing.io, a, source.file, .{ .window = .{ .offset = std.math.maxInt(u64) } }));
    try testing.expectEqualStrings("invalid_range", beyond.object.get("error").?.object.get("code").?.string);

    // A long encoded directory URI can exhaust the URI budget before the
    // requested number of entries. Resume after the entries actually returned.
    const alias: [200]u8 = @splat('%');
    try tmp.dir.symLink(testing.io, ".", &alias, .{});
    const short = (try json(a, try readTemporary(a, tmp, &alias, .{ .offset = 5, .limit = 80 }))).object.get("result").?.object;
    const received = short.get("entries").?.array.items.len;
    try testing.expect(received > 0 and received < 80);
    try testing.expectEqual(@as(i64, @intCast(5 + received)), short.get("next_offset").?.integer);
}
