//! SN76489 PSG: three square-wave tone channels and one noise channel, the
//! sound chip that sits on the VDP die. It knows nothing about the Z80 or
//! the bus — `genesis.zig` forwards the byte written to $C00011 (or the
//! Z80's $7F11 mirror) to `write`, and `scheduler.zig` calls `step` once per
//! output tick to produce one sample.
//!
//! Reference: SMS Power's SN76489 documentation for the register format,
//! LFSR taps, and the tone-period-0 quirk (DESIGN.md §7 and §11).

const std = @import("std");

/// Attenuation runs 2 dB per step over 16 steps, with step 15 silent.
///
/// The peak is what sets the PSG's level against the FM's, and the two chips
/// are mixed on the board, not in software: a full-volume PSG channel swings
/// about a fifth of what a full-scale FM channel does. `ym2612.zig` gives a
/// channel 256 * 3 * `fm_gain`, so a fifth of that peak-to-peak is 768 either
/// side of zero. Matching that ratio is the whole point of the number —
/// scaling the PSG to fill an i16 on its own (which is what 8191 did) leaves
/// it 20 dB over the music, and Sonic 1's squares and hats drown the FM.
const max_amplitude = 768;
const db_per_step = 2.0;
const silent_atten: u4 = 15;

/// White noise taps bits 0 and 3 of the shift register; periodic noise taps
/// bit 0 alone, which just recirculates the single set bit as a pulse.
const white_noise_taps: u16 = 0b1001;
const periodic_noise_taps: u16 = 0b0001;
const lfsr_reset: u16 = 0x8000;

/// Noise periods, in output ticks, for the three fixed rates; the fourth
/// setting clocks the noise off tone channel 2 instead.
const noise_fixed_period = [3]u10{ 0x10, 0x20, 0x40 };
const noise_rate_tone2: u2 = 3;

const latch_bit: u8 = 0x80;
const noise_ctrl_reg: u3 = 6;

fn attenuationTable() [16]i16 {
    @setEvalBranchQuota(2000);
    var t: [16]i16 = undefined;
    for (&t, 0..) |*v, i| {
        if (i == silent_atten) {
            v.* = 0;
            continue;
        }
        const db = -db_per_step * @as(f64, @floatFromInt(i));
        v.* = @intFromFloat(max_amplitude * std.math.pow(f64, 10.0, db / 20.0));
    }
    return t;
}
const volume_table = attenuationTable();

pub const Psg = struct {
    /// 10-bit tone periods for channels 0-2, counted down in output ticks.
    tone: [3]u10 = .{ 0, 0, 0 },
    counter: [3]u10 = .{ 0, 0, 0 },
    output: [3]bool = .{ false, false, false },

    /// Attenuation (0 loudest, 15 silent) for tone 0-2 then noise. The chip
    /// powers on silent, which is why a game that never touches it is quiet
    /// rather than screaming.
    atten: [4]u4 = @splat(silent_atten),

    noise_white: bool = false,
    noise_rate: u2 = 0,
    noise_counter: u10 = 0,
    /// The noise generator has a square of its own, toggled by its counter
    /// exactly like a tone channel's, and the shift register advances on that
    /// square's rising edge alone — so the noise runs at half the rate its
    /// period suggests.
    noise_phase: bool = false,
    lfsr: u16 = lfsr_reset,

    /// Register selected by the last latch byte, as channel * 2 + type.
    latched: u3 = 0,

    /// A byte written to the PSG's data port. Bit 7 set is a latch byte: it
    /// selects a register and writes its low 4 bits. Bit 7 clear is a data
    /// byte continuing the latched register — the high 6 bits of a tone
    /// period, or the low 4 bits again for the one-byte-wide registers.
    pub fn write(p: *Psg, val: u8) void {
        if (val & latch_bit != 0) {
            p.latched = @truncate(val >> 4);
            p.writeReg(val & 0x0F, true);
            return;
        }
        p.writeReg(val & 0x3F, false);
    }

    fn writeReg(p: *Psg, data: u8, latch: bool) void {
        const ch = p.latched >> 1;
        switch (p.latched) {
            0, 2, 4 => p.tone[ch] = if (latch)
                (p.tone[ch] & 0x3F0) | (data & 0x0F)
            else
                (p.tone[ch] & 0x00F) | (@as(u10, @truncate(data)) << 4),
            1, 3, 5, 7 => p.atten[ch] = @truncate(data),
            noise_ctrl_reg => {
                p.noise_rate = @truncate(data);
                p.noise_white = data & 0x04 != 0;
                // Any write to the noise control register reloads the shift
                // register, not just one that changes the mode.
                p.lfsr = lfsr_reset;
                p.noise_counter = 0;
            },
        }
    }

    /// Advances the chip by one output tick (the Z80 clock divided by 16)
    /// and returns the mixed sample.
    pub fn step(p: *Psg) i16 {
        var tone2_toggled = false;
        for (&p.tone, &p.counter, &p.output, 0..) |period, *counter, *output, ch| {
            const toggled = stepTone(period, counter, output);
            if (ch == 2) tone2_toggled = toggled;
        }
        p.stepNoise(tone2_toggled);

        var sum: i32 = 0;
        for (p.output, p.atten[0..3]) |on, atten| sum += channelSample(on, atten);
        sum += channelSample(p.lfsr & 1 != 0, p.atten[3]);
        return @intCast(sum);
    }

    fn stepNoise(p: *Psg, tone2_toggled: bool) void {
        if (!p.noiseClocked(tone2_toggled)) return;
        p.noise_phase = !p.noise_phase;
        if (!p.noise_phase) return;

        const taps = if (p.noise_white) white_noise_taps else periodic_noise_taps;
        const feedback: u16 = @popCount(p.lfsr & taps) & 1;
        p.lfsr = (p.lfsr >> 1) | (feedback << 15);
    }

    fn noiseClocked(p: *Psg, tone2_toggled: bool) bool {
        if (p.noise_rate == noise_rate_tone2) return tone2_toggled;
        if (p.noise_counter > 1) {
            p.noise_counter -= 1;
            return false;
        }
        p.noise_counter = noise_fixed_period[p.noise_rate];
        return true;
    }
};

/// A period of 0 does not stop the channel. The Sega-integrated PSG loads
/// the counter with 1 instead (the discrete TI part loads 0x400), so the
/// channel runs at its highest frequency — ~112 kHz, far past anything
/// audible, which is the real reason a period-0 channel reads as DC — and
/// keeps clocking the noise channel when noise runs off tone 3. Falling out
/// of the counter with a reload value of 0 gives exactly that: a toggle
/// every tick. Sonic 1's percussion is nothing but this.
fn stepTone(period: u10, counter: *u10, output: *bool) bool {
    if (counter.* > 1) {
        counter.* -= 1;
        return false;
    }
    counter.* = period;
    output.* = !output.*;
    return true;
}

fn channelSample(on: bool, atten: u4) i32 {
    const v = volume_table[atten];
    return if (on) v else -v;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

fn soloChannel(p: *Psg, ch: usize) void {
    p.atten = @splat(silent_atten);
    p.atten[ch] = 0;
}

test "the chip powers on silent on all four channels" {
    var p = Psg{};
    for (p.atten) |a| try testing.expectEqual(silent_atten, a);
    try testing.expectEqual(@as(i16, 0), p.step());
}

test "a latch byte then a data byte sets the full 10-bit tone period" {
    var p = Psg{};
    p.write(latch_bit | 0x05); // latch tone 0, low nibble 0x5
    p.write(0x02); // data byte, high 6 bits 0x02
    try testing.expectEqual(@as(u10, (0x02 << 4) | 0x05), p.tone[0]);
}

test "a latch byte alone sets volume from its low nibble" {
    var p = Psg{};
    p.write(latch_bit | (1 << 4) | 0x03); // channel 0, type 1 (volume), 3
    try testing.expectEqual(@as(u4, 3), p.atten[0]);

    // Volume is one byte wide: a following data byte rewrites the same four
    // bits rather than becoming a high half.
    p.write(0x0A);
    try testing.expectEqual(@as(u4, 0x0A), p.atten[0]);
}

test "tone period 0 is the highest frequency, not a stopped channel" {
    var p = Psg{};
    soloChannel(&p, 0);
    p.tone[0] = 0;

    // Same as period 1: a toggle every tick.
    var last = p.step();
    for (0..8) |_| {
        const cur = p.step();
        try testing.expectEqual(-last, cur);
        last = cur;
    }
}

test "noise clocked off tone 3 still shifts when tone 3's period is 0" {
    // Sonic 1's percussion: channel 3 silent at period 0 purely as the noise
    // clock, white noise on channel 4, and a volume envelope on top. Freezing
    // that counter leaves the shift register stuck and turns every drum hit
    // into a DC click instead of a hi-hat.
    var p = Psg{};
    soloChannel(&p, 3);
    p.write(latch_bit | (@as(u8, noise_ctrl_reg) << 4) | 0x04 | noise_rate_tone2);
    p.tone[2] = 0;

    var high: u32 = 0;
    for (0..2000) |_| {
        if (p.step() > 0) high += 1;
    }
    try testing.expect(high > 0 and high < 2000);
}

test "a tone channel toggles every `period` ticks, producing a square wave" {
    var p = Psg{};
    soloChannel(&p, 0);
    p.tone[0] = 4;

    var toggles: u32 = 0;
    var last = p.step() > 0;
    for (0..40) |_| {
        const cur = p.step() > 0;
        if (cur != last) toggles += 1;
        last = cur;
    }
    try testing.expectEqual(@as(u32, 40 / 4), toggles);
}

test "white noise reaches both output levels; periodic noise stays a pulse" {
    var white = Psg{};
    soloChannel(&white, 3);
    white.write(latch_bit | (@as(u8, noise_ctrl_reg) << 4) | 0x04); // white, rate 0

    var high: u32 = 0;
    for (0..2000) |_| {
        if (white.step() > 0) high += 1;
    }
    try testing.expect(high > 0 and high < 2000);

    // Periodic noise recirculates the single reset bit around all 16 stages,
    // so it is high for exactly one shift out of every 16 — and a shift is two
    // periods long, not one, because the register only advances on the rising
    // edge of the noise generator's own square. Counting the ticks it stays
    // high pins that halving: at one shift per period this reads 16.
    var periodic = Psg{};
    soloChannel(&periodic, 3);
    periodic.write(latch_bit | (@as(u8, noise_ctrl_reg) << 4) | 0x00); // periodic, rate 0

    const ticks_per_shift = 2 * @as(u32, noise_fixed_period[0]);
    var pulses: u32 = 0;
    for (0..16 * ticks_per_shift) |_| {
        if (periodic.step() > 0) pulses += 1;
    }
    try testing.expectEqual(ticks_per_shift, pulses);
}

test "louder attenuation steps produce larger samples, and 15 is silence" {
    var p = Psg{};
    soloChannel(&p, 0);
    // A long period so the channel holds its level across all sixteen steps
    // and the sample is the raw channel level.
    p.tone[0] = 1000;
    p.counter[0] = 1000;
    p.output[0] = true;

    var prev: i16 = std.math.maxInt(i16);
    for (0..16) |atten| {
        p.atten[0] = @truncate(atten);
        const s = p.step();
        try testing.expect(s < prev);
        prev = s;
    }
    try testing.expectEqual(@as(i16, 0), prev);
}
