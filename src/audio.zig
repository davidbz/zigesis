//! Mixing, resampling, and the ring buffer that feeds the frontend's sound
//! device. Chips write native-rate samples in during scanline stepping
//! (`scheduler.zig`); only `main.zig` drains the ring buffer into raylib.
//! No allocation, no raylib import — this module is plain data and math.

const std = @import("std");

pub const sample_rate: u32 = 48_000;

/// ~200ms of headroom: enough for `main.zig`'s pacing to sleep when ahead
/// without ever needing to grow this at runtime.
pub const capacity = sample_rate / 5;

/// `extern` so a pointer to an array of these is valid raw interleaved
/// s16 PCM for raylib's `UpdateAudioStream`, and so its byte layout is
/// stable for the pinned-hash regression test.
pub const Frame = extern struct { l: i16, r: i16 };

pub const Mixer = struct {
    ring: [capacity]Frame = undefined,
    head: usize = 0,
    len: usize = 0,

    /// Fractional position, in native-rate samples, toward the next
    /// output sample; carried across calls like `genesis.zig`'s `mclk_debt`
    /// so the resampled rate does not drift.
    phase: f64 = 0,
    prev_native: i16 = 0,

    volume_pct: u8 = 100,

    /// Feeds one native-rate PSG sample into the linear-interpolation
    /// downsampler, producing zero or more output frames at `sample_rate`.
    pub fn pushPsg(m: *Mixer, sample: i16, native_hz: f64) void {
        const step = native_hz / @as(f64, @floatFromInt(sample_rate));
        m.phase += 1.0;
        while (m.phase >= step) {
            m.phase -= step;
            const frac = 1.0 - m.phase / step;
            const prev_f: f64 = @floatFromInt(m.prev_native);
            const cur_f: f64 = @floatFromInt(sample);
            const interp = prev_f + (cur_f - prev_f) * frac;
            m.push(@intFromFloat(interp));
        }
        m.prev_native = sample;
    }

    fn push(m: *Mixer, mono: i16) void {
        if (m.len == capacity) return; // consumer fell behind: drop, don't corrupt the ring
        const scaled: i16 = @intCast(@divTrunc(@as(i32, mono) * m.volume_pct, 100));
        const tail = (m.head + m.len) % capacity;
        m.ring[tail] = .{ .l = scaled, .r = scaled };
        m.len += 1;
    }

    /// Pops the oldest buffered frame, or null if the ring is empty.
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

test "downsampling a constant native signal yields a constant output frame" {
    var m = Mixer{};
    for (0..1000) |_| m.pushPsg(1000, 200_000.0);

    var got: ?Frame = null;
    while (m.pop()) |f| {
        if (got) |g| try testing.expectEqual(g, f);
        got = f;
    }
    try testing.expect(got != null);
    try testing.expectEqual(@as(i16, 1000), got.?.l);
}

test "volume_pct scales the output linearly" {
    var half = Mixer{ .volume_pct = 50 };
    var full = Mixer{};
    for (0..10) |_| {
        half.pushPsg(1000, 100_000.0);
        full.pushPsg(1000, 100_000.0);
    }

    const h = half.pop().?;
    const f = full.pop().?;
    try testing.expectEqual(@divTrunc(f.l, 2), h.l);
}

test "the ring buffer drops samples instead of overflowing once full" {
    var m = Mixer{};
    for (0..capacity + 100) |_| m.push(1);
    try testing.expectEqual(@as(usize, capacity), m.len);
}

test "pop drains in FIFO order" {
    var m = Mixer{};
    m.push(1);
    m.push(2);
    m.push(3);
    try testing.expectEqual(@as(i16, 1), m.pop().?.l);
    try testing.expectEqual(@as(i16, 2), m.pop().?.l);
    try testing.expectEqual(@as(i16, 3), m.pop().?.l);
    try testing.expectEqual(@as(?Frame, null), m.pop());
}
