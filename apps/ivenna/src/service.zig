const std = @import("std");
const posix = std.posix;
const Kernel = @import("agent").Kernel;

/// Exposes listener health and the kernel's current reception state.
pub const Service = struct {
    io: std.Io,
    listener: std.Io.net.Server,

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

    pub fn listen(io: std.Io, address: std.Io.net.IpAddress) !Service {
        // Zig's reuse_address also enables SO_REUSEPORT. The status address
        // must have one live owner, including during a kernel restart.
        const threaded = std.Io.Threaded;
        const flags = posix.SOCK.STREAM | if (threaded.socket_flags_unsupported) 0 else posix.SOCK.CLOEXEC;
        const fd: posix.fd_t = @intCast(try socketCall(posix.system.socket, .{ threaded.posixAddressFamily(&address), flags, posix.IPPROTO.TCP }));
        errdefer threaded.closeFd(fd);
        if (threaded.socket_flags_unsupported) {
            _ = try socketCall(posix.system.fcntl, .{ fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC) });
        }
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&@as(c_int, 1)));
        var storage: threaded.PosixAddress = undefined;
        const len = threaded.addressToPosix(&address, &storage);
        _ = try socketCall(posix.system.bind, .{ fd, &storage.any, len });
        _ = try socketCall(posix.system.listen, .{ fd, std.Io.net.default_kernel_backlog });
        return .{
            .io = io,
            .listener = .{ .socket = .{ .handle = fd, .address = address }, .options = {} },
        };
    }

    fn socketCall(comptime operation: anytype, arguments: anytype) !usize {
        while (true) {
            const result = @call(.auto, operation, arguments);
            switch (posix.errno(result)) {
                .SUCCESS => return @intCast(result),
                .INTR => continue,
                .ACCES => return error.AccessDenied,
                .ADDRINUSE => return error.AddressInUse,
                .ADDRNOTAVAIL => return error.AddressUnavailable,
                .AFNOSUPPORT => return error.AddressFamilyUnsupported,
                .PROTONOSUPPORT => return error.ProtocolUnsupportedByAddressFamily,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS, .NOMEM => return error.SystemResources,
                else => |err| return posix.unexpectedErrno(err),
            }
        }
    }

    pub fn deinit(self: *Service) void {
        self.listener.deinit(self.io);
        self.* = undefined;
    }

    pub fn run(self: *Service, kernel: *Kernel) !void {
        var clients: std.Io.Group = .init;
        defer {
            kernel.closeReception();
            clients.cancel(self.io);
        }
        while (true) {
            const connection = self.listener.accept(self.io) catch |err| switch (err) {
                error.ConnectionAborted => continue,
                else => return err,
            };
            clients.concurrent(self.io, handle, .{ self, kernel, connection }) catch |err| {
                connection.close(self.io);
                std.log.warn("could not serve status connection: {s}", .{@errorName(err)});
            };
        }
    }

    fn handle(self: *Service, kernel: *Kernel, connection: std.Io.net.Stream) void {
        defer connection.close(self.io);
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [1024]u8 = undefined;
        var reader = connection.reader(self.io, &read_buffer);
        var writer = connection.writer(self.io, &write_buffer);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = server.receiveHead() catch return;
        const response: struct { status: std.http.Status, body: []const u8, ready: bool = false } = if (request.head.method != .GET)
            .{ .status = .method_not_allowed, .body = "method not allowed\n" }
        else if (std.mem.eql(u8, request.head.target, "/healthz"))
            .{ .status = .ok, .body = "ok\n" }
        else if (std.mem.eql(u8, request.head.target, "/readyz"))
            if (kernel.isReceiving())
                .{ .status = .ok, .body = "ready\n", .ready = true }
            else
                .{ .status = .service_unavailable, .body = "not ready\n" }
        else
            .{ .status = .not_found, .body = "not found\n" };
        request.respond(response.body, .{
            .status = response.status,
            .keep_alive = false,
            .extra_headers = if (request.head.method != .GET) &method_headers else if (response.ready) &ready_headers else &headers,
        }) catch return;
    }
};
