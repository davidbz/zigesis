//! Headless frame-hash regression suite: boots a ROM with no window, no
//! raylib anywhere in its import graph, and hashes the framebuffer at a few
//! fixed checkpoints.
//!
//! The ROM is Cave Story MD (https://github.com/andwn/cave-story-md), a
//! freely distributable open-source homebrew, fetched into the gitignored
//! `roms/` directory by `tools/fetch_test_roms.sh` and pinned to a release
//! tag so its bytes never change. The test skips cleanly when the ROM is
//! absent; run the fetch script once to enable it.

const std = @import("std");
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
    .{ .frame = 600, .expected = 0x3cbf28f634870a6d }, // title screen
};

fn frameHash(g: *const Genesis) u64 {
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&g.v.fb));
}

test "Cave Story MD boots headless and renders the same frames every run" {
    const rom = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        rom_path,
        std.testing.allocator,
        .limited(max_rom_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(rom);

    var c = Cpu{};
    // A megabyte of VDP and RAM: too much for the stack.
    const g = try std.testing.allocator.create(Genesis);
    defer std.testing.allocator.destroy(g);
    g.* = .{ .rom = rom, .cpu = &c };
    Core.reset(&c, g);

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
