const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zignal = b.dependency("zignal", .{ .target = target, .optimize = optimize });
    b.addNamedLazyPath("zignal-license", zignal.path("LICENSE"));
    _ = b.addModule("content", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zignal", .module = zignal.module("zignal") },
        },
    });
}
