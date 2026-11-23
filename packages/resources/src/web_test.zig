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
        var data: [1]u8 = undefined;
        var buffers = [_][]u8{&data};
        try testing.expectEqual(0, try stream.read(io, &buffers));
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
    try testing.expect(std.mem.indexOf(u8, redirect.failure.message, "307") != null);
    try testing.expectError(error.Canceled, watching.cancel(io));
    const empty = try fetchReply(fetcher, &arena, &listener, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n{\"title\":\"Empty\",\"content\":\"\"}");
    try testing.expectEqualStrings("Empty", empty.page.title);
    try testing.expectEqualStrings("", empty.page.markdown);
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

test "one fetch supports seeking, replay, and recovery from a bad window while the provider is offline" {
    const Tool = @import("agent_contracts").Tools;
    const read = struct {
        fn call(a: Allocator, tool: Tool, role: []const u8, args: anytype) !std.json.ObjectMap {
            const input = try std.json.Stringify.valueAlloc(a, args, .{});
            const reply = (try tool.invoke(tool.context, a, .{ .session_id = 1, .focus_id = role }, "read_resource", input)).?;
            return (try std.json.parseFromSliceLeaky(std.json.Value, a, reply.parts[0].text, .{})).object;
        }
    }.call;
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var http: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    defer http.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{});
    var listening = true;
    defer if (listening) listener.deinit(io);
    const endpoint = try std.Uri.parse(try a.print("http://{f}/v1/tools/fetch", .{listener.socket.address}));
    const markdown = "Header\n今天 明天";
    const payload = try std.json.Stringify.valueAlloc(a, .{ .title = "Notes", .content = markdown }, .{});
    const response = try a.print("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n{s}", .{ payload.len, payload });
    const fetcher: Client = .{ .http = &http, .endpoint = endpoint, .api_key = "test-key" };
    var resources: root.Resources = .{ .allocator = testing.allocator, .io = io, .directory = "/", .web = fetcher.reader() };
    defer resources.deinit();
    const tool = try resources.tools(a);
    var serving = try io.concurrent(serveOnce, .{ &listener, response, null });
    defer serving.cancel(io) catch {};
    // The first call has already paid for the fetch even though the offset
    // falls inside 今. Recovery should use those bytes without another request.
    const bad = (try read(a, tool, "core", .{ .uri = test_url, .view = .{ .offset = 8 } })).get("error").?.object;
    try testing.expectEqualStrings("invalid_range", bad.get("code").?.string);
    const snapshot = bad.get("uri").?.string;
    try serving.await(io);
    listener.deinit(io);
    listening = false;

    const middle = (try read(a, tool, "activity", .{ .uri = snapshot, .view = .{ .offset = 7, .limit = 6 } })).get("result").?.object;
    try testing.expectEqualStrings(test_url, middle.get("source_uri").?.string);
    try testing.expectEqualStrings(snapshot, middle.get("uri").?.string);
    try testing.expectEqual(7, middle.get("offset").?.integer);
    try testing.expectEqualStrings("今天", middle.get("content").?.string);
    const tail = (try read(a, tool, "core", .{ .uri = snapshot, .view = .{ .offset = middle.get("next_offset").?.integer } })).get("result").?.object;
    try testing.expectEqualStrings(" 明天", tail.get("content").?.string);
    try testing.expect(tail.get("next_offset").? == .null);
    const beginning = (try read(a, tool, "core", .{ .uri = snapshot, .view = .{ .limit = 6 } })).get("result").?.object;
    try testing.expectEqualStrings("Header", beginning.get("content").?.string);

    var restarted: root.Resources = .{ .allocator = testing.allocator, .io = io, .directory = "/" };
    defer restarted.deinit();
    const expired = (try read(a, try restarted.tools(a), "core", .{ .uri = snapshot })).get("error").?.object;
    try testing.expectEqualStrings("not_found", expired.get("code").?.string);
}
