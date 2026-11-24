const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = .{ .target = target, .optimize = optimize };
    const mod = b.addModule("channels", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = b.dependency("sqlite", options).module("sqlite") },
            .{ .name = "agent_contracts", .module = b.dependency("agent_contracts", options).module("agent_contracts") },
        },
    });
    b.step("test", "Test feed storage").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
}
