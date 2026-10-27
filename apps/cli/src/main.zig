const std = @import("std");
const greeting = @import("greeting");

pub fn main(init: std.process.Init) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try greeting.write(&stdout.interface, "Ivenna");
    try stdout.interface.flush();
}
