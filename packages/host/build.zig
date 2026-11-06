const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const agent = b.dependency("agent", .{ .target = target, .optimize = optimize });
    const content = b.dependency("content", .{ .target = target, .optimize = optimize });
    _ = b.addModule("host", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "agent", .module = agent.module("agent") },
            .{ .name = "content", .module = content.module("content") },
        },
    });
}
