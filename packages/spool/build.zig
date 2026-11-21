const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const contracts = b.dependency("agent_contracts", .{
        .target = target,
        .optimize = optimize,
    }).module("agent_contracts");
    const module = b.addModule("spool", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "agent_contracts", .module = contracts }},
    });
    const unit_tests = b.addTest(.{ .name = "spool", .root_module = module });
    const run_tests = b.addRunArtifact(unit_tests);
    const tests = b.step("test", "Run spool unit tests");
    tests.dependOn(&run_tests.step);
}
