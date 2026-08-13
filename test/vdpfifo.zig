//! VDPFIFOTesting scoreboard reader: boots Nemesis' VDP conformance ROM
//! headless, walks all 22 pages by pressing Start, and prints what each page
//! reports as text.
//!
//!     zig build vdpfifo -Doptimize=ReleaseFast
//!
//! The ROM draws its text with one tile per character and a font uploaded in
//! ASCII order, so a name table entry *is* the character code — no pixels are
//! involved in reading the screen. Its "Results: (pass/fail/total)" line is
//! cumulative across pages, so the last page carries the whole score.
//!
//! Pages are walked by watching the screen rather than on a fixed schedule: a
//! page's tests take between 900 and 1800 frames and the ROM ignores a Start
//! press that arrives while they run, so the walk waits for the picture to stop
//! changing before pressing on. Test results only ever get drawn as they come
//! in, which is what makes "stopped changing" mean "finished".

const std = @import("std");
const genesis = @import("genesis");
const scheduler = @import("scheduler");
const vdp = @import("vdp");

const Genesis = genesis.Genesis;
const Cpu = genesis.Cpu;
const Core = genesis.Core;

const rom_path = "roms/VDPFIFOTesting.bin";
const max_rom_bytes = 8 << 20;

/// Failures per page, pinned: this is the scoreboard DESIGN.md §9 M4 records,
/// and the reason the walk exists. The eleven are three clusters, each a
/// modelling ceiling written down and justified there — test 16 on page 2,
/// tests 31-33 on page 5, tests 35-41 on page 6. Any other number, on any
/// page, is a regression in the VDP's ports and fails the run.
const expected_fails = [_]u32{
    0, 1, 0, 0, 3, 7, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
};
const expected_total = 122;
/// The screen unchanged for this long means the page's tests have finished.
/// Comfortably longer than the gap between two tests' results appearing, and
/// short enough that the whole walk stays under a minute.
const stable_frames = 400;
/// A page that never settles is a hang, not a slow page: give up and say so.
const max_page_frames = 5000;
/// The ROM samples the pad on its own schedule; a press has to outlast that.
const start_hold = 20;

const cols = 40;
const rows = 28;

/// One row of the plane A name table, decoded to text and right-trimmed.
/// Tiles outside printable ASCII are the graphical result bars, which have no
/// text meaning: a row made only of those comes back empty and is not printed.
fn readRow(v: *const vdp.Vdp, row: u32, out: *[cols]u8) []const u8 {
    const nt: u32 = @as(u32, v.regs[2] & 0x38) << 10;
    var len: usize = 0;
    for (0..cols) |col| {
        const a = nt + (row * plane_cells + @as(u32, @intCast(col))) * 2;
        const tile = (@as(u16, v.vram[a]) << 8 | v.vram[a + 1]) & 0x7FF;
        out[col] = if (tile >= ' ' and tile < 0x7F) @truncate(tile) else ' ';
        if (out[col] != ' ') len = col + 1;
    }
    return out[0..len];
}

/// Plane width in cells. Register 16 can also say 32 or 128, but this ROM
/// only ever sets 64, so decoding it would be a branch that never runs.
const plane_cells = 64;

/// The ROM's own running tally, off its "Results: (pass/fail/total)" line.
/// Cumulative over every page walked so far, and reset when Start wraps past
/// the last page back to the first — which is the walk's backstop for having
/// miscounted the pages.
const Score = struct {
    pass: u32 = 0,
    fail: u32 = 0,
    total: u32 = 0,
};

fn parseScore(text: []const u8) ?Score {
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    var it = std.mem.tokenizeAny(u8, text[open + 1 ..], "/) ");
    var s: Score = .{};
    inline for (.{ &s.pass, &s.fail, &s.total }) |field| {
        field.* = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    }
    return s;
}

/// Everything on screen, hashed: the walk's "has anything happened lately?"
fn screenHash(v: *const vdp.Vdp) u64 {
    const nt: u32 = @as(u32, v.regs[2] & 0x38) << 10;
    return std.hash.Wyhash.hash(0, v.vram[nt .. nt + rows * plane_cells * 2]);
}

fn frame(g: *Genesis, c: *Cpu, buttons: u16) void {
    g.pads[0].buttons = buttons;
    scheduler.runFrame(g, c);
    // The mixer's ring is fixed-size and nothing else drains it here.
    while (g.audio.pop()) |_| {}
}

/// Runs until the screen has held still for `stable_frames`, and returns the
/// frames that took. Zero means the page never settled.
fn runUntilSettled(g: *Genesis, c: *Cpu) u32 {
    var last = screenHash(&g.v);
    var stable: u32 = 0;
    var elapsed: u32 = 0;
    while (stable < stable_frames) : (elapsed += 1) {
        if (elapsed == max_page_frames) return 0;
        frame(g, c, 0);
        const now = screenHash(&g.v);
        stable = if (now == last) stable + 1 else 0;
        last = now;
    }
    return elapsed;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    const path = args.next() orelse rom_path;

    // The ROM lives on one person's HTTP site with no mirror and cannot be
    // redistributed, so its absence is an un-fetched checkout or an outage,
    // not a failure — the same clean skip the rest of the suite does
    // (DESIGN.md §10).
    const image = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_rom_bytes)) catch |err| {
        std.debug.print("skipping: cannot read {s} ({t})\n" ++
            "run tools/fetch_test_roms.sh to fetch it\n", .{ path, err });
        return;
    };
    defer gpa.free(image);

    var c = Cpu{};
    const g = try gpa.create(Genesis);
    defer gpa.destroy(g);
    g.* = .init(image, &c);
    Core.reset(&c, g);

    var frames: u32 = 0;
    var prev: Score = .{};
    var off_pin = false;
    var page: u32 = 1;
    while (page <= expected_fails.len) : (page += 1) {
        const took = runUntilSettled(g, &c);
        if (took == 0) {
            std.debug.print("page {d}: never settled after {d} frames\n", .{ page, max_page_frames });
            return error.PageHung;
        }
        frames += took;

        // The tally sits below the test names, so it takes its own pass to
        // find: the header it feeds has to be printed first.
        var buf: [cols]u8 = undefined;
        var score: ?Score = null;
        for (0..rows) |row| {
            if (parseScore(readRow(&g.v, @intCast(row), &buf))) |s| score = s;
        }
        const now = score orelse return error.NoResultsLine;
        // Wrapping past the last page resets the tally and starts over.
        if (now.total <= prev.total and page > 1) break;

        const fails = now.fail - prev.fail;
        const want = expected_fails[page - 1];
        if (fails != want) off_pin = true;
        std.debug.print("--- page {d}: {d} pass, {d} fail{s}\n", .{
            page,
            now.pass - prev.pass,
            fails,
            if (fails == want) "" else if (fails > want) "  <-- REGRESSED" else "  <-- improved, re-pin",
        });
        for (0..rows) |row| {
            const text = readRow(&g.v, @intCast(row), &buf);
            // Everything but the numbered test names: the title, the tally,
            // and the key legend are the same on every page.
            if (std.mem.indexOfScalar(u8, text, '.') == null) continue;
            std.debug.print("  {s}\n", .{text});
        }
        prev = now;

        for (0..start_hold) |_| frame(g, &c, genesis.btn_start);
        frame(g, &c, 0);
        frames += start_hold + 1;
    }

    std.debug.print("\n{d} of {d} tests pass, {d} fail ({d} pages, {d} frames)\n", .{
        prev.pass, prev.total, prev.fail, page - 1, frames,
    });

    // A short walk is a walk that lost its way, not a smaller ROM: the page
    // count and test count are the ROM's, and neither can move on their own.
    if (prev.total != expected_total) {
        std.debug.print("expected {d} tests, saw {d}\n", .{ expected_total, prev.total });
        return error.ScoreOffPin;
    }
    if (off_pin) return error.ScoreOffPin;
}
