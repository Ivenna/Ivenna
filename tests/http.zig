const std = @import("std");

/// After the request body, the peer must close without sending more data.
pub fn expectPeerClosed(reader: *const std.Io.net.Stream.Reader) !void {
    if (reader.interface.bufferedLen() != 0) return error.UnexpectedRequestData;
    var byte: [1]u8 = undefined;
    var buffers = [_][]u8{&byte};
    const result = try reader.io.operateTimeout(.{ .net_read = .{
        .socket_handle = reader.stream.socket.handle,
        .data = &buffers,
    } }, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
    const read = result.net_read catch |err| switch (err) {
        // Closing with unread response bytes can reset a TCP connection.
        error.ConnectionResetByPeer => return,
        else => return err,
    };
    if (read.data_len != 0) return error.UnexpectedRequestData;
}
