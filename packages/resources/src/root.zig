const std = @import("std");
const content = @import("content");
const host = @import("host");
const contracts = @import("agent_contracts");

const Allocator = std.mem.Allocator;
const Tools = contracts.Tools;
const Model = contracts.Model;
const Content = content.Content;

pub const text_page_limit = 256 * 1024;
pub const max_text_page = 8 * 1024 * 1024;
pub const minimum_text_page = 4;
pub const directory_entry_limit = 100;

const DirectoryEntry = struct {
    name: []const u8,
    kind: []const u8,
    byte_length: ?u64,
    modified_ms: ?i64,

    fn lessThanName(_: void, left: DirectoryEntry, right: DirectoryEntry) bool {
        return std.mem.lessThan(u8, left.name, right.name);
    }
};

/// Read-only observation of host files and directories inside configured roots.
pub const Resources = struct {
    io: std.Io,
    roots: []const []const u8,

    /// Roots are resolved against `directory` and canonicalized. A missing or
    /// non-directory root is a startup error; unset or empty input configures
    /// no roots, so every address is outside scope until a deployment opts in.
    pub fn init(io: std.Io, a: Allocator, directory: []const u8, configured: ?[]const u8) !Resources {
        var roots: std.ArrayList([]const u8) = .empty;
        if (configured) |text| {
            if (text.len != 0) {
                var parts = std.mem.splitScalar(u8, text, ':');
                while (parts.next()) |part| {
                    if (part.len == 0) return error.InvalidResourceRoot;
                    try roots.append(a, try canonicalRoot(io, a, directory, part));
                }
            }
        }
        return .{ .io = io, .roots = try roots.toOwnedSlice(a) };
    }

    fn canonicalRoot(io: std.Io, a: Allocator, directory: []const u8, path: []const u8) ![]const u8 {
        const resolved = try std.fs.path.resolve(a, &.{ directory, path });
        const canonical = std.Io.Dir.cwd().realPathFileAlloc(io, resolved, a) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            else => return error.InvalidResourceRoot,
        };
        const stat = std.Io.Dir.cwd().statFile(io, canonical, .{}) catch |err| switch (err) {
            error.Canceled => return err,
            else => return error.InvalidResourceRoot,
        };
        if (stat.kind != .directory) return error.InvalidResourceRoot;
        return canonical;
    }

    /// Declarations belong to a and must outlive their registration with Engine.
    pub fn tools(self: *Resources, a: Allocator) !Tools {
        return .{
            .context = self,
            .invoke = invokeTool,
            .declarations = try std.json.parseFromSliceLeaky([]const Model.Tool, a, @embedFile("tools.json"), .{}),
        };
    }

    fn invokeTool(context: *anyopaque, a: Allocator, _: Tools.Invocation, name: []const u8, arguments: []const u8) anyerror!?Content {
        const self: *Resources = @ptrCast(@alignCast(context));
        const request = try Request.parse(a, name, arguments) orelse return null;
        return try self.invoke(a, request);
    }

    pub const Request = union(enum) {
        touch: struct {
            address: []const u8,
            offset: u64 = 0,
            max_bytes: u32 = text_page_limit,
        },

        pub fn parse(a: Allocator, name: []const u8, arguments: []const u8) !?Request {
            const tag = std.meta.stringToEnum(std.meta.Tag(Request), name) orelse return null;
            const request: Request = @unionInit(Request, @tagName(tag), std.json.parseFromSliceLeaky(@FieldType(Request, @tagName(tag)), a, arguments, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return error.InvalidToolArguments,
            });
            switch (request) {
                .touch => |args| {
                    if (args.address.len == 0 or std.mem.indexOfScalar(u8, args.address, 0) != null)
                        return error.InvalidToolArguments;
                    if (args.max_bytes < minimum_text_page or args.max_bytes > max_text_page)
                        return error.InvalidToolArguments;
                    if (args.offset > std.math.maxInt(i64))
                        return error.InvalidToolArguments;
                },
            }
            return request;
        }
    };

    pub fn invoke(self: *Resources, a: Allocator, request: Request) !Content {
        const args = request.touch;
        const address = self.resolve(a, args.address) catch |err| switch (err) {
            error.NotFound => return toolError(a, "not_found", try std.fmt.allocPrint(a, "No file or directory exists at '{s}'.", .{args.address})),
            error.OutsideScope => return toolError(a, "outside_scope", if (self.roots.len == 0)
                "No resource roots are configured; set RESOURCE_ROOTS to enable touch."
            else
                try std.fmt.allocPrint(a, "'{s}' is outside the configured resource roots.", .{args.address})),
            error.NotReadable => return toolError(a, "not_readable", try std.fmt.allocPrint(a, "Could not resolve '{s}' inside a resource root.", .{args.address})),
            else => return err,
        };
        const stat = std.Io.Dir.cwd().statFile(self.io, address, .{}) catch |err| return readFailure(a, err, args.address);
        return switch (stat.kind) {
            .directory => self.list(a, address, args),
            .file => self.read(a, address, args),
            else => toolError(a, "not_readable", try std.fmt.allocPrint(a, "'{s}' is not a regular file or directory.", .{args.address})),
        };
    }

    /// Relative addresses use the first root. A lexical check runs before
    /// realpath so that `..` cannot leave a root even when the target is
    /// missing; the canonical path is checked again after symlink resolution.
    fn resolve(self: *Resources, a: Allocator, address: []const u8) ![]const u8 {
        if (self.roots.len == 0) return error.OutsideScope;
        const candidate = if (std.fs.path.isAbsolute(address))
            address
        else
            try std.fs.path.resolve(a, &.{ self.roots[0], address });
        if (!self.withinAny(candidate)) return error.OutsideScope;
        const canonical = std.Io.Dir.cwd().realPathFileAlloc(self.io, candidate, a) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return error.NotFound,
            error.OutOfMemory, error.Canceled => return err,
            else => return error.NotReadable,
        };
        if (!self.withinAny(canonical)) return error.OutsideScope;
        return canonical;
    }

    fn withinAny(self: Resources, path: []const u8) bool {
        for (self.roots) |root| if (within(root, path)) return true;
        return false;
    }

    fn within(root: []const u8, path: []const u8) bool {
        if (std.mem.eql(u8, root, path)) return true;
        if (root.len == 1 and root[0] == '/') return path.len != 0 and path[0] == '/';
        return path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == '/';
    }

    fn read(self: *Resources, a: Allocator, address: []const u8, args: @FieldType(Request, "touch")) !Content {
        var file = std.Io.Dir.cwd().openFile(self.io, address, .{ .mode = .read_only, .allow_directory = false }) catch |err| return readFailure(a, err, address);
        defer file.close(self.io);
        const stat = file.stat(self.io) catch |err| return readFailure(a, err, address);
        if (stat.kind != .file) return toolError(a, "not_readable", try std.fmt.allocPrint(a, "'{s}' is not a regular file.", .{address}));
        const reader: host.Reader = .{ .io = self.io };
        if (try reader.readMedia(a, file, null, false)) |media| {
            if (args.offset != 0) return toolError(a, "invalid_range", "offset applies only to text; this source is returned complete.");
            return renderMedia(a, address, media);
        }
        if (args.offset > stat.size) return toolError(a, "invalid_range", "The byte offset is beyond the end of this file.");
        if (args.offset < stat.size) {
            var first: [1]u8 = undefined;
            const count = try file.readPositionalAll(self.io, &first, args.offset);
            if (count == 1 and first[0] & 0xc0 == 0x80)
                return toolError(a, "invalid_range", "The byte offset is inside a UTF-8 character. Resume with a next_offset returned by touch.");
        }
        // output.chunk budgets the encoded selection and needs room to make
        // progress. Return at most max_bytes of source text, trimming only at a
        // character boundary.
        const budget: usize = @max(@as(usize, args.max_bytes) + 64, host.output.minimum_budget);
        const chunk = host.output.chunk(a, self.io, file, args.offset, budget, true) catch |err| switch (err) {
            error.InvalidOutputOffset => return toolError(a, "invalid_range", "The byte offset is beyond the end of this file."),
            error.OutOfMemory, error.Canceled => return err,
            else => return readFailure(a, err, address),
        };
        return switch (chunk.content) {
            .text => |preview| blk: {
                var text = preview.text;
                var next_offset = chunk.next_offset;
                if (text.len > args.max_bytes) {
                    const end = content.textPrefixLength(text[0..args.max_bytes], true) orelse blk2: {
                        var cut: usize = args.max_bytes;
                        while (cut > 0 and text[cut] & 0xc0 == 0x80) cut -= 1;
                        break :blk2 cut;
                    };
                    text = text[0..end];
                    next_offset = chunk.offset + end;
                }
                break :blk Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .result = .{
                    .address = address,
                    .kind = "file",
                    .content = text,
                    .byte_length = chunk.byte_length,
                    .offset = chunk.offset,
                    .next_offset = if (next_offset < chunk.byte_length) @as(?u64, next_offset) else null,
                } }, .{}));
            },
            .unavailable => blk: {
                // Binary was found after a textual header. Classify the complete
                // source and deliver it as one native part instead of a range.
                if (try reader.readMedia(a, file, null, true)) |media| {
                    if (args.offset != 0) return toolError(a, "invalid_range", "offset applies only to text; this source is returned complete.");
                    break :blk try renderMedia(a, address, media);
                }
                break :blk toolError(a, "not_readable", "The source is not text and its complete content is unavailable.");
            },
        };
    }

    fn list(self: *Resources, a: Allocator, address: []const u8, args: @FieldType(Request, "touch")) !Content {
        if (args.offset != 0) return toolError(a, "invalid_range", "offset applies only to text files.");
        var dir = std.Io.Dir.cwd().openDir(self.io, address, .{ .iterate = true }) catch |err| return readFailure(a, err, address);
        defer dir.close(self.io);
        var entries: std.ArrayList(DirectoryEntry) = .empty;
        var truncated = false;
        var iterator = dir.iterate();
        while (true) {
            const next = iterator.next(self.io) catch |err| return readFailure(a, err, address);
            const entry = next orelse break;
            if (entries.items.len == directory_entry_limit) {
                truncated = true;
                break;
            }
            // Do not follow symlinks while listing; metadata for the link
            // target could leave the root even though the name does not.
            const stat: ?std.Io.File.Stat = if (entry.kind == .sym_link) null else dir.statFile(self.io, entry.name, .{}) catch null;
            const byte_length: ?u64 = if (stat) |found| switch (found.kind) {
                .file => found.size,
                else => null,
            } else null;
            try entries.append(a, .{
                .name = try a.dupe(u8, entry.name),
                .kind = @tagName(entry.kind),
                .byte_length = byte_length,
                .modified_ms = if (stat) |found| found.mtime.toMilliseconds() else null,
            });
        }
        std.mem.sort(DirectoryEntry, entries.items, {}, DirectoryEntry.lessThanName);
        return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .result = .{
            .address = address,
            .kind = "directory",
            .entries = entries.items,
            .truncated = truncated,
        } }, .{}));
    }

    fn renderMedia(a: Allocator, address: []const u8, media: host.Reader.FileContent) !Content {
        switch (media) {
            .text => unreachable,
            .image => |image| {
                const byte_length: u64 = switch (image) {
                    .data => |data| data.bytes.len,
                    .url => |url| url.len,
                };
                const text = try std.json.Stringify.valueAlloc(a, .{ .result = .{
                    .address = address,
                    .kind = "file",
                    .content = .{ .image = image.describe() },
                    .byte_length = byte_length,
                } }, .{});
                return Content.fromParts(a, &.{ .{ .text = text }, .{ .image = image } });
            },
            .file => |document| {
                const text = try std.json.Stringify.valueAlloc(a, .{ .result = .{
                    .address = address,
                    .kind = "file",
                    .content = .{ .file = document.describe() },
                    .byte_length = document.bytes.len,
                } }, .{});
                return Content.fromParts(a, &.{ .{ .text = text }, .{ .file = document } });
            },
            .unavailable => |diagnostic| return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .result = .{
                .address = address,
                .kind = "file",
                .content = .{ .unavailable = diagnostic },
                .byte_length = diagnostic.byte_length,
            } }, .{})),
        }
    }

    fn readFailure(a: Allocator, err: anyerror, address: []const u8) !Content {
        return switch (err) {
            error.FileNotFound, error.NotDir => toolError(a, "not_found", try std.fmt.allocPrint(a, "No file or directory exists at '{s}'.", .{address})),
            error.AccessDenied, error.PermissionDenied => toolError(a, "not_readable", try std.fmt.allocPrint(a, "Permission denied while reading '{s}'.", .{address})),
            error.IsDir => toolError(a, "not_readable", try std.fmt.allocPrint(a, "'{s}' is a directory, not a regular file.", .{address})),
            error.OutOfMemory, error.Canceled => return err,
            else => toolError(a, "not_readable", try std.fmt.allocPrint(a, "Could not read '{s}': {s}.", .{ address, @errorName(err) })),
        };
    }
};

fn toolError(a: Allocator, code: []const u8, message: []const u8) !Content {
    return Content.fromText(a, try std.json.Stringify.valueAlloc(a, .{ .@"error" = .{ .code = code, .message = message } }, .{}));
}

const testing = std.testing;

fn temporaryPath(a: Allocator, temporary: *std.testing.TmpDir) ![]const u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try temporary.dir.realPath(testing.io, &buffer);
    return a.dupe(u8, buffer[0..length]);
}

fn parseResult(a: Allocator, result: Content) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, result.parts[0].text, .{});
}

fn resultObject(value: std.json.Value) std.json.ObjectMap {
    return value.object.get("result").?.object;
}

fn errorCode(a: Allocator, result: Content) ![]const u8 {
    const value = try parseResult(a, result);
    return value.object.get("error").?.object.get("code").?.string;
}

test "touch returns full text, pages, and refuses offsets inside a character" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try temporary.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "hello world" });
    var resources = try Resources.init(io, a, try temporaryPath(a, &temporary), ".");

    const page = try resources.invoke(a, .{ .touch = .{ .address = "note.txt", .max_bytes = 4 } });
    const page_result = resultObject(try parseResult(a, page));
    try testing.expectEqualStrings("hell", page_result.get("content").?.string);
    try testing.expectEqual(@as(i64, 0), page_result.get("offset").?.integer);
    try testing.expectEqual(@as(i64, 4), page_result.get("next_offset").?.integer);
    try testing.expectEqual(@as(i64, 11), page_result.get("byte_length").?.integer);
    try testing.expect(std.mem.endsWith(u8, page_result.get("address").?.string, "note.txt"));

    const rest = try resources.invoke(a, .{ .touch = .{ .address = "note.txt", .offset = 4, .max_bytes = 100 } });
    const rest_result = resultObject(try parseResult(a, rest));
    try testing.expectEqualStrings("o world", rest_result.get("content").?.string);
    try testing.expect(std.meta.activeTag(rest_result.get("next_offset").?) == .null);

    const full = try resources.invoke(a, .{ .touch = .{ .address = "note.txt", .max_bytes = 100 } });
    try testing.expectEqualStrings("hello world", resultObject(try parseResult(a, full)).get("content").?.string);

    try temporary.dir.writeFile(io, .{ .sub_path = "accent.txt", .data = "\xc3\xa9" });
    const inside = try resources.invoke(a, .{ .touch = .{ .address = "accent.txt", .offset = 1 } });
    try testing.expectEqualStrings("invalid_range", try errorCode(a, inside));

    const beyond = try resources.invoke(a, .{ .touch = .{ .address = "note.txt", .offset = 12 } });
    try testing.expectEqualStrings("invalid_range", try errorCode(a, beyond));
}

test "touch returns images and complete files as native content" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const png = "\x89PNG\r\n\x1a\n" ++ "image bytes";
    const jpeg = "\xff\xd8\xff\xe0" ++ "\x00\x10JFIF\x00";
    try temporary.dir.writeFile(io, .{ .sub_path = "image.png", .data = png });
    try temporary.dir.writeFile(io, .{ .sub_path = "photo.jpg", .data = jpeg });
    var resources = try Resources.init(io, a, try temporaryPath(a, &temporary), ".");

    for ([_]struct { path: []const u8, format: content.Image.Format, bytes: []const u8 }{
        .{ .path = "image.png", .format = .png, .bytes = png },
        .{ .path = "photo.jpg", .format = .jpeg, .bytes = jpeg },
    }) |expected| {
        const result = try resources.invoke(a, .{ .touch = .{ .address = expected.path } });
        try testing.expectEqual(@as(usize, 2), result.parts.len);
        try testing.expectEqual(expected.format, result.parts[1].image.data.format);
        try testing.expectEqualSlices(u8, expected.bytes, result.parts[1].image.data.bytes);
        const value = resultObject(try parseResult(a, result));
        try testing.expectEqual(@as(i64, @intCast(expected.bytes.len)), value.get("content").?.object.get("image").?.object.get("data").?.object.get("byte_length").?.integer);
        const bad = try resources.invoke(a, .{ .touch = .{ .address = expected.path, .offset = 1 } });
        try testing.expectEqualStrings("invalid_range", try errorCode(a, bad));
    }

    const pdf = "%PDF-1.7\nall ASCII";
    try temporary.dir.writeFile(io, .{ .sub_path = "document.pdf", .data = pdf });
    const result = try resources.invoke(a, .{ .touch = .{ .address = "document.pdf" } });
    try testing.expectEqual(@as(usize, 2), result.parts.len);
    try testing.expectEqualSlices(u8, pdf, result.parts[1].file.bytes);
    const value = resultObject(try parseResult(a, result));
    try testing.expectEqual(@as(i64, pdf.len), value.get("content").?.object.get("file").?.object.get("byte_length").?.integer);
}

test "a complete source over the shared limit is reported unavailable" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var file = try temporary.dir.createFile(io, "large.bin", .{});
    defer file.close(io);
    try file.setLength(io, content.file_size_limit + 1);
    var resources = try Resources.init(io, a, try temporaryPath(a, &temporary), ".");
    const result = try resources.invoke(a, .{ .touch = .{ .address = "large.bin" } });
    const value = resultObject(try parseResult(a, result));
    const unavailable = value.get("content").?.object.get("unavailable").?.object;
    try testing.expectEqualStrings("file_too_large", unavailable.get("reason").?.string);
    try testing.expectEqual(@as(i64, @intCast(content.file_size_limit + 1)), unavailable.get("byte_length").?.integer);
    try testing.expectEqual(@as(usize, 1), result.parts.len);
}

test "touch lists one directory level and caps entries" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try temporary.dir.createDirPath(io, "many");
    var name_buffer: [32]u8 = undefined;
    for (0..105) |index| {
        const name = try std.fmt.bufPrint(&name_buffer, "many/f{d:0>3}", .{index});
        try temporary.dir.writeFile(io, .{ .sub_path = name, .data = "x" });
    }
    var resources = try Resources.init(io, a, try temporaryPath(a, &temporary), ".");
    const result = try resources.invoke(a, .{ .touch = .{ .address = "many" } });
    const value = resultObject(try parseResult(a, result));
    const entries = value.get("entries").?.array.items;
    try testing.expectEqual(@as(usize, directory_entry_limit), entries.len);
    try testing.expect(value.get("truncated").?.bool);
    const first = entries[0].object;
    try testing.expect(first.get("name").?.string.len != 0);
    try testing.expectEqualStrings("file", first.get("kind").?.string);
    try testing.expectEqual(@as(i64, 1), first.get("byte_length").?.integer);
    try testing.expect(first.get("modified_ms").?.integer > 0);
    for (1..entries.len) |index| {
        const previous = entries[index - 1].object.get("name").?.string;
        const current = entries[index].object.get("name").?.string;
        try testing.expect(std.mem.lessThan(u8, previous, current));
    }
    const bad = try resources.invoke(a, .{ .touch = .{ .address = "many", .offset = 1 } });
    try testing.expectEqualStrings("invalid_range", try errorCode(a, bad));
}

test "touch rejects lexical and symlink escapes and reports missing paths" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try temporary.dir.createDirPath(io, "root");
    try temporary.dir.writeFile(io, .{ .sub_path = "outside.txt", .data = "outside" });
    try temporary.dir.writeFile(io, .{ .sub_path = "root/inside.txt", .data = "inside" });
    try temporary.dir.symLink(io, "../outside.txt", "root/link", .{});
    try temporary.dir.symLink(io, "loop", "root/loop", .{});
    const temporary_path = try temporaryPath(a, &temporary);
    const root = try std.fs.path.join(a, &.{ temporary_path, "root" });
    var resources = try Resources.init(io, a, root, ".");

    const inside = try resources.invoke(a, .{ .touch = .{ .address = "inside.txt" } });
    try testing.expectEqualStrings("inside", resultObject(try parseResult(a, inside)).get("content").?.string);

    const relative_escape = try resources.invoke(a, .{ .touch = .{ .address = "../outside.txt" } });
    try testing.expectEqualStrings("outside_scope", try errorCode(a, relative_escape));
    const symlink_escape = try resources.invoke(a, .{ .touch = .{ .address = "link" } });
    try testing.expectEqualStrings("outside_scope", try errorCode(a, symlink_escape));
    const absolute_outside = try std.fs.path.join(a, &.{ temporary_path, "outside.txt" });
    const absolute_escape = try resources.invoke(a, .{ .touch = .{ .address = absolute_outside } });
    try testing.expectEqualStrings("outside_scope", try errorCode(a, absolute_escape));

    const missing = try resources.invoke(a, .{ .touch = .{ .address = "missing.txt" } });
    try testing.expectEqualStrings("not_found", try errorCode(a, missing));
    const loop = try resources.invoke(a, .{ .touch = .{ .address = "loop" } });
    try testing.expectEqualStrings("not_readable", try errorCode(a, loop));
}

test "relative addresses use the first root and absolute addresses may use another" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try temporary.dir.createDirPath(io, "first");
    try temporary.dir.createDirPath(io, "second");
    try temporary.dir.writeFile(io, .{ .sub_path = "first/value.txt", .data = "from first" });
    try temporary.dir.writeFile(io, .{ .sub_path = "second/value.txt", .data = "from second" });
    const temporary_path = try temporaryPath(a, &temporary);
    var resources = try Resources.init(io, a, temporary_path, "first:second");

    const first = try resources.invoke(a, .{ .touch = .{ .address = "value.txt" } });
    try testing.expectEqualStrings("from first", resultObject(try parseResult(a, first)).get("content").?.string);
    const second_path = try std.fs.path.join(a, &.{ temporary_path, "second/value.txt" });
    const second = try resources.invoke(a, .{ .touch = .{ .address = second_path } });
    try testing.expectEqualStrings("from second", resultObject(try parseResult(a, second)).get("content").?.string);
}

test "without configured roots every address is outside scope" {
    const io = testing.io;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try temporary.dir.writeFile(io, .{ .sub_path = "note.txt", .data = "hello" });
    const path = try temporaryPath(a, &temporary);

    for ([_]?[]const u8{ null, "" }) |configured| {
        var resources = try Resources.init(io, a, path, configured);
        const relative = try resources.invoke(a, .{ .touch = .{ .address = "note.txt" } });
        try testing.expectEqualStrings("outside_scope", try errorCode(a, relative));
        const message = (try parseResult(a, relative)).object.get("error").?.object.get("message").?.string;
        try testing.expect(std.mem.indexOf(u8, message, "RESOURCE_ROOTS") != null);
        const absolute = try std.fs.path.join(a, &.{ path, "note.txt" });
        const outside = try resources.invoke(a, .{ .touch = .{ .address = absolute } });
        try testing.expectEqualStrings("outside_scope", try errorCode(a, outside));
    }
}

test "touch validates its declaration and exposes one capability" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try Resources.Request.parse(a, "other", "{}")) == null);
    try testing.expectError(error.InvalidToolArguments, Resources.Request.parse(a, "touch", "{\"address\":\"\"}"));
    try testing.expectError(error.InvalidToolArguments, Resources.Request.parse(a, "touch", "{}"));
    try testing.expectError(error.InvalidToolArguments, Resources.Request.parse(a, "touch", "{\"address\":\"x\",\"max_bytes\":3}"));
    try testing.expectError(error.InvalidToolArguments, Resources.Request.parse(a, "touch", "{\"address\":\"x\",\"max_bytes\":8388609}"));

    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var resources = try Resources.init(testing.io, a, try temporaryPath(a, &temporary), ".");
    const tools = try resources.tools(a);
    try testing.expectEqual(@as(usize, 1), tools.declarations.len);
    try testing.expectEqualStrings("touch", tools.declarations[0].name);
    const properties = tools.declarations[0].parameters.object.get("properties").?.object;
    try testing.expect(properties.get("address") != null);
    try testing.expect(properties.get("offset") != null);
    try testing.expect(properties.get("max_bytes") != null);
}
