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

    const tests = b.step("test", "Run Zig regression tests");
    inline for (.{ "agent", "email", "content", "responses", "host", "memory" }) |name| {
        const module = b.dependency(name, .{ .target = target, .optimize = optimize }).module(name);
        const unit_tests = b.addTest(.{ .name = name, .root_module = module });
        tests.dependOn(&b.addRunArtifact(unit_tests).step);
    }
}
