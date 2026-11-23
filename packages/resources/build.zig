const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const contracts = b.dependency("agent_contracts", .{ .target = target, .optimize = optimize });
    const content = b.dependency("content", .{ .target = target, .optimize = optimize });
    const host = b.dependency("host", .{ .target = target, .optimize = optimize });
    _ = b.addModule("resources", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "agent_contracts", .module = contracts.module("agent_contracts") },
            .{ .name = "content", .module = content.module("content") },
            .{ .name = "host", .module = host.module("host") },
        },
    });
}
