const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const server = b.dependency("server", .{
        .target = target,
        .optimize = optimize,
    }).artifact("ivenna-server");
    b.installArtifact(server);
    const serve = b.addRunArtifact(server);
    b.step("serve", "Run the Ivenna HTTP service").dependOn(&serve.step);
}
