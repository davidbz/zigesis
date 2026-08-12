const std = @import("std");

/// Test data is gitignored, so the steps that need it are wired up only when
/// it has been fetched — a fresh checkout still builds and tests green.
fn dirExists(b: *std.Build, rel: []const u8) bool {
    b.build_root.handle.access(b.graph.io, rel, .{}) catch return false;
    return true;
}

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
    const z80 = b.addModule("z80", .{
        .root_source_file = b.path("src/z80/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const psg = b.addModule("psg", .{
        .root_source_file = b.path("src/psg.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ym2612 = b.addModule("ym2612", .{
        .root_source_file = b.path("src/ym2612.zig"),
        .target = target,
        .optimize = optimize,
    });
    const audio = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
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
            .{ .name = "z80", .module = z80 },
            .{ .name = "psg", .module = psg },
            .{ .name = "ym2612", .module = ym2612 },
            .{ .name = "audio", .module = audio },
        },
    });
    // Frontend data modules: bindings, options, and the idle screen's pixels.
    // Still no raylib — only `main.zig` and `ui/shell.zig` draw anything.
    const input = b.addModule("input", .{
        .root_source_file = b.path("src/input.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "genesis", .module = genesis }},
    });
    const cfg = b.addModule("config", .{
        .root_source_file = b.path("src/config.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "input", .module = input }},
    });
    const snow = b.addModule("snow", .{
        .root_source_file = b.path("src/ui/snow.zig"),
        .target = target,
        .optimize = optimize,
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

    const z80_tests = b.addTest(.{ .root_module = z80 });
    test_step.dependOn(&b.addRunArtifact(z80_tests).step);
    check_step.dependOn(&z80_tests.step);

    const psg_tests = b.addTest(.{ .root_module = psg });
    test_step.dependOn(&b.addRunArtifact(psg_tests).step);
    check_step.dependOn(&psg_tests.step);

    const ym_tests = b.addTest(.{ .root_module = ym2612 });
    test_step.dependOn(&b.addRunArtifact(ym_tests).step);
    check_step.dependOn(&ym_tests.step);

    const audio_tests = b.addTest(.{ .root_module = audio });
    test_step.dependOn(&b.addRunArtifact(audio_tests).step);
    check_step.dependOn(&audio_tests.step);

    const genesis_tests = b.addTest(.{ .root_module = genesis });
    test_step.dependOn(&b.addRunArtifact(genesis_tests).step);
    check_step.dependOn(&genesis_tests.step);

    const scheduler_tests = b.addTest(.{ .root_module = scheduler });
    test_step.dependOn(&b.addRunArtifact(scheduler_tests).step);
    check_step.dependOn(&scheduler_tests.step);

    const input_tests = b.addTest(.{ .root_module = input });
    test_step.dependOn(&b.addRunArtifact(input_tests).step);
    check_step.dependOn(&input_tests.step);

    const config_tests = b.addTest(.{ .root_module = cfg });
    test_step.dependOn(&b.addRunArtifact(config_tests).step);
    check_step.dependOn(&config_tests.step);

    const snow_tests = b.addTest(.{ .root_module = snow });
    test_step.dependOn(&b.addRunArtifact(snow_tests).step);
    check_step.dependOn(&snow_tests.step);

    // The headless frame-hash regression suite: no raylib in its import
    // graph, so it can run anywhere `zig build test` runs.
    const system_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/system_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "genesis", .module = genesis },
            .{ .name = "scheduler", .module = scheduler },
            .{ .name = "audio", .module = audio },
        },
    }) });
    const system_tests_run = b.addRunArtifact(system_tests);
    system_tests_run.setCwd(b.path(".")); // roms/ is resolved relative to the project
    test_step.dependOn(&system_tests_run.step);
    check_step.dependOn(&system_tests.step);

    // --- YM2612 differential harness ------------------------------------------
    // Nuked-OPN2 is LGPL-2.1 and test-only: it is fetched into the gitignored
    // testdata/ by tools/fetch_ym_reference.sh, never linked into the
    // emulator, and this step only exists once it is there.
    const nuked_dir = "testdata/nuked-opn2";
    if (dirExists(b, nuked_dir)) {
        const ym_nuked_mod = b.createModule(.{
            .root_source_file = b.path("test/ym_nuked_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "ym2612", .module = ym2612 }},
        });
        ym_nuked_mod.addIncludePath(b.path(nuked_dir));
        ym_nuked_mod.addCSourceFile(.{
            .file = b.path(nuked_dir ++ "/ym3438.c"),
            // Nuked shifts negative values left in its envelope generator,
            // which is UB in C and traps under the sanitizer Debug turns on.
            // It is the reference, not code to fix: let it wrap.
            .flags = &.{ "-std=c99", "-fno-sanitize=undefined" },
        });
        const ym_nuked = b.addTest(.{ .root_module = ym_nuked_mod });
        const ym_nuked_run = b.addRunArtifact(ym_nuked);
        test_step.dependOn(&ym_nuked_run.step);
        check_step.dependOn(&ym_nuked.step);
        b.step("ym-nuked", "Diff the YM2612 against Nuked-OPN2, with the report")
            .dependOn(&ym_nuked_run.step);
    }

    // --- Z80 SingleStepTests conformance harness ------------------------------
    const z80_harness_mod = b.createModule(.{
        .root_source_file = b.path("test/z80_sst_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "z80", .module = z80 }},
    });
    const z80_harness_tests = b.addTest(.{ .root_module = z80_harness_mod });
    test_step.dependOn(&b.addRunArtifact(z80_harness_tests).step);
    check_step.dependOn(&z80_harness_tests.step);

    // The runner chews through 1.3 GiB of JSON across 1.6M cases: Debug takes
    // ~2m40s where ReleaseFast takes ~30s, so it always builds fast no matter
    // what -Doptimize says. Safety-checked coverage of the core still comes
    // from the Debug unit/system tests above.
    const z80_fast = b.createModule(.{
        .root_source_file = b.path("src/z80/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const z80_sst = b.addExecutable(.{
        .name = "z80-sst",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/z80_sst_test.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "z80", .module = z80_fast }},
        }),
    });

    const z80_sst_run = b.addRunArtifact(z80_sst);
    z80_sst_run.setCwd(b.path(".")); // testdata/ is resolved relative to the project
    if (b.args) |args| z80_sst_run.addArgs(args);
    b.step("z80-sst", "Run the Z80 SingleStepTests conformance suite (needs testdata/z80/)")
        .dependOn(&z80_sst_run.step);

    // --- VDPFIFOTesting scoreboard --------------------------------------------
    const vdpfifo = b.addExecutable(.{
        .name = "vdpfifo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/vdpfifo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "genesis", .module = genesis },
                .{ .name = "scheduler", .module = scheduler },
                .{ .name = "vdp", .module = vdp },
            },
        }),
    });
    check_step.dependOn(&vdpfifo.step);
    const vdpfifo_run = b.addRunArtifact(vdpfifo);
    vdpfifo_run.setCwd(b.path(".")); // roms/ is resolved relative to the project
    if (b.args) |args| vdpfifo_run.addArgs(args);
    b.step("vdpfifo", "Walk VDPFIFOTesting and print its scoreboard (needs roms/)")
        .dependOn(&vdpfifo_run.step);

    // --- the emulator ----------------------------------------------------------
    // raylib is a lazy dependency, but zigesis always needs it: the call below
    // still runs on every build after a fresh clone, a build script cannot
    // see which step was asked for.
    if (b.lazyDependency("raylib", .{
        .target = target,
        .optimize = optimize,
        .rmodels = false,
    })) |raylib_dep| {
        const zigesis = b.addExecutable(.{
            .name = "zigesis",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true, // raylib.h comes in through @cImport
                .imports = &.{
                    .{ .name = "genesis", .module = genesis },
                    .{ .name = "scheduler", .module = scheduler },
                    .{ .name = "vdp", .module = vdp },
                    .{ .name = "audio", .module = audio },
                    .{ .name = "config", .module = cfg },
                    .{ .name = "input", .module = input },
                    .{ .name = "snow", .module = snow },
                },
            }),
        });
        // The menu's arithmetic is testable without a window; the drawing is
        // not. This links raylib because `shell.zig` imports its header, and
        // runs nothing that needs a display.
        const shell = b.createModule(.{
            .root_source_file = b.path("src/ui/shell.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "config", .module = cfg },
                .{ .name = "input", .module = input },
            },
        });
        shell.linkLibrary(raylib_dep.artifact("raylib"));
        const shell_tests = b.addTest(.{ .root_module = shell });
        if (target.result.os.tag == .linux) shell_tests.use_lld = false;
        test_step.dependOn(&b.addRunArtifact(shell_tests).step);
        check_step.dependOn(&shell_tests.step);

        zigesis.root_module.linkLibrary(raylib_dep.artifact("raylib"));
        // ponytail: zig folds raylib's system libs (libGL.so, libX11.so, ...)
        // into libraylib.a as archive members (ziglang/zig#20476). LLD warns
        // once per member, and the build runner turns any unexpected linker
        // stderr into a failed step — even though the same libraries are
        // already on the link line as -lGL -lX11 ... and the link is fine.
        // The self-hosted ELF linker skips them silently, but only ELF: the
        // COFF and MachO backends cannot link this yet, so those keep LLD.
        // Drop this once zig stops archiving .so paths.
        if (target.result.os.tag == .linux) zigesis.use_lld = false;
        b.installArtifact(zigesis);
        check_step.dependOn(&zigesis.step);

        const run = b.addRunArtifact(zigesis);
        run.setCwd(b.path(".")); // roms/ is resolved relative to the project
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);
        b.step("run", "Run a Genesis ROM (needs roms/)").dependOn(&run.step);
    }
}
