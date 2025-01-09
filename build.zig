const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_check = b.addExecutable(.{
        .name = "check",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const check_step = b.step("check", "Run code analysis");
    check_step.dependOn(&exe_check.step);

    const exe = b.addExecutable(.{
        .name = "zigdoc",
        .root_module = exe_mod,
    });

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("httpz", httpz.module("httpz"));
    exe_check.root_module.addImport("httpz", httpz.module("httpz"));

    const zdt = b.dependency("zdt", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zdt", zdt.module("zdt"));
    exe_check.root_module.addImport("zdt", zdt.module("zdt"));

    const mustache = b.dependency("mustache", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("mustache", mustache.module("mustache"));
    exe_check.root_module.addImport("mustache", mustache.module("mustache"));

    const zig_cli = b.dependency("zig-cli", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zig-cli", zig_cli.module("zig-cli"));
    exe_check.root_module.addImport("zig-cli", zig_cli.module("zig-cli"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .test_runner = b.path("test_runner.zig"),
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
