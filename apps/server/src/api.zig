const std = @import("std");
const agent = @import("agent");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Api = struct {
    allocator: Allocator,
    io: Io,
    store: *agent.Store,
    engine: *agent.Engine,
    workers: Io.Group = .init,

    /// Requests and session workers belong to the service. Stop request tasks
    /// before workers so no request can submit work during worker teardown.
    pub fn listen(self: *Api, listener: *Io.net.Server) !void {
        defer self.workers.cancel(self.io);
        var connections: Io.Group = .init;
        defer connections.cancel(self.io);
        {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            for (try self.store.pendingSessionIds(arena.allocator())) |id| {
                try self.startSession(id);
            }
        }
        while (true) {
            const stream = try listener.accept(self.io);
            connections.concurrent(self.io, serveConnection, .{ self, stream }) catch |err| {
                stream.close(self.io);
                return err;
            };
        }
    }

    fn serveConnection(self: *Api, stream: Io.net.Stream) void {
        defer stream.close(self.io);
        var read_buffer: [8192]u8 = undefined;
        var write_buffer: [8192]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        var writer = stream.writer(self.io, &write_buffer);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = server.receiveHead() catch return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        self.handle(arena.allocator(), &request) catch |err| {
            if (err == error.Canceled) return;
            // Stream adapters retain the original cancellation underneath the
            // generic ReadFailed/WriteFailed returned by HTTP parsing.
            if (reader.err) |read_error| if (read_error == error.Canceled) return;
            if (writer.err) |write_error| if (write_error == error.Canceled) return;
            switch (err) {
                error.InvalidUserFields => return sendError(&request, .bad_request, "invalid_user_fields") catch {},
                error.InvalidInput => return sendError(&request, .bad_request, "invalid_input") catch {},
                error.HttpExpectationFailed => return sendError(&request, .expectation_failed, "invalid_expectation") catch {},
                error.SessionNotFound => return sendError(&request, .not_found, "session_not_found") catch {},
                error.SessionNotAvailable => return sendError(&request, .conflict, "session_not_available") catch {},
                else => {},
            }
            std.log.err("HTTP request failed: {s}", .{@errorName(err)});
            sendError(&request, .internal_server_error, "internal_error") catch {};
        };
    }

    fn handle(self: *Api, allocator: Allocator, request: *std.http.Server.Request) !void {
        // Reading a body invalidates the strings in request.head, so resolve the
        // route and copy its numeric ID before beginning body decoding.
        const path = std.mem.sliceTo(request.head.target, '?');
        const route = parseRoute(path);
        const method = request.head.method;
        switch (route) {
            .sessions => {
                if (method != .POST) return methodNotAllowed(request, "POST");
                const user_fields = readObject(allocator, request) catch |err| switch (err) {
                    error.InvalidJsonObject => return error.InvalidUserFields,
                    else => return err,
                };
                const id = try self.engine.createSession(allocator, user_fields);
                const session = try self.store.getSession(allocator, id) orelse return error.SessionNotFound;
                return sendSession(allocator, request, .created, session);
            },
            .session => |id| {
                if (method != .GET) return methodNotAllowed(request, "GET");
                const session = try self.store.getSession(allocator, id) orelse return error.SessionNotFound;
                return sendSession(allocator, request, .ok, session);
            },
            .session_input => |id| {
                if (method != .POST) return methodNotAllowed(request, "POST");
                const input = readObject(allocator, request) catch |err| switch (err) {
                    error.InvalidJsonObject => return error.InvalidInput,
                    else => return err,
                };
                try self.engine.submitInput(allocator, id, input);
                try self.startSession(id);
                return sendJson(allocator, request, .accepted, .{ .id = id, .status = "accepted" });
            },
            .resume_session => |id| {
                if (method != .POST) return methodNotAllowed(request, "POST");
                try self.store.resumeSession(id);
                try self.startSession(id);
                return sendJson(allocator, request, .accepted, .{ .id = id, .status = "accepted" });
            },
            .missing => return sendError(request, .not_found, "not_found"),
        }
    }

    fn startSession(self: *Api, id: i64) !void {
        try self.workers.concurrent(self.io, executeSession, .{ self, id });
    }

    fn executeSession(self: *Api, id: i64) void {
        self.engine.execute(id) catch |err| switch (err) {
            error.Canceled, error.SessionNotAvailable => return,
            else => std.log.warn("session {d} stopped: {s}", .{ id, @errorName(err) }),
        };
    }
};

const Route = union(enum) { sessions, session: i64, session_input: i64, resume_session: i64, missing };

fn parseRoute(path: []const u8) Route {
    if (std.mem.eql(u8, path, "/sessions")) return .sessions;
    if (!std.mem.startsWith(u8, path, "/sessions/")) return .missing;
    var parts = std.mem.splitScalar(u8, path["/sessions/".len..], '/');
    const id = std.fmt.parseInt(i64, parts.next() orelse return .missing, 10) catch return .missing;
    if (id <= 0) return .missing;
    const action = parts.next() orelse return .{ .session = id };
    if (parts.next() != null) return .missing;
    if (std.mem.eql(u8, action, "inputs")) return .{ .session_input = id };
    if (std.mem.eql(u8, action, "resume")) return .{ .resume_session = id };
    return .missing;
}

fn readObject(allocator: Allocator, request: *std.http.Server.Request) !std.json.Value {
    const reader = try request.readerExpectContinue(&.{});
    const body = try reader.allocRemaining(allocator, .unlimited);
    const decoded = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidJsonObject,
    };
    if (decoded != .object) return error.InvalidJsonObject;
    return decoded;
}

fn sendSession(allocator: Allocator, request: *std.http.Server.Request, status: std.http.Status, session: agent.Session) !void {
    return sendJson(allocator, request, status, .{
        .id = session.id,
        .user_fields = try std.json.parseFromSliceLeaky(std.json.Value, allocator, session.user_fields_json, .{}),
        .status = session.status,
        .messages = try std.json.parseFromSliceLeaky(std.json.Value, allocator, session.messages_json, .{}),
        .pending_inputs = try std.json.parseFromSliceLeaky(std.json.Value, allocator, session.pending_inputs_json, .{}),
        .error_message = session.error_message,
    });
}

fn sendJson(allocator: Allocator, request: *std.http.Server.Request, status: std.http.Status, value: anytype) !void {
    const body = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(body);
    return request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

fn sendError(request: *std.http.Server.Request, status: std.http.Status, comptime code: []const u8) !void {
    return request.respond("{\"error\":\"" ++ code ++ "\"}", .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

fn methodNotAllowed(request: *std.http.Server.Request, comptime allow: []const u8) !void {
    return request.respond("{\"error\":\"method_not_allowed\"}", .{
        .status = .method_not_allowed,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "allow", .value = allow },
        },
    });
}
