const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const content = b.dependency("content", .{ .target = target, .optimize = optimize });
    _ = b.addModule("agent_contracts", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "content", .module = content.module("content") }},
    });
}
