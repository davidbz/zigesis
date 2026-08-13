//! Compatibility sweep: boots every ROM in a directory headless, runs each for
//! a fixed number of frames, and reports what the machine did with it.
//!
//!     zig build compat -Doptimize=ReleaseFast
//!     zig build compat -Doptimize=ReleaseFast -- mydir --frames 1800
//!
//! DESIGN.md §9 M8 asks for a 25-30 game list, and §10 forbids committing or
//! fetching a ROM that cannot be redistributed — so the list is whatever is in
//! the directory when the sweep runs, discovered at runtime. Nothing here names
//! a game, and nothing is pinned: this is a triage tool, not a regression gate.
//! The gates are `zig build test` and `zig build vdpfifo`.
//!
//! What it looks at, per ROM: whether the 68000 halted, whether the picture is
//! blank, whether the picture stopped moving, and whether either sound chip was
//! ever heard. Those four catch every way a game fails to boot; a game that
//! boots wrong in some subtler way needs eyes on it, and this says where to
//! point them.

const std = @import("std");
const audio = @import("audio");
const cart = @import("cart");
const genesis = @import("genesis");
const scheduler = @import("scheduler");

const Genesis = genesis.Genesis;
const Cpu = genesis.Cpu;
const Core = genesis.Core;

const rom_dir = "roms";
const max_rom_bytes = 8 << 20;
/// Twenty seconds: past every licence screen and logo, into the title screen
/// or the attract mode behind it.
const default_frames = 1200;
/// A ROM whose picture has not changed in this long has stopped, whether it
/// hung or is just showing a still title screen — the two look the same from
/// out here, so this reports rather than judges.
const still_frames = 240;
/// Start and C are tapped this often, held this long: enough to walk a title
/// screen and a character-select into the game, short enough that a game
/// already running is barely poked. Start alone leaves several games sitting
/// on a menu that wants a face button.
const press_every = 300;
const press_hold = 12;

const extensions = [_][]const u8{ ".bin", ".gen", ".md", ".smd" };

fn isRom(name: []const u8) bool {
    for (extensions) |ext| {
        if (std.ascii.endsWithIgnoreCase(name, ext)) return true;
    }
    return false;
}

fn buttonsAt(frame: u32) u16 {
    if (frame <= press_every or frame % press_every >= press_hold) return 0;
    return if (frame / press_every % 2 == 0) genesis.btn_start else genesis.btn_c;
}

fn frameHash(g: *const Genesis) u64 {
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&g.v.fb));
}

/// True when every pixel of the mode's own rectangle is the same colour, which
/// is what a game that never got as far as drawing anything leaves behind.
fn blank(g: *const Genesis) bool {
    const w = g.v.frameWidth();
    for (0..g.v.frameHeight()) |y| {
        const row = g.v.fb[y * @import("vdp").max_width ..][0..w];
        for (row) |px| {
            if (px != g.v.fb[0]) return false;
        }
    }
    return true;
}

const Report = struct {
    frames: u32,
    halted: bool,
    blank: bool,
    still: u32,
    peak: i32,
    pal: bool,

    /// The one-word verdict, worst first: a halted CPU explains a blank
    /// picture, and a blank picture explains a still one.
    fn verdict(r: Report) []const u8 {
        if (r.halted) return "HALTED";
        if (r.blank) return "BLANK";
        if (r.still >= still_frames) return "STILL";
        if (r.peak == 0) return "SILENT";
        return "ok";
    }
};

fn run(g: *Genesis, c: *Cpu, frames: u32) Report {
    var r = Report{
        .frames = 0,
        .halted = false,
        .blank = false,
        .still = 0,
        .peak = 0,
        .pal = g.v.pal,
    };
    var last = frameHash(g);
    while (r.frames < frames and !c.halted) : (r.frames += 1) {
        g.pads[0].buttons = buttonsAt(r.frames);
        scheduler.runFrame(g, c);
        // The ring is fixed-size and nothing else drains it here.
        while (g.audio.pop()) |s| r.peak = @max(r.peak, @as(i32, @intCast(@abs(@as(i32, s.l)))));

        const now = frameHash(g);
        r.still = if (now == last) r.still + 1 else 0;
        last = now;
    }
    r.halted = c.halted;
    r.blank = blank(g);
    return r;
}

fn sweep(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8, frames: u32) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("skipping: cannot open {s} ({t})\n", .{ dir_path, err });
        return;
    };
    defer dir.close(io);

    // Sorted, so two sweeps of the same directory print in the same order and
    // can be diffed against each other.
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !isRom(entry.name)) continue;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    const g = try gpa.create(Genesis);
    defer gpa.destroy(g);

    var ok: u32 = 0;
    std.debug.print("{d} ROMs, {d} frames each\n\n", .{ names.items.len, frames });
    for (names.items) |name| {
        const image = try dir.readFileAlloc(io, name, gpa, .limited(max_rom_bytes));
        defer gpa.free(image);
        // A copier dump is a plain image by the time the machine sees it, the
        // same as every path in `main.zig` (`readRom`).
        const rom = if (cart.interleaved(image)) image[0..cart.deinterleave(image)] else image;

        var c = Cpu{};
        g.* = .init(rom, &c);
        g.v.pal = genesis.romIsPal(rom);
        Core.reset(&c, g);

        const r = run(g, &c, frames);
        if (std.mem.eql(u8, r.verdict(), "ok")) ok += 1;
        std.debug.print("{s:<8} {s:<52} {d:>5} KiB {s} still={d:<4} peak={d}\n", .{
            r.verdict(), name, rom.len >> 10, if (r.pal) "PAL " else "NTSC", r.still, r.peak,
        });
    }
    std.debug.print("\n{d} of {d} ok\n", .{ ok, names.items.len });
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();

    var dir_path: []const u8 = rom_dir;
    var frames: u32 = default_frames;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--frames")) {
            frames = try std.fmt.parseInt(u32, args.next() orelse return error.MissingFrameCount, 10);
        } else dir_path = arg;
    }

    try sweep(init.io, init.gpa, dir_path, frames);
}
