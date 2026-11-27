const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = .{ .target = target, .optimize = optimize };
    const app = b.dependency("ivenna", options);
    b.installArtifact(app.artifact("ivenna"));

    const release = b.step("release", "Stage the GNU/Linux executable and its license notices");
    if (target.result.os.tag == .linux and target.result.isGnuLibC()) {
        release.dependOn(b.getInstallStep());
        const notices = .{
            .{ b.path("LICENSE"), "LICENSE" },
            .{ b.graph.path(.zig_lib, "../LICENSE"), "licenses/zig.txt" },
            .{ b.dependency("agent", options).namedLazyPath("yaml-license"), "licenses/yaml-zig.txt" },
            .{ b.dependency("content", options).namedLazyPath("zignal-license"), "licenses/zignal.txt" },
            .{ b.dependency("sqlite", options).namedLazyPath("zqlite-license"), "licenses/zqlite.txt" },
        };
        inline for (notices) |notice| {
            release.dependOn(&b.addInstallFile(notice[0], notice[1]).step);
        }
    } else {
        release.dependOn(&b.addFail("Release staging requires a GNU/Linux target with glibc.").step);
    }

    const run = b.addRunFile(.{ .relative = .{ .base = .install_bin, .sub_path = "ivenna" } });
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run Ivenna").dependOn(&run.step);

    const tests = b.step("test", "Run Zig regression tests");
    const http_test = b.createModule(.{ .root_source_file = b.path("tests/http.zig") });
    inline for (.{ "email", "responses", "resources" }) |name| {
        b.dependency(name, options).module(name).addImport("http_test", http_test);
    }
    inline for (.{ "agent", "email", "content", "responses", "host", "memory", "resources", "instance_state" }) |name| {
        const module = b.dependency(name, options).module(name);
        const unit_tests = b.addTest(.{ .name = name, .root_module = module });
        tests.dependOn(&b.addRunArtifact(unit_tests).step);
    }

    const cli_tests = b.addTest(.{ .name = "ivenna-cli", .root_module = app.module("cli_tests") });
    tests.dependOn(&b.addRunArtifact(cli_tests).step);
}
