const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const subscriptions = b.dependency("subscriptions", .{ .target = target, .optimize = optimize }).module("subscriptions");
    const imports: []const std.Build.Module.Import = &.{.{ .name = "subscriptions", .module = subscriptions }};

    const report = b.addExecutable(.{
        .name = "ivenna-report",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    b.installArtifact(report);

    const process_tests = b.addModule("process_tests", .{
        .root_source_file = b.path("src/report_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    const reporter = b.addOptions();
    reporter.addOptionPath("executable", report.getEmittedBin());
    process_tests.addOptions("reporter", reporter);
    const tests = b.addTest(.{ .root_module = process_tests });
    b.step("test", "Test the reporting executable").dependOn(&b.addRunArtifact(tests).step);
}
