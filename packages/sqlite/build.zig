const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sqlite = b.dependency("amalgamation", .{});
    const bindings = b.addTranslateC(.{
        .root_source_file = sqlite.path("sqlite3.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();
    const zqlite = b.createModule(.{
        .root_source_file = b.dependency("zqlite", .{}).module("zqlite").root_source_file,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "c", .module = bindings }},
    });
    const mod = b.addModule("sqlite", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zqlite", .module = zqlite }},
    });
    mod.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{ "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DQS=0", "-DSQLITE_DEFAULT_FILE_PERMISSIONS=0600" },
    });
}
