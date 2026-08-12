//! The Sega Genesis / Mega Drive machine: cartridge ROM, 64 KiB of work RAM,
//! a controller, and the memory map and bus arbitration that ties them to
//! the CPUs and VDP. Frame timing and interrupt delivery live in
//! `scheduler.zig`; this file only answers bus reads and writes.
//!
//! Both sound chips run for real (`psg.zig` and `ym2612.zig`, stepped by
//! `scheduler.zig` into the `audio` mixer this struct owns). The Z80 runs
//! for real too, with its
//! own memory map, BUSREQ/RESET handshake, and banked window onto this same
//! 68k bus.

const std = @import("std");
const m68k = @import("m68k");
const z80 = @import("z80");
const vdp = @import("vdp");
const psg = @import("psg");
const ym2612 = @import("ym2612");
const audio = @import("audio");

pub const Cpu = m68k.Cpu;
pub const Core = m68k.Core(Genesis);
pub const Z80Cpu = z80.Cpu;
pub const Z80Core = z80.Core(Genesis);
pub const Psg = psg.Psg;
pub const Ym2612 = ym2612.Ym2612;
pub const Mixer = audio.Mixer;

// NTSC: a 53.693175 MHz master clock, seven of which make a 68000 cycle, 15
// of which make a Z80 cycle, and 3420 of which make a scanline. The line and
// frame lengths belong to the VDP, which is the chip that counts them; they
// are re-exported here because `scheduler.zig` drives the frame loop off the
// whole set.
pub const master_clock_hz = 53_693_175;
pub const mclk_per_cpu = 7;
pub const mclk_per_z80 = 15;
pub const mclk_per_line = vdp.mclk_per_line;
pub const lines_per_frame = vdp.lines_per_frame;

/// The PSG steps once per 16 Z80 clocks (DESIGN.md §3.3), so mclk/240, or
/// about 223.7 kHz — not a whole number of hertz, which is why the ratio
/// down to 48 kHz is carried as an exact fraction rather than a rate.
pub const mclk_per_psg = mclk_per_z80 * 16;
pub const psg_rate = audio.Rate{
    .out = audio.sample_rate * mclk_per_psg,
    .in = master_clock_hz,
};

/// The YM2612 is clocked at the 68000's rate and takes 144 of those clocks
/// per stereo sample (DESIGN.md §3.3), so mclk/1008, or about 53.3 kHz.
pub const mclk_per_ym = mclk_per_cpu * ym2612.clocks_per_sample;
pub const ym_rate = audio.Rate{
    .out = audio.sample_rate * mclk_per_ym,
    .in = master_clock_hz,
};

/// The YM2612's four ports, mirrored across the block the 68k decodes for it.
const ym_port_lo: u24 = 0xA0_4000;
const ym_port_hi: u24 = 0xA0_5FFF;

const ram_bytes = 64 << 10;
const zram_bytes = 8 << 10;
const ram_mask = ram_bytes - 1;
const zram_mask = zram_bytes - 1;

/// The controller's TH pin, bit 6 of both the data and control port bytes.
const th_bit: u8 = 0x40;

/// The PSG's write-only port, $C00011, and the rest of the VDP block it
/// decodes over.
const psg_port_lo: u24 = 0xC0_0010;
const psg_port_hi: u24 = 0xC0_001F;
/// The Z80's 32-byte window onto the VDP block at $C00000, which is how a
/// sound driver reaches the PSG without asking the 68k for the bus.
const z80_vdp_mask: u24 = 0x1F;

/// A DMA's source counter is 17 bits wide and the bank above it is fixed, so
/// a transfer that runs off the end of a 128 KiB bank comes back at its start.
const dma_bank_mask: u32 = 0x1_FFFF;

// Controller bits, active high here and inverted on the way out to the ROM.
pub const btn_up: u8 = 0x01;
pub const btn_down: u8 = 0x02;
pub const btn_left: u8 = 0x04;
pub const btn_right: u8 = 0x08;
pub const btn_b: u8 = 0x10;
pub const btn_c: u8 = 0x20;
pub const btn_a: u8 = 0x40;
pub const btn_start: u8 = 0x80;

pub const Genesis = struct {
    rom: []const u8,
    /// Mutable because the VDP stalls it: a full FIFO or a DMA off the 68k
    /// bus holds the CPU by pushing its cycle count forward.
    cpu: *Cpu,
    ram: [ram_bytes]u8 = @splat(0),
    zram: [zram_bytes]u8 = @splat(0),
    v: vdp.Vdp = .{},

    p: Psg = .{},
    y: Ym2612 = .{},
    audio: Mixer = .{},

    z: Z80Cpu = .{},
    /// Held true by hardware at power-on; the 68k must write $A11200 to
    /// release it before the Z80 fetches its first opcode.
    z80_reset: bool = true,
    /// True once the 68k has requested (and, in this instant-grant model,
    /// been given) the Z80's bus.
    z80_busreq: bool = false,
    /// 9-bit bank register selecting which 32 KiB of the 68k address space
    /// $8000-$FFFF of Z80 address space is a window onto. Loaded one bit at
    /// a time, LSB first, by successive writes to $6000.
    z80_bank: u9 = 0,
    /// Set for one line at VBlank, cleared once `Core.interrupt` reports the
    /// Z80 actually took it (mirrors real hardware's level-triggered IM1
    /// line closely enough for M1: no cycle-exact pulse width yet).
    z80_int_pending: bool = false,
    /// Toggles per-instruction Z80 tracing to stderr; see `scheduler.zig`.
    z80_trace: bool = false,

    buttons: u8 = 0,
    pad_ctrl: u8 = 0,
    pad_data: u8 = 0,

    frame: u32 = 0,
    line: u32 = 0,
    /// Master clock at the start of the current scanline, counted from power
    /// on and never reset: the VDP's whole notion of time is a position in
    /// this (see `now`).
    mclk: u64 = 0,
    /// CPU cycle count when the current scanline started, which is what turns
    /// the CPU's clock back into the master clock.
    line_start: u64 = 0,
    /// A scanline isn't a whole number of CPU cycles; the remainder is carried
    /// here so a frame comes out at the right length instead of 0.1% short.
    mclk_debt: u64 = 0,
    /// Same idea as `mclk_debt`, but for the Z80's /15 divider. Only accrues
    /// while the Z80 is actually free to run (see `scheduler.runZ80Line`):
    /// real hardware doesn't bank cycles while the chip is held.
    zclk_debt: u64 = 0,
    /// And again for the PSG's /240. This one is never gated: the chip is on
    /// the VDP die and keeps running whatever the Z80 is doing.
    pclk_debt: u64 = 0,
    /// And for the YM2612's /1008, which is never gated either.
    yclk_debt: u64 = 0,
    /// Cycles the 68000's last line ran past its budget, because an
    /// instruction is indivisible and the line boundary falls mid-instruction.
    /// Repaid out of the next line's budget: unrepaid, it compounds line after
    /// line and the CPU pulls ahead of the master clock by over 1%.
    cpu_over: u64 = 0,
    /// The same debt for the Z80. Its divider leaves no remainder (3420 is a
    /// whole number of /15 cycles), but its instructions still straddle the
    /// line boundary just like the 68000's.
    z80_over: u64 = 0,

    // ------------------------------------------------------------------ clock

    /// The master clock as the 68000 has run it: the line's start plus the
    /// cycles it has executed into that line.
    pub fn now(g: *const Genesis) u64 {
        return g.mclk + (g.cpu.cycles -| g.line_start) * mclk_per_cpu;
    }

    /// Holds the 68000 off until `mclk` by charging it the cycles it would
    /// have run in the meantime. `scheduler.zig`'s `cpu_over` carries the
    /// overrun into the following lines, so a stall longer than a line works
    /// out on its own.
    fn stallUntil(g: *Genesis, mclk: u64) void {
        const into_line = (mclk -| g.mclk + mclk_per_cpu - 1) / mclk_per_cpu;
        g.cpu.cycles = @max(g.cpu.cycles, g.line_start + into_line);
    }

    // -------------------------------------------------------------- memory map

    pub fn read8(g: *Genesis, addr: u24) u8 {
        return switch (addr) {
            0x00_0000...0x3F_FFFF => if (addr < g.rom.len) g.rom[addr] else 0xFF,
            0xA0_0000...0xA0_3FFF => g.zram[addr & zram_mask],
            ym_port_lo...ym_port_hi => g.y.status(),
            0xA1_0000...0xA1_001F => g.ioRead(addr),
            // Bit 0 low means the 68k has the bus; this model grants it the
            // instant it's requested, so it only ever reads busreq back.
            0xA1_1100...0xA1_11FF => if (g.z80_busreq) 0x00 else 0x01,
            0xC0_0000...0xC0_000F => @truncate(g.read16(addr & ~@as(u24, 1)) >> @intCast(8 * (~addr & 1))),
            0xE0_0000...0xFF_FFFF => g.ram[addr & ram_mask],
            else => 0xFF,
        };
    }

    pub fn read16(g: *Genesis, addr: u24) u16 {
        return switch (addr) {
            0x00_0000...0x3F_FFFF => if (addr + 1 < g.rom.len) rd16(g.rom, addr) else 0xFFFF,
            0xA0_0000...0xA0_3FFF => rd16(&g.zram, addr & zram_mask),
            0xC0_0000...0xC0_0003 => g.v.readData(),
            0xC0_0004...0xC0_0007 => g.v.readStatus(g.now()),
            0xC0_0008...0xC0_000F => g.v.hvCounter(g.now()),
            0xE0_0000...0xFF_FFFF => rd16(&g.ram, addr & ram_mask),
            // Everything else on this bus is a byte-wide device, and answers
            // a word read with the same byte in both halves.
            else => @as(u16, g.read8(addr)) << 8 | g.read8(addr),
        };
    }

    pub fn write8(g: *Genesis, addr: u24, val: u8) void {
        switch (addr) {
            0xA0_0000...0xA0_3FFF => g.zram[addr & zram_mask] = val,
            0xA1_0000...0xA1_001F => g.ioWrite(addr, val),
            ym_port_lo...ym_port_hi => g.y.write(@truncate(addr), val),
            0xA1_1100...0xA1_11FF => g.z80_busreq = val & 1 != 0,
            0xA1_1200...0xA1_12FF => g.writeZ80Reset(val),
            // A byte write to a VDP port still presents a full word, with the
            // byte in both halves.
            0xC0_0000...0xC0_000F => g.write16(addr & ~@as(u24, 1), @as(u16, val) << 8 | val),
            // The PSG hangs off the low byte of the bus only, so it hears
            // $C00011 and ignores the even address beside it.
            psg_port_lo...psg_port_hi => if (addr & 1 != 0) g.p.write(val),
            0xE0_0000...0xFF_FFFF => g.ram[addr & ram_mask] = val,
            else => {},
        }
    }

    pub fn write16(g: *Genesis, addr: u24, val: u16) void {
        switch (addr) {
            0xA0_0000...0xA0_3FFF => wr16(&g.zram, addr & zram_mask, val),
            0xC0_0000...0xC0_0003 => g.stallUntil(g.v.writeData(g.now(), val)),
            0xC0_0004...0xC0_0007 => {
                g.v.writeControl(g.now(), val);
                if (g.v.dma_request) g.dmaFrom68k();
            },
            // The H/V counter is read-only, and swallowing the write here
            // keeps it out of the `else` arm, which would bounce it back and
            // forth with `write8` forever.
            0xC0_0008...0xC0_000F => {},
            // Word writes reach the PSG too, and it still only sees D0-D7.
            psg_port_lo...psg_port_hi => g.p.write(@truncate(val)),
            0xE0_0000...0xFF_FFFF => wr16(&g.ram, addr & ram_mask, val),
            else => g.write8(addr, @truncate(val >> 8)),
        }
    }

    /// The one DMA mode the VDP can't run on its own: its source is out here.
    /// The 68000 is held for the whole of it, which is why a game can raise
    /// DMA and read the result on the very next instruction.
    fn dmaFrom68k(g: *Genesis) void {
        g.v.dma_request = false;
        var src = g.v.dmaSource();
        var len = g.v.dmaLength();
        const end = g.now() + g.v.dmaMclk(.transfer, len);
        g.v.dmaBusyUntil(end);
        while (len > 0) : (len -= 1) {
            g.v.busWrite(g.read16(@truncate(src)));
            // The source counter wraps inside its own 128 KiB bank: only the
            // low 17 bits count up.
            src = (src & ~dma_bank_mask) | ((src + 2) & dma_bank_mask);
        }
        g.v.dmaDone();
        g.stallUntil(end);
    }

    // --------------------------------------------------------------------- I/O

    fn ioRead(g: *Genesis, addr: u24) u8 {
        return switch (addr & 0x1F) {
            // Export (not Japanese), no expansion, VA0 — and the region's
            // own bit, which is the one a game reads to pick its timing.
            0x01 => if (g.v.pal) 0xE0 else 0xA0,
            0x03 => g.padByte(),
            0x05, 0x07 => if (g.pad_ctrl & th_bit != 0) 0x7F else 0x3F, // no pad 2 or 3
            0x09 => g.pad_ctrl,
            else => 0x00,
        };
    }

    fn ioWrite(g: *Genesis, addr: u24, val: u8) void {
        switch (addr & 0x1F) {
            0x03 => g.pad_data = val,
            0x09 => g.pad_ctrl = val,
            else => {},
        }
    }

    /// Three-button pad. TH is an output the ROM toggles to pick which half of
    /// the pad it sees; every button reads low when pressed.
    fn padByte(g: *Genesis) u8 {
        const th = g.pad_ctrl & th_bit == 0 or g.pad_data & th_bit != 0;
        const b = g.buttons;
        const low: u8 = if (th)
            b & 0x3F // C B R L D U
        else
            (b & (btn_up | btn_down)) | ((b & btn_a) >> 2) | ((b & btn_start) >> 2);
        return (if (th) th_bit else 0) | (~low & 0x3F);
    }

    /// RESET pin semantics: while held (bit 0 clear), the Z80's registers
    /// stay cleared, same as real silicon; releasing it just lets `step`
    /// resume from wherever `Z80Core.reset` left PC (0).
    fn writeZ80Reset(g: *Genesis, val: u8) void {
        const held = val & 1 == 0;
        if (held and !g.z80_reset) Z80Core.reset(&g.z);
        g.z80_reset = held;
    }

    // ------------------------------------------------------------- Z80 bus

    fn z80BankAddr(g: *Genesis, addr: u16) u24 {
        return (@as(u24, g.z80_bank) << 15) | (addr & 0x7FFF);
    }

    pub fn z80Read8(g: *Genesis, addr: u16) u8 {
        return switch (addr) {
            0x0000...0x3FFF => g.zram[addr & zram_mask],
            0x4000...0x5FFF => g.y.status(),
            0x7F00...0x7FFF => g.read8(@as(u24, addr) & z80_vdp_mask | 0xC0_0000),
            0x8000...0xFFFF => g.read8(g.z80BankAddr(addr)),
            else => 0xFF,
        };
    }

    pub fn z80Write8(g: *Genesis, addr: u16, val: u8) void {
        switch (addr) {
            0x0000...0x3FFF => g.zram[addr & zram_mask] = val,
            0x4000...0x5FFF => g.y.write(@truncate(addr), val),
            // Loaded LSB-first: each write shifts the new bit into bit 8.
            0x6000...0x60FF => g.z80_bank = (g.z80_bank >> 1) | (@as(u9, val & 1) << 8),
            0x7F00...0x7FFF => g.write8(@as(u24, addr) & z80_vdp_mask | 0xC0_0000, val),
            0x8000...0xFFFF => g.write8(g.z80BankAddr(addr), val),
            else => {},
        }
    }

    /// Nothing on the Genesis is wired to the Z80's IORQ pins; every chip a
    /// sound driver touches is memory-mapped instead.
    pub fn z80In(g: *Genesis, port: u16) u8 {
        _ = g;
        _ = port;
        return 0xFF;
    }
    pub fn z80Out(g: *Genesis, port: u16, val: u8) void {
        _ = g;
        _ = port;
        _ = val;
    }
};

fn rd16(mem: []const u8, addr: usize) u16 {
    return std.mem.readInt(u16, mem[addr..][0..2], .big);
}

fn wr16(mem: []u8, addr: usize, val: u16) void {
    std.mem.writeInt(u16, mem[addr..][0..2], val, .big);
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

test "ROM reads return cartridge bytes and 0xFF past the end" {
    var c = Cpu{};
    const rom = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    var g = Genesis{ .rom = &rom, .cpu = &c };

    try testing.expectEqual(@as(u8, 0x11), g.read8(0));
    try testing.expectEqual(@as(u8, 0x44), g.read8(3));
    try testing.expectEqual(@as(u8, 0xFF), g.read8(4));
    try testing.expectEqual(@as(u16, 0x1122), g.read16(0));
    try testing.expectEqual(@as(u16, 0xFFFF), g.read16(4));
}

test "work RAM mirrors every 64 KiB across 0xE00000-0xFFFFFF" {
    var c = Cpu{};
    var g = Genesis{ .rom = &.{}, .cpu = &c };

    g.write16(0xFF0100, 0xBEEF);
    try testing.expectEqual(@as(u16, 0xBEEF), g.read16(0xE00100));
    try testing.expectEqual(@as(u8, 0xBE), g.read8(0xE00100));
    try testing.expectEqual(@as(u8, 0xEF), g.read8(0xE00101));
}

test "Z80 RAM mirrors every 8 KiB and the YM2612 always reads not-busy" {
    var c = Cpu{};
    var g = Genesis{ .rom = &.{}, .cpu = &c };

    g.write8(0xA00010, 0x42);
    try testing.expectEqual(@as(u8, 0x42), g.read8(0xA02010)); // 0x2010 & 0x1FFF == 0x10
    try testing.expectEqual(@as(u8, 0), g.read8(0xA04000));
}

test "Z80 bus request reads granted only after the 68k asks for it" {
    var c = Cpu{};
    var g = Genesis{ .rom = &.{}, .cpu = &c };

    try testing.expectEqual(@as(u8, 0x01), g.read8(0xA11100));
    g.write8(0xA11100, 0x01);
    try testing.expectEqual(@as(u8, 0x00), g.read8(0xA11100));
    g.write8(0xA11100, 0x00);
    try testing.expectEqual(@as(u8, 0x01), g.read8(0xA11100));
}

test "Z80 reset clears architectural state and holds it there until released" {
    var c = Cpu{};
    var g = Genesis{ .rom = &.{}, .cpu = &c };
    g.z80_reset = false;
    g.z.pc = 0x1234;
    g.z.iff1 = true;

    g.write8(0xA11200, 0x00); // assert reset
    try testing.expect(g.z80_reset);
    try testing.expectEqual(@as(u16, 0), g.z.pc);
    try testing.expect(!g.z.iff1);

    g.write8(0xA11200, 0x01); // release
    try testing.expect(!g.z80_reset);
}

test "Z80 bank register shifts in LSB-first and windows the 68k bus" {
    var c = Cpu{};
    const rom = [_]u8{0xAB} ** 0x9000;
    var g = Genesis{ .rom = &rom, .cpu = &c };

    // Selects bank 1 (bit 8 set): write nine bits, a single 1 then eight 0s.
    g.z80Write8(0x6000, 0x01);
    var i: u32 = 0;
    while (i < 8) : (i += 1) g.z80Write8(0x6000, 0x00);
    try testing.expectEqual(@as(u9, 1), g.z80_bank);

    // Bank 1 * 32 KiB = 0x8000, so the window's first byte is rom[0x8000].
    try testing.expectEqual(@as(u8, 0xAB), g.z80Read8(0x8000));
}

test "Z80 sees its own RAM mirrored across 0x0000-0x3FFF" {
    var c = Cpu{};
    var g = Genesis{ .rom = &.{}, .cpu = &c };

    g.z80Write8(0x0010, 0x42);
    try testing.expectEqual(@as(u8, 0x42), g.z80Read8(0x2010));
}

test "Z80's VDP window lands on the same VRAM the 68k writes" {
    var c = Cpu{};
    var g = Genesis{ .rom = &.{}, .cpu = &c };
    g.write16(0xC00004, 0x8104); // mode 5, which is where two-word writes exist
    g.write16(0xC00004, 0x4000); // VRAM write mode
    g.write16(0xC00004, 0x0003); // address 0xC000 (see vdp.zig's own control-port test)

    g.z80Write8(0x7F00, 0xAB); // data port: a byte write doubles into the word

    try testing.expectEqual(@as(u8, 0xAB), g.v.vram[0xC000]);
}

test "the PSG hears $C00011 and the Z80's $7F11 window, but not the byte beside them" {
    var c = Cpu{};
    var g = Genesis{ .rom = &.{}, .cpu = &c };
    const silent: u4 = 15;

    // Latch bytes selecting a volume register: $80 | channel << 5 | 1 << 4.
    g.write8(0xC0_0011, 0x80 | (0 << 5) | (1 << 4) | 0x03);
    try testing.expectEqual(@as(u4, 3), g.p.atten[0]);

    g.z80Write8(0x7F11, 0x80 | (1 << 5) | (1 << 4) | 0x05);
    try testing.expectEqual(@as(u4, 5), g.p.atten[1]);

    // A word write presents the same low byte the chip is wired to...
    g.write16(0xC0_0010, 0x80 | (2 << 5) | (1 << 4) | 0x07);
    try testing.expectEqual(@as(u4, 7), g.p.atten[2]);

    // ...but a byte write to the even address is on D8-D15, which is not.
    g.write8(0xC0_0010, 0x80 | (3 << 5) | (1 << 4) | 0x09);
    try testing.expectEqual(silent, g.p.atten[3]);
}

test "a word write to the read-only H/V counter is swallowed, not bounced" {
    var c = Cpu{};
    var g = Genesis{ .rom = &.{}, .cpu = &c };

    g.write16(0xC0_0008, 0xBEEF);
    try testing.expectEqual(@as(u16, 0), g.read16(0xC0_0008));
}

test "version register reports export, NTSC, no expansion" {
    var c = Cpu{};
    var g = Genesis{ .rom = &.{}, .cpu = &c };

    try testing.expectEqual(@as(u8, 0xA0), g.read8(0xA10001));
}

test "ioWrite roundtrips pad_data and pad_ctrl" {
    var c = Cpu{};
    var g = Genesis{ .rom = &.{}, .cpu = &c };

    g.write8(0xA10003, 0x55);
    try testing.expectEqual(@as(u8, 0x55), g.pad_data);
    g.write8(0xA10009, 0x40);
    try testing.expectEqual(@as(u8, 0x40), g.pad_ctrl);
}

test "controller: TH driven high reads face buttons, TH driven low reads Start/A" {
    var c = Cpu{};
    var g = Genesis{ .rom = &.{}, .cpu = &c };
    g.pad_ctrl = 0x40; // TH configured as an output
    g.buttons = btn_c | btn_left | btn_a | btn_start;

    g.pad_data = 0x40; // TH high: C,B,Right,Left,Down,Up
    const th_high = g.padByte();
    try testing.expectEqual(@as(u8, 0x40), th_high & 0x40); // TH echoed back
    try testing.expectEqual(@as(u8, 0), th_high & btn_c); // pressed -> bit low
    try testing.expectEqual(@as(u8, 0), th_high & btn_left); // pressed -> bit low
    try testing.expectEqual(@as(u8, btn_up | btn_down | btn_right | btn_b), th_high & 0x3F);

    g.pad_data = 0x00; // TH low: Start,A,0,0,Down,Up
    const th_low = g.padByte();
    try testing.expectEqual(@as(u8, 0), th_low & 0x40);
    try testing.expectEqual(@as(u8, 0), th_low & 0x10); // A -> bit4 low
    try testing.expectEqual(@as(u8, 0), th_low & 0x20); // Start -> bit5 low
    try testing.expectEqual(@as(u8, 0x0C), th_low & 0x0C); // bits 2-3: always unpressed
}

test "controller: TH configured as an input always reads the TH-high state" {
    var c = Cpu{};
    var g = Genesis{ .rom = &.{}, .cpu = &c };
    g.pad_ctrl = 0x00; // TH is an input
    g.pad_data = 0x00; // irrelevant while TH is an input
    g.buttons = btn_up;

    const got = g.padByte();
    try testing.expectEqual(@as(u8, 0x40), got & 0x40);
    try testing.expectEqual(@as(u8, 0), got & btn_up);
}

test "the H/V counter port reads the master clock, not the CPU's own cycles" {
    var c = Cpu{ .cycles = 100 };
    var g = Genesis{ .rom = &.{}, .cpu = &c };
    g.mclk = 5 * mclk_per_line; // line 5, and the line just started
    g.line_start = 100;

    try testing.expectEqual(@as(u16, 5 << 8), g.read16(0xC0_0008));

    c.cycles = 100 + (mclk_per_line / mclk_per_cpu) / 2; // halfway through it
    const mid = g.read16(0xC0_0008);
    try testing.expectEqual(@as(u8, 5), @as(u8, @truncate(mid >> 8)));
    try testing.expect(@as(u8, @truncate(mid)) > 0 and @as(u8, @truncate(mid)) < 0xFF);
}

test "a full FIFO stalls the 68000 until the oldest write has drained" {
    var c = Cpu{ .cycles = 100 };
    var g = Genesis{ .rom = &.{}, .cpu = &c };
    g.line_start = 100;
    g.v.regs[1] = 0x54; // display on, mode 5

    g.write16(0xC0_0004, 0x4000); // VRAM write at 0
    g.write16(0xC0_0004, 0x0000);
    for (0..4) |_| g.write16(0xC0_0000, 0xFFFF);
    try testing.expectEqual(@as(u64, 100), c.cycles); // four fit; nothing waits

    // The fifth is held until the oldest of the four reaches VRAM, on the
    // second access slot of an active H32 line: 510 master clocks in (see
    // vdp.zig's slot table), or 73 of the 68000's own cycles.
    g.write16(0xC0_0000, 0xFFFF);
    try testing.expectEqual(@as(u64, (510 + mclk_per_cpu - 1) / mclk_per_cpu), c.cycles - 100);
}

test "a full-volume PSG channel sits a fifth of a full-scale FM channel, as the board mixes them" {
    var c = Cpu{};
    var g = Genesis{ .rom = &.{}, .cpu = &c };

    // Channel 6's DAC drives the same ±256 a channel's own output does, so it
    // stands in for a full-scale FM channel without an operator patch. Both
    // levels are read as peak-to-peak, which is what the ratio is about, and
    // taking the difference of two DAC codes cancels anything the other five
    // channels might be contributing.
    g.write8(0xA0_4000, 0x2b);
    g.write8(0xA0_4001, 0x80); // DAC enable
    g.write8(0xA0_4000, 0x2a);
    g.write8(0xA0_4001, 0x00);
    const fm_low = g.y.step().l;
    g.write8(0xA0_4001, 0xff);
    const fm_pp = g.y.step().l - fm_low;

    // Tone 0 at period 1 and attenuation 0: a toggle every tick at full
    // volume, so two steps span the channel's whole swing.
    g.write8(0xC0_0011, 0x80 | 0x01); // tone 0, period low nibble 1
    g.write8(0xC0_0011, 0x00); // ...and high bits 0
    g.write8(0xC0_0011, 0x90); // tone 0, attenuation 0
    var lo: i32 = 0;
    var hi: i32 = 0;
    for (0..4) |_| {
        const s = g.p.step();
        lo = @min(lo, s);
        hi = @max(hi, s);
    }
    const psg_pp = hi - lo;

    // Genesis Plus GX puts a PSG channel at 2800 against ±8192 per FM channel
    // (0.17), BlastEm at 2340 against ±5372 (0.22); both are matched against a
    // real board. Anywhere in that neighbourhood is right, ten times over it
    // is the bug this pins: the PSG drowning the music in Sonic 1.
    const ratio = @as(f64, @floatFromInt(psg_pp)) / @as(f64, @floatFromInt(fm_pp));
    try testing.expect(ratio > 0.15 and ratio < 0.30);
}
