const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const contracts = b.dependency("agent_contracts", .{
        .target = target,
        .optimize = optimize,
    }).module("agent_contracts");
    _ = b.addModule("email", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "agent_contracts", .module = contracts }},
    });
}
