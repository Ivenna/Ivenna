const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const agent = b.dependency("agent", .{
        .target = target,
        .optimize = optimize,
    }).module("agent");
    const contracts = b.dependency("agent_contracts", .{ .target = target, .optimize = optimize }).module("agent_contracts");
    const email = b.dependency("email", .{ .target = target, .optimize = optimize }).module("email");
    const responses = b.dependency("responses", .{ .target = target, .optimize = optimize }).module("responses");
    const host = b.dependency("host", .{ .target = target, .optimize = optimize }).module("host");
    const memory = b.dependency("memory", .{ .target = target, .optimize = optimize }).module("memory");
    const spool = b.dependency("spool", .{ .target = target, .optimize = optimize }).module("spool");
    const app = b.addExecutable(.{
        .name = "ivenna",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "agent", .module = agent },
                .{ .name = "agent_contracts", .module = contracts },
                .{ .name = "email", .module = email },
                .{ .name = "responses", .module = responses },
                .{ .name = "host", .module = host },
                .{ .name = "memory", .module = memory },
                .{ .name = "spool", .module = spool },
            },
        }),
    });
    b.installArtifact(app);

    const run = b.addRunArtifact(app);
    b.step("run", "Run Ivenna").dependOn(&run.step);
}
