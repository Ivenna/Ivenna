const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = .{ .target = target, .optimize = optimize };
    const app = b.dependency("ivenna", options);
    b.installArtifact(app.artifact("ivenna"));
    const run = b.addRunFile(.{ .relative = .{ .base = .install_bin, .sub_path = "ivenna" } });
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run Ivenna").dependOn(&run.step);

    const tests = b.step("test", "Run Zig regression tests");
    const http_test = b.createModule(.{ .root_source_file = b.path("tests/http.zig") });
    inline for (.{ "email", "responses", "resources" }) |name| {
        b.dependency(name, options).module(name).addImport("http_test", http_test);
    }
    inline for (.{ "agent", "email", "content", "responses", "host", "memory", "resources", "instance_state" }) |name| {
        const module = b.dependency(name, options).module(name);
        const unit_tests = b.addTest(.{ .name = name, .root_module = module });
        tests.dependOn(&b.addRunArtifact(unit_tests).step);
    }

    const cli_tests = b.addTest(.{ .name = "ivenna-cli", .root_module = app.module("cli_tests") });
    tests.dependOn(&b.addRunArtifact(cli_tests).step);
}
