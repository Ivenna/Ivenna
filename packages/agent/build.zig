const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sqlite = b.dependency("sqlite", .{});
    const sqlite_header = b.addTranslateC(.{
        .root_source_file = sqlite.path("sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });
    const sqlite_module = sqlite_header.createModule();
    sqlite_module.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{"-DSQLITE_OMIT_LOAD_EXTENSION"},
    });
    const yaml = b.dependency("yaml", .{ .target = target, .optimize = optimize });
    const zignal = b.dependency("zignal", .{ .target = target, .optimize = optimize });
    _ = b.addModule("agent", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_module },
            .{ .name = "yaml", .module = yaml.module("yaml") },
            .{ .name = "zignal", .module = zignal.module("zignal") },
        },
    });
}
