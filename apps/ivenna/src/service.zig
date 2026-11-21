const std = @import("std");
const Kernel = @import("agent").Kernel;

/// Exposes listener health and the kernel's current reception state.
pub const Service = struct {
    io: std.Io,
    listener: std.Io.net.Server,
    kernel: *Kernel,

    const Result = union(enum) { accept: anyerror!void, client: anyerror!void };
    const Tasks = std.Io.Select(Result);
    const headers = [_]std.http.Header{
        .{ .name = "Content-Type", .value = "text/plain; charset=utf-8" },
        .{ .name = "Cache-Control", .value = "no-store" },
    };
    const ready_headers = headers ++ [_]std.http.Header{
        .{ .name = "X-Ivenna-Ready", .value = "true" },
    };
    const method_headers = headers ++ [_]std.http.Header{
        .{ .name = "Allow", .value = "GET" },
    };

    pub fn listen(io: std.Io, address: std.Io.net.IpAddress, kernel: *Kernel) !Service {
        return .{
            .io = io,
            .listener = try address.listen(io, .{}),
            .kernel = kernel,
        };
    }

    pub fn deinit(self: *Service) void {
        self.listener.deinit(self.io);
        self.* = undefined;
    }

    pub fn run(self: *Service) !void {
        var results: [1]Result = undefined;
        var tasks = Tasks.init(self.io, &results);
        defer {
            self.kernel.closeReception();
            tasks.cancelDiscard();
        }
        try tasks.concurrent(.accept, acceptLoop, .{ self, &tasks });
        while (true) switch (try tasks.await()) {
            .accept => |result| return result,
            .client => |result| try result,
        };
    }

    fn acceptLoop(self: *Service, tasks: *Tasks) !void {
        while (true) {
            const connection = self.listener.accept(self.io) catch |err| switch (err) {
                error.ConnectionAborted => continue,
                else => return err,
            };
            tasks.concurrent(.client, handle, .{ self, connection }) catch |err| {
                connection.close(self.io);
                return err;
            };
        }
    }

    fn handle(self: *Service, connection: std.Io.net.Stream) !void {
        defer connection.close(self.io);
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [1024]u8 = undefined;
        var reader = connection.reader(self.io, &read_buffer);
        var writer = connection.writer(self.io, &write_buffer);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = server.receiveHead() catch |err| switch (err) {
            error.ReadFailed => return switch (reader.err.?) {
                error.ConnectionResetByPeer, error.SocketUnconnected, error.ConnectionTimedOut => {},
                else => |cause| cause,
            },
            else => return,
        };
        const response: struct { status: std.http.Status, body: []const u8, ready: bool = false } = if (request.head.method != .GET)
            .{ .status = .method_not_allowed, .body = "method not allowed\n" }
        else if (std.mem.eql(u8, request.head.target, "/healthz"))
            .{ .status = .ok, .body = "ok\n" }
        else if (std.mem.eql(u8, request.head.target, "/readyz"))
            if (self.kernel.isReceiving())
                .{ .status = .ok, .body = "ready\n", .ready = true }
            else
                .{ .status = .service_unavailable, .body = "not ready\n" }
        else
            .{ .status = .not_found, .body = "not found\n" };
        request.respond(response.body, .{
            .status = response.status,
            .keep_alive = false,
            .extra_headers = if (request.head.method != .GET) &method_headers else if (response.ready) &ready_headers else &headers,
        }) catch |err| switch (err) {
            error.HttpExpectationFailed => return,
            error.WriteFailed => return switch (writer.err orelse err) {
                error.ConnectionResetByPeer,
                error.SocketUnconnected,
                error.ConnectionTimedOut,
                error.ConnectionRefused,
                error.HostUnreachable,
                error.NetworkUnreachable,
                => {},
                else => |cause| cause,
            },
        };
    }
};
