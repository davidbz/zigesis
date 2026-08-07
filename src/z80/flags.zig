//! Z80 flag computation, one function per ALU/rotate/shift family. Ported
//! from the algorithms Ares' Z80 core uses (itself validated against the
//! SingleStepTests suite this project also targets), since the undocumented
//! X/Y/H/N bits are underspecified in every written reference but pinned
//! exactly by that test data.
//!
//! Every function here sets `c.q` and touches only the flags real silicon
//! documents for that instruction — callers must not zero unrelated flags
//! around these calls. Q is not a plain "flags changed" boolean: real
//! silicon latches the flag *bus*, so after a flag-writing instruction Q
//! numerically equals the resulting F (confirmed against the SingleStepTests
//! corpus: `final.q == final.f` in every recorded case), which collapses to
//! false whenever that F happens to be zero even though flags were written.
//! Instructions that don't touch flags leave `c.q` at whatever `core.zig`
//! reset it to (false) at the top of the current instruction.

const cpu = @import("cpu.zig");
const Cpu = cpu.Cpu;
const Flags = cpu.Flags;

fn parity(v: u8) bool {
    return @popCount(v) % 2 == 0;
}

fn xy(v: u8) struct { x: bool, y: bool } {
    return .{ .x = v & 0x08 != 0, .y = v & 0x20 != 0 };
}

/// ADD/ADC A,x and the identical 16-bit half-add ADD/ADC HL,rr use on their
/// low and high bytes.
pub fn add(c: *Cpu, x: u8, y: u8, carry_in: bool) u8 {
    const full: u16 = @as(u16, x) + y + @intFromBool(carry_in);
    const z: u8 = @truncate(full);
    const v = xy(z);
    c.f = .{
        .c = full & 0x100 != 0,
        .n = false,
        .pv = (~(x ^ y) & (x ^ z)) & 0x80 != 0,
        .x = v.x,
        .h = (x ^ y ^ z) & 0x10 != 0,
        .y = v.y,
        .z = z == 0,
        .s = z & 0x80 != 0,
    };
    c.q = c.f.toInt() != 0;
    return z;
}

/// SUB/SBC A,x (also CP's core — see `cp`) and the 16-bit half-subtract
/// SBC HL,rr uses on its low and high bytes.
pub fn sub(c: *Cpu, x: u8, y: u8, carry_in: bool) u8 {
    const full: u16 = @as(u16, x) -% y -% @intFromBool(carry_in);
    const z: u8 = @truncate(full);
    const v = xy(z);
    c.f = .{
        .c = full & 0x100 != 0,
        .n = true,
        .pv = ((x ^ y) & (x ^ z)) & 0x80 != 0,
        .x = v.x,
        .h = (x ^ y ^ z) & 0x10 != 0,
        .y = v.y,
        .z = z == 0,
        .s = z & 0x80 != 0,
    };
    c.q = c.f.toInt() != 0;
    return z;
}

/// CP A,x: a SUB whose result is discarded, with X/Y taken from the
/// *operand* rather than the discarded result — every other flag matches
/// a real subtraction.
pub fn cp(c: *Cpu, x: u8, y: u8) void {
    _ = sub(c, x, y, false);
    const v = xy(y);
    c.f.x = v.x;
    c.f.y = v.y;
    c.q = c.f.toInt() != 0;
}

/// AND/OR/XOR's shared flag tail: C=0, N=0, P/V=parity; only H differs
/// (set for AND, clear for OR/XOR).
fn logicFlags(c: *Cpu, z: u8, h: bool) void {
    const v = xy(z);
    c.f = .{ .c = false, .n = false, .pv = parity(z), .x = v.x, .h = h, .y = v.y, .z = z == 0, .s = z & 0x80 != 0 };
    c.q = c.f.toInt() != 0;
}

pub fn andOp(c: *Cpu, x: u8, y: u8) u8 {
    const z = x & y;
    logicFlags(c, z, true);
    return z;
}

pub fn orOp(c: *Cpu, x: u8, y: u8) u8 {
    const z = x | y;
    logicFlags(c, z, false);
    return z;
}

pub fn xorOp(c: *Cpu, x: u8, y: u8) u8 {
    const z = x ^ y;
    logicFlags(c, z, false);
    return z;
}

pub fn inc(c: *Cpu, x: u8) u8 {
    const z = x +% 1;
    const v = xy(z);
    c.f.n = false;
    c.f.pv = z == 0x80;
    c.f.x = v.x;
    c.f.h = z & 0x0F == 0x00;
    c.f.y = v.y;
    c.f.z = z == 0;
    c.f.s = z & 0x80 != 0;
    c.q = c.f.toInt() != 0;
    return z;
}

pub fn dec(c: *Cpu, x: u8) u8 {
    const z = x -% 1;
    const v = xy(z);
    c.f.n = true;
    c.f.pv = z == 0x7F;
    c.f.x = v.x;
    c.f.h = z & 0x0F == 0x0F;
    c.f.y = v.y;
    c.f.z = z == 0;
    c.f.s = z & 0x80 != 0;
    c.q = c.f.toInt() != 0;
    return z;
}

/// Common tail for the rotate/shift family: full flag set from the result,
/// H=N=0, P/V=parity. Shared by both the CB-prefixed r/(HL)/(IX+d) forms and
/// the undocumented DDCB/FDCB copy-back forms — never by RLCA/RLA/RRCA/RRA,
/// which only touch C/H/N/X/Y and leave S/Z/P/V alone.
fn rotFlags(c: *Cpu, z: u8, carry_out: bool) void {
    const v = xy(z);
    c.f = .{ .c = carry_out, .n = false, .pv = parity(z), .x = v.x, .h = false, .y = v.y, .z = z == 0, .s = z & 0x80 != 0 };
    c.q = c.f.toInt() != 0;
}

pub fn rlc(c: *Cpu, x: u8) u8 {
    const z = (x << 1) | (x >> 7);
    rotFlags(c, z, x & 0x80 != 0);
    return z;
}
pub fn rrc(c: *Cpu, x: u8) u8 {
    const z = (x >> 1) | (x << 7);
    rotFlags(c, z, x & 0x01 != 0);
    return z;
}
pub fn rl(c: *Cpu, x: u8) u8 {
    const z = (x << 1) | @intFromBool(c.f.c);
    rotFlags(c, z, x & 0x80 != 0);
    return z;
}
pub fn rr(c: *Cpu, x: u8) u8 {
    const z = (x >> 1) | (@as(u8, @intFromBool(c.f.c)) << 7);
    rotFlags(c, z, x & 0x01 != 0);
    return z;
}
pub fn sla(c: *Cpu, x: u8) u8 {
    const z = x << 1;
    rotFlags(c, z, x & 0x80 != 0);
    return z;
}
pub fn sra(c: *Cpu, x: u8) u8 {
    const z = (x >> 1) | (x & 0x80);
    rotFlags(c, z, x & 0x01 != 0);
    return z;
}
/// Undocumented: shifts in a 1 at bit 0 rather than a 0. Real silicon.
pub fn sll(c: *Cpu, x: u8) u8 {
    const z = (x << 1) | 1;
    rotFlags(c, z, x & 0x80 != 0);
    return z;
}
pub fn srl(c: *Cpu, x: u8) u8 {
    const z = x >> 1;
    rotFlags(c, z, x & 0x01 != 0);
    return z;
}

/// RLCA/RLA/RRCA/RRA: only C/H/N/X/Y change, S/Z/P/V carry over untouched.
pub fn rlca(c: *Cpu, a: u8) u8 {
    const z = (a << 1) | (a >> 7);
    accumRotFlags(c, z, a & 0x80 != 0);
    return z;
}
pub fn rrca(c: *Cpu, a: u8) u8 {
    const z = (a >> 1) | (a << 7);
    accumRotFlags(c, z, a & 0x01 != 0);
    return z;
}
pub fn rla(c: *Cpu, a: u8) u8 {
    const z = (a << 1) | @intFromBool(c.f.c);
    accumRotFlags(c, z, a & 0x80 != 0);
    return z;
}
pub fn rra(c: *Cpu, a: u8) u8 {
    const z = (a >> 1) | (@as(u8, @intFromBool(c.f.c)) << 7);
    accumRotFlags(c, z, a & 0x01 != 0);
    return z;
}
fn accumRotFlags(c: *Cpu, z: u8, carry_out: bool) void {
    const v = xy(z);
    c.f.c = carry_out;
    c.f.n = false;
    c.f.h = false;
    c.f.x = v.x;
    c.f.y = v.y;
    c.q = c.f.toInt() != 0;
}

/// ADD HL,rr / ADD IX,rr: only C/H/N/X/Y change, S/Z/P/V carry over untouched.
/// Callers run this once per byte (low then high, carry chained through
/// `add`) and must restore S/Z/P/V themselves — see `core.zig`.
pub fn add16(c: *Cpu, x: u16, y: u16) u16 {
    const s = c.f.s;
    const z = c.f.z;
    const p = c.f.pv;
    const lo = add(c, @truncate(x), @truncate(y), false);
    const hi = add(c, @truncate(x >> 8), @truncate(y >> 8), c.f.c);
    c.f.s = s;
    c.f.z = z;
    c.f.pv = p;
    c.q = c.f.toInt() != 0; // S/Z/P/V above post-date `add`'s own Q write
    return @as(u16, hi) << 8 | lo;
}

/// ADC HL,rr / SBC HL,rr (ED-prefixed): full flag set, unlike ADD HL,rr.
pub fn adc16(c: *Cpu, x: u16, y: u16) u16 {
    const lo = add(c, @truncate(x), @truncate(y), c.f.c);
    const hi = add(c, @truncate(x >> 8), @truncate(y >> 8), c.f.c);
    const z: u16 = @as(u16, hi) << 8 | lo;
    c.f.z = z == 0;
    c.q = c.f.toInt() != 0; // Z above post-dates `add`'s own Q write
    return z;
}
pub fn sbc16(c: *Cpu, x: u16, y: u16) u16 {
    const lo = sub(c, @truncate(x), @truncate(y), c.f.c);
    const hi = sub(c, @truncate(x >> 8), @truncate(y >> 8), c.f.c);
    const z: u16 = @as(u16, hi) << 8 | lo;
    c.f.z = z == 0;
    c.q = c.f.toInt() != 0; // Z above post-dates `sub`'s own Q write
    return z;
}

/// RLD/RRD's shared tail: A's new value sets S/Z/P/V/X/Y, H=N=0, C untouched.
pub fn rotDigitFlags(c: *Cpu, a: u8) void {
    const v = xy(a);
    c.f.n = false;
    c.f.pv = parity(a);
    c.f.x = v.x;
    c.f.h = false;
    c.f.y = v.y;
    c.f.z = a == 0;
    c.f.s = a & 0x80 != 0;
    c.q = c.f.toInt() != 0;
}

pub fn cpl(c: *Cpu, a: u8) u8 {
    const z = ~a;
    const v = xy(z);
    c.f.n = true;
    c.f.x = v.x;
    c.f.h = true;
    c.f.y = v.y;
    c.q = c.f.toInt() != 0;
    return z;
}

pub fn daa(c: *Cpu, a_in: u8) u8 {
    var a = a_in;
    if (c.f.c or a > 0x99) {
        a = if (c.f.n) a -% 0x60 else a +% 0x60;
        c.f.c = true;
    }
    if (c.f.h or (a_in & 0x0F) > 0x09) {
        a = if (c.f.n) a -% 0x06 else a +% 0x06;
    }
    const v = xy(a);
    c.f.pv = parity(a);
    c.f.x = v.x;
    c.f.h = (a ^ a_in) & 0x10 != 0;
    c.f.y = v.y;
    c.f.z = a == 0;
    c.f.s = a & 0x80 != 0;
    c.q = c.f.toInt() != 0;
    return a;
}

/// BIT n,x. `xy_source` is the tested register for `BIT n,r`/`BIT n,(HL)`,
/// or MEMPTR's high byte for the indexed `BIT n,(IX+d)`/`(IY+d)` forms —
/// real silicon leaks the never-latched address high byte onto the bus
/// instead of the operand there.
pub fn bit(c: *Cpu, n: u3, x: u8, xy_source: u8) void {
    const z = x & (@as(u8, 1) << n);
    const v = xy(xy_source);
    c.f.n = false;
    c.f.pv = z == 0;
    c.f.x = v.x;
    c.f.h = true;
    c.f.y = v.y;
    c.f.z = z == 0;
    c.f.s = n == 7 and z != 0;
    c.q = c.f.toInt() != 0;
}

/// SCF/CCF's undocumented X/Y: OR'd onto the *current* X/Y when the previous
/// instruction wrote F (`q_before` is true), or replacing them outright
/// otherwise — see cpu.zig's doc comment on `q` for why. `q_before` must be
/// `c.q` as it stood *before* this instruction's dispatch touched it, since
/// `core.zig` defaults `c.q` to false for every instruction up front.
fn scfCcfXY(c: *Cpu, a: u8, q_before: bool) void {
    if (q_before) {
        c.f.x = false;
        c.f.y = false;
    }
    c.f.x = c.f.x or (a & 0x08 != 0);
    c.f.y = c.f.y or (a & 0x20 != 0);
}

pub fn scf(c: *Cpu, a: u8, q_before: bool) void {
    scfCcfXY(c, a, q_before);
    c.f.c = true;
    c.f.n = false;
    c.f.h = false;
    c.q = c.f.toInt() != 0;
}

pub fn ccf(c: *Cpu, a: u8, q_before: bool) void {
    scfCcfXY(c, a, q_before);
    c.f.h = c.f.c;
    c.f.c = !c.f.c;
    c.f.n = false;
    c.q = c.f.toInt() != 0;
}

/// LD A,I / LD A,R: N=0, H=0, P/V=IFF2 (a documented way to read the
/// interrupt-enable state), S/Z/X/Y from the loaded value.
pub fn ldAIR(c: *Cpu, v: u8) void {
    const xyv = xy(v);
    c.f.n = false;
    c.f.pv = c.iff2;
    c.f.x = xyv.x;
    c.f.h = false;
    c.f.y = xyv.y;
    c.f.z = v == 0;
    c.f.s = v & 0x80 != 0;
    c.q = c.f.toInt() != 0;
}

/// IN r,(C) (and the undocumented `IN F,(C)` / `IN (C)` that discard the
/// byte): C=unaffected, N=H=0, P/V=parity, S/Z/X/Y from the byte read.
pub fn in(c: *Cpu, v: u8) void {
    const vv = xy(v);
    c.f.n = false;
    c.f.pv = parity(v);
    c.f.x = vv.x;
    c.f.h = false;
    c.f.y = vv.y;
    c.f.z = v == 0;
    c.f.s = v & 0x80 != 0;
    c.q = c.f.toInt() != 0;
}

const testing = @import("std").testing;

test "add sets carry, half-carry and overflow" {
    var c = Cpu{};
    const z = add(&c, 0xFF, 0x01, false);
    try testing.expectEqual(@as(u8, 0), z);
    try testing.expect(c.f.c);
    try testing.expect(c.f.h);
    try testing.expect(c.f.z);
    try testing.expect(!c.f.pv);
}

test "cp takes X/Y from the operand, not the discarded result" {
    var c = Cpu{ .a = 0x28 };
    cp(&c, 0x28, 0x28); // equal operands: result is 0, but operand has bits 3/5 set
    try testing.expect(c.f.x);
    try testing.expect(c.f.y);
    try testing.expect(c.f.z);
}

test "add16 preserves S/Z/P/V across the two ADD-derived bytes" {
    var c = Cpu{};
    c.f.s = true;
    c.f.pv = true;
    const z = add16(&c, 0x0FFF, 0x0001);
    try testing.expectEqual(@as(u16, 0x1000), z);
    try testing.expect(c.f.h); // carry out of bit 11
    try testing.expect(c.f.s); // untouched, still whatever it was
    try testing.expect(c.f.pv);
}

test "scf ORs X/Y onto A's bits when Q was set, replaces them when it wasn't" {
    var c = Cpu{ .a = 0x28 };
    c.f.x = false;
    c.f.y = false;
    scf(&c, c.a, false);
    try testing.expect(c.f.x);
    try testing.expect(c.f.y);
    try testing.expect(c.f.c);
}

test "daa corrects a BCD addition" {
    var c = Cpu{};
    _ = add(&c, 0x15, 0x27, false); // 15 + 27 (BCD) = 0x3C raw
    const z = daa(&c, 0x3C);
    try testing.expectEqual(@as(u8, 0x42), z);
}
