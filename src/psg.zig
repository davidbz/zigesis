//! SN76489 PSG: three square-wave tone channels and one noise channel,
//! the chip built into the VDP die. Knows nothing about the Z80 or the
//! bus; `genesis.zig` forwards the byte the Z80/68k writes to `write`, and
//! `scheduler.zig` calls `step` once per native-rate clock tick to produce
//! one PCM sample.
//!
//! Reference: SMS Power's SN76489 documentation (register format, LFSR
//! taps, the tone-0 DC quirk) — see DESIGN.md §7 and §11.

const std = @import("std");

/// Each channel's attenuation is 2 dB per step, 16 steps, step 15 silent.
/// Four channels summed must still fit an i16 sample, so the loudest single
/// channel is scaled to leave headroom: 4 * 8191 = 32764 <= 32767.
const max_amplitude = 8191;
const db_per_step = 2.0;
const silent_atten = 15;

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

/// LFSR feedback taps for white noise mode (bits 0 and 3); periodic noise
/// mode taps only bit 0.
const white_noise_taps: u16 = 0b1001;
const lfsr_reset: u16 = 0x8000;

/// Fixed noise-rate dividers selected by the low two bits of the noise
/// control register; rate 3 instead clocks the noise off tone channel 2.
const noise_fixed_period = [3]u10{ 0x10, 0x20, 0x40 };
const noise_rate_tone2 = 3;

pub const Psg = struct {
    /// 10-bit tone periods for channels 0-2.
    tone: [3]u10 = .{ 0, 0, 0 },
    counter: [3]u10 = .{ 0, 0, 0 },
    output: [3]bool = .{ false, false, false },

    /// Attenuation (0 = loudest, 15 = silent) for tone 0-2 then noise.
    atten: [4]u4 = .{ silent_atten, silent_atten, silent_atten, silent_atten },

    noise_mode_white: bool = false,
    noise_rate: u2 = 0,
    noise_counter: u10 = 0,
    lfsr: u16 = lfsr_reset,

    /// Which of the 8 registers (channel*2+type) the last latch byte
    /// selected; a following non-latch byte updates that register's high bits.
    latched: u3 = 0,

    /// A byte written to the PSG's data port. Bit 7 set is a latch byte
    /// (selects a register and writes its low bits); bit 7 clear continues
    /// the previously latched tone register with its high 6 bits.
    pub fn write(p: *Psg, val: u8) void {
        if (val & 0x80 != 0) {
            p.latched = @truncate((val >> 4) & 0x07);
            applyLow(p, val & 0x0F);
        } else {
            applyHigh(p, val & 0x3F);
        }
    }

    fn applyLow(p: *Psg, data4: u8) void {
        switch (p.latched) {
            0, 2, 4 => {
                const ch = p.latched / 2;
                p.tone[ch] = (p.tone[ch] & 0x3F0) | data4;
            },
            1, 3, 5, 7 => {
                const ch = p.latched / 2;
                p.atten[ch] = @truncate(data4);
            },
            6 => {
                p.noise_rate = @truncate(data4 & 0x03);
                p.noise_mode_white = data4 & 0x04 != 0;
                // Real hardware resets the shift register on any write to
                // the noise control register, not just on a mode change.
                p.lfsr = lfsr_reset;
                p.noise_counter = 0;
            },
        }
    }

    fn applyHigh(p: *Psg, data6: u8) void {
        switch (p.latched) {
            0, 2, 4 => {
                const ch = p.latched / 2;
                p.tone[ch] = (p.tone[ch] & 0x00F) | (@as(u10, data6) << 4);
            },
            // Volume and noise-control registers are one byte wide; a
            // stray second byte while one is latched does nothing.
            else => {},
        }
    }

    /// Advances the chip by one native-rate clock (the Z80 clock divided by
    /// 16) and returns the mixed PCM sample.
    pub fn step(p: *Psg) i16 {
        var tone2_toggled = false;
        for (0..3) |ch| {
            const toggled = stepTone(p.tone[ch], &p.counter[ch], &p.output[ch]);
            if (ch == 2) tone2_toggled = toggled;
        }
        stepNoise(p, tone2_toggled);

        var sum: i32 = 0;
        for (0..3) |ch| sum += channelSample(p.output[ch], p.atten[ch]);
        sum += channelSample(p.lfsr & 1 != 0, p.atten[3]);
        return @intCast(sum);
    }

    fn stepNoise(p: *Psg, tone2_toggled: bool) void {
        const clock = if (p.noise_rate == noise_rate_tone2) tone2_toggled else blk: {
            if (p.noise_counter == 0) {
                p.noise_counter = noise_fixed_period[p.noise_rate];
                break :blk true;
            }
            p.noise_counter -= 1;
            break :blk false;
        };
        if (!clock) return;

        const taps: u16 = if (p.noise_mode_white) white_noise_taps else 0b0001;
        const feedback: u16 = @popCount(p.lfsr & taps) & 1;
        p.lfsr = (p.lfsr >> 1) | (feedback << 15);
    }
};

/// A period of 0 is the documented DC quirk (DESIGN.md §7): the channel
/// never toggles and sits at a constant high output, which games exploit
/// for crude sample playback by pulsing the volume register instead.
fn stepTone(period: u10, counter: *u10, output: *bool) bool {
    if (period == 0) {
        output.* = true;
        return false;
    }
    if (counter.* == 0) {
        counter.* = period;
        output.* = !output.*;
        return true;
    }
    counter.* -= 1;
    return false;
}

fn channelSample(active: bool, atten: u4) i32 {
    const v = volume_table[atten];
    return if (active) v else -v;
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "reset attenuation is silent on all four channels" {
    const p = Psg{};
    for (p.atten) |a| try testing.expectEqual(@as(u4, silent_atten), a);
}

test "a latch byte then a data byte sets the full 10-bit tone period" {
    var p = Psg{};
    p.write(0x80 | 0x05); // latch tone0, low nibble 0x5
    p.write(0x00 | 0x02); // data byte, high 6 bits 0x02
    try testing.expectEqual(@as(u10, (0x02 << 4) | 0x05), p.tone[0]);
}

test "a latch byte alone sets volume from its low nibble" {
    var p = Psg{};
    p.write(0x80 | (1 << 4) | 0x03); // channel 0, type 1 (volume), data 3
    try testing.expectEqual(@as(u4, 3), p.atten[0]);
}

test "tone period 0 holds the channel at a constant high output" {
    var p = Psg{};
    p.atten[0] = 0;
    p.tone[0] = 0;
    p.atten[1] = silent_atten;
    p.atten[2] = silent_atten;
    p.atten[3] = silent_atten;

    const s1 = p.step();
    const s2 = p.step();
    try testing.expectEqual(s1, s2);
    try testing.expect(s1 > 0); // stuck high, so a positive (not silent) sample
}

test "a tone channel toggles every `period` steps, producing a square wave" {
    var p = Psg{};
    p.atten[0] = 0;
    p.tone[0] = 4;
    p.atten[1] = silent_atten;
    p.atten[2] = silent_atten;
    p.atten[3] = silent_atten;

    var toggles: u32 = 0;
    var last = p.step() > 0;
    for (0..40) |_| {
        const cur = p.step() > 0;
        if (cur != last) toggles += 1;
        last = cur;
    }
    // 40 steps / (period 4 => toggle every 4 steps) ~= 10 toggles.
    try testing.expect(toggles >= 8 and toggles <= 12);
}

test "white noise mode eventually produces both LFSR output levels" {
    var p = Psg{};
    for (0..4) |ch| p.atten[ch] = silent_atten;
    p.atten[3] = 0;
    p.write(0x80 | (0b11 << 5) | (0 << 4) | 0x04); // noise control: white mode, rate 0

    var saw_high = false;
    var saw_low = false;
    for (0..2000) |_| {
        if (p.step() > 0) saw_high = true else saw_low = true;
    }
    try testing.expect(saw_high and saw_low);
}
