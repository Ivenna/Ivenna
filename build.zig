const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const app = b.dependency("app", .{
        .target = target,
        .optimize = optimize,
    }).artifact("ivenna");
    b.installArtifact(app);
    const run = b.addRunArtifact(app);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run Ivenna").dependOn(&run.step);
}
