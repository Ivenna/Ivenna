const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const greeting = b.dependency("greeting", .{
        .target = target,
        .optimize = optimize,
    }).module("greeting");

    const cli = b.addExecutable(.{
        .name = "ivenna",
        .root_module = b.createModule(.{
            .root_source_file = b.path("apps/cli/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "greeting", .module = greeting }},
        }),
    });
    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    run_cli.addPassthruArgs();
    const run_step = b.step("run", "Run the Ivenna CLI");
    run_step.dependOn(&run_cli.step);

    const greeting_tests = b.addTest(.{ .root_module = greeting });
    const run_greeting_tests = b.addRunArtifact(greeting_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_greeting_tests.step);
}
