const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const agent = b.dependency("agent", .{
        .target = target,
        .optimize = optimize,
    }).module("agent");
    const server = b.addExecutable(.{
        .name = "ivenna-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "agent", .module = agent }},
        }),
    });
    b.installArtifact(server);

    const run_server = b.addRunArtifact(server);
    b.step("run", "Run the Ivenna HTTP service").dependOn(&run_server.step);
}
