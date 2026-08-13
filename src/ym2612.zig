//! YM2612 (OPN2) FM synthesizer: six four-operator channels, a low-frequency
//! oscillator, two timers, and channel 6's PCM DAC mode. Plain data and
//! integer math, no bus knowledge — `genesis.zig` forwards writes to
//! $A04000-$A04003 (and the Z80's $4000-$4003 mirror) to `write`, and steps
//! the chip once per 144 chip clocks through `step`.
//!
//! The model is per-sample rather than per-internal-cycle: every operator is
//! evaluated once per output sample, walked in the order the chip walks them
//! (S1, S3, S2, S4) and carrying the same one-sample modulation delays the
//! real pipeline has, but without its 24-slot rotation. `test/ym_nuked.zig`
//! diffs it against Nuked-OPN2, which is cycle-accurate, and pins how far
//! apart the two are allowed to drift.
//!
//! References: DESIGN.md §7 and §11, Nuked-OPN2's die-shot-derived tables
//! (the ROM tables here are generated from the same formulas and checked
//! against it), and the OPN2 algorithm chart.

const std = @import("std");

pub const channels = 6;
pub const operators = 4;
const slots = channels * operators;

/// The chip is clocked at the 68000's rate; one internal cycle per 6 of those
/// clocks, one stereo sample per 24 internal cycles (DESIGN.md §3.3).
pub const clocks_per_sample = 144;

/// A data write holds the busy flag for 32 internal cycles. Drivers poll it.
const busy_clocks = 32 * 6;

/// Status register bits; every port in the block answers with them.
const st_busy: u8 = 0x80;
const st_timer_b: u8 = 0x02;
const st_timer_a: u8 = 0x01;

/// Operator index within a channel, in the order the chip walks them — which
/// is also the order the registers number them: S1, S3, S2, S4.
const s1 = 0;
const s3 = 1;
const s2 = 2;
const s4 = 3;

/// Key-on/off ($28) names its operators in the other order, S1, S2, S3, S4.
const kon_bit_order = [operators]usize{ s1, s2, s3, s4 };

const max_atten: u16 = 0x3ff;
/// Half the envelope's range, where an SSG-EG segment turns around.
const ssg_atten: u16 = 0x200;

/// The SSG-EG register ($90): bit 3 switches it on, and the low three bits
/// name one of the eight segment shapes.
const ssg_hold: u4 = 0x1;
const ssg_alternate: u4 = 0x2;
const ssg_attack: u4 = 0x4;
const ssg_enable: u4 = 0x8;
const ssg_shape: u4 = ssg_attack | ssg_alternate | ssg_hold;

/// The multiplexer gives each channel four of the 24 cycles in a sample and
/// drives its real value on three of them (see `dacLevel`), so six channels
/// of ±256 peak at 4608 — scaled here to about three quarters of an i16, so
/// that a loud FM mix and a loud PSG can share the output without clipping.
const slots_per_channel = 4;
const driven_slots = 3;
const fm_gain = 5;

const EgState = enum(u2) { attack, decay, sustain, release };

// --------------------------------------------------------------- ROM tables

/// Attenuation of a quarter sine, in 1/256ths of an octave (the chip's log
/// domain). Generated from the same formula as the die's ROM; the
/// Nuked-OPN2 diff test asserts the two are identical.
fn logSinTable() [256]u16 {
    @setEvalBranchQuota(20_000);
    var t: [256]u16 = undefined;
    for (&t, 0..) |*v, i| {
        const angle = (@as(f64, @floatFromInt(i)) + 0.5) * std.math.pi / 512.0;
        v.* = @intFromFloat(@round(-@log2(@sin(angle)) * 256.0));
    }
    return t;
}

/// The inverse: 2^(x/256) - 1, in 1/1024ths, read backwards by `operator`.
fn expTable() [256]u16 {
    @setEvalBranchQuota(20_000);
    var t: [256]u16 = undefined;
    for (&t, 0..) |*v, i| {
        const x = @as(f64, @floatFromInt(i)) / 256.0;
        v.* = @intFromFloat(@round((@exp2(x) - 1.0) * 1024.0));
    }
    return t;
}

pub const log_sin = logSinTable();
pub const exp_of = expTable();

/// F-number's top bits to the low two bits of the key code, which is what
/// rate scaling and detune are really keyed on.
const fn_note = [16]u2{ 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 3, 3, 3, 3, 3, 3 };

const pg_detune = [8]u32{ 16, 17, 19, 20, 22, 24, 27, 29 };

/// LFO phase modulation: two shifts of the F-number's high bits, summed,
/// indexed by the channel's PMS depth and the LFO's triangle position.
const pg_lfo_sh1 = [8][8]u5{
    .{ 7, 7, 7, 7, 7, 7, 7, 7 },
    .{ 7, 7, 7, 7, 7, 7, 7, 7 },
    .{ 7, 7, 7, 7, 7, 7, 1, 1 },
    .{ 7, 7, 7, 7, 1, 1, 1, 1 },
    .{ 7, 7, 7, 1, 1, 1, 1, 0 },
    .{ 7, 7, 1, 1, 0, 0, 0, 0 },
    .{ 7, 7, 1, 1, 0, 0, 0, 0 },
    .{ 7, 7, 1, 1, 0, 0, 0, 0 },
};
const pg_lfo_sh2 = [8][8]u5{
    .{ 7, 7, 7, 7, 7, 7, 7, 7 },
    .{ 7, 7, 7, 7, 2, 2, 2, 2 },
    .{ 7, 7, 7, 2, 2, 2, 7, 7 },
    .{ 7, 7, 2, 2, 7, 7, 2, 2 },
    .{ 7, 7, 2, 7, 7, 7, 2, 7 },
    .{ 7, 7, 7, 2, 7, 7, 2, 1 },
    .{ 7, 7, 7, 2, 7, 7, 2, 1 },
    .{ 7, 7, 7, 2, 7, 7, 2, 1 },
};

/// How far the LFO's amplitude sweep is shifted down, per channel AMS. The
/// first entry shifts it away entirely.
const eg_am_shift = [4]u4{ 7, 3, 1, 0 };

/// Samples per LFO step, per LFO frequency setting.
const lfo_cycles = [8]u32{ 108, 77, 71, 67, 62, 44, 8, 5 };

/// The envelope's step at rates 48 and up. The row is the rate's low two bits,
/// the column the envelope timer's.
const eg_stephi = [4][4]u2{
    .{ 0, 0, 0, 0 },
    .{ 1, 0, 0, 0 },
    .{ 1, 0, 1, 0 },
    .{ 1, 1, 1, 0 },
};

/// The rate at which the attack is instant and the envelope jumps to full.
const instant_attack_rate = 62;

/// Whether the envelope has run out: at the bottom of its range normally, or
/// at the half-attenuation turnaround point under SSG-EG.
fn envelopeOff(level: i32, ssg_on: bool) bool {
    return if (ssg_on) level >= ssg_atten else (level & 0x3f0) == 0x3f0;
}

/// The attack is exponential in the log domain: each step covers a fixed
/// fraction of the attenuation that is left.
fn attackStep(level: i32, step: u3) i32 {
    return (~level * (@as(i32, 1) << step)) >> 5;
}

/// How far the envelope steps this tick, as a power of two, or 0 for "not this
/// tick". Below rate 48 the chip compares the rate against where the lowest
/// set bit of its 12-bit timer falls, which is what thins the slow rates out
/// to one step in thousands of ticks; from 48 up it steps every tick, by 1 to
/// 8. Both branches read the timer, so the phase of a slow envelope is not
/// free to differ from the reference by even one tick.
fn egInc(rate: u6, cnt: u32) u3 {
    const group: u32 = rate >> 2;
    if (rate >= 48) return @intCast(@min(4, eg_stephi[rate & 3][cnt & 3] + group - 11));

    // One past the bit the chip's shift register found, and zero when the
    // timer is all zeroes and it finds nothing at all.
    const shift: u32 = if (cnt == 0) 0 else @ctz(cnt) + 1;
    return switch ((group + shift) & 0x0f) {
        12 => 1,
        13 => @intCast((rate >> 1) & 1),
        14 => @intCast(rate & 1),
        else => 0,
    };
}

// -------------------------------------------------------------- algorithms

fn opBit(op: usize) u4 {
    return @as(u4, 1) << @intCast(op);
}

/// One row of the OPN2 algorithm chart: which operators modulate S3, S2 and
/// S4, and which of the four reach the channel's output.
const Algorithm = struct {
    s3_mod: u4 = 0,
    s2_mod: u4 = 0,
    s4_mod: u4 = 0,
    out: u4,
};

const algorithms = [8]Algorithm{
    .{ .s2_mod = opBit(s1), .s3_mod = opBit(s2), .s4_mod = opBit(s3), .out = opBit(s4) },
    .{ .s3_mod = opBit(s1) | opBit(s2), .s4_mod = opBit(s3), .out = opBit(s4) },
    .{ .s3_mod = opBit(s2), .s4_mod = opBit(s1) | opBit(s3), .out = opBit(s4) },
    .{ .s2_mod = opBit(s1), .s4_mod = opBit(s2) | opBit(s3), .out = opBit(s4) },
    .{ .s2_mod = opBit(s1), .s4_mod = opBit(s3), .out = opBit(s2) | opBit(s4) },
    .{ .s2_mod = opBit(s1), .s3_mod = opBit(s1), .s4_mod = opBit(s1), .out = opBit(s2) | opBit(s3) | opBit(s4) },
    .{ .s2_mod = opBit(s1), .out = opBit(s2) | opBit(s3) | opBit(s4) },
    .{ .out = opBit(s1) | opBit(s2) | opBit(s3) | opBit(s4) },
};

// ------------------------------------------------------------------- state

pub const Sample = struct { l: i16, r: i16 };

/// A channel's F-number, block and key code — normally the channel's own, but
/// channel 3's operators can each carry their own in special mode.
const Note = struct { fnum: u11, block: u3, kcode: u5 };

pub const Ym2612 = struct {
    // Per operator, indexed `channel * operators + s1|s3|s2|s4`.
    dt: [slots]u3 = @splat(0),
    /// MUL, pre-doubled the way the chip stores it: 1 for MUL=0, else MUL*2.
    multi: [slots]u5 = @splat(1),
    tl: [slots]u7 = @splat(0),
    ks: [slots]u2 = @splat(0),
    ar: [slots]u5 = @splat(0),
    dr: [slots]u5 = @splat(0),
    sr: [slots]u5 = @splat(0),
    rr: [slots]u4 = @splat(0),
    sl: [slots]u5 = @splat(0),
    ssg: [slots]u4 = @splat(0),
    am: [slots]bool = @splat(false),

    phase: [slots]u20 = @splat(0),
    /// Envelope attenuation, 0 (loudest) to 0x3ff. Powers on silent.
    level: [slots]u16 = @splat(max_atten),
    state: [slots]EgState = @splat(.release),
    /// Key state as the operator sees it, and as $28 last set it. They differ
    /// only while CSM mode is pulsing channel 3.
    key: [slots]bool = @splat(false),
    key_reg: [slots]bool = @splat(false),
    ssg_dir: [slots]bool = @splat(false),
    ssg_inv: [slots]bool = @splat(false),
    /// What the operators see of `ssg_inv`, which is a sample behind: the
    /// chip recomputes the flag a full pass before it reads it out, so a
    /// turnaround pairs the new level with the old inversion for one sample
    /// and clicks. Real drivers use SSG-EG for buzzy bass and the click is
    /// part of the sound.
    ssg_inv_out: [slots]bool = @splat(false),

    // Per channel.
    fnum: [channels]u11 = @splat(0),
    block: [channels]u3 = @splat(0),
    kcode: [channels]u5 = @splat(0),
    /// Channel 3's supplementary frequencies ($A8-$AA), one per operator bar
    /// S4, which keeps using the channel's own.
    fnum3: [3]u11 = @splat(0),
    block3: [3]u3 = @splat(0),
    kcode3: [3]u5 = @splat(0),
    alg: [channels]u3 = @splat(0),
    fb: [channels]u3 = @splat(0),
    ams: [channels]u2 = @splat(0),
    pms: [channels]u3 = @splat(0),
    pan_l: [channels]bool = @splat(true),
    pan_r: [channels]bool = @splat(true),
    /// S1's last two outputs (its own feedback, and the delayed tap S3 and S4
    /// read in some algorithms) and S2's last output.
    op1_hist: [channels][2]i16 = @splat(.{ 0, 0 }),
    op2_out: [channels]i16 = @splat(0),

    // Global.
    /// Register address latch; bit 8 selects the second bank of channels.
    addr: u9 = 0,
    /// The high halves of the F-number latches, held until their low byte
    /// lands: writing $A0 is what commits an $A4 written earlier.
    reg_a4: u8 = 0,
    reg_ac: u8 = 0,

    lfo_en: bool = false,
    lfo_freq: u3 = 0,
    lfo_cnt: u7 = 0,
    lfo_timer: u32 = 0,
    lfo_am: u16 = 0,
    lfo_pm: u5 = 0,

    /// The envelope advances once every three samples.
    eg_timer: u2 = 0,
    /// Carried out of the envelope count's twelfth bit, and added back on the
    /// next sample: the count gains a tick every time it wraps.
    eg_carry: u1 = 0,
    eg_cnt: u32 = 0,

    timer_a_reg: u10 = 0,
    timer_a_cnt: u10 = 0,
    timer_a_load: bool = false,
    timer_a_enable: bool = false,
    timer_a_flag: bool = false,
    timer_b_reg: u8 = 0,
    timer_b_cnt: u8 = 0,
    timer_b_sub: u4 = 0,
    timer_b_load: bool = false,
    timer_b_enable: bool = false,
    timer_b_flag: bool = false,

    /// 0 normal, 1 and 3 channel-3 special mode, 2 CSM.
    mode_ch3: u2 = 0,
    csm_on: bool = false,
    /// Channels whose operator 1 is still waiting for its key-on latch.
    kon_wait: u6 = 0,

    /// Channel 6's PCM sample, already sign-extended into the same ±256 range
    /// a channel's own output has.
    dac_data: i16 = 0,
    dac_en: bool = false,

    /// Chip clocks left on the busy flag.
    busy: u16 = 0,

    /// Debug knobs (DESIGN.md §9 M3): silence a channel, or model the
    /// discrete YM2612's DAC crossover distortion.
    mute: [channels]bool = @splat(false),
    ladder: bool = false,

    // ------------------------------------------------------------ registers

    /// Port 0/2 latch a register address (2 selects the second bank), 1/3
    /// write data to the latched one.
    pub fn write(y: *Ym2612, port: u2, val: u8) void {
        if (port & 1 == 0) {
            y.addr = (@as(u9, port >> 1) << 8) | val;
            return;
        }
        y.busy = busy_clocks;
        y.writeReg(val);
    }

    pub fn status(y: *const Ym2612) u8 {
        var v: u8 = 0;
        if (y.busy != 0) v |= st_busy;
        if (y.timer_b_flag) v |= st_timer_b;
        if (y.timer_a_flag) v |= st_timer_a;
        return v;
    }

    fn writeReg(y: *Ym2612, val: u8) void {
        const part: u1 = @intCast(y.addr >> 8);
        const reg: u8 = @truncate(y.addr);
        if (reg < 0x30) {
            if (part == 0) y.writeMode(reg, val);
            return;
        }
        // The fourth slot of each bank is not a channel.
        if (reg & 3 == 3) return;
        const ch = @as(usize, part) * 3 + (reg & 3);
        if (reg < 0xa0) return y.writeOperator(ch * operators + ((reg >> 2) & 3), reg & 0xf0, val);
        y.writeChannel(ch, part, reg, val);
    }

    fn writeMode(y: *Ym2612, reg: u8, val: u8) void {
        switch (reg) {
            0x22 => {
                y.lfo_en = val & 0x08 != 0;
                y.lfo_freq = @truncate(val);
                if (!y.lfo_en) y.lfo_cnt = 0;
            },
            0x24 => y.timer_a_reg = (y.timer_a_reg & 3) | (@as(u10, val) << 2),
            0x25 => y.timer_a_reg = (y.timer_a_reg & 0x3fc) | (val & 3),
            0x26 => y.timer_b_reg = val,
            0x27 => y.writeTimerControl(val),
            0x28 => y.writeKey(val),
            // 0 is full negative and 0x80 silence, so the byte is unsigned
            // around a midpoint and doubled into a channel's own range.
            0x2a => y.dac_data = @as(i16, val) * 2 - 256,
            0x2b => y.dac_en = val & 0x80 != 0,
            else => {},
        }
    }

    fn writeTimerControl(y: *Ym2612, val: u8) void {
        const load_a = val & 0x01 != 0;
        const load_b = val & 0x02 != 0;
        // A counter reloads when its load bit rises, not on every write.
        if (load_a and !y.timer_a_load) y.timer_a_cnt = y.timer_a_reg;
        if (load_b and !y.timer_b_load) y.timer_b_cnt = y.timer_b_reg;
        y.timer_a_load = load_a;
        y.timer_b_load = load_b;
        y.timer_a_enable = val & 0x04 != 0;
        y.timer_b_enable = val & 0x08 != 0;
        if (val & 0x10 != 0) y.timer_a_flag = false;
        if (val & 0x20 != 0) y.timer_b_flag = false;
        y.mode_ch3 = @truncate(val >> 6);
    }

    fn writeKey(y: *Ym2612, val: u8) void {
        if (val & 3 == 3) return; // no such channel
        const ch = (val & 3) + (val >> 2 & 1) * 3;
        for (kon_bit_order, 0..) |op, i| {
            const on = val & (@as(u8, 0x10) << @intCast(i)) != 0;
            const slot = @as(usize, ch) * operators + op;
            y.key_reg[slot] = on;
            if (op != s1) y.setKey(slot, on or (y.csm_on and ch == 2));
        }
        y.kon_wait |= @as(u6, 1) << @intCast(ch);
    }

    /// The chip polls $28's latch one operator per internal cycle, and
    /// operator 1's poll falls on the very cycle a write to $28 lands: it
    /// misses by a whole pass every time, so operator 1 keys on and off one
    /// sample behind the other three. Nothing here is audible on its own, but
    /// it shifts operator 1's phase by a sample for as long as the note lasts.
    fn applyKeyDelay(y: *Ym2612) void {
        while (y.kon_wait != 0) {
            const ch: usize = @ctz(y.kon_wait);
            y.kon_wait &= y.kon_wait - 1;
            const slot = ch * operators + s1;
            y.setKey(slot, y.key_reg[slot] or (y.csm_on and ch == 2));
        }
    }

    fn writeOperator(y: *Ym2612, slot: usize, reg: u8, val: u8) void {
        switch (reg) {
            0x30 => {
                const mul: u5 = @truncate(val & 0x0f);
                y.multi[slot] = if (mul == 0) 1 else mul * 2;
                y.dt[slot] = @truncate(val >> 4);
            },
            0x40 => y.tl[slot] = @truncate(val),
            0x50 => {
                y.ar[slot] = @truncate(val);
                y.ks[slot] = @truncate(val >> 6);
            },
            0x60 => {
                y.dr[slot] = @truncate(val);
                y.am[slot] = val & 0x80 != 0;
            },
            0x70 => y.sr[slot] = @truncate(val),
            0x80 => {
                y.rr[slot] = @truncate(val);
                // Sustain level 15 means "all the way down", one step past
                // the 4-bit field: the chip forms that by carrying into bit 4.
                const sl: u5 = @truncate(val >> 4);
                y.sl[slot] = sl | ((sl +% 1) & 0x10);
            },
            0x90 => y.ssg[slot] = @truncate(val),
            else => {},
        }
    }

    fn writeChannel(y: *Ym2612, ch: usize, part: u1, reg: u8, val: u8) void {
        switch (reg & 0xfc) {
            0xa0 => {
                y.fnum[ch] = @truncate((@as(u16, y.reg_a4 & 0x07) << 8) | val);
                y.block[ch] = @truncate(y.reg_a4 >> 3);
                y.kcode[ch] = keyCode(y.block[ch], y.fnum[ch]);
            },
            0xa4 => y.reg_a4 = val,
            // Channel 3's extra frequencies live in the first bank only.
            0xa8 => {
                if (part != 0) return;
                const i = reg & 3;
                y.fnum3[i] = @truncate((@as(u16, y.reg_ac & 0x07) << 8) | val);
                y.block3[i] = @truncate(y.reg_ac >> 3);
                y.kcode3[i] = keyCode(y.block3[i], y.fnum3[i]);
            },
            0xac => if (part == 0) {
                y.reg_ac = val;
            },
            0xb0 => {
                y.alg[ch] = @truncate(val);
                y.fb[ch] = @truncate(val >> 3);
            },
            0xb4 => {
                y.pms[ch] = @truncate(val);
                y.ams[ch] = @truncate(val >> 4);
                y.pan_l[ch] = val & 0x80 != 0;
                y.pan_r[ch] = val & 0x40 != 0;
            },
            else => {},
        }
    }

    // -------------------------------------------------------------- stepping

    /// Advances the chip by one output sample: 24 internal cycles, 144 chip
    /// clocks.
    pub fn step(y: *Ym2612) Sample {
        const s = y.stepRaw();
        return .{ .l = clampSample(s.l * fm_gain), .r = clampSample(s.r * fm_gain) };
    }

    /// The same sample in the chip's own DAC units, before the output gain.
    /// This is what Nuked-OPN2 accumulates over its 24 cycles, so it is what
    /// `test/ym_nuked_test.zig` compares against.
    pub fn stepRaw(y: *Ym2612) struct { l: i32, r: i32 } {
        y.busy -|= clocks_per_sample;
        y.advanceLfo();
        y.advanceTimers();
        y.eg_timer = if (y.eg_timer == 2) 0 else y.eg_timer + 1;
        y.advanceEnvelope(y.eg_timer == 0);

        var l: i32 = 0;
        var r: i32 = 0;
        for (0..channels) |ch| {
            const out = y.channelOut(ch);
            l += y.dacLevel(out, y.pan_l[ch]);
            r += y.dacLevel(out, y.pan_r[ch]);
        }
        y.applyKeyDelay();
        return .{ .l = l, .r = r };
    }

    /// What one channel puts on its side of the output, summed over the four
    /// cycles of the 24 the multiplexer gives it.
    ///
    /// The discrete YM2612's DAC has no code for zero: it steps straight from
    /// -1 to +1, and it drives the channel's real value on only one of those
    /// four cycles, parking on the sign for the other three. That crossover
    /// gap is the "ladder effect" — inaudible at full volume, unmistakable on
    /// quiet PCM. The YM3438 in later consoles drives three of the four cycles
    /// properly and has no gap, which is why both paths come out at the same
    /// amplitude.
    fn dacLevel(y: *const Ym2612, out: i16, panned: bool) i32 {
        if (!y.ladder) return if (panned) @as(i32, out) * driven_slots else 0;

        var v: i32 = out;
        var sign: i32 = v >> 8;
        if (v >= 0) {
            v += 1;
            sign += 1;
        }
        return if (panned) v + driven_slots * sign else slots_per_channel * sign;
    }

    fn advanceLfo(y: *Ym2612) void {
        // The prescaler is not compared against its limit but masked with it:
        // counting up from zero that is the same thing, but after a frequency
        // change mid-count it is not, and the sweep's phase afterwards depends
        // on it.
        const limit = lfo_cycles[y.lfo_freq];
        y.lfo_timer += 1;
        if (y.lfo_timer & limit == limit) {
            y.lfo_timer = 0;
            y.lfo_cnt +%= 1;
        }
        // The counter is held at zero while the LFO is off, but its prescaler
        // keeps running, so enabling it mid-note does not restart the sweep.
        if (!y.lfo_en) y.lfo_cnt = 0;
        y.lfo_pm = @truncate(y.lfo_cnt >> 2);
        // A triangle over the counter's low 6 bits, doubled.
        const half: u16 = y.lfo_cnt & 0x3f;
        y.lfo_am = (if (y.lfo_cnt & 0x40 != 0) half else half ^ 0x3f) << 1;
    }

    /// Timer A counts samples, timer B one in sixteen; both reload from their
    /// register on overflow. Their flags are what a sound driver polls for
    /// tempo — nothing on the Genesis wires the chip's IRQ pin anywhere.
    fn advanceTimers(y: *Ym2612) void {
        var overflow_a = false;
        if (y.timer_a_load) {
            if (y.timer_a_cnt == std.math.maxInt(u10)) {
                y.timer_a_cnt = y.timer_a_reg;
                overflow_a = true;
                if (y.timer_a_enable) y.timer_a_flag = true;
            } else y.timer_a_cnt += 1;
        }
        if (y.timer_b_load) {
            y.timer_b_sub +%= 1;
            if (y.timer_b_sub == 0) {
                if (y.timer_b_cnt == std.math.maxInt(u8)) {
                    y.timer_b_cnt = y.timer_b_reg;
                    if (y.timer_b_enable) y.timer_b_flag = true;
                } else y.timer_b_cnt += 1;
            }
        }
        y.setCsm(overflow_a and y.mode_ch3 == 2);
    }

    /// CSM mode keys channel 3 on for the one sample timer A overflows on,
    /// which is how speech drivers retrigger an envelope per pitch period.
    fn setCsm(y: *Ym2612, on: bool) void {
        if (on == y.csm_on) return;
        y.csm_on = on;
        for (0..operators) |op| {
            const slot = 2 * operators + op;
            y.setKey(slot, on or y.key_reg[slot]);
        }
    }

    fn setKey(y: *Ym2612, slot: usize, on: bool) void {
        if (on == y.key[slot]) return;
        y.key[slot] = on;
        if (on) {
            y.state[slot] = .attack;
            y.phase[slot] = 0;
            y.ssg_dir[slot] = false;
            y.ssg_inv[slot] = false;
            // A maximum attack rate has no ramp to run: the envelope is open
            // the moment the key lands, not on the next envelope tick.
            if (y.egRate(slot, y.ar[slot]) >= instant_attack_rate) y.level[slot] = 0;
            return;
        }
        // Releasing out of an inverted SSG-EG segment continues from where
        // the inversion had the envelope, not from the raw level.
        if (y.ssg_inv[slot]) y.level[slot] = (ssg_atten -% y.level[slot]) & max_atten;
        y.ssg_inv[slot] = false;
        y.state[slot] = .release;
    }

    // ------------------------------------------------------------- envelope

    /// The envelope generator. Levels only move on one sample in three — the
    /// rate the chip's envelope timer ticks at — but the state machine runs
    /// every sample, which is what lets an SSG-EG segment turn around between
    /// two ticks.
    fn advanceEnvelope(y: *Ym2612, tick: bool) void {
        for (0..slots) |slot| y.envelopeStep(slot, tick);
        // Stepped after the slots, not before: the chip latches the shift it
        // derives the increments from one cycle ahead of using it, so a tick
        // works off the count as it stood before that tick.
        if (tick or y.eg_carry != 0) {
            const next = y.eg_cnt + 1;
            y.eg_carry = @intCast(next >> 12);
            y.eg_cnt = next & 0xfff;
        }
    }

    /// The rate an operator's envelope runs at in a given state: the register
    /// doubled, plus key scaling off the note's key code.
    fn egRate(y: *const Ym2612, slot: usize, base: u6) u6 {
        if (base == 0) return 0;
        const scaling = y.slotNote(slot).kcode >> (3 - y.ks[slot]);
        return @intCast(@min(63, @as(u8, base) * 2 + scaling));
    }

    /// What SSG-EG asks of this sample, once the inversion latches have been
    /// advanced.
    const Segment = struct {
        on: bool,
        restart: bool = false,
        reset_phase: bool = false,
        /// The segment has run into its hold, so the envelope stays where it
        /// is instead of releasing.
        hold_up: bool = false,
    };

    /// SSG-EG turns the tail of the envelope into a repeating segment: at half
    /// attenuation the operator restarts, holds, or flips into an inverted
    /// (rising) segment, which is what makes those patches buzz.
    fn ssgSegment(y: *Ym2612, slot: usize) Segment {
        const ssg = y.ssg[slot];
        const key = y.key[slot];
        const turn = ssg_alternate | ssg_hold;

        var seg = Segment{ .on = ssg & ssg_enable != 0 };
        var dir = false;
        if (seg.on) {
            dir = y.ssg_dir[slot];
            if (y.level[slot] & ssg_atten != 0) {
                if (ssg & turn == 0) seg.reset_phase = true;
                if (ssg & ssg_hold == 0) seg.restart = true;
                if (ssg & turn == ssg_alternate) dir = !dir;
                if (ssg & turn == turn) dir = true;
            }
            seg.hold_up = key and (ssg & ssg_shape == ssg_attack | ssg_hold or
                ssg & ssg_shape == ssg_alternate | ssg_hold);
            dir = dir and key;
        }

        y.ssg_dir[slot] = dir;
        y.ssg_inv_out[slot] = y.ssg_inv[slot];
        y.ssg_inv[slot] = key and (dir != (seg.on and ssg & ssg_attack != 0));
        return seg;
    }

    fn envelopeStep(y: *Ym2612, slot: usize, tick: bool) void {
        const key = y.key[slot];
        const seg = y.ssgSegment(slot);
        const ssg_on = seg.on;

        const retrigger = key and seg.restart;
        if (seg.reset_phase) y.phase[slot] = 0;

        const state = y.state[slot];
        const base: u6 = if (retrigger) y.ar[slot] else switch (state) {
            .attack => y.ar[slot],
            .decay => y.dr[slot],
            .sustain => y.sr[slot],
            // Release is four bits wide and always odd, so it never rests.
            .release => (@as(u6, y.rr[slot]) << 1) | 1,
        };
        const rate = y.egRate(slot, base);
        const eg_step: u3 = if (tick and base != 0) egInc(rate, y.eg_cnt) else 0;

        const level: i32 = y.level[slot];
        var next = level;
        var inc: i32 = 0;
        if (retrigger) {
            y.state[slot] = .attack;
            if (rate >= instant_attack_rate) {
                next = 0;
            } else if (state == .attack and level != 0 and eg_step != 0) {
                inc = attackStep(level, eg_step);
            }
        } else switch (state) {
            .attack => {
                if (level == 0) {
                    y.state[slot] = .decay;
                } else if (eg_step != 0 and rate < instant_attack_rate) {
                    inc = attackStep(level, eg_step);
                }
            },
            // The sustain level is reached exactly, never passed: every step
            // is a power of two and the comparison is against a multiple of
            // the same, which is why the chip can test for equality here.
            .decay, .sustain, .release => {
                const at_sustain = state == .decay and (level >> 4) == @as(i32, y.sl[slot]) * 2;
                if (at_sustain) {
                    y.state[slot] = .sustain;
                } else if (eg_step != 0 and !envelopeOff(level, ssg_on)) {
                    // An SSG-EG segment falls four times as fast, because it
                    // only has to reach half attenuation to turn around.
                    inc = @as(i32, 1) << (eg_step - 1);
                    if (ssg_on) inc <<= 2;
                }
            },
        }
        if (!key) y.state[slot] = .release;

        if (!retrigger and !seg.hold_up and state != .attack and envelopeOff(level, ssg_on)) {
            y.state[slot] = .release;
            next = max_atten;
        }
        y.level[slot] = @intCast((next + inc) & max_atten);
    }

    // ---------------------------------------------------------------- audio

    fn slotNote(y: *const Ym2612, slot: usize) Note {
        const ch = slot / operators;
        if (ch != 2 or y.mode_ch3 == 0) {
            return .{ .fnum = y.fnum[ch], .block = y.block[ch], .kcode = y.kcode[ch] };
        }
        const i: usize = switch (slot % operators) {
            s1 => 1,
            s3 => 0,
            s2 => 2,
            else => return .{ .fnum = y.fnum[ch], .block = y.block[ch], .kcode = y.kcode[ch] },
        };
        return .{ .fnum = y.fnum3[i], .block = y.block3[i], .kcode = y.kcode3[i] };
    }

    fn phaseIncrement(y: *const Ym2612, slot: usize) u20 {
        const ch = slot / operators;
        const note = y.slotNote(slot);

        // Phase modulation: the LFO's triangle folds into a shift-and-add of
        // the F-number's high bits, deepened by the channel's PMS.
        var lfo_l: u5 = @truncate(y.lfo_pm & 0x0f);
        if (lfo_l & 0x08 != 0) lfo_l ^= 0x0f;
        const pms = y.pms[ch];
        const fnum_h: u32 = @as(u32, note.fnum) >> 4;
        var fm = (fnum_h >> pg_lfo_sh1[pms][lfo_l]) + (fnum_h >> pg_lfo_sh2[pms][lfo_l]);
        if (pms > 5) fm <<= @intCast(pms - 5);
        fm >>= 2;

        var fnum: u32 = @as(u32, note.fnum) << 1;
        fnum = if (y.lfo_pm & 0x10 != 0) fnum -% fm else fnum + fm;
        fnum &= 0xfff;

        var freq = (fnum << note.block) >> 2;
        freq = applyDetune(freq, y.dt[slot], note.kcode) & 0x1ffff;
        return @truncate((freq * y.multi[slot]) >> 1);
    }

    /// One operator's 14-bit output: sine of its phase plus the incoming
    /// modulation, attenuated by the envelope, through the exponential table.
    fn operator(y: *Ym2612, slot: usize, mod: i32) i16 {
        const phase: u32 = (@as(u32, @bitCast(mod)) +% (y.phase[slot] >> 10)) & 0x3ff;
        y.phase[slot] +%= y.phaseIncrement(slot);

        // The table holds a quarter sine; the other three are mirrors of it.
        const quarter: u32 = if (phase & 0x100 != 0) ~phase & 0xff else phase & 0xff;
        const atten = @min(0x1fff, @as(u32, log_sin[quarter]) + (@as(u32, y.egOut(slot)) << 2));
        const mantissa: u32 = (exp_of[(atten & 0xff) ^ 0xff] | 0x400) << 2;
        const out: i16 = @intCast(mantissa >> @intCast(atten >> 8));
        return if (phase & 0x200 != 0) -out else out;
    }

    /// The attenuation an operator is actually playing at: its envelope, the
    /// LFO's amplitude sweep if it subscribes, and its total level.
    fn egOut(y: *const Ym2612, slot: usize) u16 {
        var level = y.level[slot];
        if (y.ssg_inv_out[slot]) level = (ssg_atten -% level) & max_atten;
        if (y.am[slot]) level += y.lfo_am >> eg_am_shift[y.ams[slot / operators]];
        level += @as(u16, y.tl[slot]) << 3;
        return @min(level, max_atten);
    }

    /// One channel's 9-bit output. The operators are walked S1, S3, S2, S4;
    /// the ones that reach a later operator in that order modulate it with
    /// this sample's value, and the ones that do not are read from the chip's
    /// delay registers, a sample behind.
    fn channelOut(y: *Ym2612, ch: usize) i16 {
        if (ch == channels - 1 and y.dac_en) return if (y.mute[ch]) 0 else y.dac_data;

        const alg = algorithms[y.alg[ch]];
        const base = ch * operators;
        const prev1 = y.op1_hist[ch][0];
        const prev2 = y.op2_out[ch];

        const fb = y.fb[ch];
        const feedback: i32 = if (fb == 0) 0 else (@as(i32, prev1) + y.op1_hist[ch][1]) >> @intCast(10 - @as(u4, fb));
        const out1 = y.operator(base + s1, feedback);
        const out3 = y.operator(base + s3, modOf(alg.s3_mod, prev1, prev2, 0));
        const out2 = y.operator(base + s2, modOf(alg.s2_mod, out1, 0, 0));
        // S4 is prepared late enough in the walk to see this sample's S1,
        // where S3 is prepared before S1's output has been latched and sees
        // the sample before.
        const out4 = y.operator(base + s4, modOf(alg.s4_mod, out1, prev2, out3));

        y.op1_hist[ch][1] = y.op1_hist[ch][0];
        y.op1_hist[ch][0] = out1;
        y.op2_out[ch] = out2;
        if (y.mute[ch]) return 0;

        // The accumulator is 9 bits wide and saturates on the way in, so a
        // loud algorithm clips per channel rather than wrapping.
        var acc: i32 = 0;
        for ([_]struct { u4, i16 }{ .{ opBit(s1), out1 }, .{ opBit(s3), out3 }, .{ opBit(s2), out2 }, .{ opBit(s4), out4 } }) |pair| {
            if (alg.out & pair[0] == 0) continue;
            acc = std.math.clamp(acc + (@as(i32, pair[1]) >> 5), -256, 255);
        }
        return @intCast(acc);
    }
};

/// Sums the modulators one operator's algorithm row selects, then halves the
/// total the way the chip's modulation input does.
fn modOf(mask: u4, from_s1: i16, from_s2: i16, from_s3: i16) i32 {
    var sum: i32 = 0;
    if (mask & opBit(s1) != 0) sum += from_s1;
    if (mask & opBit(s2) != 0) sum += from_s2;
    if (mask & opBit(s3) != 0) sum += from_s3;
    return sum >> 1;
}

fn keyCode(block: u3, fnum: u11) u5 {
    return (@as(u5, block) << 2) | fn_note[fnum >> 7];
}

/// Detune shifts the phase increment by a fraction of a semitone that grows
/// with pitch, read out of a four-entry table by a skewed key code.
fn applyDetune(freq: u32, dt: u3, kcode: u5) u32 {
    const dt_l = dt & 3;
    if (dt_l == 0) return freq;

    const kc = @min(kcode, 0x1c);
    const note = kc & 3;
    // The chip ORs two conditions into this sum, which lands on +0, +2, +3
    // for detune 1, 2 and 3.
    const skew: u32 = @intFromBool(dt_l == 3) | (dt_l & 2);
    const sum = (kc >> 2) + 9 + skew;
    const detune = pg_detune[((sum & 1) << 2) | note] >> @intCast(9 - (sum >> 1));
    return if (dt & 4 != 0) freq -% detune else freq + detune;
}

fn clampSample(v: i32) i16 {
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// Programs one channel as a plain sine: algorithm 7 (all four operators
/// straight out), S4 audible at full volume and the rest silenced.
fn sineChannel(y: *Ym2612, ch: usize, block: u3, fnum: u11) void {
    const part: u2 = if (ch < 3) 0 else 2;
    const idx: u8 = @intCast(ch % 3);
    const w = struct {
        fn reg(chip: *Ym2612, p: u2, r: u8, v: u8) void {
            chip.write(p, r);
            chip.write(p | 1, v);
        }
    };
    w.reg(y, part, 0xb0 + idx, 0x07); // algorithm 7, no feedback
    w.reg(y, part, 0xb4 + idx, 0xc0); // both speakers
    for (0..operators) |op| {
        const o: u8 = @intCast(op * 4);
        w.reg(y, part, 0x30 + o + idx, 0x01); // MUL 1, no detune
        w.reg(y, part, 0x40 + o + idx, if (op == s4) 0 else 127); // only S4 audible
        w.reg(y, part, 0x50 + o + idx, 31); // instant attack
        w.reg(y, part, 0x60 + o + idx, 0); // no decay
        w.reg(y, part, 0x70 + o + idx, 0);
        w.reg(y, part, 0x80 + o + idx, 0); // no sustain drop, slowest release
    }
    w.reg(y, part, 0xa4 + idx, (@as(u8, block) << 3) | @as(u8, @truncate(fnum >> 8)));
    w.reg(y, part, 0xa0 + idx, @truncate(fnum));
    w.reg(y, 0, 0x28, 0xf0 | (idx + (if (ch < 3) @as(u8, 0) else 4)));
}

test "the chip powers on silent" {
    var y = Ym2612{};
    for (0..100) |_| {
        const s = y.step();
        try testing.expectEqual(@as(i16, 0), s.l);
        try testing.expectEqual(@as(i16, 0), s.r);
    }
}

test "a keyed-on operator produces a sine at the frequency its F-number names" {
    var y = Ym2612{};
    // The phase increment is fnum * 2^(block-1) and 2^20 of phase is one
    // cycle, so at the chip's 53.267 kHz sample rate block 4 with F-number
    // 1082 is 440 Hz: 1082 * 8 * 53267 / 2^20.
    sineChannel(&y, 0, 4, 1082);

    var crossings: u32 = 0;
    var prev: i16 = 0;
    const samples = 53_267; // one second at the chip's native rate
    for (0..samples) |_| {
        const s = y.step();
        if (prev <= 0 and s.l > 0) crossings += 1;
        prev = s.l;
    }
    try testing.expect(crossings >= 438 and crossings <= 441);
}

test "panning routes a channel to one speaker at a time" {
    var y = Ym2612{};
    sineChannel(&y, 0, 4, 1164);
    y.write(0, 0xb4);
    y.write(1, 0x80); // left only

    var left: u32 = 0;
    var right: u32 = 0;
    for (0..1000) |_| {
        const s = y.step();
        left += @abs(s.l);
        right += @abs(s.r);
    }
    try testing.expect(left > 0);
    try testing.expectEqual(@as(u32, 0), right);
}

test "muting a channel silences it without touching the others" {
    var y = Ym2612{};
    sineChannel(&y, 0, 4, 1164);
    sineChannel(&y, 1, 4, 1164);
    y.mute[0] = true;

    var energy: u32 = 0;
    for (0..1000) |_| energy += @abs(y.step().l);
    try testing.expect(energy > 0);

    y.mute[1] = true;
    for (0..1000) |_| try testing.expectEqual(@as(i16, 0), y.step().l);
}

test "channel 6 in DAC mode plays the byte it is fed, not its operators" {
    var y = Ym2612{};
    sineChannel(&y, 5, 4, 1164);
    y.write(0, 0x2b);
    y.write(1, 0x80); // DAC on
    y.write(0, 0x2a);
    y.write(1, 0xff); // full positive

    const loud = y.step();
    try testing.expect(loud.l > 0);

    y.write(0, 0x2a);
    y.write(1, 0x80); // midpoint
    try testing.expectEqual(@as(i16, 0), y.step().l);
}

test "a data write reports busy until the chip has had 32 internal cycles" {
    var y = Ym2612{};
    try testing.expectEqual(@as(u8, 0), y.status() & st_busy);

    y.write(0, 0x22);
    try testing.expectEqual(@as(u8, 0), y.status() & st_busy); // address writes do not
    y.write(1, 0x00);
    try testing.expectEqual(st_busy, y.status() & st_busy);

    _ = y.step();
    _ = y.step();
    try testing.expectEqual(@as(u8, 0), y.status() & st_busy);
}

test "timer A overflows after (1024 - period) samples and latches its flag" {
    var y = Ym2612{};
    const period = 1000;
    y.write(0, 0x24);
    y.write(1, period >> 2);
    y.write(0, 0x25);
    y.write(1, period & 3);
    y.write(0, 0x27);
    y.write(1, 0x05); // load and enable timer A

    for (0..1023 - period) |_| _ = y.step();
    try testing.expectEqual(@as(u8, 0), y.status() & st_timer_a);
    _ = y.step();
    try testing.expectEqual(st_timer_a, y.status() & st_timer_a);

    y.write(0, 0x27);
    y.write(1, 0x15); // reset the flag
    try testing.expectEqual(@as(u8, 0), y.status() & st_timer_a);
}

test "timer B counts one sample in sixteen" {
    var y = Ym2612{};
    y.write(0, 0x26);
    y.write(1, 254);
    y.write(0, 0x27);
    y.write(1, 0x0a); // load and enable timer B

    // (256 - 254) ticks of sixteen samples each.
    for (0..2 * 16 - 1) |_| _ = y.step();
    try testing.expectEqual(@as(u8, 0), y.status() & st_timer_b);
    _ = y.step();
    try testing.expectEqual(st_timer_b, y.status() & st_timer_b);
}

test "key off releases the envelope back to silence" {
    var y = Ym2612{};
    sineChannel(&y, 0, 4, 1164);
    // Fastest release, so the tail is short enough to sit in a unit test.
    y.write(0, 0x80 + s4 * 4);
    y.write(1, 0x0f);

    var loud: u32 = 0;
    for (0..100) |_| loud += @abs(y.step().l);
    try testing.expect(loud > 0);

    y.write(0, 0x28);
    y.write(1, 0x00); // all operators off, channel 0
    for (0..2000) |_| _ = y.step();
    for (0..100) |_| try testing.expectEqual(@as(i16, 0), y.step().l);
}

test "total level attenuates, and 127 is silence" {
    var y = Ym2612{};
    sineChannel(&y, 0, 4, 1164);

    var prev: u32 = std.math.maxInt(u32);
    var tl: u8 = 0;
    while (tl <= 64) : (tl += 8) {
        y.write(0, 0x40 + s4 * 4);
        y.write(1, tl);
        var energy: u32 = 0;
        for (0..2000) |_| energy += @abs(y.step().l);
        try testing.expect(energy < prev);
        prev = energy;
    }
    y.write(0, 0x40 + s4 * 4);
    y.write(1, 127);
    for (0..2000) |_| _ = y.step();
    for (0..100) |_| try testing.expectEqual(@as(i16, 0), y.step().l);
}

test "the ladder option offsets a silent channel off zero and a loud one not much" {
    var plain = Ym2612{};
    var ladder = Ym2612{ .ladder = true };
    sineChannel(&plain, 0, 4, 1164);
    sineChannel(&ladder, 0, 4, 1164);

    // Both channels idle at zero; only the discrete DAC's crossover gap can
    // put anything but silence on the output.
    plain.mute[0] = true;
    ladder.mute[0] = true;
    try testing.expectEqual(@as(i16, 0), plain.step().l);
    try testing.expect(ladder.step().l != 0);
}

test "the log-sine and exponential tables are the chip's own" {
    // Landmarks straight out of the die-shot ROMs: the quarter sine's ends,
    // and the exponential's.
    try testing.expectEqual(@as(u16, 0x859), log_sin[0]);
    try testing.expectEqual(@as(u16, 0x000), log_sin[255]);
    try testing.expectEqual(@as(u16, 0x000), exp_of[0]);
    try testing.expectEqual(@as(u16, 0x3fa), exp_of[255]);
}

test "detune matches the published table at the ends of its range" {
    // Key code 0 with detune 1, 2, 3 is 0, 1, 2 steps; the top of the range
    // saturates at 22.
    try testing.expectEqual(@as(u32, 0), applyDetune(0, 1, 0));
    try testing.expectEqual(@as(u32, 1), applyDetune(0, 2, 0));
    try testing.expectEqual(@as(u32, 2), applyDetune(0, 3, 0));
    try testing.expectEqual(@as(u32, 22), applyDetune(0, 3, 0x1c));
    // Bit 2 of the field flips the sign.
    try testing.expectEqual(@as(u32, 100 - 2), applyDetune(100, 7, 0));
}

test "an envelope rate's increment thins out as the rate drops" {
    // Rate 63 steps by 8 (2^(4-1)) every tick; rate 4 by 1 every other 1024.
    try testing.expectEqual(@as(u3, 4), egInc(63, 0));
    var steps: u32 = 0;
    for (0..8192) |cnt| steps += egInc(4, @intCast(cnt));
    try testing.expectEqual(@as(u32, 4), steps);
}
