//! The Sega Genesis / Mega Drive machine: cartridge ROM, 64 KiB of work RAM,
//! a controller, and the memory map and bus arbitration that ties them to
//! the CPU and VDP. Frame timing and interrupt delivery live in
//! `scheduler.zig`; this file only answers bus reads and writes.
//!
//! The Z80, YM2612 and PSG are stubs: present enough in the memory map that
//! a ROM's handshakes complete, but nothing executes or synthesizes yet
//! (M1-M3 in DESIGN.md).

const std = @import("std");
const m68k = @import("m68k");
const vdp = @import("vdp");

pub const Cpu = m68k.Cpu;
pub const Core = m68k.Core(Genesis);

// NTSC: a 53.693175 MHz master clock, seven of which make a 68000 cycle, and
// 3420 of which make a scanline. `scheduler.zig` drives the frame loop off
// these; `hvCounter` below needs them too, so they live with the rest of the
// machine's hardware constants rather than with the loop that steps it.
pub const mclk_per_cpu = 7;
pub const mclk_per_line = 3420;
pub const lines_per_frame = 262;

const ram_bytes = 64 << 10;
/// The Z80's RAM. Nothing runs it yet; the 68k still fills it with a driver.
const zram_bytes = 8 << 10;

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
    cpu: *const Cpu,
    ram: [ram_bytes]u8 = @splat(0),
    zram: [zram_bytes]u8 = @splat(0),
    v: vdp.Vdp = .{},

    buttons: u8 = 0,
    pad_ctrl: u8 = 0,
    pad_data: u8 = 0,

    line: u32 = 0,
    /// Cycle count when the current scanline started, for the H counter.
    line_start: u64 = 0,
    /// A scanline isn't a whole number of CPU cycles; the remainder is carried
    /// here so a frame comes out at the right length instead of 0.1% short.
    mclk_debt: u64 = 0,

    // -------------------------------------------------------------- memory map

    pub fn read8(g: *Genesis, addr: u24) u8 {
        return switch (addr) {
            0x00_0000...0x3F_FFFF => if (addr < g.rom.len) g.rom[addr] else 0xFF,
            0xA0_0000...0xA0_3FFF => g.zram[addr & 0x1FFF],
            0xA0_4000...0xA0_5FFF => 0, // YM2612: never busy
            0xA1_0000...0xA1_001F => g.ioRead(addr),
            // Z80 bus request and reset. The bus is always granted at once:
            // bit 0 low means the 68k has it.
            0xA1_1100...0xA1_11FF => 0x00,
            0xC0_0000...0xC0_000F => @truncate(g.read16(addr & ~@as(u24, 1)) >> @intCast(8 * (~addr & 1))),
            0xE0_0000...0xFF_FFFF => g.ram[addr & 0xFFFF],
            else => 0xFF,
        };
    }

    pub fn read16(g: *Genesis, addr: u24) u16 {
        return switch (addr) {
            0x00_0000...0x3F_FFFF => if (addr + 1 < g.rom.len) rd16(g.rom, addr) else 0xFFFF,
            0xA0_0000...0xA0_3FFF => rd16(&g.zram, addr & 0x1FFF),
            0xC0_0000...0xC0_0003 => g.v.readData(),
            0xC0_0004...0xC0_0007 => g.v.readStatus(),
            0xC0_0008...0xC0_000F => g.hvCounter(),
            0xE0_0000...0xFF_FFFF => rd16(&g.ram, addr & 0xFFFF),
            // Everything else on this bus is a byte-wide device, and answers
            // a word read with the same byte in both halves.
            else => @as(u16, g.read8(addr)) << 8 | g.read8(addr),
        };
    }

    pub fn write8(g: *Genesis, addr: u24, val: u8) void {
        switch (addr) {
            0xA0_0000...0xA0_3FFF => g.zram[addr & 0x1FFF] = val,
            0xA1_0000...0xA1_001F => g.ioWrite(addr, val),
            // A byte write to a VDP port still presents a full word, with the
            // byte in both halves.
            0xC0_0000...0xC0_000F => g.write16(addr & ~@as(u24, 1), @as(u16, val) << 8 | val),
            0xE0_0000...0xFF_FFFF => g.ram[addr & 0xFFFF] = val,
            else => {},
        }
    }

    pub fn write16(g: *Genesis, addr: u24, val: u16) void {
        switch (addr) {
            0xA0_0000...0xA0_3FFF => wr16(&g.zram, addr & 0x1FFF, val),
            0xC0_0000...0xC0_0003 => g.v.writeData(val),
            0xC0_0004...0xC0_0007 => {
                g.v.writeControl(val);
                if (g.v.dma_request) g.dmaFrom68k();
            },
            0xE0_0000...0xFF_FFFF => wr16(&g.ram, addr & 0xFFFF, val),
            else => g.write8(addr, @truncate(val >> 8)),
        }
    }

    /// The one DMA mode the VDP can't run on its own: its source is out here.
    fn dmaFrom68k(g: *Genesis) void {
        g.v.dma_request = false;
        var src = g.v.dmaSource();
        var len = g.v.dmaLength();
        while (len > 0) : (len -= 1) {
            g.v.writeTarget(g.read16(@truncate(src)));
            // The source counter wraps inside its own 128 KiB bank.
            src = (src & 0xFF_0000) | ((src + 2) & 0xFFFF);
        }
        g.v.dmaDone();
    }

    // --------------------------------------------------------------------- I/O

    /// The H counter runs 0..$FF across a line here rather than the real
    /// blanking-aware ramp; games use it as an entropy source, not a clock.
    fn hvCounter(g: *Genesis) u16 {
        const into_line = g.cpu.cycles -| g.line_start;
        const h: u16 = @truncate(into_line * 256 / (mclk_per_line / mclk_per_cpu));
        return @as(u16, @truncate(g.line)) << 8 | (h & 0xFF);
    }

    fn ioRead(g: *Genesis, addr: u24) u8 {
        return switch (addr & 0x1F) {
            0x01 => 0xA0, // export, NTSC, no expansion, VA0
            0x03 => g.padByte(),
            0x05, 0x07 => if (g.pad_ctrl & 0x40 != 0) 0x7F else 0x3F, // no pad 2 or 3
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
        const th = g.pad_ctrl & 0x40 == 0 or g.pad_data & 0x40 != 0;
        const b = g.buttons;
        const low: u8 = if (th)
            b & 0x3F // C B R L D U
        else
            (b & (btn_up | btn_down)) | ((b & btn_a) >> 2) | ((b & btn_start) >> 2);
        return (if (th) @as(u8, 0x40) else 0) | (~low & 0x3F);
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

test "Z80 bus request/reset region always reads granted" {
    var c = Cpu{};
    var g = Genesis{ .rom = &.{}, .cpu = &c };

    try testing.expectEqual(@as(u8, 0x00), g.read8(0xA11100));
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

test "hvCounter reports the line in the high byte and ramps through it in the low byte" {
    var c = Cpu{ .cycles = 100 };
    var g = Genesis{ .rom = &.{}, .cpu = &c };
    g.line = 5;
    g.line_start = 100; // the line just started

    try testing.expectEqual(@as(u16, 5 << 8), g.hvCounter());

    c.cycles = 100 + (mclk_per_line / mclk_per_cpu) / 2; // halfway through the line
    const mid = g.hvCounter();
    try testing.expectEqual(@as(u8, 5), @as(u8, @truncate(mid >> 8)));
    try testing.expect(@as(u8, @truncate(mid)) > 0 and @as(u8, @truncate(mid)) < 0xFF);
}
