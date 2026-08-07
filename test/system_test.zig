//! Headless frame-hash regression suite: boots a ROM with no window, no
//! raylib anywhere in its import graph, and hashes the framebuffer at a few
//! fixed checkpoints.
//!
//! Commercial ROMs are never committed or fetched (DESIGN.md §10): this
//! test looks for one in `roms/`, gitignored, and skips cleanly when it is
//! absent — which is always, in CI. A maintainer with a legal copy of the
//! ROM runs it locally and gates on the hashes pinned below.

const std = @import("std");
const genesis = @import("genesis");
const scheduler = @import("scheduler");

const Genesis = genesis.Genesis;
const Cpu = genesis.Cpu;
const Core = genesis.Core;

const rom_path = "roms/Sonic-the-Hedgehog.bin";
const max_rom_bytes = 4 << 20;

const Checkpoint = struct { frame: u32, expected: u64 };

const checkpoints = [_]Checkpoint{
    .{ .frame = 60, .expected = 0xde64cb3e31e6f7aa }, // past the Sega logo
    .{ .frame = 300, .expected = 0xccf77dc20adc1ad3 }, // title screen
    .{ .frame = 600, .expected = 0xf00436ae93ff4a87 }, // attract-mode demo running
};

fn frameHash(g: *const Genesis) u64 {
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&g.v.fb));
}

test "Sonic 1 boots headless and renders the same frames every run" {
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
