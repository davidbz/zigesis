//! Z80 architectural state: registers, flags, interrupt latches. No bus, no
//! logic — see `core.zig` for execution and `decode.zig` for opcode tables.

const std = @import("std");

/// Bit layout of F, MSB to LSB: S Z Y H X P/V N C. Y and X are undocumented
/// copies of bits 5 and 3 of the last ALU result (or, for BIT n,(HL)/(IX+d),
/// of MEMPTR's high byte); real programs never read them, but SCF/CCF/BIT
/// timing tests do.
pub const Flags = packed struct(u8) {
    c: bool = false,
    n: bool = false,
    pv: bool = false,
    x: bool = false,
    h: bool = false,
    y: bool = false,
    z: bool = false,
    s: bool = false,

    pub fn toInt(f: Flags) u8 {
        return @bitCast(f);
    }
    pub fn fromInt(v: u8) Flags {
        return @bitCast(v);
    }
};

pub const Im = enum(u2) { im0 = 0, im1 = 1, im2 = 2 };

/// One of the two interrupting sources a host can assert; `Core.step` samples
/// both at instruction boundaries, NMI first.
pub const Interrupt = struct {
    nmi: bool = false,
    /// Level-triggered, as on real hardware: stays asserted until the host
    /// (the Genesis scheduler) clears it, typically after one instruction.
    int: bool = false,
    /// The vectoring byte an IM2 device places on the data bus; ignored in
    /// IM0/IM1. The Genesis has none, so this only matters to future callers.
    data: u8 = 0xFF,
};

pub const Cpu = struct {
    a: u8 = 0,
    f: Flags = .{},
    b: u8 = 0,
    c: u8 = 0,
    d: u8 = 0,
    e: u8 = 0,
    h: u8 = 0,
    l: u8 = 0,

    /// Shadow bank, swapped whole by EX AF,AF'/EXX: never addressed byte-wise.
    af_: u16 = 0,
    bc_: u16 = 0,
    de_: u16 = 0,
    hl_: u16 = 0,

    ix: u16 = 0,
    iy: u16 = 0,
    sp: u16 = 0,
    pc: u16 = 0,

    i: u8 = 0,
    /// 7-bit DRAM refresh counter; bit 7 is only ever set by `LD R,A`.
    r: u8 = 0,

    iff1: bool = false,
    iff2: bool = false,
    im: Im = .im0,

    /// MEMPTR/WZ: an internal latch with no programmer-visible register, but
    /// it feeds BIT n,(HL)'s undocumented flags and is checked bit-for-bit by
    /// the conformance suite.
    wz: u16 = 0,
    /// The undocumented "Q" latch: true if the immediately-preceding
    /// instruction wrote to F. SCF/CCF's undocumented X/Y bits OR into the
    /// *current* X/Y when Q is set, or replace them outright when it isn't —
    /// real silicon's ALU-output latch bleeding onto the flag bus.
    q: bool = false,

    halted: bool = false,
    cycles: u64 = 0,

    /// Set by EI, cleared at the start of the *next* instruction: the reason
    /// EI's own interrupt-enable takes effect one instruction late — `Core`
    /// checks this (not `iff1`) when deciding whether to sample INT.
    ei_delay: bool = false,

    pub fn bc(c: *const Cpu) u16 {
        return @as(u16, c.b) << 8 | c.c;
    }
    pub fn setBc(c: *Cpu, v: u16) void {
        c.b = @truncate(v >> 8);
        c.c = @truncate(v);
    }
    pub fn de(c: *const Cpu) u16 {
        return @as(u16, c.d) << 8 | c.e;
    }
    pub fn setDe(c: *Cpu, v: u16) void {
        c.d = @truncate(v >> 8);
        c.e = @truncate(v);
    }
    pub fn hl(c: *const Cpu) u16 {
        return @as(u16, c.h) << 8 | c.l;
    }
    pub fn setHl(c: *Cpu, v: u16) void {
        c.h = @truncate(v >> 8);
        c.l = @truncate(v);
    }
    pub fn af(c: *const Cpu) u16 {
        return @as(u16, c.a) << 8 | c.f.toInt();
    }
    pub fn setAf(c: *Cpu, v: u16) void {
        c.a = @truncate(v >> 8);
        c.f = Flags.fromInt(@truncate(v));
    }

    /// Advances the 7-bit refresh counter by one opcode fetch (two for a
    /// prefixed instruction — call once per M1 cycle, not once per
    /// instruction). Bit 7 is preserved.
    pub fn bumpR(c: *Cpu) void {
        c.r = (c.r & 0x80) | ((c.r +% 1) & 0x7F);
    }
};

test "register pair accessors compose big-endian halves" {
    var c = Cpu{};
    c.setBc(0x1234);
    try std.testing.expectEqual(@as(u8, 0x12), c.b);
    try std.testing.expectEqual(@as(u8, 0x34), c.c);
    try std.testing.expectEqual(@as(u16, 0x1234), c.bc());

    c.setAf(0xABCD);
    try std.testing.expectEqual(@as(u8, 0xAB), c.a);
    try std.testing.expectEqual(@as(u8, 0xCD), c.f.toInt());
}

test "bumpR wraps at 7 bits and preserves bit 7" {
    var c = Cpu{ .r = 0x7F };
    c.bumpR();
    try std.testing.expectEqual(@as(u8, 0x00), c.r);

    c.r = 0xFF;
    c.bumpR();
    try std.testing.expectEqual(@as(u8, 0x80), c.r);
}
