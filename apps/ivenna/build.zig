const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const agent = b.dependency("agent", .{
        .target = target,
        .optimize = optimize,
    }).module("agent");
    const app = b.addExecutable(.{
        .name = "ivenna",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "agent", .module = agent }},
        }),
    });
    b.installArtifact(app);

    const run = b.addRunArtifact(app);
    b.step("run", "Run Ivenna").dependOn(&run.step);
}
