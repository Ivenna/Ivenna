const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.addModule("greeting", .{
        .root_source_file = b.path("src/root.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });

    const unit_tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run greeting package tests");
    test_step.dependOn(&run_tests.step);
}
