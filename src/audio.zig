//! Mixing, resampling, and the ring buffer that feeds the frontend's sound
//! device. The sound chips push native-rate samples in during scanline
//! stepping (`scheduler.zig`); only `main.zig` drains the ring into raylib.
//! Plain data and integer math: no allocation, no raylib, no floats — so a
//! headless run resamples to the same bytes on every machine.

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

pub const Mixer = struct {
    ring: [capacity]Frame = undefined,
    head: usize = 0,
    len: usize = 0,

    /// Fractional position toward the next output sample, carried across
    /// calls exactly like `genesis.zig`'s `mclk_debt`.
    phase: u64 = 0,
    /// Running sum of the native samples an output sample covers. Averaging
    /// them costs one add and doubles as the low-pass that a 4.66:1 rate
    /// drop needs; DESIGN.md §6.2 asks only for linear interpolation.
    sum: i64 = 0,
    count: u32 = 0,

    volume_pct: u8 = 100,

    /// Feeds one native-rate sample in, emitting an output frame whenever
    /// enough of them have accumulated to cover one.
    pub fn pushNative(m: *Mixer, sample: i16, rate: Rate) void {
        m.sum += sample;
        m.count += 1;
        m.phase += rate.out;
        if (m.phase < rate.in) return;

        m.phase -= rate.in;
        m.push(@intCast(@divTrunc(m.sum, m.count)));
        m.sum = 0;
        m.count = 0;
    }

    fn push(m: *Mixer, mono: i16) void {
        if (m.len == capacity) return; // consumer fell behind: drop, don't corrupt the ring
        const scaled: i16 = @intCast(@divTrunc(@as(i32, mono) * m.volume_pct, 100));
        m.ring[(m.head + m.len) % capacity] = .{ .l = scaled, .r = scaled };
        m.len += 1;
    }

    /// Pops the oldest buffered frame, or null when the ring is empty.
    pub fn pop(m: *Mixer) ?Frame {
        if (m.len == 0) return null;
        const f = m.ring[m.head];
        m.head = (m.head + 1) % capacity;
        m.len -= 1;
        return f;
    }
};

// ------------------------------------------------------------------- tests

const testing = std.testing;

// A stand-in for the PSG's mclk/(15*16): a rate that is not a whole number
// of output samples, so the phase remainder actually has work to do.
const test_rate = Rate{ .out = 48_000 * 240, .in = 53_693_175 };

test "downsampling a constant signal yields that constant, at the right rate" {
    var m = Mixer{};
    const native_ticks: u64 = 40_000; // fewer output frames than `capacity`, so nothing is dropped
    for (0..native_ticks) |_| m.pushNative(1000, test_rate);

    var frames: u64 = 0;
    while (m.pop()) |f| : (frames += 1) try testing.expectEqual(@as(i16, 1000), f.l);

    try testing.expectEqual(native_ticks * test_rate.out / test_rate.in, frames);
}

test "the phase remainder carries, so long runs do not drift" {
    var m = Mixer{};
    const batches: u64 = 50;
    const per_batch: u64 = 10_000;
    var produced: u64 = 0;
    for (0..batches) |_| {
        for (0..per_batch) |_| m.pushNative(0, test_rate);
        while (m.pop()) |_| produced += 1;
    }

    // Dropping the phase remainder rather than carrying it would lose most
    // of a sample per batch; carrying it keeps the count exact over any
    // number of them.
    try testing.expectEqual(batches * per_batch * test_rate.out / test_rate.in, produced);
}

test "volume_pct scales the output linearly" {
    var half = Mixer{ .volume_pct = 50 };
    var full = Mixer{};
    for (0..100) |_| {
        half.pushNative(1000, test_rate);
        full.pushNative(1000, test_rate);
    }
    try testing.expectEqual(@divTrunc(full.pop().?.l, 2), half.pop().?.l);
}

test "the ring drops samples instead of overflowing once full" {
    var m = Mixer{};
    for (0..capacity + 100) |_| m.push(1);
    try testing.expectEqual(@as(usize, capacity), m.len);
}

test "pop drains in FIFO order and wraps around the ring" {
    var m = Mixer{};
    // Push past the end of the array so head and tail both wrap.
    for (0..capacity - 1) |_| m.push(0);
    for (0..capacity - 1) |_| _ = m.pop();

    for (1..4) |i| m.push(@intCast(i));
    for (1..4) |i| try testing.expectEqual(@as(i16, @intCast(i)), m.pop().?.l);
    try testing.expectEqual(@as(?Frame, null), m.pop());
}
