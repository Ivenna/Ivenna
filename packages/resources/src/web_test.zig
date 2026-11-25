const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const root = @import("root.zig");
const Client = root.DeepSeek;
const Outcome = @import("web.zig").Outcome;
const test_url = "https://example.invalid/article?q=one&lang=中文";

fn serveOnce(listener: *std.Io.net.Server, reply: []const u8, wait_for_close: ?*std.Io.Event) !void {
    const io = testing.io;
    const stream = try listener.accept(io);
    defer stream.close(io);
    var read_buffer: [2048]u8 = undefined;
    var write_buffer: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();
    try testing.expectEqual(.POST, request.head.method);
    try testing.expectEqualStrings("/v1/tools/fetch", request.head.target);
    try testing.expectEqualStrings("application/json", request.head.content_type.?);
    var headers = request.iterateHeaders();
    var authenticated = false;
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization"))
            authenticated = std.mem.eql(u8, "Bearer test-key", header.value);
    }
    try testing.expect(authenticated);
    const body = try request.readerExpectNone(&.{}).allocRemaining(testing.allocator, .limited(1024));
    defer testing.allocator.free(body);
    const parsed = try std.json.parseFromSlice(struct { url: []const u8 }, testing.allocator, body, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(test_url, parsed.value.url);
    try writer.interface.writeAll(reply);
    try writer.interface.flush();
    if (wait_for_close) |event| {
        event.set(io);
        try @import("http_test").expectPeerClosed(&reader);
    }
}

fn fetch(service: Client, arena: Allocator) !Outcome {
    const reader = service.reader();
    return reader.fetch(reader.context, arena, test_url);
}

fn fetchReply(service: Client, arena: *std.heap.ArenaAllocator, listener: *std.Io.net.Server, reply: []const u8) !Outcome {
    var serving = try testing.io.concurrent(serveOnce, .{ listener, reply, null });
    defer serving.cancel(testing.io) catch {};
    const result = try fetch(service, arena.allocator());
    try serving.await(testing.io);
    return result;
}

test "fetch reads a bounded Markdown response and leaves provider redirects unfollowed" {
    const io = testing.io;
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    const service = try std.Uri.parse(try std.fmt.allocPrint(a, "http://{f}/v1/tools/fetch", .{listener.socket.address}));
    const fetcher: Client = .{ .http = &client, .api_key = "test-key", .endpoint = service };
    try testing.expectEqual(.rate_limited, (try fetchReply(fetcher, &arena, &listener, "HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\n\r\n")).failure.code);
    try testing.expectEqual(.page_too_large, (try fetchReply(fetcher, &arena, &listener, "HTTP/1.1 200 OK\r\nContent-Length: 40000000\r\n\r\n")).failure.code);
    try testing.expectEqual(.web_unavailable, (try fetchReply(fetcher, &arena, &listener, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n{\"title\":\"Article\",\"content\":[255]}")).failure.code);
    var destination = try address.listen(io, .{});
    defer destination.deinit(io);
    const observeRedirect = struct {
        fn accept(server: *std.Io.net.Server) !void {
            const stream = try server.accept(testing.io);
            stream.close(testing.io);
        }
    }.accept;
    var watching = try io.concurrent(observeRedirect, .{&destination});
    defer watching.cancel(io) catch {};
    const moved = try a.print("HTTP/1.1 307 Temporary Redirect\r\nLocation: http://{f}/other\r\n\r\n", .{destination.socket.address});
    const redirect = try fetchReply(fetcher, &arena, &listener, moved);
    try testing.expectEqual(.web_unavailable, redirect.failure.code);
    try testing.expectError(error.Canceled, watching.cancel(io));
    const article = try fetchReply(fetcher, &arena, &listener, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n{\"title\":\"Article\",\"content\":\"# Notes\\n今天\"}");
    try testing.expectEqualStrings("Article", article.page.title);
    try testing.expectEqualStrings("# Notes\n今天", article.page.markdown);
}

test "a canceled fetch releases an incomplete provider response" {
    const io = testing.io;
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer client.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{});
    defer listener.deinit(io);
    const raw_service = try std.fmt.allocPrint(testing.allocator, "http://{f}/v1/tools/fetch", .{listener.socket.address});
    defer testing.allocator.free(raw_service);
    var sent: std.Io.Event = .unset;
    var serving = try io.concurrent(serveOnce, .{ &listener, "HTTP/1.1 200 OK\r\nContent-Length: 999\r\n\r\n{", &sent });
    defer serving.cancel(io) catch {};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const fetcher: Client = .{ .http = &client, .api_key = "test-key", .endpoint = try std.Uri.parse(raw_service) };
    var pending = try io.concurrent(fetch, .{ fetcher, arena.allocator() });
    defer _ = pending.cancel(io) catch {};
    try sent.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(3), .clock = .awake } });
    try testing.expectError(error.Canceled, pending.cancel(io));
    try serving.await(io);
}

test "two focuses can recover from a bad window and reread a snapshot with one fetch" {
    const Tool = @import("agent_contracts").Tools;
    const core: Tool.Invocation = .{ .session_id = 1, .focus_id = "core" };
    const activity: Tool.Invocation = .{ .session_id = 2, .focus_id = "activity-2" };
    const read = struct {
        fn call(a: Allocator, tool: Tool, invocation: Tool.Invocation, args: anytype) !std.json.ObjectMap {
            const input = try std.json.Stringify.valueAlloc(a, args, .{});
            const reply = (try tool.invoke(tool.context, a, invocation, "read_resource", input)).?;
            return (try std.json.parseFromSliceLeaky(std.json.Value, a, reply.parts[0].text, .{})).object;
        }
    }.call;
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fetch_count: usize = 0;
    const page = struct {
        fn fetch(context: *const anyopaque, scratch: Allocator, url: []const u8) error{OutOfMemory}!Outcome {
            const count: *usize = @ptrCast(@alignCast(@constCast(context)));
            count.* += 1;
            if (!std.mem.eql(u8, test_url, url)) return .failed(.invalid_uri, "Unexpected test URL.");
            return .{ .page = .{ .title = "Notes", .markdown = try scratch.dupe(u8, "Header\n今天 明天") } };
        }
    };
    var resources: root.Resources = .{
        .allocator = testing.allocator,
        .io = io,
        .directory = "/",
        .web = .{ .context = &fetch_count, .disclosure = "Test page reader.", .fetch = page.fetch },
    };
    defer resources.deinit();
    const tool = try resources.tools(a);
    // The first call has already paid for the fetch even though the offset
    // falls inside 今. Recovery should use those bytes without another request.
    const bad = (try read(a, tool, core, .{ .location = test_url, .view = .{ .offset = 8 } })).get("error").?.object;
    try testing.expectEqualStrings("invalid_range", bad.get("code").?.string);
    const snapshot = bad.get("uri").?.string;

    const middle = (try read(a, tool, activity, .{ .location = snapshot, .view = .{ .offset = 7, .limit = 6 } })).get("result").?.object;
    try testing.expectEqualStrings(snapshot, middle.get("uri").?.string);
    try testing.expect(!middle.contains("source_uri") and !middle.contains("title"));
    try testing.expectEqual(7, middle.get("offset").?.integer);
    try testing.expectEqualStrings("今天", middle.get("content").?.string);
    const tail = (try read(a, tool, core, .{ .location = snapshot, .view = .{ .offset = middle.get("next_offset").?.integer } })).get("result").?.object;
    try testing.expectEqualStrings(" 明天", tail.get("content").?.string);
    try testing.expect(tail.get("next_offset") == null);
    const beginning = (try read(a, tool, core, .{ .location = snapshot, .view = .{ .limit = 6 } })).get("result").?.object;
    try testing.expectEqualStrings(test_url, beginning.get("source_uri").?.string);
    try testing.expectEqualStrings("Notes", beginning.get("title").?.string);
    try testing.expectEqualStrings("Header", beginning.get("content").?.string);

    var restarted: root.Resources = .{ .allocator = testing.allocator, .io = io, .directory = "/" };
    defer restarted.deinit();
    const expired = (try read(a, try restarted.tools(a), core, .{ .location = snapshot })).get("error").?.object;
    try testing.expectEqualStrings("not_found", expired.get("code").?.string);
    try testing.expectEqual(1, fetch_count);
}
