const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const z68k_dep = b.dependency("z68k", .{ .target = target, .optimize = optimize });
    const m68k = z68k_dep.module("m68k");

    // Emulation modules, in dependency order. None of these may import
    // raylib: `main.zig` is the only module that touches a display.
    const vdp = b.addModule("vdp", .{
        .root_source_file = b.path("src/vdp.zig"),
        .target = target,
        .optimize = optimize,
    });
    const genesis = b.addModule("genesis", .{
        .root_source_file = b.path("src/genesis.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "m68k", .module = m68k },
            .{ .name = "vdp", .module = vdp },
        },
    });
    const scheduler = b.addModule("scheduler", .{
        .root_source_file = b.path("src/scheduler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "m68k", .module = m68k },
            .{ .name = "vdp", .module = vdp },
            .{ .name = "genesis", .module = genesis },
        },
    });

    // A fast compile-only pass over everything, for editors (zls) and CI:
    // catches type errors without linking or running anything.
    const check_step = b.step("check", "Check that everything compiles");

    // --- tests ---------------------------------------------------------------
    const test_step = b.step("test", "Run unit and headless regression tests");

    const vdp_tests = b.addTest(.{ .root_module = vdp });
    test_step.dependOn(&b.addRunArtifact(vdp_tests).step);
    check_step.dependOn(&vdp_tests.step);

    const genesis_tests = b.addTest(.{ .root_module = genesis });
    test_step.dependOn(&b.addRunArtifact(genesis_tests).step);
    check_step.dependOn(&genesis_tests.step);

    const scheduler_tests = b.addTest(.{ .root_module = scheduler });
    test_step.dependOn(&b.addRunArtifact(scheduler_tests).step);
    check_step.dependOn(&scheduler_tests.step);

    // The headless frame-hash regression suite: no raylib in its import
    // graph, so it can run anywhere `zig build test` runs.
    const system_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/system_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "genesis", .module = genesis },
            .{ .name = "scheduler", .module = scheduler },
        },
    }) });
    const system_tests_run = b.addRunArtifact(system_tests);
    system_tests_run.setCwd(b.path(".")); // roms/ is resolved relative to the project
    test_step.dependOn(&system_tests_run.step);
    check_step.dependOn(&system_tests.step);

    // --- the emulator ----------------------------------------------------------
    // raylib is a lazy dependency, but zgen always needs it: the call below
    // still runs on every build after a fresh clone, a build script cannot
    // see which step was asked for.
    if (b.lazyDependency("raylib", .{
        .target = target,
        .optimize = optimize,
        .raudio = false, // no sound emulation yet, so nothing to play it with
        .rmodels = false,
    })) |raylib_dep| {
        const zgen = b.addExecutable(.{
            .name = "zgen",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true, // raylib.h comes in through @cImport
                .imports = &.{
                    .{ .name = "genesis", .module = genesis },
                    .{ .name = "scheduler", .module = scheduler },
                    .{ .name = "vdp", .module = vdp },
                },
            }),
        });
        zgen.root_module.linkLibrary(raylib_dep.artifact("raylib"));
        b.installArtifact(zgen);
        check_step.dependOn(&zgen.step);

        const run = b.addRunArtifact(zgen);
        run.setCwd(b.path(".")); // roms/ is resolved relative to the project
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);
        b.step("run", "Run a Genesis ROM (needs roms/)").dependOn(&run.step);
    }
}
