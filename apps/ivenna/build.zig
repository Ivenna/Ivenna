const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = .{ .target = target, .optimize = optimize };
    const agent = b.dependency("agent", options).module("agent");
    const subscriptions = b.dependency("subscriptions", options).module("subscriptions");
    const channels = b.dependency("channels", options).module("channels");
    const contracts = b.dependency("agent_contracts", options).module("agent_contracts");
    const email = b.dependency("email", options).module("email");
    const responses = b.dependency("responses", options).module("responses");
    const host = b.dependency("host", options).module("host");
    const memory = b.dependency("memory", options).module("memory");
    const resources = b.dependency("resources", options).module("resources");
    const app = b.addExecutable(.{
        .name = "ivenna",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "agent", .module = agent },
                .{ .name = "subscriptions", .module = subscriptions },
                .{ .name = "channels", .module = channels },
                .{ .name = "agent_contracts", .module = contracts },
                .{ .name = "email", .module = email },
                .{ .name = "responses", .module = responses },
                .{ .name = "host", .module = host },
                .{ .name = "memory", .module = memory },
                .{ .name = "resources", .module = resources },
            },
        }),
    });
    b.installArtifact(app);

    const reporter = b.dependency("ivenna_report", options);
    b.installArtifact(reporter.artifact("ivenna-report"));
    const run = b.addRunFile(.{ .relative = .{ .base = .install_bin, .sub_path = "ivenna" } });
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run Ivenna").dependOn(&run.step);
}
