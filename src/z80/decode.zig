//! Z80 opcode decoding. Every unprefixed, CB, ED, DD and FD opcode fits the
//! same `xxyyyzzz` bitfield shape (Young, "Decoding Z80 Opcodes"): two bits
//! pick a broad family, three pick a register/operation within it, and the
//! low three further split into a two-bit/one-bit pair for 16-bit register
//! and ALU-family selection. Building the tables this way, rather than a
//! 256-entry-per-prefix switch, is what makes the undocumented opcodes (they
//! decode the same as the documented ones either side of them) fall out for
//! free instead of needing their own cases.

const cpu = @import("cpu.zig");
const Flags = cpu.Flags;

/// `xxyyyzzz`, plus `y` split into `ppq` for the 16-bit-register families.
pub const Fields = struct {
    x: u2,
    y: u3,
    z: u3,
    p: u2,
    q: u1,
};

pub fn decompose(op: u8) Fields {
    const y: u3 = @truncate(op >> 3);
    return .{
        .x = @truncate(op >> 6),
        .y = y,
        .z = @truncate(op),
        .p = @truncate(y >> 1),
        .q = @truncate(y),
    };
}

/// The `r[z]`/`r[y]` table. `hl_ind` is `(HL)` — or, under a DD/FD prefix,
/// `(IX+d)`/`(IY+d)` — never a register; callers must special-case it.
pub const Reg8 = enum(u3) { b, c, d, e, h, l, hl_ind, a };

/// The `rp[p]` table: general 16-bit operands (LD/INC/DEC/ADD).
pub const Reg16 = enum(u2) { bc, de, hl, sp };

/// The `rp2[p]` table: PUSH/POP and EX AF,AF' use AF where `rp` uses SP.
pub const Reg16Alt = enum(u2) { bc, de, hl, af };

/// The `cc[y]` table, restricted to y in 0..7 by construction.
pub const Cond = enum(u3) { nz, z, nc, c, po, pe, p, m };

pub fn testCond(cc: Cond, f: Flags) bool {
    return switch (cc) {
        .nz => !f.z,
        .z => f.z,
        .nc => !f.c,
        .c => f.c,
        .po => !f.pv,
        .pe => f.pv,
        .p => !f.s,
        .m => f.s,
    };
}

/// The `alu[y]` table used by both the `A,r`/`A,(HL)` form (x=2) and the
/// `A,n` immediate form (x=3, z=6).
pub const AluOp = enum(u3) { add, adc, sub, sbc, and_, xor, or_, cp };

/// The `rot[y]` table (CB prefix, x=0). `sll` ("shift logic left", sets bit 0)
/// is the one undocumented member — real silicon implements it, nothing else
/// occupies the encoding.
pub const RotOp = enum(u3) { rlc, rrc, rl, rr, sla, sra, sll, srl };

const testing = @import("std").testing;

test "decompose splits an opcode into x/y/z and y into p/q" {
    // LD (nn),HL = 0x22 = 00 100 010: x=0 y=4(p=2,q=0) z=2.
    const f = decompose(0x22);
    try testing.expectEqual(@as(u2, 0), f.x);
    try testing.expectEqual(@as(u3, 4), f.y);
    try testing.expectEqual(@as(u3, 2), f.z);
    try testing.expectEqual(@as(u2, 2), f.p);
    try testing.expectEqual(@as(u1, 0), f.q);
}

test "condition table matches the flag it names" {
    const set = Flags{ .z = true, .c = true, .s = true, .pv = true };
    try testing.expect(testCond(.z, set));
    try testing.expect(!testCond(.nz, set));
    try testing.expect(testCond(.c, set));
    try testing.expect(testCond(.pe, set));
    try testing.expect(testCond(.m, set));
    try testing.expect(!testCond(.p, set));
}
