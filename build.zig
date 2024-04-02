const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libxev_dep = b.dependency("libxev", .{ .target = target, .optimize = optimize });

    const test_step = b.step("test", "Run tests");

    const mod = b.addModule("zttp", .{
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });

    const mod_test_cases = b.addModule("test-cases", .{
        .root_source_file = .{ .path = "test/cases/root.zig" },
        .target = target,
        .optimize = optimize,
    });

    const mod_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/root.zig" },
        .target = target,
        .optimize = optimize,
    });
    mod_tests.root_module.addImport("xev", libxev_dep.module("xev"));
    mod_tests.root_module.addImport("test-cases", mod_test_cases);
    const mod_tests_run = b.addRunArtifact(mod_tests);
    mod_tests_run.has_side_effects = true;
    test_step.dependOn(&mod_tests_run.step);

    const main = b.addExecutable(.{
        .name = "zttp",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    main.root_module.addImport("xev", libxev_dep.module("xev"));
    main.root_module.addImport("zttp", mod);
    b.installArtifact(main);
}
