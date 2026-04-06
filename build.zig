const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep_argzon = b.dependency("argzon", .{
        .target = target,
        .optimize = optimize,
    });
    const mod_argzon = dep_argzon.module("argzon");

    const mod_lz4u = b.addModule("lz4u", .{
        .root_source_file = b.path("src/lz4u.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_dec = b.addExecutable(.{
        .name = "lz4u-dec",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/lz4u-dec/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "argzon", .module = mod_argzon },
                .{ .name = "lz4u", .module = mod_lz4u },
            },
        }),
    });

    b.installArtifact(exe_dec);

    const exe_enc = b.addExecutable(.{
        .name = "lz4u-enc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cmd/lz4u-enc/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "argzon", .module = mod_argzon },
                .{ .name = "lz4u", .module = mod_lz4u },
            },
        }),
    });

    b.installArtifact(exe_enc);

    //
    // tests
    //
    const tests_lz4u = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lz4u.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests_all = b.addRunArtifact(tests_lz4u);

    tests_lz4u.root_module.addImport("lz4u", mod_lz4u);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests_all.step);

    //
    // check stage for ZLS
    //
    const check_dec = b.addExecutable(.{
        .name = "lz4u-dec",
        .root_module = exe_dec.root_module,
    });
    check_dec.root_module.addImport("lz4u", mod_lz4u);
    const check_enc = b.addExecutable(.{
        .name = "lz4u-enc",
        .root_module = exe_enc.root_module,
    });
    check_enc.root_module.addImport("lz4u", mod_lz4u);
    const check_tests = b.addTest(.{
        .root_module = tests_lz4u.root_module,
    });
    check_tests.root_module.addImport("lz4u", mod_lz4u);

    const step_check = b.step("check", "Check if the project compiles");
    step_check.dependOn(&check_dec.step);
    step_check.dependOn(&check_enc.step);
    step_check.dependOn(&check_tests.step);
}
