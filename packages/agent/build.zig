const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const yaml = b.dependency("yaml", .{ .target = target, .optimize = optimize });
    b.addNamedLazyPath("yaml-license", yaml.path("LICENSE"));
    const zdt = b.dependency("zdt", .{ .target = target, .optimize = optimize });
    const content = b.dependency("content", .{ .target = target, .optimize = optimize });
    const instance_state = b.dependency("instance_state", .{ .target = target, .optimize = optimize }).module("instance_state");
    const contracts = b.dependency("agent_contracts", .{ .target = target, .optimize = optimize });
    _ = b.addModule("agent", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "yaml", .module = yaml.module("yaml") },
            .{ .name = "zdt", .module = zdt.module("zdt") },
            .{ .name = "content", .module = content.module("content") },
            .{ .name = "instance_state", .module = instance_state },
            .{ .name = "agent_contracts", .module = contracts.module("agent_contracts") },
        },
    });
}
