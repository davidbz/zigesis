//! Headless frame-hash and audio-hash regression suite: boots a ROM with no
//! window, no raylib anywhere in its import graph, and hashes the
//! framebuffer and the resampled sound output at fixed checkpoints.
//!
//! Two ROMs, both fetched into the gitignored `roms/` directory by
//! `tools/fetch_test_roms.sh` and both pinned by checksum so their bytes
//! never change: Cave Story MD (https://github.com/andwn/cave-story-md), a
//! freely distributable open-source homebrew, for the boot-to-gameplay and
//! audio checkpoints; and Nemesis' VDPFIFOTesting for VDP conformance.
//!
//! Every test here skips cleanly when its ROM is absent, so a fresh checkout
//! is green before anything is downloaded; run the fetch script once to
//! enable them.

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

/// `frame` is the number of frames run before hashing, so it means the same
/// thing here as `--shot N` does on the command line and the pinned values can
/// be regenerated with `zigesis <rom> --replay <log> --shot N --hash`.
const checkpoints = [_]Checkpoint{
    .{ .frame = 60, .expected = 0xa46b13979b5ddf92 }, // boot
    .{ .frame = 300, .expected = 0xd558811ccad79b7b }, // intro cutscene
    .{ .frame = 600, .expected = 0xd13de8a0c2506874 }, // title screen
    .{ .frame = 900, .expected = 0xd4081df3ff6ad6db }, // save-data menu, past Start
};

/// The scripted input log DESIGN.md §6.3 asks for, inline rather than in a
/// fixture file: Start held over these frames takes this ROM off its title
/// screen into the save-data menu, so the suite covers a screen that only
/// appears if input actually reaches the machine.
const start_at = 620;
const start_until = 641;

fn buttonsAt(frame: u32) u8 {
    return if (frame >= start_at and frame < start_until) genesis.btn_start else 0;
}

/// Runs up to `until` total frames, feeding the scripted input.
fn runTo(g: *Genesis, c: *Cpu, frame: *u32, until: u32) !void {
    while (frame.* < until) : (frame.* += 1) {
        try std.testing.expect(!c.halted);
        g.buttons = buttonsAt(frame.*);
        scheduler.runFrame(g, c);
    }
}

fn frameHash(g: *const Genesis) u64 {
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&g.v.fb));
}

/// Boots the ROM into a heap-allocated machine (a megabyte of VDP and RAM is
/// too much for the stack), or skips the test when the ROM was never fetched.
fn boot(c: *Cpu, path: []const u8) !*Genesis {
    const rom = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
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
    const g = try boot(&c, rom_path);
    defer shutdown(g);

    var frame: u32 = 0;
    for (checkpoints) |cp| {
        try runTo(g, &c, &frame, cp.frame);
        try std.testing.expectEqual(cp.expected, frameHash(g));
    }
}

/// Fifteen seconds: past the title screen, where this ROM's driver plays FM
/// on the YM2612 and its percussion on the PSG's noise channel — clocked off
/// tone channel 2, with a decaying attenuation envelope — and on through the
/// menu jingle Start makes.
const audio_frames = 900;
const audio_expected: u64 = 0x2154bd2b6d7f801b;

test "the resampled sound output is the same bytes every run" {
    var c = Cpu{};
    const g = try boot(&c, rom_path);
    defer shutdown(g);

    var hasher = std.hash.Wyhash.init(0);
    var samples: u64 = 0;
    var peak: i32 = 0;
    var frame: u32 = 0;
    while (frame < audio_frames) : (frame += 1) {
        try std.testing.expect(!c.halted);
        g.buttons = buttonsAt(frame);
        scheduler.runFrame(g, &c);
        // Drained every frame so the fixed-size ring never drops a sample,
        // exactly as `main.zig`'s loop drains it.
        while (g.audio.pop()) |s| : (samples += 1) {
            hasher.update(std.mem.asBytes(&s));
            peak = @max(peak, @as(i32, @intCast(@abs(@as(i32, s.l)))));
        }
    }

    // A frame of emulated time is a frame's worth of 48 kHz samples; anything
    // else means the pipeline is running at the wrong rate, and a pitch-wrong
    // soundtrack is exactly the M2 hazard DESIGN.md §7 warns about.
    const mclk = @as(u64, genesis.mclk_per_line) * genesis.lines_per_frame * audio_frames;
    const psg_frames = (mclk / genesis.mclk_per_psg) * genesis.psg_rate.out / genesis.psg_rate.in;
    const ym_frames = (mclk / genesis.mclk_per_ym) * genesis.ym_rate.out / genesis.ym_rate.in;
    // Minus one: the frame the leading chip is still filling is not ready.
    try std.testing.expectEqual(@max(psg_frames, ym_frames) - 1, samples);
    // This ROM's driver keys the FM channels and its DAC on at frame ~524, so
    // silence here means the sound chips are wired up but never heard.
    try std.testing.expect(peak > 4000);
    try std.testing.expectEqual(audio_expected, hasher.final());
}

/// Nemesis' VDP conformance ROM, also fetched by `tools/fetch_test_roms.sh`.
/// It draws its own verdict on screen as a green/red bar per test, so hashing
/// the framebuffer pins the *results*, not just the rendering: any change to
/// FIFO, DMA, or port behaviour moves this hash.
///
/// The pinned value is today's failing score (4 of 29, tabulated in DESIGN.md
/// §9 under M4) and is meant to move as M4 lands. A mismatch is not a
/// failure to debug from the hash — run
/// `zigesis roms/VDPFIFOTesting.bin out.png --shot 120 --hash`, look at the
/// PNG, and re-pin.
///
/// ponytail: page 1 only, which is tests 1-9. The later pages need Start
/// presses and minutes of emulated time, and page 5 onward does not render at
/// all yet; widen this once the FIFO exists and there is a score worth
/// watching.
const vdp_rom_path = "roms/VDPFIFOTesting.bin";
const vdp_frames = 120; // the page is drawn and static by frame 60
const vdp_expected: u64 = 0xcff0f2056acd5cca;

test "the VDP scores the same on VDPFIFOTesting page 1 every run" {
    var c = Cpu{};
    const g = try boot(&c, vdp_rom_path);
    defer shutdown(g);

    for (0..vdp_frames) |_| {
        try std.testing.expect(!c.halted);
        scheduler.runFrame(g, &c);
    }
    try std.testing.expectEqual(vdp_expected, frameHash(g));
}
