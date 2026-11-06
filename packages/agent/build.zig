const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const yaml = b.dependency("yaml", .{ .target = target, .optimize = optimize });
    const content = b.dependency("content", .{ .target = target, .optimize = optimize });
    _ = b.addModule("agent", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "yaml", .module = yaml.module("yaml") },
            .{ .name = "content", .module = content.module("content") },
        },
    });
}
