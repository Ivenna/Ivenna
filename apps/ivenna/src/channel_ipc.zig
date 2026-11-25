const std = @import("std");
const contracts = @import("agent_contracts");
const linux = std.os.linux;
const net = std.Io.net;

const max_id_bytes = 4 * contracts.Reference.max_name_characters + 21;
const prefix = "\x00ivenna.channels.";
const timeout_header_size = @sizeOf(u32);
const next_request = "\x01";

pub const handshake_time = std.Io.Clock.Duration{ .raw = .fromSeconds(2), .clock = .awake };
pub const request_buffer_size = timeout_header_size + max_id_bytes + 1;
pub const response_buffer_size = 1 + contracts.Channels.max_message_bytes + 1;

pub const Response = union(enum(u8)) {
    waiting,
    message: []const u8,
    timeout,
    closed,
    unknown_channel,
};

pub fn listen(io: std.Io, data_directory: []const u8) !net.Server {
    const socket = try openSocket(false);
    errdefer socket.close(io);
    const name = address(data_directory);
    const bind_result = linux.bind(socket.handle, @ptrCast(&name), address_length);
    switch (linux.errno(bind_result)) {
        .SUCCESS => {},
        .ADDRINUSE => return error.AddressInUse,
        else => |err| return std.posix.unexpectedErrno(err),
    }
    switch (linux.errno(linux.listen(socket.handle, net.default_kernel_backlog))) {
        .SUCCESS => return .{ .socket = socket, .options = {} },
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

pub fn connect(io: std.Io, data_directory: []const u8, id: []const u8, timeout_ms: ?u32) !net.Stream {
    if (id.len > max_id_bytes) return error.UnknownChannel;
    const socket = try openSocket(true);
    errdefer socket.close(io);
    const name = address(data_directory);
    while (true) {
        switch (linux.errno(linux.connect(socket.handle, &name, address_length))) {
            .SUCCESS, .ISCONN => break,
            .INTR => try io.checkCancel(),
            .AGAIN, .CONNREFUSED, .PROTOTYPE => return error.ChannelServiceUnavailable,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
    const connection: net.Stream = .{ .socket = socket };
    try requireSameUser(connection);
    var header: [timeout_header_size]u8 = undefined;
    std.mem.writeInt(u32, &header, timeout_ms orelse 0, .little);
    try writeRequest(connection, &header, id);
    return connection;
}

pub fn requestNext(connection: net.Stream) !void {
    try writeRequest(connection, next_request, "");
}

fn writeRequest(connection: net.Stream, header: []const u8, text: []const u8) !void {
    writePacket(connection, header, text) catch |err| switch (err) {
        error.PeerDisconnected, error.WouldBlock => return error.ChannelServiceUnavailable,
        else => return err,
    };
}

const address_length = @offsetOf(linux.sockaddr.un, "path") + prefix.len + 64;

fn address(data_directory: []const u8) linux.sockaddr.un {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var hash = Sha256.init(.{});
    hash.update(std.mem.asBytes(&linux.geteuid()));
    hash.update(data_directory);
    var digest: [Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    var name: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(name.path[0..prefix.len], prefix);
    name.path[prefix.len..][0..64].* = std.fmt.bytesToHex(digest, .lower);
    return name;
}

fn openSocket(nonblocking: bool) !net.Socket {
    const extra: u32 = if (nonblocking) linux.SOCK.NONBLOCK else 0;
    const flags = linux.SOCK.SEQPACKET | linux.SOCK.CLOEXEC | extra;
    const result = linux.socket(linux.AF.UNIX, flags, 0);
    switch (linux.errno(result)) {
        .SUCCESS => return .{ .handle = @intCast(result), .address = .{ .ip4 = .loopback(0) } },
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM, .NOBUFS => return error.SystemResources,
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

pub fn requireSameUser(connection: net.Stream) !void {
    const Credentials = extern struct { pid: linux.pid_t, uid: linux.uid_t, gid: linux.gid_t };
    var credentials: Credentials = undefined;
    var length: linux.socklen_t = @sizeOf(Credentials);
    const result = linux.getsockopt(connection.socket.handle, linux.SOL.SOCKET, linux.SO.PEERCRED, std.mem.asBytes(&credentials), &length);
    if (linux.errno(result) != .SUCCESS or length != @sizeOf(Credentials) or credentials.uid != linux.geteuid())
        return error.AccessDenied;
}

pub const Request = struct { id: []const u8, timeout_ms: ?u32 };

pub fn readRequest(connection: net.Stream, io: std.Io, buffer: *[request_buffer_size]u8) !Request {
    const size = try read(connection, io, buffer, .{ .duration = handshake_time });
    if (size <= timeout_header_size or size >= buffer.len) return error.InvalidChannelRequest;
    const timeout = std.mem.readInt(u32, buffer[0..timeout_header_size], .little);
    return .{
        .id = buffer[timeout_header_size..size],
        .timeout_ms = if (timeout == 0) null else timeout,
    };
}

pub fn reply(connection: net.Stream, response: Response) WriteError!void {
    const header = [_]u8{@backingInt(std.meta.activeTag(response))};
    const text = if (response == .message) response.message else "";
    try writePacket(connection, &header, text);
}

pub fn readResponse(connection: net.Stream, buffer: *[response_buffer_size]u8) !Response {
    const size = std.posix.read(connection.socket.handle, buffer) catch |err| switch (err) {
        error.ConnectionResetByPeer => return error.ChannelServiceUnavailable,
        else => return err,
    };
    if (size == 0) return error.ChannelServiceUnavailable;
    if (size == buffer.len) return error.InvalidChannelReply;
    const tag = std.enums.fromInt(std.meta.Tag(Response), buffer[0]) orelse return error.InvalidChannelReply;
    return switch (tag) {
        .message => message: {
            const text = buffer[1..size];
            if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return error.InvalidChannelReply;
            break :message .{ .message = text };
        },
        inline else => |status| if (size == 1) @unionInit(Response, @tagName(status), {}) else error.InvalidChannelReply,
    };
}

const WaitResult = enum { next, ended, timeout };

pub fn waitForNext(connection: net.Stream, io: std.Io, deadline: ?std.Io.Clock.Timestamp) WaitResult {
    // The extra byte lets us reject oversized requests on the packet socket.
    var packet: [next_request.len + 1]u8 = undefined;
    const timeout: std.Io.Timeout = if (deadline) |end| .{ .deadline = end } else .none;
    while (true) {
        const size = read(connection, io, &packet, timeout) catch |err| switch (err) {
            error.Timeout => {
                const end = deadline.?;
                const remaining = end.durationFromNow(io).raw.toNanoseconds();
                // Threaded I/O caps long polls and rounds down to milliseconds.
                if (remaining >= std.time.ns_per_ms) continue;
                if (remaining > 0) end.wait(io) catch return .ended;
                return .timeout;
            },
            else => return .ended,
        };
        return if (std.mem.eql(u8, packet[0..size], next_request)) .next else .ended;
    }
}

pub fn endRequests(connection: net.Stream) void {
    _ = linux.shutdown(connection.socket.handle, linux.SHUT.RD);
}

fn read(connection: net.Stream, io: std.Io, buffer: []u8, timeout: std.Io.Timeout) !usize {
    var buffers = [_][]u8{buffer};
    const result = try (try io.operateTimeout(.{ .net_read = .{
        .socket_handle = connection.socket.handle,
        .data = &buffers,
    } }, timeout)).net_read;
    return result.data_len;
}

const WriteError = error{ PeerDisconnected, WouldBlock } || std.posix.UnexpectedError;

fn writePacket(connection: net.Stream, header: []const u8, text: []const u8) WriteError!void {
    const parts = [_]std.posix.iovec_const{
        .{ .base = header.ptr, .len = header.len },
        .{ .base = text.ptr, .len = text.len },
    };
    const packet: linux.msghdr_const = .{
        .name = null,
        .namelen = 0,
        .iov = &parts,
        .iovlen = parts.len,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    while (true) {
        const result = linux.sendmsg(connection.socket.handle, &packet, linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT);
        switch (linux.errno(result)) {
            .SUCCESS => {
                std.debug.assert(result == header.len + text.len);
                return;
            },
            .INTR => continue,
            .PIPE, .CONNRESET, .NOTCONN => return error.PeerDisconnected,
            .AGAIN, .NOBUFS, .NOMEM => return error.WouldBlock,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}
