const std = @import("std");
const contracts = @import("agent_contracts");
const Content = @import("content").Content;
const result = @import("result.zig");
const locator = @import("locator.zig");
const local = @import("local.zig");
const WebReader = @import("web.zig").Reader;
const Window = @import("window.zig").Window;
const View = @import("window.zig").View;
const pages = @import("pages.zig");
const Allocator = std.mem.Allocator;

pub const DeepSeek = @import("deepseek.zig").Client;

const Arguments = struct {
    uri: ?[]const u8 = null,
    view: View = .{ .window = .{} },

    fn parse(a: Allocator, json: []const u8) !Arguments {
        // The image view retains the parsed URL in the tool result.
        const value = std.json.parseFromSliceLeaky(std.json.Value, a, json, .{ .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidToolArguments,
        };
        if (value != .object) return error.InvalidToolArguments;
        var args: Arguments = .{};
        var fields = value.object.iterator();
        while (fields.next()) |field| {
            const name = field.key_ptr.*;
            const input = field.value_ptr.*;
            if (std.mem.eql(u8, name, "uri")) {
                if (input != .string or input.string.len == 0) return error.InvalidToolArguments;
                args.uri = input.string;
            } else if (std.mem.eql(u8, name, "view")) {
                args.view = try View.parse(input);
            } else return error.InvalidToolArguments;
        }
        return args;
    }
};

pub const Resources = struct {
    allocator: Allocator,
    io: std.Io,
    directory: []const u8,
    web: ?WebReader = null,
    snapshots: pages.Cache = .{},

    pub fn deinit(self: *Resources) void {
        self.snapshots.deinit(self.allocator);
    }

    pub fn tools(self: *Resources, a: Allocator) !contracts.Tools {
        const declarations = try std.json.parseFromSliceLeaky([]contracts.Model.Tool, a, @embedFile("tools.json"), .{});
        if (self.web) |web|
            declarations[0].description = try a.print("{s} {s} Use the returned snapshot URI to read more of the same page. To visit another page, open a link from the Markdown.", .{ declarations[0].description, web.disclosure });
        return .{
            .context = self,
            .invoke = invoke,
            .declarations = declarations,
        };
    }

    fn invoke(context: *anyopaque, a: Allocator, _: contracts.Tools.Invocation, name: []const u8, arguments: []const u8) anyerror!?Content {
        if (!std.mem.eql(u8, name, "read_resource")) return null;
        const self: *Resources = @ptrCast(@alignCast(context));
        const args = try Arguments.parse(a, arguments);

        const source: locator.Locator = if (args.uri) |uri| locator.parse(a, uri) catch |err| switch (err) {
            error.InvalidUri => return try result.failure(a, "invalid_uri", "Use an absolute resource URI with valid percent escapes, such as file:///path."),
            error.InvalidFileUri => return try result.failure(a, "invalid_uri", "Use a local file URI with an absolute path, such as file:///path. Encode literal ? and # in a filename."),
            error.InvalidWebUrl => return try result.failure(a, "invalid_uri", "Use an HTTP(S) URL with a host and no embedded username or password."),
            error.InvalidSnapshotUri => return try result.failure(a, "invalid_uri", "Use the complete snapshot URI returned by a web read."),
            error.UnsupportedScheme => return try result.failure(a, "unsupported_scheme", "This URI scheme is unsupported. For a host file or directory, use a file URI such as file:///path."),
            else => return err,
        } else .{ .file = self.directory };
        return switch (source) {
            .file => |path| try local.read(self.io, a, path, args.view),
            .web => |url| switch (args.view) {
                .window => |window| try self.fetchWeb(a, url, window),
                .image => try result.imageUrl(a, url),
            },
            .snapshot => |id| switch (args.view) {
                .window => |window| try self.snapshots.read(self.io, a, id, window) orelse
                    try result.failure(a, "not_found", "No snapshot is available at this URI. Open the original HTTP(S) URL to fetch a fresh copy."),
                .image => try result.failure(a, "unsupported_view", "Web snapshots contain Markdown. Omit view to read the text."),
            },
        };
    }

    fn fetchWeb(self: *Resources, a: Allocator, url: []const u8, window: Window) !Content {
        const web = self.web orelse return result.failure(a, "web_unavailable", "Web page reading is disabled in this runtime.");
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        return switch (try web.fetch(web.context, scratch.allocator(), url)) {
            .page => |page| self.snapshots.open(self.io, self.allocator, a, url, page, window),
            .failure => |reason| result.failure(a, @tagName(reason.code), reason.message),
        };
    }
};

test {
    _ = locator;
    _ = local;
    _ = @import("web_test.zig");
    _ = pages;
}

test "the registered reader accepts an image URL even when page retrieval is disabled" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var resources: Resources = .{ .io = std.testing.io, .allocator = std.testing.allocator, .directory = "/" };
    const tools = try resources.tools(a);
    const invocation: contracts.Tools.Invocation = .{ .session_id = 0, .focus_id = "core" };
    for ([_][]const u8{
        \\{"uri":""}
        ,
        \\{"uri":[46,47]}
        ,
        \\{"uri":"https://example.org/","view":"video"}
        ,
        \\{"uri":"file:///","view":{"offset":-1}}
        ,
        \\{"uri":"file:///","view":{"limit":0}}
        ,
        \\{"uri":"https://example.org/","view":"image","limit":1}
        ,
    }) |args| try std.testing.expectError(error.InvalidToolArguments, tools.invoke(tools.context, a, invocation, "read_resource", args));
    const disabled = (try tools.invoke(tools.context, a, invocation, "read_resource",
        \\{"uri":"https://example.org/"}
    )).?;
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, disabled.parts[0].text, .{});
    try std.testing.expectEqualStrings("web_unavailable", value.object.get("error").?.object.get("code").?.string);

    const url = "https://example.org/preview?file=a%2Fb";
    const args = try std.json.Stringify.valueAlloc(a, .{ .uri = url, .view = "image" }, .{});
    const picture = (try tools.invoke(tools.context, a, invocation, "read_resource", args)).?;
    // A retained image reference must outlive the model's argument buffer.
    @memset(args, ' ');
    try std.testing.expectEqual(2, picture.parts.len);
    try std.testing.expectEqualStrings(url, picture.parts[1].image.url);
    const description = (try std.json.parseFromSliceLeaky(std.json.Value, a, picture.parts[0].text, .{})).object.get("result").?.object;
    try std.testing.expectEqualStrings("image_url", description.get("kind").?.string);
    try std.testing.expectEqualStrings(url, description.get("uri").?.string);
}

test "a focus opens a child from the startup directory listing" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "a", .data = "first" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "b #.md", .data = "second" });
    var path: [std.fs.max_path_bytes]u8 = undefined;
    const length = try tmp.dir.realPath(t.io, &path);
    var reader: Resources = .{ .allocator = t.allocator, .io = t.io, .directory = path[0..length] };
    defer reader.deinit();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tool = try reader.tools(a);
    const focus: contracts.Tools.Invocation = .{ .session_id = 0, .focus_id = "core" };
    const listing = (try tool.invoke(tool.context, a, focus, "read_resource", "{}")).?;
    const directory = (try std.json.parseFromSliceLeaky(std.json.Value, a, listing.parts[0].text, .{})).object.get("result").?.object;
    try t.expectEqualStrings("directory", directory.get("kind").?.string);
    try t.expectEqualStrings(path[0..length], std.mem.trimEnd(u8, (try locator.parse(a, directory.get("uri").?.string)).file, "/"));
    const window = (try tool.invoke(tool.context, a, focus, "read_resource",
        \\{"view":{"offset":1,"limit":1}}
    )).?;
    const entries = (try std.json.parseFromSliceLeaky(std.json.Value, a, window.parts[0].text, .{})).object.get("result").?.object.get("entries").?.array.items;
    try t.expectEqual(1, entries.len);
    const child = entries[0].object.get("uri").?.string;
    const args = try std.json.Stringify.valueAlloc(a, .{ .uri = child }, .{});
    const opened = (try tool.invoke(tool.context, a, focus, "read_resource", args)).?;
    const file = (try std.json.parseFromSliceLeaky(std.json.Value, a, opened.parts[0].text, .{})).object.get("result").?.object;
    try t.expectEqualStrings("second", file.get("content").?.string);
}
