//! Z80 fetch/decode/execute and interrupt handling.
//!
//! Bus contract (any `BusT`, mirroring `m68k.Core`'s host-supplied-bus
//! shape): `z80Read8`, `z80Write8`, `z80In`, `z80Out`, each `fn (*BusT, u16)
//! u8` / `fn (*BusT, u16, u8) void` as appropriate.
//!
//! `step` runs exactly one instruction (or one HALT-idle cycle) and returns;
//! callers own the interrupt/scheduling loop and call `interrupt` between
//! instructions. Cycle costs are the standard published Z80 T-state table;
//! see the SingleStepTests conformance suite (`test/z80_sst_test.zig`) for
//! how they're checked.

const cpu_mod = @import("cpu.zig");
const decode = @import("decode.zig");
const flags = @import("flags.zig");

pub const Cpu = cpu_mod.Cpu;
pub const Interrupt = cpu_mod.Interrupt;
const Im = cpu_mod.Im;
const Reg8 = decode.Reg8;
const Reg16 = decode.Reg16;
const Reg16Alt = decode.Reg16Alt;

/// Which index register (if any) the current instruction's DD/FD prefix
/// substitutes for HL. `hl_ind` (register-table index 6) always still means
/// literal `(HL)` under `.none` and indexed `(IX+d)`/`(IY+d)` otherwise.
const Prefix = enum { none, ix, iy };

pub fn Core(comptime Bus: type) type {
    return struct {
        /// RESET pin semantics (not power-on): PC/I/R/IFF1/IFF2/IM clear and
        /// the halt latch drops, but general registers keep whatever they
        /// held — real silicon doesn't touch them, and the Genesis only ever
        /// drives this pin, never power-cycles the chip.
        pub fn reset(c: *Cpu) void {
            c.pc = 0;
            c.i = 0;
            c.r = 0;
            c.iff1 = false;
            c.iff2 = false;
            c.im = .im0;
            c.wz = 0;
            c.halted = false;
            c.ei_delay = false;
            c.q = false;
        }

        pub fn step(c: *Cpu, bus: *Bus) void {
            if (c.halted) {
                // The CPU keeps fetching and discarding NOPs while halted,
                // one M1 cycle (and one refresh bump) at a time.
                c.cycles += 4;
                c.bumpR();
                return;
            }
            c.ei_delay = false;
            const q_before = c.q; // SCF/CCF need the *previous* instruction's Q
            c.q = false;
            execute(c, bus, q_before);
        }

        /// Samples NMI (edge, so the caller must not keep `req.nmi` asserted
        /// across calls) ahead of INT (level, gated on IFF1 and the
        /// one-instruction EI delay). Returns whether either fired.
        pub fn interrupt(c: *Cpu, bus: *Bus, req: Interrupt) bool {
            if (req.nmi) {
                c.halted = false;
                c.bumpR();
                push16(c, bus, c.pc);
                c.wz = 0x0066;
                c.pc = c.wz;
                c.iff1 = false;
                c.q = false;
                c.cycles += 11;
                return true;
            }
            if (req.int and c.iff1 and !c.ei_delay) {
                c.halted = false;
                c.bumpR();
                c.iff1 = false;
                c.iff2 = false;
                c.q = false;
                switch (c.im) {
                    // The Genesis has no IM0 device to place a real opcode on
                    // the data bus (games always select IM1), so this folds
                    // to the same handler as IM1 rather than modeling an
                    // arbitrary bus-supplied instruction nothing ever sends.
                    .im0, .im1 => {
                        c.wz = 0x0038;
                        c.cycles += 13;
                        push16(c, bus, c.pc);
                        c.pc = c.wz;
                    },
                    .im2 => {
                        const addr: u16 = @as(u16, c.i) << 8 | req.data;
                        const lo = read8(c, bus, addr);
                        const hi = read8(c, bus, addr +% 1);
                        c.wz = @as(u16, hi) << 8 | lo;
                        c.cycles += 19 - 6; // read8 already billed the 3+3
                        push16(c, bus, c.pc);
                        c.pc = c.wz;
                    },
                }
                return true;
            }
            return false;
        }

        // ----------------------------------------------------------- bus

        fn read8(c: *Cpu, bus: *Bus, addr: u16) u8 {
            c.cycles += 3;
            return bus.z80Read8(addr);
        }
        fn write8(c: *Cpu, bus: *Bus, addr: u16, v: u8) void {
            c.cycles += 3;
            bus.z80Write8(addr, v);
        }
        fn ioIn(c: *Cpu, bus: *Bus, port: u16) u8 {
            c.cycles += 4;
            return bus.z80In(port);
        }
        fn ioOut(c: *Cpu, bus: *Bus, port: u16, v: u8) void {
            c.cycles += 4;
            bus.z80Out(port, v);
        }
        /// An M1 (opcode fetch) cycle: 4T, and it's the only kind of memory
        /// access that advances the refresh counter.
        fn fetchOpcode(c: *Cpu, bus: *Bus) u8 {
            c.cycles += 4;
            c.bumpR();
            const v = bus.z80Read8(c.pc);
            c.pc +%= 1;
            return v;
        }
        /// A non-M1 PC-relative read (immediate operand, displacement, or
        /// the DDCB/FDCB "pseudo opcode" byte): 3T, no refresh bump.
        fn fetchOperand(c: *Cpu, bus: *Bus) u8 {
            c.cycles += 3;
            const v = bus.z80Read8(c.pc);
            c.pc +%= 1;
            return v;
        }
        fn fetchOperand16(c: *Cpu, bus: *Bus) u16 {
            const lo = fetchOperand(c, bus);
            const hi = fetchOperand(c, bus);
            return @as(u16, hi) << 8 | lo;
        }
        fn push16(c: *Cpu, bus: *Bus, v: u16) void {
            c.sp -%= 1;
            write8(c, bus, c.sp, @truncate(v >> 8));
            c.sp -%= 1;
            write8(c, bus, c.sp, @truncate(v));
        }
        fn pop16(c: *Cpu, bus: *Bus) u16 {
            const lo = read8(c, bus, c.sp);
            c.sp +%= 1;
            const hi = read8(c, bus, c.sp);
            c.sp +%= 1;
            return @as(u16, hi) << 8 | lo;
        }

        // ------------------------------------------------------ registers

        fn ixiy(c: *Cpu, prefix: Prefix) u16 {
            return switch (prefix) {
                .none => unreachable,
                .ix => c.ix,
                .iy => c.iy,
            };
        }
        fn setIxiy(c: *Cpu, prefix: Prefix, v: u16) void {
            switch (prefix) {
                .none => unreachable,
                .ix => c.ix = v,
                .iy => c.iy = v,
            }
        }

        /// `(IX+d)`/`(IY+d)`: consumes the displacement byte and the
        /// standard 5T address-compute stall, and latches WZ. Only valid
        /// when `prefix != .none`.
        fn indexedAddr(c: *Cpu, bus: *Bus, prefix: Prefix) u16 {
            const d: i8 = @bitCast(fetchOperand(c, bus));
            c.cycles += 5;
            const addr = ixiy(c, prefix) +% @as(u16, @bitCast(@as(i16, d)));
            c.wz = addr;
            return addr;
        }
        /// The `LD (IX+d),n` special case: its stall overlaps the trailing
        /// `n` fetch, so the total is 2T shorter than every other indexed op.
        fn indexedAddrOverlap(c: *Cpu, bus: *Bus, prefix: Prefix) u16 {
            const d: i8 = @bitCast(fetchOperand(c, bus));
            c.cycles += 2;
            const addr = ixiy(c, prefix) +% @as(u16, @bitCast(@as(i16, d)));
            c.wz = addr;
            return addr;
        }

        /// Register-table read for indices 0..5,7 (never 6 — `(HL)` has no
        /// single-byte-register meaning and must be special-cased by the
        /// caller, since only it knows whether a sibling operand in the same
        /// instruction is *also* index 6, which suppresses H/L substitution
        /// project-wide for that one instruction — see `ld_r_r` below).
        fn reg8(c: *Cpu, prefix: Prefix, idx: Reg8) u8 {
            return switch (idx) {
                .b => c.b,
                .c => c.c,
                .d => c.d,
                .e => c.e,
                .h => if (prefix == .none) c.h else @as(u8, @truncate(ixiy(c, prefix) >> 8)),
                .l => if (prefix == .none) c.l else @as(u8, @truncate(ixiy(c, prefix))),
                .a => c.a,
                .hl_ind => unreachable,
            };
        }
        fn setReg8(c: *Cpu, prefix: Prefix, idx: Reg8, v: u8) void {
            switch (idx) {
                .b => c.b = v,
                .c => c.c = v,
                .d => c.d = v,
                .e => c.e = v,
                .h => if (prefix == .none) {
                    c.h = v;
                } else {
                    setIxiy(c, prefix, (ixiy(c, prefix) & 0x00FF) | (@as(u16, v) << 8));
                },
                .l => if (prefix == .none) {
                    c.l = v;
                } else {
                    setIxiy(c, prefix, (ixiy(c, prefix) & 0xFF00) | v);
                },
                .a => c.a = v,
                .hl_ind => unreachable,
            }
        }

        fn reg16(c: *Cpu, prefix: Prefix, idx: Reg16) u16 {
            return switch (idx) {
                .bc => c.bc(),
                .de => c.de(),
                .hl => if (prefix == .none) c.hl() else ixiy(c, prefix),
                .sp => c.sp,
            };
        }
        fn setReg16(c: *Cpu, prefix: Prefix, idx: Reg16, v: u16) void {
            switch (idx) {
                .bc => c.setBc(v),
                .de => c.setDe(v),
                .hl => if (prefix == .none) c.setHl(v) else setIxiy(c, prefix, v),
                .sp => c.sp = v,
            }
        }
        fn reg16Alt(c: *Cpu, prefix: Prefix, idx: Reg16Alt) u16 {
            return switch (idx) {
                .bc => c.bc(),
                .de => c.de(),
                .hl => if (prefix == .none) c.hl() else ixiy(c, prefix),
                .af => c.af(),
            };
        }
        fn setReg16Alt(c: *Cpu, prefix: Prefix, idx: Reg16Alt, v: u16) void {
            switch (idx) {
                .bc => c.setBc(v),
                .de => c.setDe(v),
                .hl => if (prefix == .none) c.setHl(v) else setIxiy(c, prefix, v),
                .af => c.setAf(v),
            }
        }

        // ------------------------------------------------------- dispatch

        /// Collapses redundant/legal DD/FD prefix chains, dispatches to the
        /// CB/ED sub-tables or the base table, and restores `prefix` to
        /// `.none` for the next instruction.
        fn execute(c: *Cpu, bus: *Bus, q_before: bool) void {
            var prefix: Prefix = .none;
            var code = fetchOpcode(c, bus);
            while (code == 0xDD or code == 0xFD) {
                prefix = if (code == 0xDD) .ix else .iy;
                code = fetchOpcode(c, bus);
            }

            if (code == 0xCB and prefix != .none) {
                // DD/FD CB d op: unlike every other indexed form, the 5T
                // address-compute stall does not follow the displacement
                // byte here — only a 2T stall after the pseudo-opcode byte.
                const d: i8 = @bitCast(fetchOperand(c, bus));
                const addr = ixiy(c, prefix) +% @as(u16, @bitCast(@as(i16, d)));
                c.wz = addr;
                const inner = fetchOperand(c, bus); // "pseudo opcode": no R bump
                c.cycles += 2;
                execCBIndexed(c, bus, addr, inner);
            } else if (code == 0xCB) {
                const inner = fetchOpcode(c, bus);
                execCB(c, bus, inner);
            } else if (code == 0xED) {
                const inner = fetchOpcode(c, bus);
                execED(c, bus, inner);
            } else {
                execBase(c, bus, prefix, code, q_before);
            }
        }

        fn alu(c: *Cpu, op: decode.AluOp, x: u8, y: u8) u8 {
            return switch (op) {
                .add => flags.add(c, x, y, false),
                .adc => flags.add(c, x, y, c.f.c),
                .sub => flags.sub(c, x, y, false),
                .sbc => flags.sub(c, x, y, c.f.c),
                .and_ => flags.andOp(c, x, y),
                .xor => flags.xorOp(c, x, y),
                .or_ => flags.orOp(c, x, y),
                .cp => blk: {
                    flags.cp(c, x, y);
                    break :blk x;
                },
            };
        }
        fn rot(c: *Cpu, op: decode.RotOp, x: u8) u8 {
            return switch (op) {
                .rlc => flags.rlc(c, x),
                .rrc => flags.rrc(c, x),
                .rl => flags.rl(c, x),
                .rr => flags.rr(c, x),
                .sla => flags.sla(c, x),
                .sra => flags.sra(c, x),
                .sll => flags.sll(c, x),
                .srl => flags.srl(c, x),
            };
        }

        /// The unprefixed table (x=0..3), also entered — with `prefix` set —
        /// for every DD/FD-prefixed opcode outside CB/ED, since the base
        /// table already handles the r[y]/r[z]/rp[p] substitution.
        fn execBase(c: *Cpu, bus: *Bus, prefix: Prefix, code: u8, q_before: bool) void {
            const f = decode.decompose(code);
            switch (f.x) {
                0 => execX0(c, bus, prefix, f, q_before),
                1 => execLdRR(c, bus, prefix, f),
                2 => {
                    const op: decode.AluOp = @enumFromInt(f.y);
                    const y = operand8(c, bus, prefix, @enumFromInt(f.z));
                    c.a = alu(c, op, c.a, y);
                },
                3 => execX3(c, bus, prefix, f),
            }
        }

        /// Reads r[z]: a plain register, or `(HL)`/`(IX+d)`/`(IY+d)` (billed
        /// its own 3T/19T access cost) when z selects index 6.
        fn operand8(c: *Cpu, bus: *Bus, prefix: Prefix, idx: Reg8) u8 {
            if (idx == .hl_ind) {
                const addr = if (prefix == .none) c.hl() else indexedAddr(c, bus, prefix);
                return read8(c, bus, addr);
            }
            return reg8(c, prefix, idx);
        }

        fn execX0(c: *Cpu, bus: *Bus, prefix: Prefix, f: decode.Fields, q_before: bool) void {
            switch (f.z) {
                0 => switch (f.y) {
                    0 => {}, // NOP
                    1 => { // EX AF,AF'
                        const t = c.af();
                        c.setAf(c.af_);
                        c.af_ = t;
                    },
                    2 => { // DJNZ d
                        c.cycles += 1;
                        const d: i8 = @bitCast(fetchOperand(c, bus));
                        c.b -%= 1;
                        if (c.b != 0) {
                            c.cycles += 5;
                            c.pc +%= @bitCast(@as(i16, d));
                            c.wz = c.pc;
                        }
                    },
                    3 => jr(c, bus, true), // JR d
                    else => jr(c, bus, decode.testCond(@enumFromInt(f.y - 4), c.f)),
                },
                1 => if (f.q == 0) { // LD rp[p],nn
                    setReg16(c, prefix, @enumFromInt(f.p), fetchOperand16(c, bus));
                } else { // ADD HL,rp[p]
                    const x = reg16(c, prefix, .hl);
                    const y = reg16(c, prefix, @enumFromInt(f.p));
                    c.wz = x +% 1;
                    c.cycles += 7;
                    setReg16(c, prefix, .hl, flags.add16(c, x, y));
                },
                2 => execIndirect16(c, bus, prefix, f),
                3 => { // INC/DEC rp[p]
                    c.cycles += 2;
                    const idx: Reg16 = @enumFromInt(f.p);
                    const v = reg16(c, prefix, idx);
                    setReg16(c, prefix, idx, if (f.q == 0) v +% 1 else v -% 1);
                },
                4 => { // INC r[y]
                    const idx: Reg8 = @enumFromInt(f.y);
                    if (idx == .hl_ind) rmw(c, bus, prefix, flags.inc) else setReg8(c, prefix, idx, flags.inc(c, reg8(c, prefix, idx)));
                },
                5 => { // DEC r[y]
                    const idx: Reg8 = @enumFromInt(f.y);
                    if (idx == .hl_ind) rmw(c, bus, prefix, flags.dec) else setReg8(c, prefix, idx, flags.dec(c, reg8(c, prefix, idx)));
                },
                6 => { // LD r[y],n
                    const idx: Reg8 = @enumFromInt(f.y);
                    if (idx == .hl_ind) {
                        const addr = if (prefix == .none) c.hl() else indexedAddrOverlap(c, bus, prefix);
                        const n = fetchOperand(c, bus);
                        write8(c, bus, addr, n);
                    } else setReg8(c, prefix, idx, fetchOperand(c, bus));
                },
                // A DD/FD prefix that turns out not to touch IX/IY (as here:
                // SCF/CCF never do) still behaves, for this undocumented
                // X/Y-flag formula, as if it reset Q to false first.
                7 => execAccum(c, f.y, q_before and prefix == .none),
            }
        }

        /// INC/DEC (HL)/(IX+d): read, apply `op` (billing its own flags),
        /// wait 1T, write back.
        fn rmw(c: *Cpu, bus: *Bus, prefix: Prefix, op: fn (*Cpu, u8) u8) void {
            const addr = if (prefix == .none) c.hl() else indexedAddr(c, bus, prefix);
            const v = op(c, read8(c, bus, addr));
            c.cycles += 1;
            write8(c, bus, addr, v);
        }

        fn jr(c: *Cpu, bus: *Bus, taken: bool) void {
            const d: i8 = @bitCast(fetchOperand(c, bus));
            if (taken) {
                c.cycles += 5;
                c.pc +%= @bitCast(@as(i16, d));
                c.wz = c.pc;
            }
        }

        fn execIndirect16(c: *Cpu, bus: *Bus, prefix: Prefix, f: decode.Fields) void {
            if (f.q == 0) switch (f.p) {
                0 => { // LD (BC),A
                    write8(c, bus, c.bc(), c.a);
                    c.wz = (@as(u16, c.a) << 8) | ((c.bc() +% 1) & 0xFF);
                },
                1 => { // LD (DE),A
                    write8(c, bus, c.de(), c.a);
                    c.wz = (@as(u16, c.a) << 8) | ((c.de() +% 1) & 0xFF);
                },
                2 => { // LD (nn),HL
                    const addr = fetchOperand16(c, bus);
                    const v = reg16(c, prefix, .hl);
                    write8(c, bus, addr, @truncate(v));
                    write8(c, bus, addr +% 1, @truncate(v >> 8));
                    c.wz = addr +% 1;
                },
                3 => { // LD (nn),A
                    const addr = fetchOperand16(c, bus);
                    write8(c, bus, addr, c.a);
                    c.wz = (@as(u16, c.a) << 8) | ((addr +% 1) & 0xFF);
                },
            } else switch (f.p) {
                0 => { // LD A,(BC)
                    c.wz = c.bc() +% 1;
                    c.a = read8(c, bus, c.bc());
                },
                1 => { // LD A,(DE)
                    c.wz = c.de() +% 1;
                    c.a = read8(c, bus, c.de());
                },
                2 => { // LD HL,(nn)
                    const addr = fetchOperand16(c, bus);
                    const lo = read8(c, bus, addr);
                    const hi = read8(c, bus, addr +% 1);
                    setReg16(c, prefix, .hl, @as(u16, hi) << 8 | lo);
                    c.wz = addr +% 1;
                },
                3 => { // LD A,(nn)
                    const addr = fetchOperand16(c, bus);
                    c.a = read8(c, bus, addr);
                    c.wz = addr +% 1;
                },
            }
        }

        fn execAccum(c: *Cpu, y: u3, q_before: bool) void {
            switch (y) {
                0 => c.a = flags.rlca(c, c.a),
                1 => c.a = flags.rrca(c, c.a),
                2 => c.a = flags.rla(c, c.a),
                3 => c.a = flags.rra(c, c.a),
                4 => c.a = flags.daa(c, c.a),
                5 => c.a = flags.cpl(c, c.a),
                6 => flags.scf(c, c.a, q_before),
                7 => flags.ccf(c, c.a, q_before),
            }
        }

        /// x=1: `LD r[y],r[z]`, or HALT for the `(HL),(HL)` collision. Per
        /// real hardware, when either side is `(HL)` under a DD/FD prefix,
        /// *only* that side becomes `(IX+d)`/`(IY+d)` — the other side's H/L
        /// (if any) stays the literal register, never `IXH`/`IXL`.
        fn execLdRR(c: *Cpu, bus: *Bus, prefix: Prefix, f: decode.Fields) void {
            const y: Reg8 = @enumFromInt(f.y);
            const z: Reg8 = @enumFromInt(f.z);
            if (y == .hl_ind and z == .hl_ind) {
                c.halted = true;
                return;
            }
            if (y == .hl_ind) {
                const addr = if (prefix == .none) c.hl() else indexedAddr(c, bus, prefix);
                write8(c, bus, addr, reg8(c, .none, z));
            } else if (z == .hl_ind) {
                const addr = if (prefix == .none) c.hl() else indexedAddr(c, bus, prefix);
                setReg8(c, .none, y, read8(c, bus, addr));
            } else {
                setReg8(c, prefix, y, reg8(c, prefix, z));
            }
        }

        fn execX3(c: *Cpu, bus: *Bus, prefix: Prefix, f: decode.Fields) void {
            switch (f.z) {
                0 => { // RET cc[y]
                    c.cycles += 1;
                    if (decode.testCond(@enumFromInt(f.y), c.f)) {
                        c.wz = pop16(c, bus);
                        c.pc = c.wz;
                    }
                },
                1 => if (f.q == 0) { // POP rp2[p]
                    setReg16Alt(c, prefix, @enumFromInt(f.p), pop16(c, bus));
                } else switch (f.p) {
                    0 => { // RET
                        c.wz = pop16(c, bus);
                        c.pc = c.wz;
                    },
                    1 => { // EXX
                        swap(&c.b, &c.c, &c.bc_);
                        swap(&c.d, &c.e, &c.de_);
                        const hl = c.hl();
                        c.setHl(c.hl_);
                        c.hl_ = hl;
                    },
                    2 => c.pc = reg16(c, prefix, .hl), // JP (HL)/(IX)/(IY)
                    3 => { // LD SP,HL
                        c.cycles += 2;
                        c.sp = reg16(c, prefix, .hl);
                    },
                },
                2 => { // JP cc[y],nn
                    const addr = fetchOperand16(c, bus);
                    c.wz = addr;
                    if (decode.testCond(@enumFromInt(f.y), c.f)) c.pc = addr;
                },
                3 => switch (f.y) {
                    0 => { // JP nn
                        const addr = fetchOperand16(c, bus);
                        c.wz = addr;
                        c.pc = addr;
                    },
                    1 => unreachable, // CB: peeled off in execute()
                    2 => { // OUT (n),A
                        const n = fetchOperand(c, bus);
                        const port = (@as(u16, c.a) << 8) | n;
                        ioOut(c, bus, port, c.a);
                        const z: u8 = n +% 1; // low byte only: no carry into W
                        c.wz = (@as(u16, c.a) << 8) | z;
                    },
                    3 => { // IN A,(n)
                        const n = fetchOperand(c, bus);
                        const port = (@as(u16, c.a) << 8) | n;
                        c.a = ioIn(c, bus, port);
                        c.wz = port +% 1;
                    },
                    4 => { // EX (SP),HL/(IX)/(IY)
                        const v = reg16(c, prefix, .hl);
                        const lo = read8(c, bus, c.sp);
                        const hi = read8(c, bus, c.sp +% 1);
                        c.cycles += 1;
                        write8(c, bus, c.sp +% 1, @truncate(v >> 8));
                        write8(c, bus, c.sp, @truncate(v));
                        c.cycles += 2;
                        c.wz = @as(u16, hi) << 8 | lo;
                        setReg16(c, prefix, .hl, c.wz);
                    },
                    5 => { // EX DE,HL (never indexed: DD/FD EB behaves as plain)
                        const t = c.de();
                        c.setDe(c.hl());
                        c.setHl(t);
                    },
                    6 => { // DI
                        c.iff1 = false;
                        c.iff2 = false;
                    },
                    else => { // EI
                        c.iff1 = true;
                        c.iff2 = true;
                        c.ei_delay = true;
                    },
                },
                4 => { // CALL cc[y],nn
                    const addr = fetchOperand16(c, bus);
                    c.wz = addr;
                    if (decode.testCond(@enumFromInt(f.y), c.f)) {
                        c.cycles += 1;
                        push16(c, bus, c.pc);
                        c.pc = addr;
                    }
                },
                5 => if (f.q == 0) { // PUSH rp2[p]
                    c.cycles += 1;
                    push16(c, bus, reg16Alt(c, prefix, @enumFromInt(f.p)));
                } else if (f.p == 0) { // CALL nn
                    const addr = fetchOperand16(c, bus);
                    c.wz = addr;
                    c.cycles += 1;
                    push16(c, bus, c.pc);
                    c.pc = addr;
                } else unreachable, // DD/ED/FD: peeled off in execute()
                6 => { // alu[y] A,n
                    const op: decode.AluOp = @enumFromInt(f.y);
                    c.a = alu(c, op, c.a, fetchOperand(c, bus));
                },
                7 => { // RST y*8
                    c.cycles += 1;
                    push16(c, bus, c.pc);
                    c.wz = @as(u16, f.y) << 3;
                    c.pc = c.wz;
                },
            }
        }

        fn swap(hi: *u8, lo: *u8, shadow: *u16) void {
            const v = @as(u16, hi.*) << 8 | lo.*;
            hi.* = @truncate(shadow.* >> 8);
            lo.* = @truncate(shadow.*);
            shadow.* = v;
        }

        // -------------------------------------------------------- CB/ED

        /// Plain (unprefixed) CB: DD/FD CB always goes through
        /// `execCBIndexed` instead, since its address comes from a
        /// displacement byte rather than `(HL)`.
        fn execCB(c: *Cpu, bus: *Bus, code: u8) void {
            const f = decode.decompose(code);
            const idx: Reg8 = @enumFromInt(f.z);
            switch (f.x) {
                0 => {
                    const op: decode.RotOp = @enumFromInt(f.y);
                    if (idx == .hl_ind) rmwCB(c, bus, op) else setReg8(c, .none, idx, rot(c, op, reg8(c, .none, idx)));
                },
                1 => { // BIT y,r[z]
                    const v = operand8(c, bus, .none, idx);
                    const src = if (idx == .hl_ind) @as(u8, @truncate(c.wz >> 8)) else v;
                    flags.bit(c, @intCast(f.y), v, src);
                    if (idx == .hl_ind) c.cycles += 1;
                },
                2 => { // RES y,r[z]
                    if (idx == .hl_ind) rmwSetRes(c, bus, f.y, false) else setReg8(c, .none, idx, reg8(c, .none, idx) & ~(@as(u8, 1) << f.y));
                },
                3 => { // SET y,r[z]
                    if (idx == .hl_ind) rmwSetRes(c, bus, f.y, true) else setReg8(c, .none, idx, reg8(c, .none, idx) | (@as(u8, 1) << f.y));
                },
            }
        }

        fn rmwCB(c: *Cpu, bus: *Bus, op: decode.RotOp) void {
            const v = read8(c, bus, c.hl());
            c.cycles += 1;
            write8(c, bus, c.hl(), rot(c, op, v));
        }
        fn rmwSetRes(c: *Cpu, bus: *Bus, bitn: u3, set: bool) void {
            const v = read8(c, bus, c.hl());
            c.cycles += 1;
            write8(c, bus, c.hl(), if (set) v | (@as(u8, 1) << bitn) else v & ~(@as(u8, 1) << bitn));
        }

        /// DDCB/FDCB: the displacement byte already picked the address; the
        /// trailing z-field still names a register, which real (and this)
        /// silicon copies the memory result *back into* alongside the
        /// read-modify-write — the well-known undocumented "copy-back".
        fn execCBIndexed(c: *Cpu, bus: *Bus, addr: u16, code: u8) void {
            const f = decode.decompose(code);
            const idx: Reg8 = @enumFromInt(f.z);
            const v = read8(c, bus, addr);
            c.cycles += 1;
            if (f.x == 1) { // BIT y,(IX+d)/(IY+d): reads only, no copy-back
                flags.bit(c, @intCast(f.y), v, @truncate(c.wz >> 8));
                return;
            }
            const z = switch (f.x) {
                0 => rot(c, @enumFromInt(f.y), v),
                2 => v & ~(@as(u8, 1) << f.y), // RES y
                else => v | (@as(u8, 1) << f.y), // SET y
            };
            write8(c, bus, addr, z);
            if (idx != .hl_ind) setReg8(c, .none, idx, z);
        }

        fn execED(c: *Cpu, bus: *Bus, code: u8) void {
            const f = decode.decompose(code);
            switch (f.x) {
                1 => switch (f.z) {
                    0 => { // IN r[y],(C) / undocumented IN (C) (y=6: discard)
                        c.wz = c.bc() +% 1;
                        const v = ioIn(c, bus, c.bc());
                        flags.in(c, v);
                        const idx: Reg8 = @enumFromInt(f.y);
                        if (idx != .hl_ind) setReg8(c, .none, idx, v);
                    },
                    1 => { // OUT (C),r[y] / undocumented OUT (C),0
                        const idx: Reg8 = @enumFromInt(f.y);
                        const v: u8 = if (idx == .hl_ind) 0 else reg8(c, .none, idx);
                        ioOut(c, bus, c.bc(), v);
                        c.wz = c.bc() +% 1;
                    },
                    2 => { // SBC/ADC HL,rp[p]
                        const x = c.hl();
                        const y = reg16(c, .none, @enumFromInt(f.p));
                        c.wz = x +% 1;
                        c.cycles += 7;
                        c.setHl(if (f.q == 0) flags.sbc16(c, x, y) else flags.adc16(c, x, y));
                    },
                    3 => { // LD (nn),rp[p] / LD rp[p],(nn)
                        const addr = fetchOperand16(c, bus);
                        c.wz = addr +% 1;
                        const idx: Reg16 = @enumFromInt(f.p);
                        if (f.q == 0) {
                            const v = reg16(c, .none, idx);
                            write8(c, bus, addr, @truncate(v));
                            write8(c, bus, addr +% 1, @truncate(v >> 8));
                        } else {
                            const lo = read8(c, bus, addr);
                            const hi = read8(c, bus, addr +% 1);
                            setReg16(c, .none, idx, @as(u16, hi) << 8 | lo);
                        }
                    },
                    4 => c.a = flags.sub(c, 0, c.a, false), // NEG
                    5 => { // RETN, or RETI at y=1
                        c.wz = pop16(c, bus);
                        c.pc = c.wz;
                        c.iff1 = c.iff2;
                    },
                    6 => c.im = im_table[f.y],
                    7 => execEDMisc(c, bus, f.y),
                },
                2 => if (f.z <= 3 and f.y >= 4) execBlock(c, bus, f.y, f.z) else {}, // undefined ED: NOP
                else => {}, // undefined ED (x=0,3): NOP
            }
        }

        const im_table = [8]Im{ .im0, .im0, .im1, .im2, .im0, .im0, .im1, .im2 };

        fn execEDMisc(c: *Cpu, bus: *Bus, y: u3) void {
            switch (y) {
                0 => { // LD I,A
                    c.cycles += 1;
                    c.i = c.a;
                },
                1 => { // LD R,A
                    c.cycles += 1;
                    c.r = c.a;
                },
                2 => { // LD A,I
                    c.cycles += 1;
                    c.a = c.i;
                    flags.ldAIR(c, c.a);
                },
                3 => { // LD A,R
                    c.cycles += 1;
                    c.a = c.r;
                    flags.ldAIR(c, c.a);
                },
                4 => { // RRD
                    c.wz = c.hl() +% 1;
                    const v = read8(c, bus, c.hl());
                    c.cycles += 4;
                    write8(c, bus, c.hl(), (v >> 4) | (c.a << 4));
                    c.a = (c.a & 0xF0) | (v & 0x0F);
                    flags.rotDigitFlags(c, c.a);
                },
                5 => { // RLD
                    c.wz = c.hl() +% 1;
                    const v = read8(c, bus, c.hl());
                    c.cycles += 4;
                    write8(c, bus, c.hl(), (v << 4) | (c.a & 0x0F));
                    c.a = (c.a & 0xF0) | (v >> 4);
                    flags.rotDigitFlags(c, c.a);
                },
                else => {}, // undocumented ED 0x77/0x7F: NOP
            }
        }

        /// LDI/LDD/CPI/CPD/INI/IND/OUTI/OUTD and their repeating R-suffixed
        /// forms, selected by `y` (direction: 4=I, 5=D, 6=IR, 7=DR) and `z`
        /// (operation: 0=LD, 1=CP, 2=IN, 3=OUT).
        fn execBlock(c: *Cpu, bus: *Bus, y: u3, z: u3) void {
            const dec_dir = y == 5 or y == 7;
            const repeat = y == 6 or y == 7;
            const more = switch (z) {
                0 => blockLd(c, bus, dec_dir),
                1 => blockCp(c, bus, dec_dir),
                2 => blockIn(c, bus, dec_dir),
                else => blockOut(c, bus, dec_dir),
            };
            if (repeat and more) {
                c.cycles += 5;
                c.pc -%= 2;
                c.wz = c.pc +% 1;
                // Undocumented: on the repeat continuation the single-op
                // X/Y (bits of A+data or the block result) are overwritten
                // by bits 11/13 of the (already rewound) PC instead.
                c.f.x = c.pc & 0x0800 != 0;
                c.f.y = c.pc & 0x2000 != 0;
                if (z == 2 or z == 3) blockRepeatIoFlags(c); // INIR/INDR/OTIR/OTDR
                c.q = c.f.toInt() != 0; // X/Y/PV/H above post-date the single-op Q write
            }
        }

        /// Undocumented PV/H correction applied only on the repeat
        /// continuation of INIR/INDR/OTIR/OTDR, on top of the single-op
        /// flags `blockIoFlags` already set.
        fn blockRepeatIoFlags(c: *Cpu) void {
            if (c.f.c and c.f.n) {
                c.f.pv = c.f.pv == (@popCount((c.b -% 1) & 7) % 2 == 0);
                c.f.h = c.b & 0x0F == 0x00;
            } else if (c.f.c and !c.f.n) {
                c.f.pv = c.f.pv == (@popCount((c.b +% 1) & 7) % 2 == 0);
                c.f.h = c.b & 0x0F == 0x0F;
            } else {
                c.f.pv = c.f.pv == (@popCount(c.b & 7) % 2 == 0);
            }
        }

        fn step16(v: u16, dec_dir: bool) u16 {
            return if (dec_dir) v -% 1 else v +% 1;
        }

        fn blockLd(c: *Cpu, bus: *Bus, dec_dir: bool) bool {
            const data = read8(c, bus, c.hl());
            write8(c, bus, c.de(), data);
            c.cycles += 2;
            c.setHl(step16(c.hl(), dec_dir));
            c.setDe(step16(c.de(), dec_dir));
            c.setBc(c.bc() -% 1);
            const n = data +% c.a;
            c.f.n = false;
            c.f.h = false;
            c.f.pv = c.bc() != 0;
            c.f.x = n & 0x08 != 0;
            c.f.y = n & 0x02 != 0;
            c.q = c.f.toInt() != 0;
            return c.bc() != 0;
        }

        fn blockCp(c: *Cpu, bus: *Bus, dec_dir: bool) bool {
            const data = read8(c, bus, c.hl());
            c.cycles += 5;
            c.wz = step16(c.wz, dec_dir);
            c.setHl(step16(c.hl(), dec_dir));
            c.setBc(c.bc() -% 1);
            const full: u16 = @as(u16, c.a) -% data;
            const n8_: u8 = @truncate(full);
            const half = (c.a ^ data ^ n8_) & 0x10 != 0;
            const nn = n8_ -% @intFromBool(half);
            c.f.n = true;
            c.f.pv = c.bc() != 0;
            c.f.h = half;
            c.f.x = nn & 0x08 != 0;
            c.f.y = nn & 0x02 != 0;
            c.f.z = n8_ == 0;
            c.f.s = n8_ & 0x80 != 0;
            c.q = c.f.toInt() != 0;
            return c.bc() != 0 and !c.f.z;
        }

        fn blockIn(c: *Cpu, bus: *Bus, dec_dir: bool) bool {
            c.cycles += 1;
            c.wz = step16(c.bc(), dec_dir);
            const data = ioIn(c, bus, c.bc());
            c.b -%= 1;
            write8(c, bus, c.hl(), data);
            c.setHl(step16(c.hl(), dec_dir));
            blockIoFlags(c, data, if (dec_dir) c.c -% 1 else c.c +% 1);
            return c.b != 0;
        }

        fn blockOut(c: *Cpu, bus: *Bus, dec_dir: bool) bool {
            c.cycles += 1;
            const data = read8(c, bus, c.hl());
            c.b -%= 1;
            ioOut(c, bus, c.bc(), data);
            c.setHl(step16(c.hl(), dec_dir));
            c.wz = step16(c.bc(), dec_dir);
            blockIoFlags(c, data, c.l);
            return c.b != 0;
        }

        /// Shared IN{I,D}/OUT{I,D} flag tail: `k` is the undocumented
        /// carry-source byte (C±1 for IN, L for OUT) added to the
        /// just-transferred `data`.
        fn blockIoFlags(c: *Cpu, data: u8, k: u8) void {
            const sum: u16 = @as(u16, k) + data;
            c.f.c = sum > 0xFF;
            c.f.n = data & 0x80 != 0;
            c.f.pv = @popCount(@as(u8, @truncate(sum & 7)) ^ c.b) % 2 == 0;
            c.f.x = c.b & 0x08 != 0;
            c.f.h = c.f.c;
            c.f.y = c.b & 0x20 != 0;
            c.f.z = c.b == 0;
            c.f.s = c.b & 0x80 != 0;
            c.q = c.f.toInt() != 0;
        }
    };
}

const testing = @import("std").testing;

const TestBus = struct {
    mem: [0x10000]u8 = [_]u8{0} ** 0x10000,
    io: [0x100]u8 = [_]u8{0} ** 0x100,

    fn z80Read8(b: *TestBus, addr: u16) u8 {
        return b.mem[addr];
    }
    fn z80Write8(b: *TestBus, addr: u16, v: u8) void {
        b.mem[addr] = v;
    }
    fn z80In(b: *TestBus, port: u16) u8 {
        return b.io[@as(u8, @truncate(port))];
    }
    fn z80Out(b: *TestBus, port: u16, v: u8) void {
        b.io[@as(u8, @truncate(port))] = v;
    }
};

const TestCore = Core(TestBus);

test "NOP takes 4 T-states and advances PC by one" {
    var c = Cpu{};
    var b = TestBus{};
    b.mem[0] = 0x00;
    TestCore.step(&c, &b);
    try testing.expectEqual(@as(u16, 1), c.pc);
    try testing.expectEqual(@as(u64, 4), c.cycles);
}

test "LD BC,nn loads the immediate and costs 10 T-states" {
    var c = Cpu{};
    var b = TestBus{};
    b.mem[0] = 0x01;
    b.mem[1] = 0x34;
    b.mem[2] = 0x12;
    TestCore.step(&c, &b);
    try testing.expectEqual(@as(u16, 0x1234), c.bc());
    try testing.expectEqual(@as(u64, 10), c.cycles);
}

test "LD (IX+d),B stores the literal B register, not IXH-substituted" {
    var c = Cpu{ .ix = 0x1000, .b = 0x42 };
    var b = TestBus{};
    b.mem[0] = 0xDD;
    b.mem[1] = 0x70; // LD (IX+d),B
    b.mem[2] = 0x05;
    TestCore.step(&c, &b);
    try testing.expectEqual(@as(u8, 0x42), b.mem[0x1005]);
    try testing.expectEqual(@as(u64, 19), c.cycles);
}

test "HALT halts and each idle step still costs 4 T-states" {
    var c = Cpu{};
    var b = TestBus{};
    b.mem[0] = 0x76;
    TestCore.step(&c, &b);
    try testing.expect(c.halted);
    const cycles_after_halt = c.cycles;
    TestCore.step(&c, &b);
    try testing.expectEqual(cycles_after_halt + 4, c.cycles);
}

test "EI delays IFF1's effect on INT by exactly one instruction" {
    var c = Cpu{ .im = .im1 };
    var b = TestBus{};
    b.mem[0] = 0xFB; // EI
    b.mem[1] = 0x00; // NOP
    b.mem[2] = 0x00; // NOP
    TestCore.step(&c, &b); // EI
    try testing.expect(!TestCore.interrupt(&c, &b, .{ .int = true }));
    TestCore.step(&c, &b); // NOP right after EI: still not interruptible until it retires
    try testing.expect(TestCore.interrupt(&c, &b, .{ .int = true }));
    try testing.expectEqual(@as(u16, 0x0038), c.pc);
}

test "RST 38h pushes PC and jumps to the fixed vector" {
    var c = Cpu{ .pc = 0x1000, .sp = 0xFFFE };
    var b = TestBus{};
    b.mem[0x1000] = 0xFF; // RST 38h
    TestCore.step(&c, &b);
    try testing.expectEqual(@as(u16, 0x0038), c.pc);
    try testing.expectEqual(@as(u16, 0x1001), b.z80Read8(0xFFFC) | (@as(u16, b.z80Read8(0xFFFD)) << 8));
}
