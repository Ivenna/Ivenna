const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = .{ .target = target, .optimize = optimize };
    const ivenna = b.dependency("ivenna", options);
    const report = b.dependency("ivenna_report", options);
    b.installArtifact(ivenna.artifact("ivenna"));
    b.installArtifact(report.artifact("ivenna-report"));
    const run = b.addRunFile(.{ .relative = .{ .base = .install_bin, .sub_path = "ivenna" } });
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run Ivenna").dependOn(&run.step);

    const tests = b.step("test", "Run Zig regression tests");
    inline for (.{ "agent", "email", "content", "responses", "host", "memory", "subscriptions" }) |name| {
        const module = b.dependency(name, options).module(name);
        const unit_tests = b.addTest(.{ .name = name, .root_module = module });
        tests.dependOn(&b.addRunArtifact(unit_tests).step);
    }

    const reporter_tests = b.addTest(.{ .name = "ivenna-report", .root_module = report.module("process_tests") });
    tests.dependOn(&b.addRunArtifact(reporter_tests).step);
}
