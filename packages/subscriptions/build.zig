const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sqlite = b.dependency("sqlite", .{});
    const options = .{ .target = target, .optimize = optimize };
    const bindings = b.addTranslateC(.{
        .root_source_file = sqlite.path("sqlite3.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();
    const mod = b.addModule("subscriptions", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "sqlite", .module = bindings },
            .{ .name = "agent_contracts", .module = b.dependency("agent_contracts", options).module("agent_contracts") },
        },
    });
    mod.addCSourceFile(.{ .file = sqlite.path("sqlite3.c"), .flags = &.{ "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DQS=0", "-DSQLITE_DEFAULT_FILE_PERMISSIONS=0600" } });
    b.step("test", "Test subscription storage").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
}
