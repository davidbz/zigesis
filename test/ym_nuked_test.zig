//! Differential test of `src/ym2612.zig` against Nuked-OPN2, the die-shot
//! reference implementation, which DESIGN.md §9 names as M3's oracle.
//!
//! Both chips are driven with byte-identical bus traffic on the same sample
//! grid, and their outputs are compared in the chip's own DAC units — no
//! resampling, no pre-baked reference blobs, nothing to go stale. Nuked
//! accumulates one output sample over 24 internal cycles, which is exactly
//! the sum this model computes in one go, so the two are directly
//! comparable: see `nukedSample`.
//!
//! Nuked-OPN2 is LGPL-2.1 and stays a test-only dependency, fetched into the
//! gitignored `testdata/` by `tools/fetch_ym_reference.sh`. Nothing here is
//! linked into the emulator, and `zig build ym-nuked` only exists when the
//! source is present.
//!
//! Two structural differences are expected, and are why the checks below are
//! thresholds rather than equalities:
//!
//!   * This model evaluates all 24 operators at once per sample, where the
//!     chip walks them one per internal cycle. Register writes therefore take
//!     effect up to a sample earlier here, and the output lags Nuked's by a
//!     fixed number of samples, which `align` measures rather than assumes.
//!   * The envelope's decay-to-sustain test is `>=` here and `==` on the die,
//!     which can move a decay's knee by one envelope step.

const std = @import("std");
const ym2612 = @import("ym2612");

const c = @cImport({
    @cInclude("ym3438.h");
});

const Ym2612 = ym2612.Ym2612;
const testing = std.testing;

/// One byte on the chip's bus at a given sample index. At most one per
/// sample: Nuked latches a write on its next clock, so two in a row without
/// clocking in between would lose the first.
const Event = struct { at: u32, port: u2, val: u8 };

/// Builds a register script, spacing every byte a sample apart.
const Script = struct {
    buf: [1024]Event = undefined,
    n: usize = 0,
    at: u32 = 0,

    fn byte(s: *Script, port: u2, val: u8) void {
        s.buf[s.n] = .{ .at = s.at, .port = port, .val = val };
        s.n += 1;
        s.at += 1;
    }

    /// Address bit 8 selects the second bank, as on the bus.
    fn reg(s: *Script, addr: u16, val: u8) void {
        const port: u2 = if (addr & 0x100 != 0) 2 else 0;
        s.byte(port, @truncate(addr));
        s.byte(port | 1, val);
    }

    fn wait(s: *Script, samples: u32) void {
        s.at += samples;
    }

    fn events(s: *const Script) []const Event {
        return s.buf[0..s.n];
    }
};

/// A four-operator patch, in the order the registers number the operators:
/// S1, S3, S2, S4.
const Patch = struct {
    dt_mul: [4]u8,
    tl: [4]u8,
    ks_ar: [4]u8,
    am_dr: [4]u8,
    sr: [4]u8,
    sl_rr: [4]u8,
    ssg: [4]u8 = .{ 0, 0, 0, 0 },
    fb_alg: u8,
    /// Both speakers, no AM/PM sensitivity, unless a test says otherwise.
    pan_ams_pms: u8 = 0xc0,
};

/// Channel 0's registers; `ch` picks the bank and offset for the others.
fn program(s: *Script, ch: u16, p: Patch) void {
    const base: u16 = (if (ch < 3) @as(u16, 0) else 0x100) + (ch % 3);
    for (0..4) |op| {
        const o: u16 = @intCast(op * 4);
        s.reg(0x30 + o + base, p.dt_mul[op]);
        s.reg(0x40 + o + base, p.tl[op]);
        s.reg(0x50 + o + base, p.ks_ar[op]);
        s.reg(0x60 + o + base, p.am_dr[op]);
        s.reg(0x70 + o + base, p.sr[op]);
        s.reg(0x80 + o + base, p.sl_rr[op]);
        s.reg(0x90 + o + base, p.ssg[op]);
    }
    s.reg(0xb0 + base, p.fb_alg);
    s.reg(0xb4 + base, p.pan_ams_pms);
}

fn note(s: *Script, ch: u16, block: u8, fnum: u16) void {
    const base: u16 = (if (ch < 3) @as(u16, 0) else 0x100) + (ch % 3);
    s.reg(0xa4 + base, (block << 3) | @as(u8, @intCast(fnum >> 8)));
    s.reg(0xa0 + base, @truncate(fnum));
}

fn keyOn(s: *Script, ch: u16, ops: u8) void {
    s.reg(0x28, ops | @as(u8, @intCast(ch % 3)) | (if (ch < 3) @as(u8, 0) else 4));
}

// --------------------------------------------------------------- the chips

const Trace = struct {
    l: []i32,
    r: []i32,

    fn init(n: usize) !Trace {
        return .{
            .l = try testing.allocator.alloc(i32, n),
            .r = try testing.allocator.alloc(i32, n),
        };
    }

    fn deinit(t: Trace) void {
        testing.allocator.free(t.l);
        testing.allocator.free(t.r);
    }
};

/// Nuked emits one channel-slot per internal cycle; a sample is the sum of
/// the 24 it takes to walk every channel.
fn nukedSample(chip: *c.ym3438_t, l: *i32, r: *i32) void {
    l.* = 0;
    r.* = 0;
    for (0..ym2612.clocks_per_sample / 6) |_| {
        var buf: [2]c.Bit16s = undefined;
        c.OPN2_Clock(chip, &buf);
        l.* += buf[0];
        r.* += buf[1];
    }
}

/// In its YM2612 mode Nuked also applies the discrete DAC's 3x output
/// amplifier, which this model folds into `fm_gain` instead.
const ladder_amp = 3;

fn runNuked(script: []const Event, out: Trace, ladder: bool) !void {
    const chip = try testing.allocator.create(c.ym3438_t);
    defer testing.allocator.destroy(chip);

    c.OPN2_SetChipType(if (ladder) c.ym3438_mode_ym2612 else 0);
    c.OPN2_Reset(chip);

    var e: usize = 0;
    for (out.l, out.r, 0..) |*l, *r, i| {
        while (e < script.len and script[e].at == i) : (e += 1) {
            c.OPN2_Write(chip, script[e].port, script[e].val);
        }
        nukedSample(chip, l, r);
        if (ladder) {
            l.* = @divTrunc(l.*, ladder_amp);
            r.* = @divTrunc(r.*, ladder_amp);
        }
    }
}

fn runMine(script: []const Event, out: Trace, ladder: bool) !void {
    const y = try testing.allocator.create(Ym2612);
    defer testing.allocator.destroy(y);
    y.* = .{ .ladder = ladder };

    var e: usize = 0;
    for (out.l, out.r, 0..) |*l, *r, i| {
        while (e < script.len and script[e].at == i) : (e += 1) {
            y.write(script[e].port, script[e].val);
        }
        const s = y.stepRaw();
        l.* = s.l;
        r.* = s.r;
    }
}

// ------------------------------------------------------------- comparisons

/// Full scale for one channel's contribution, in the units both traces are
/// in: the reference for every error figure below.
const full_scale: f64 = 256 * 3;

const Diff = struct {
    /// Samples this model's output runs ahead of the reference's.
    lead: i32,
    /// Worst and root-mean-square sample error, as a fraction of full scale.
    max: f64,
    rms: f64,
};

const max_lead = 32;

/// Compares two traces at the alignment that fits best, since the two models
/// run the chip's pipeline differently: evaluating a whole sample at once
/// gets an operator's output out a couple of samples before a 24-cycle walk
/// does. The offset is measured, not assumed — one that wandered across the
/// bank would itself be a finding.
fn compare(mine: []const i32, ref: []const i32) Diff {
    var best = Diff{ .lead = 0, .max = std.math.inf(f64), .rms = std.math.inf(f64) };
    const n = mine.len - 2 * max_lead;
    for (0..2 * max_lead + 1) |k| {
        const lead = @as(i32, @intCast(k)) - max_lead;
        var sum: f64 = 0;
        var peak: f64 = 0;
        for (0..n) |i| {
            const j: usize = @intCast(@as(i32, @intCast(i + max_lead)) + lead);
            const d = @abs(@as(f64, @floatFromInt(mine[i + max_lead])) - @as(f64, @floatFromInt(ref[j])));
            sum += d * d;
            peak = @max(peak, d);
        }
        const rms = @sqrt(sum / @as(f64, @floatFromInt(n))) / full_scale;
        if (rms < best.rms) best = .{ .lead = lead, .max = peak / full_scale, .rms = rms };
    }
    return best;
}

/// Peak amplitude per window, in dB below full scale — the envelope shape
/// DESIGN.md §9 asks to see matching. Silence floors at -96 dB.
fn envelope(trace: []const i32, window: usize, out: []f64) void {
    for (out, 0..) |*v, w| {
        var peak: i32 = 0;
        for (trace[w * window ..][0..window]) |s| peak = @max(peak, @as(i32, @intCast(@abs(s))));
        v.* = if (peak == 0) -96 else @max(-96.0, 20 * @log10(@as(f64, @floatFromInt(peak)) / full_scale));
    }
}

/// Worst per-window difference between two envelopes, in dB.
fn envelopeError(mine: []const i32, ref: []const i32, window: usize) !f64 {
    const n = mine.len / window;
    const a = try testing.allocator.alloc(f64, n);
    defer testing.allocator.free(a);
    const b = try testing.allocator.alloc(f64, n);
    defer testing.allocator.free(b);

    envelope(mine, window, a);
    envelope(ref, window, b);

    var worst: f64 = 0;
    for (a, b) |x, y| worst = @max(worst, @abs(x - y));
    return worst;
}

/// Runs one script through both chips and reports how far apart they are.
fn diff(name: []const u8, s: *const Script, samples: usize, ladder: bool) !Diff {
    const mine = try Trace.init(samples);
    defer mine.deinit();
    const ref = try Trace.init(samples);
    defer ref.deinit();

    try runMine(s.events(), mine, ladder);
    try runNuked(s.events(), ref, ladder);

    const l = compare(mine.l, ref.l);
    const r = compare(mine.r, ref.r);
    std.debug.print(
        "  {s: <22} lead {d: >2}  max {d: >7.4}  rms {d: >7.5}  (right: max {d: >7.4})\n",
        .{ name, l.lead, l.max, l.rms, r.max },
    );
    try testing.expectEqual(l.lead, r.lead);
    return l;
}

/// A patch per algorithm would be a lot of registers; these are the two the
/// bank reuses. `stack` is a plain four-operator chain, `organ` has every
/// operator audible so an algorithm's output mix is exercised too.
const stack = Patch{
    .dt_mul = .{ 0x01, 0x02, 0x11, 0x01 },
    .tl = .{ 0x20, 0x28, 0x18, 0x00 },
    .ks_ar = .{ 0x5f, 0x1f, 0x9f, 0x5f },
    .am_dr = .{ 0x05, 0x0a, 0x07, 0x04 },
    .sr = .{ 0x02, 0x03, 0x02, 0x02 },
    .sl_rr = .{ 0x2a, 0x1a, 0x3a, 0x2a },
    .fb_alg = 0x20, // feedback 4, algorithm 0
};

const organ = Patch{
    .dt_mul = .{ 0x01, 0x02, 0x04, 0x08 },
    .tl = .{ 0x10, 0x14, 0x18, 0x00 },
    .ks_ar = .{ 0x1f, 0x1f, 0x1f, 0x1f },
    .am_dr = .{ 0x00, 0x00, 0x00, 0x00 },
    .sr = .{ 0x00, 0x00, 0x00, 0x00 },
    .sl_rr = .{ 0x0f, 0x0f, 0x0f, 0x0f },
    .fb_alg = 0x07, // no feedback, algorithm 7
};

const settle = 64; // samples of silence before the first note

test "a single operator matches Nuked sample for sample" {
    std.debug.print("\n", .{});
    // Algorithm 7 with three operators silenced is one bare sine: the phase
    // generator, the log-sine and exponential tables, and the envelope's
    // attack, all with nothing else mixed in to hide an error.
    var s = Script{};
    var p = organ;
    p.tl = .{ 127, 127, 127, 0 };
    program(&s, 0, p);
    note(&s, 0, 4, 1082); // 440 Hz
    s.wait(settle);
    keyOn(&s, 0, 0xf0);

    const d = try diff("single operator", &s, 8192, false);
    try testing.expect(d.max == 0);
}

test "every algorithm matches Nuked" {
    for (0..8) |alg| {
        var s = Script{};
        var p = stack;
        p.fb_alg = @intCast(0x20 | alg);
        program(&s, 0, p);
        note(&s, 0, 4, 1082);
        s.wait(settle);
        keyOn(&s, 0, 0xf0);

        var name: [24]u8 = undefined;
        const d = try diff(try std.fmt.bufPrint(&name, "algorithm {d}", .{alg}), &s, 16384, false);
        // Feedback squares any per-sample difference back into the operator,
        // so the algorithms that use it drift furthest.
        try testing.expect(d.rms < 0.01);
        try testing.expect(d.max < 0.05);
    }
}

test "envelope shapes match Nuked across a bank of rates" {
    // The acceptance criterion in DESIGN.md §9: attack, decay, sustain and
    // release, over rates from instant to slow, with key scaling on.
    const rates = [_]struct { ar: u8, dr: u8, sl_rr: u8, ks: u8 }{
        .{ .ar = 31, .dr = 0, .sl_rr = 0x0f, .ks = 0 }, // instant attack, no decay
        .{ .ar = 31, .dr = 12, .sl_rr = 0x4a, .ks = 0 }, // percussive
        .{ .ar = 18, .dr = 6, .sl_rr = 0x27, .ks = 1 }, // slow attack, key scaled
        .{ .ar = 10, .dr = 3, .sl_rr = 0x83, .ks = 2 }, // very slow
        .{ .ar = 25, .dr = 20, .sl_rr = 0xf1, .ks = 3 }, // full key scaling
    };

    for (rates, 0..) |r, i| {
        var s = Script{};
        var p = organ;
        p.tl = .{ 127, 127, 127, 0 };
        p.ks_ar = .{ 0, 0, 0, (r.ks << 6) | r.ar };
        p.am_dr = .{ 0, 0, 0, r.dr };
        p.sr = .{ 0, 0, 0, 5 };
        p.sl_rr = .{ 0, 0, 0, r.sl_rr };
        program(&s, 0, p);
        note(&s, 0, 6, 1082); // high, so key scaling has something to scale
        s.wait(settle);
        keyOn(&s, 0, 0xf0);
        s.wait(24_000);
        keyOn(&s, 0, 0x00); // release

        const samples = 48_000;
        const mine = try Trace.init(samples);
        defer mine.deinit();
        const ref = try Trace.init(samples);
        defer ref.deinit();
        try runMine(s.events(), mine, false);
        try runNuked(s.events(), ref, false);

        // 512 samples is ~10 ms: short enough to follow a fast attack, long
        // enough that a window always holds a whole cycle of the note.
        const err = try envelopeError(mine.l, ref.l, 512);
        std.debug.print("  envelope bank {d}         worst window {d: >5.2} dB\n", .{ i, err });
        try testing.expect(err < 1.5);
    }
}

test "the LFO's amplitude and pitch sweeps match Nuked" {
    for (0..8) |freq| {
        var s = Script{};
        var p = organ;
        p.tl = .{ 127, 127, 127, 0 };
        p.am_dr = .{ 0, 0, 0, 0x80 }; // S4 subscribes to the amplitude sweep
        p.pan_ams_pms = 0xc0 | 0x30 | 0x07; // both speakers, max AMS and PMS
        program(&s, 0, p);
        note(&s, 0, 4, 1082);
        s.reg(0x22, 0x08 | @as(u8, @intCast(freq))); // LFO on
        s.wait(settle);
        keyOn(&s, 0, 0xf0);

        var name: [24]u8 = undefined;
        const d = try diff(try std.fmt.bufPrint(&name, "LFO freq {d}", .{freq}), &s, 32_768, false);
        // Both the sweep's phase and its effect on pitch are exact, so any
        // drift at all is a bug rather than a rounding difference.
        try testing.expect(d.max == 0);
    }
}

test "detune and multiple match Nuked over their whole range" {
    for (0..8) |dt| {
        var s = Script{};
        var p = organ;
        p.tl = .{ 127, 127, 127, 0 };
        p.dt_mul = .{ 0, 0, 0, @intCast((dt << 4) | ((dt % 4) + 1)) };
        program(&s, 0, p);
        note(&s, 0, @intCast(dt % 8), 1082);
        s.wait(settle);
        keyOn(&s, 0, 0xf0);

        var name: [24]u8 = undefined;
        const d = try diff(try std.fmt.bufPrint(&name, "detune {d}", .{dt}), &s, 8192, false);
        // Pitch is exact or it is not: a wrong detune drifts out of phase and
        // the error grows without bound.
        try testing.expect(d.max == 0);
    }
}

test "channel 6's DAC and the ladder effect match Nuked" {
    for ([_]bool{ false, true }) |ladder| {
        var s = Script{};
        program(&s, 5, organ);
        s.reg(0x2b, 0x80); // DAC on
        s.wait(settle);
        // A quiet triangle around the midpoint, which is where the ladder
        // effect lives: every value near zero crossing the DAC's gap.
        var v: u8 = 0x70;
        var up = true;
        for (0..200) |_| {
            s.reg(0x2a, v);
            s.wait(8);
            if (up) v += 1 else v -= 1;
            if (v == 0x90 or v == 0x70) up = !up;
        }

        var name: [24]u8 = undefined;
        const d = try diff(
            try std.fmt.bufPrint(&name, "DAC ladder={}", .{ladder}),
            &s,
            8192,
            ladder,
        );
        try testing.expect(d.max == 0);
    }
}

test "stereo panning matches Nuked" {
    var s = Script{};
    program(&s, 0, organ);
    program(&s, 1, organ);
    note(&s, 0, 4, 1082);
    note(&s, 1, 4, 1200);
    s.reg(0xb4, 0x80); // channel 0 left
    s.reg(0xb5, 0x40); // channel 1 right
    s.wait(settle);
    keyOn(&s, 0, 0xf0);
    keyOn(&s, 1, 0xf0);

    const d = try diff("panning", &s, 8192, false);
    try testing.expect(d.max == 0);
}

test "SSG-EG segments match Nuked" {
    // All eight modes; the four that invert or repeat are the ones that
    // sound wrong when this is modelled naively.
    for (0..8) |mode| {
        var s = Script{};
        var p = organ;
        p.tl = .{ 127, 127, 127, 0 };
        p.ks_ar = .{ 0, 0, 0, 31 };
        p.am_dr = .{ 0, 0, 0, 12 };
        p.sr = .{ 0, 0, 0, 12 };
        p.sl_rr = .{ 0, 0, 0, 0x0f };
        p.ssg = .{ 0, 0, 0, @intCast(0x08 | mode) };
        program(&s, 0, p);
        note(&s, 0, 4, 1082);
        s.wait(settle);
        keyOn(&s, 0, 0xf0);

        const samples = 32_768;
        const mine = try Trace.init(samples);
        defer mine.deinit();
        const ref = try Trace.init(samples);
        defer ref.deinit();
        try runMine(s.events(), mine, false);
        try runNuked(s.events(), ref, false);

        const err = try envelopeError(mine.l, ref.l, 512);
        std.debug.print("  SSG-EG mode {d}           worst window {d: >5.2} dB\n", .{ mode, err });
        // Every mode tracks the reference exactly except for the width of the
        // click a turnaround makes, which lands on a different point of the
        // operator's sine here than it does on the chip.
        try testing.expect(err < 1);
    }
}

test "timer periods and the status register match Nuked" {
    const chip = try testing.allocator.create(c.ym3438_t);
    defer testing.allocator.destroy(chip);
    c.OPN2_SetChipType(0);
    c.OPN2_Reset(chip);

    var y = Ym2612{};

    // Timer A at 1000 (24 samples) and timer B at 250 (6 * 16 samples), both
    // enabled, then read back over a few periods of each.
    const setup = [_][2]u8{
        .{ 0x24, 250 }, .{ 0x25, 0 }, .{ 0x26, 250 }, .{ 0x27, 0x0f },
    };
    for (setup) |w| {
        c.OPN2_Write(chip, 0, w[0]);
        var l: i32 = undefined;
        var r: i32 = undefined;
        nukedSample(chip, &l, &r);
        c.OPN2_Write(chip, 1, w[1]);
        nukedSample(chip, &l, &r);
        y.write(0, w[0]);
        _ = y.step();
        y.write(1, w[1]);
        _ = y.step();
    }

    // Both flags, sampled every 16 samples so the comparison does not depend
    // on which of the 24 cycles a flag is raised on.
    var mine_a: u32 = 0;
    var ref_a: u32 = 0;
    var mine_b: u32 = 0;
    var ref_b: u32 = 0;
    for (0..4096) |i| {
        var l: i32 = undefined;
        var r: i32 = undefined;
        nukedSample(chip, &l, &r);
        _ = y.step();
        if (i % 16 != 0) continue;

        const ref = c.OPN2_Read(chip, 0);
        const got = y.status();
        ref_a += ref & 1;
        ref_b += (ref >> 1) & 1;
        mine_a += got & 1;
        mine_b += (got >> 1) & 1;
        // Flags latch until reset, so clear them and count the next window.
        c.OPN2_Write(chip, 0, 0x27);
        nukedSample(chip, &l, &r);
        c.OPN2_Write(chip, 1, 0x3f);
        nukedSample(chip, &l, &r);
        y.write(0, 0x27);
        _ = y.step();
        y.write(1, 0x3f);
        _ = y.step();
    }
    std.debug.print("  timers                 A {d}/{d}  B {d}/{d} overflows\n", .{ mine_a, ref_a, mine_b, ref_b });

    // Timer A fires roughly once per sampling window and B a fifth as often;
    // an off-by-one in either period would show up as a different count.
    try testing.expect(@abs(@as(i64, mine_a) - ref_a) <= 2);
    try testing.expect(@abs(@as(i64, mine_b) - ref_b) <= 2);
}
