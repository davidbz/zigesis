//! Mixing, resampling, and the ring buffer that feeds the frontend's sound
//! device. The sound chips push native-rate samples in during scanline
//! stepping (`scheduler.zig`); only `main.zig` drains the ring into raylib.
//! Plain data and integer math: no allocation, no raylib, and no floats at
//! run time — the resampling filter is designed in floating point at comptime
//! and shipped as an integer table, so a headless run resamples to the same
//! bytes on every machine.

const std = @import("std");

pub const sample_rate: u32 = 48_000;

/// ~200 ms of headroom: enough for `main.zig` to pace off the fill level
/// without ever needing to grow at runtime.
pub const capacity = sample_rate / 5;

/// `extern` so an array of these is raw interleaved s16 PCM for raylib's
/// `UpdateAudioStream`, and so its layout is stable for the pinned-hash
/// regression test.
pub const Frame = extern struct { l: i16, r: i16 };

/// Output samples per native-rate input sample, as an exact integer
/// fraction. Chip rates are not whole numbers of hertz, so keeping the
/// ratio as a fraction is what stops the resampled rate from drifting.
/// Downsampling only: `out` must not exceed `in`.
pub const Rate = struct { out: u64, in: u64 };

/// The antialias filter for the rate drop, as a polyphase windowed-sinc bank.
///
/// Averaging the native samples an output sample covers — what this used to do
/// — is a boxcar, and a boxcar's first null lands on the output rate rather
/// than on Nyquist. Everything a square wave puts above 24 kHz therefore folds
/// straight back into the audible band at frequencies unrelated to the note.
/// Measured on square waves from the PSG itself, the worst alias tone below
/// 16 kHz sat 33 dB under the fundamental for a 3.5 kHz note — loud enough,
/// and inharmonic enough, to be heard as the note being subtly wrong rather
/// than merely dull. With this filter it sits 76 dB under. Low notes were
/// always less affected (440 Hz went from -46 dB to -80 dB), which is why it
/// was the high beeps that sounded off.
///
/// ponytail: both sizes were measured, not guessed. Past 65 taps nothing
/// improves (97 and 129 scored identically), and past 32 phases nothing
/// improves either; what is left is a single tone up at 23.5 kHz, which no
/// amount of filter fixes and nothing can hear. Revisit only if a chip lands
/// here with a harsher ratio than the PSG's 4.66:1.
const fir_taps = 65;
const fir_phases = 32;
const fir_shift = 15;

/// As a fraction of the output rate: 20 kHz at 48 kHz out, which leaves the
/// stopband down before anything can fold past Nyquist.
const fir_cutoff = 0.417;

fn firBank(comptime rate: Rate) [fir_phases][fir_taps]i32 {
    @setEvalBranchQuota(200_000);
    const half = fir_taps / 2;
    // Cutoff in cycles per *input* sample, which is what the sinc is in terms of.
    const fc = fir_cutoff * @as(f64, @floatFromInt(rate.out)) / @as(f64, @floatFromInt(rate.in));

    var bank: [fir_phases][fir_taps]i32 = undefined;
    for (&bank, 0..) |*row, p| {
        const frac = @as(f64, @floatFromInt(p)) / fir_phases;
        var w: [fir_taps]f64 = undefined;
        var gain: f64 = 0;
        for (&w, 0..) |*v, j| {
            // `frac` counts forward from the output instant to the newest
            // sample, so it *adds* to each tap's offset from the centre.
            const d = @as(f64, @floatFromInt(j)) - half + frac;
            const s = if (@abs(d) < 1e-9)
                2 * fc
            else
                @sin(2 * std.math.pi * fc * d) / (std.math.pi * d);
            // Hamming window, so the stopband is flat instead of sinc-shaped.
            v.* = s * (0.54 + 0.46 * @cos(std.math.pi * d / (half + 1)));
            gain += v.*;
        }
        // Normalised per phase, so every phase has the same DC gain and a
        // constant signal does not ripple as the fraction walks.
        var total: i32 = 0;
        for (row, w) |*c, v| {
            c.* = @intFromFloat(@round(v / gain * (1 << fir_shift)));
            total += c.*;
        }
        // Rounding leaves the gain a hair off unity; park the error on the
        // centre tap so a constant really does resample to itself.
        row[half] += (1 << fir_shift) - total;
    }
    return bank;
}

/// The two sound chips, each resampled by its own filter state and summed in
/// the ring. They run at unrelated native rates — mclk/240 and mclk/1008 —
/// so there is no common grid to add them on before the rate drop.
pub const Chip = enum(u1) { psg, ym };

/// One chip's path from its native rate to the output rate.
const Source = struct {
    /// Fractional position toward the next output sample, carried across
    /// calls exactly like `genesis.zig`'s `mclk_debt`.
    phase: u64 = 0,
    /// The last `fir_taps` native samples, oldest first at `hist_at`.
    hist: [fir_taps]Frame = @splat(.{ .l = 0, .r = 0 }),
    hist_at: usize = 0,
    /// Output frames this source has finished contributing to.
    produced: u64 = 0,
};

pub const Mixer = struct {
    /// Frames under construction, indexed by absolute frame number. Wider
    /// than the output so two full-scale chips can sum without wrapping;
    /// clamped on the way out.
    ring: [capacity]Frame32 = @splat(.{}),
    /// Frames handed to the consumer, and the furthest any source has run.
    emitted: u64 = 0,
    produced: u64 = 0,

    sources: [2]Source = @splat(.{}),

    volume_pct: u8 = 100,

    const Frame32 = struct { l: i32 = 0, r: i32 = 0 };

    /// Feeds one native-rate sample in, finishing an output frame whenever
    /// enough of them have accumulated to cover one.
    pub fn pushNative(m: *Mixer, chip: Chip, l: i16, r: i16, comptime rate: Rate) void {
        const s = &m.sources[@intFromEnum(chip)];
        s.hist[s.hist_at] = .{ .l = l, .r = r };
        s.hist_at = (s.hist_at + 1) % fir_taps;

        s.phase += rate.out;
        if (s.phase < rate.in) return;
        s.phase -= rate.in;
        // Consumer fell behind: drop this frame rather than sum into one it
        // has not read yet. Both sources stall on the same test, so they stay
        // on the same frame when it catches up.
        // Addition, not subtraction: a source that somehow fell behind the
        // emitted frame would underflow into a permanent silent stall.
        if (s.produced >= m.emitted + capacity) return;

        // What is left in `phase` is how far past the output instant this
        // sample sits, in units of `rate.out` per input sample. That fraction
        // is exactly what selects the filter phase.
        const bank = comptime firBank(rate);
        const p = s.phase * fir_phases / rate.out;

        var left: i64 = 0;
        var right: i64 = 0;
        for (bank[p], 0..) |c, j| {
            const h = s.hist[(s.hist_at + j) % fir_taps];
            left += @as(i64, c) * h.l;
            right += @as(i64, c) * h.r;
        }

        const slot = &m.ring[s.produced % capacity];
        slot.l += @intCast(left >> fir_shift);
        slot.r += @intCast(right >> fir_shift);
        s.produced += 1;
        m.produced = @max(m.produced, s.produced);
    }

    /// Frames every source has finished. A source runs at most one frame
    /// ahead of the other — an output frame is 1118 mclk and the slower
    /// chip's native tick is 1008 — so the frame before the leader is always
    /// complete.
    pub fn ready(m: *const Mixer) usize {
        return @intCast(m.produced -| m.emitted -| 1);
    }

    /// Pops the oldest complete frame, or null when there is none.
    pub fn pop(m: *Mixer) ?Frame {
        if (m.ready() == 0) return null;
        const slot = &m.ring[m.emitted % capacity];
        defer {
            slot.* = .{};
            m.emitted += 1;
        }
        // Two chips summed, and a windowed sinc that overshoots on a square
        // edge, both ring past i16. Clamp rather than wrap: wrapping turns a
        // loud note into a burst of noise.
        return .{ .l = m.scale(slot.l), .r = m.scale(slot.r) };
    }

    fn scale(m: *const Mixer, v: i32) i16 {
        const adjusted = @divTrunc(@as(i64, v) * m.volume_pct, 100);
        return @intCast(std.math.clamp(adjusted, std.math.minInt(i16), std.math.maxInt(i16)));
    }
};

// ------------------------------------------------------------------- tests

const testing = std.testing;

// A stand-in for the PSG's mclk/(15*16): a rate that is not a whole number
// of output samples, so the phase remainder actually has work to do.
const test_rate = Rate{ .out = 48_000 * 240, .in = 53_693_175 };

/// The filter reaches back `fir_taps` native samples, so the first handful of
/// output frames are still mixing in the zero-filled history. That is real
/// behaviour — the machine does start from silence — so the tests step over
/// the ramp rather than pretending it is not there.
const settled = fir_taps;

test "downsampling a constant signal yields that constant, at the right rate" {
    var m = Mixer{};
    const native_ticks: u64 = 40_000; // fewer output frames than `capacity`, so nothing is dropped
    for (0..native_ticks) |_| m.pushNative(.psg, 1000, 1000, test_rate);

    var frames: u64 = 0;
    while (m.pop()) |f| : (frames += 1) {
        // Unity DC gain on every phase, or a constant would ripple as the
        // fractional position walks across the bank.
        if (frames >= settled) try testing.expectEqual(@as(i16, 1000), f.l);
    }

    // One frame short of what the ratio produces: the last one is not
    // complete until a source runs past it.
    try testing.expectEqual(native_ticks * test_rate.out / test_rate.in - 1, frames);
}

const native_hz = @as(f64, sample_rate) *
    @as(f64, @floatFromInt(test_rate.in)) / @as(f64, @floatFromInt(test_rate.out));

/// Pushes a sine at `hz` through the mixer at the native rate and fills `out`
/// with the settled output.
fn resampleSine(hz: f64, amplitude: f64, out: []i16) void {
    var m = Mixer{};
    var frames: usize = 0;
    var kept: usize = 0;
    var i: usize = 0;
    while (kept < out.len) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / native_hz;
        const v: i16 = @intFromFloat(amplitude * @sin(2 * std.math.pi * hz * t));
        m.pushNative(.psg, v, v, test_rate);
        while (m.pop()) |f| : (frames += 1) {
            if (frames >= settled and kept < out.len) {
                out[kept] = f.l;
                kept += 1;
            }
        }
    }
}

/// Peak amplitude of `hz` after the rate drop.
fn peakOf(hz: f64, amplitude: f64) i16 {
    var buf: [8192]i16 = undefined;
    resampleSine(hz, amplitude, &buf);

    var peak: i16 = 0;
    for (buf) |v| peak = @max(peak, @as(i16, @intCast(@abs(v))));
    return peak;
}

test "a tone inside the passband survives the rate drop at full amplitude" {
    // 1 kHz is far below the 20 kHz cutoff, so it should come through
    // essentially untouched.
    const peak = peakOf(1000, 8000);
    try testing.expect(peak > 7800 and peak <= 8100);
}

/// Magnitude of `x` at `hz`, by Goertzel: one frequency, no FFT, no table.
fn magAt(x: []const i16, hz: f64) f64 {
    const w = 2 * std.math.pi * hz / @as(f64, sample_rate);
    const c = 2 * @cos(w);
    var s1: f64 = 0;
    var s2: f64 = 0;
    for (x) |v| {
        const s0 = @as(f64, @floatFromInt(v)) + c * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    return @sqrt(@abs(s1 * s1 + s2 * s2 - c * s1 * s2));
}

test "a resampled sine is still just that sine, so the output instants are right" {
    // 3500 Hz lands exactly on bin 350 of 4800 samples at 48 kHz, so Goertzel
    // measures the tone with no leakage and everything left over is noise the
    // resampler invented. This is what catches a wrong fractional phase:
    // picking the output instants wrong jitters a clean tone into broadband
    // hiss without changing *which* frequencies pass, so the passband and
    // stopband tests above both sail straight through it.
    const n = 4800;
    var buf: [n]i16 = undefined;
    resampleSine(3500, 8000, &buf);

    var total: f64 = 0;
    for (buf) |v| total += @as(f64, @floatFromInt(v)) * @as(f64, @floatFromInt(v));
    const mag = magAt(&buf, 3500);
    const tone = 2 * mag * mag / n;

    // Measured: 8.6e-7 with the phase right, 3.2e-3 with its sign flipped.
    try testing.expect((total - tone) / total < 1e-5);
}

test "a tone above the output's Nyquist is rejected instead of folding back" {
    // 30 kHz cannot be represented at 48 kHz; a boxcar passed enough of it to
    // alias down as an audible inharmonic tone, which is what made PSG beeps
    // sound wrong. It must arrive attenuated by better than 40 dB.
    const peak = peakOf(30_000, 8000);
    try testing.expect(peak < 80);
}

test "the phase remainder carries, so long runs do not drift" {
    var m = Mixer{};
    const batches: u64 = 50;
    const per_batch: u64 = 10_000;
    var produced: u64 = 0;
    for (0..batches) |_| {
        for (0..per_batch) |_| m.pushNative(.psg, 0, 0, test_rate);
        while (m.pop()) |_| produced += 1;
    }

    // Dropping the phase remainder rather than carrying it would lose most
    // of a sample per batch; carrying it keeps the count exact over any
    // number of them.
    try testing.expectEqual(batches * per_batch * test_rate.out / test_rate.in - 1, produced);
}

test "volume_pct scales the output linearly" {
    var half = Mixer{ .volume_pct = 50 };
    var full = Mixer{};
    for (0..100) |_| {
        half.pushNative(.psg, 1000, 1000, test_rate);
        full.pushNative(.psg, 1000, 1000, test_rate);
    }
    try testing.expectEqual(@divTrunc(full.pop().?.l, 2), half.pop().?.l);
}

test "the ring drops frames instead of overflowing once full" {
    var m = Mixer{};
    // Enough native samples for well over a ring's worth of output frames,
    // with nothing draining them.
    for (0..(capacity + 1000) * test_rate.in / test_rate.out) |_| m.pushNative(.psg, 1, 1, test_rate);
    try testing.expectEqual(@as(usize, capacity - 1), m.ready());

    var drained: usize = 0;
    while (m.pop()) |_| drained += 1;
    try testing.expectEqual(@as(usize, capacity - 1), drained);
}

test "two chips at different rates sum into the same frames" {
    // Half the ratio, so this source produces the same output rate from a
    // quarter as many native samples.
    const other = Rate{ .out = test_rate.out * 4, .in = test_rate.in };
    var m = Mixer{};
    for (0..40_000) |i| {
        m.pushNative(.psg, 1000, 1000, test_rate);
        if (i % 4 == 0) m.pushNative(.ym, 300, -300, other);
    }

    var frames: usize = 0;
    while (m.pop()) |f| : (frames += 1) {
        if (frames < settled) continue;
        try testing.expectEqual(@as(i16, 1300), f.l);
        try testing.expectEqual(@as(i16, 700), f.r);
    }
    try testing.expect(frames > 0);
}

test "the mixer clamps instead of wrapping when both chips run loud" {
    var m = Mixer{};
    for (0..40_000) |_| {
        m.pushNative(.psg, 30_000, 30_000, test_rate);
        m.pushNative(.ym, 30_000, 30_000, test_rate);
    }
    var frames: usize = 0;
    while (m.pop()) |f| : (frames += 1) {
        if (frames >= settled) try testing.expectEqual(@as(i16, std.math.maxInt(i16)), f.l);
    }
}
