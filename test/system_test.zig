//! Headless frame-hash and audio-hash regression suite: boots a ROM with no
//! window, no raylib anywhere in its import graph, and hashes the
//! framebuffer and the resampled PSG output at fixed checkpoints.
//!
//! The ROM is Cave Story MD (https://github.com/andwn/cave-story-md), a
//! freely distributable open-source homebrew, fetched into the gitignored
//! `roms/` directory by `tools/fetch_test_roms.sh` and pinned to a release
//! tag so its bytes never change. The test skips cleanly when the ROM is
//! absent; run the fetch script once to enable it.

const std = @import("std");
const audio = @import("audio");
const genesis = @import("genesis");
const scheduler = @import("scheduler");

const Genesis = genesis.Genesis;
const Cpu = genesis.Cpu;
const Core = genesis.Core;

const rom_path = "roms/doukutsu-en.gen";
const max_rom_bytes = 8 << 20;

const Checkpoint = struct { frame: u32, expected: u64 };

const checkpoints = [_]Checkpoint{
    .{ .frame = 60, .expected = 0xa46b13979b5ddf92 }, // boot
    .{ .frame = 300, .expected = 0xd251378cc7ee0066 }, // intro cutscene
    .{ .frame = 600, .expected = 0xd13de8a0c2506874 }, // title screen
};

fn frameHash(g: *const Genesis) u64 {
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&g.v.fb));
}

/// Boots the ROM into a heap-allocated machine (a megabyte of VDP and RAM is
/// too much for the stack), or skips the test when the ROM was never fetched.
fn boot(c: *Cpu) !*Genesis {
    const rom = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        rom_path,
        std.testing.allocator,
        .limited(max_rom_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    errdefer std.testing.allocator.free(rom);

    const g = try std.testing.allocator.create(Genesis);
    g.* = .{ .rom = rom, .cpu = c };
    Core.reset(c, g);
    return g;
}

fn shutdown(g: *Genesis) void {
    std.testing.allocator.free(g.rom);
    std.testing.allocator.destroy(g);
}

test "Cave Story MD boots headless and renders the same frames every run" {
    var c = Cpu{};
    const g = try boot(&c);
    defer shutdown(g);

    var next: usize = 0;
    var frame: u32 = 0;
    while (next < checkpoints.len) : (frame += 1) {
        try std.testing.expect(!c.halted);
        scheduler.runFrame(g, &c);
        if (frame != checkpoints[next].frame) continue;

        try std.testing.expectEqual(checkpoints[next].expected, frameHash(g));
        next += 1;
    }
}

/// Ten seconds: long enough to reach the title screen, where this ROM's
/// driver plays its percussion on the PSG's noise channel — clocked off tone
/// channel 2, with a decaying attenuation envelope.
const audio_frames = 600;
const audio_expected: u64 = 0xebb50a14ea6202b5;

test "the resampled PSG output is the same bytes every run" {
    var c = Cpu{};
    const g = try boot(&c);
    defer shutdown(g);

    var hasher = std.hash.Wyhash.init(0);
    var samples: u64 = 0;
    for (0..audio_frames) |_| {
        try std.testing.expect(!c.halted);
        scheduler.runFrame(g, &c);
        // Drained every frame so the fixed-size ring never drops a sample,
        // exactly as `main.zig`'s loop drains it.
        while (g.audio.pop()) |s| : (samples += 1) hasher.update(std.mem.asBytes(&s));
    }

    // A frame of emulated time is a frame's worth of 48 kHz samples; anything
    // else means the pipeline is running at the wrong rate, and a pitch-wrong
    // soundtrack is exactly the M2 hazard DESIGN.md §7 warns about.
    const ticks = @as(u64, genesis.mclk_per_line) * genesis.lines_per_frame *
        audio_frames / genesis.mclk_per_psg;
    const expected_samples = ticks * genesis.psg_rate.out / genesis.psg_rate.in;
    try std.testing.expectEqual(expected_samples, samples);
    try std.testing.expectEqual(audio_expected, hasher.final());
}
