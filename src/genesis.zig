//! The Sega Genesis / Mega Drive machine: cartridge ROM, 64 KiB of work RAM,
//! a controller, and the memory map and bus arbitration that ties them to
//! the CPUs and VDP. Frame timing and interrupt delivery live in
//! `scheduler.zig`; this file only answers bus reads and writes.
//!
//! This struct owns every chip by value, including the `audio` mixer both
//! sound chips push into. The Z80 has its own memory map here, plus the
//! BUSREQ/RESET handshake and the banked window onto this same 68k bus.

const std = @import("std");
const m68k = @import("m68k");
const z80 = @import("z80");
const vdp = @import("vdp");
const psg = @import("psg");
const ym2612 = @import("ym2612");
const audio = @import("audio");
const cart = @import("cart");

pub const Cpu = m68k.Cpu;
pub const Cart = cart.Cart;
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

/// The 68000's memory map (DESIGN.md §3.3). Each range is the whole block the
/// bus decodes for that device, mirrors and all, so the switches below read as
/// names rather than as addresses.
const rom_lo: u24 = 0x00_0000;
const rom_hi: u24 = 0x3F_FFFF;
const zram_lo: u24 = 0xA0_0000;
const zram_hi: u24 = 0xA0_3FFF;
/// The YM2612's four ports, mirrored across the block the 68k decodes for it.
const ym_port_lo: u24 = 0xA0_4000;
const ym_port_hi: u24 = 0xA0_5FFF;
const io_lo: u24 = 0xA1_0000;
const io_hi: u24 = 0xA1_001F;
const busreq_lo: u24 = 0xA1_1100;
const busreq_hi: u24 = 0xA1_11FF;
const z80_reset_lo: u24 = 0xA1_1200;
const z80_reset_hi: u24 = 0xA1_12FF;
/// The "TIME" block, where a cartridge may put registers of its own: the
/// backup-RAM control byte and the banking mapper (see `cart.zig`).
const time_lo: u24 = 0xA1_3000;
const time_hi: u24 = 0xA1_30FF;
/// TMSS, on later boards: the BIOS writes "SEGA" here and unlocks the VDP.
/// This machine has no BIOS and no lock, so the writes are accepted and
/// dropped rather than left to fall through the memory map (DESIGN.md §8).
const tmss_lo: u24 = 0xA1_4000;
const tmss_hi: u24 = 0xA1_41FF;
/// The VDP's three port pairs, each mirrored once inside the 16 bytes.
const vdp_data_lo: u24 = 0xC0_0000;
const vdp_data_hi: u24 = 0xC0_0003;
const vdp_ctrl_lo: u24 = 0xC0_0004;
const vdp_ctrl_hi: u24 = 0xC0_0007;
const vdp_hv_lo: u24 = 0xC0_0008;
const vdp_hv_hi: u24 = 0xC0_000F;
/// The PSG's write-only port, $C00011, and the rest of the VDP block it
/// decodes over.
const psg_port_lo: u24 = 0xC0_0010;
const psg_port_hi: u24 = 0xC0_001F;
const ram_lo: u24 = 0xE0_0000;
const ram_hi: u24 = 0xFF_FFFF;

/// The Z80's own map: 8 KiB of RAM mirrored to $3FFF, the YM2612, the
/// write-only bank register, a 32-byte window onto the VDP block at $C00000
/// (how a sound driver reaches the PSG without asking the 68k for the bus),
/// and the banked window onto the 68k bus.
const z80_ram_hi: u16 = 0x3FFF;
const z80_ym_lo: u16 = 0x4000;
const z80_ym_hi: u16 = 0x5FFF;
const z80_bank_lo: u16 = 0x6000;
const z80_bank_hi: u16 = 0x60FF;
const z80_vdp_lo: u16 = 0x7F00;
const z80_vdp_hi: u16 = 0x7FFF;
const z80_vdp_mask: u24 = 0x1F;
const z80_window_lo: u16 = 0x8000;
const z80_window_hi: u16 = 0xFFFF;

const ram_bytes = 64 << 10;
const zram_bytes = 8 << 10;
const ram_mask = ram_bytes - 1;
const zram_mask = zram_bytes - 1;

/// The controller's TH pin, bit 6 of both the data and control port bytes.
const th_bit: u8 = 0x40;
/// The six button bits a pad reports in one half of its multiplexed byte.
const pad_bits: u8 = 0x3F;
/// The four direction bits, which the six-button pad's extra reads drive as a
/// group rather than as buttons.
const dir_bits: u16 = btn_up | btn_down | btn_left | btn_right;
/// How long TH has to stand still before a six-button pad forgets where it was
/// in its sequence. The counter is reset by an RC network on the pad, at
/// roughly 1.5 ms; a game that abandons a poll half way through starts the
/// next one from the top because of it.
const pad_reset_mclk = master_clock_hz * 3 / 2000;

/// I/O register offsets within the block at $A10000, all on odd addresses.
const io_mask: u24 = 0x1F;
const io_version: u24 = 0x01;
const io_data1: u24 = 0x03;
const io_data2: u24 = 0x05;
const io_data3: u24 = 0x07;
const io_ctrl1: u24 = 0x09;
const io_ctrl2: u24 = 0x0B;

/// What $A10001 reports about the board. The PAL bit is the one a game reads
/// to pick its timing; the rest say export (not Japanese), no expansion
/// connected, and VA0-revision hardware.
const version_export: u8 = 0x80;
const version_pal: u8 = 0x40;
const version_no_expansion: u8 = 0x20;

/// A DMA's source counter is 17 bits wide and the bank above it is fixed, so
/// a transfer that runs off the end of a 128 KiB bank comes back at its start.
const dma_bank_mask: u32 = 0x1_FFFF;

/// The cartridge header's region field, four bytes at $1F0.
const region_field = 0x1F0;
const region_field_len = 4;

/// The regions a cartridge says it runs in, one bit each. The header field is
/// written two ways: the old one lists them as letters (`JUE`, `E`), the newer
/// one packs them into one hex digit — bit 0 Japan, bit 2 overseas NTSC, bit 3
/// overseas PAL.
const region_japan: u3 = 0b001;
const region_ntsc: u3 = 0b010;
const region_pal: u3 = 0b100;

fn romRegions(rom: []const u8) u3 {
    if (rom.len < region_field + region_field_len) return 0;
    const field = std.mem.trim(u8, rom[region_field..][0..region_field_len], " \x00");
    if (field.len == 0) return 0;
    // 'E' is both a region letter and a hex digit, so the letter form has to
    // win whenever the whole field reads as letters.
    for (field) |ch| {
        if (std.mem.indexOfScalar(u8, "JUE", ch) == null) break;
    } else {
        var out: u3 = 0;
        for (field) |ch| out |= switch (ch) {
            'J' => region_japan,
            'U' => region_ntsc,
            else => region_pal,
        };
        return out;
    }

    const bits = std.fmt.charToDigit(field[0], 16) catch return 0;
    return @as(u3, @intFromBool(bits & 0b0001 != 0)) |
        @as(u3, @intFromBool(bits & 0b0100 != 0)) << 1 |
        @as(u3, @intFromBool(bits & 0b1000 != 0)) << 2;
}

/// Whether a cartridge wants a PAL machine, for the frontend's `auto` region.
/// PAL means Europe and nothing else, because a cart that also runs on an
/// American machine should run at the speed it was written for.
pub fn romIsPal(rom: []const u8) bool {
    return romRegions(rom) == region_pal;
}

/// Whether a cartridge wants a Japanese machine, which is the other half of
/// what the region field says and the one $A10001 answers. A Japan-only cart
/// on a machine that reports itself as export hits the ROM's own lockout
/// screen — the game boots, draws "this cartridge is for another system", and
/// stops, which looks exactly like a hang that isn't one. Same rule as the PAL
/// side: a cart that also runs overseas gets the export machine it lists.
pub fn romIsDomestic(rom: []const u8) bool {
    return romRegions(rom) == region_japan;
}

// Controller bits, active high here and inverted on the way out to the ROM.
// The low byte is what a three-button pad has; the high byte is the six-button
// pad's second half, in the bit order its extra read reports them (M X Y Z).
pub const btn_up: u16 = 0x01;
pub const btn_down: u16 = 0x02;
pub const btn_left: u16 = 0x04;
pub const btn_right: u16 = 0x08;
pub const btn_b: u16 = 0x10;
pub const btn_c: u16 = 0x20;
pub const btn_a: u16 = 0x40;
pub const btn_start: u16 = 0x80;
pub const btn_z: u16 = 0x100;
pub const btn_y: u16 = 0x200;
pub const btn_x: u16 = 0x400;
pub const btn_mode: u16 = 0x800;

/// One controller port. Both ports are the same circuit, so both are this.
///
/// TH is an output the ROM toggles to pick which half of the pad it sees. A
/// six-button pad counts those toggles: the sixth read of a poll answers with
/// every direction pressed, which is how a ROM tells the two pads apart, the
/// seventh with X/Y/Z/Mode, and the eighth with every direction released.
/// Three reads is all a three-button game does, so it never reaches any of
/// that — until it does, which is why `six` is an option and not a default.
pub const Pad = struct {
    buttons: u16 = 0,
    ctrl: u8 = 0,
    data: u8 = 0,
    /// Which pad is plugged in. Set by the frontend, never by the machine.
    six: bool = false,
    /// TH falling edges since the pad last forgot where it was: the four steps
    /// of the sequence, cycling 1-2-3-4 rather than through zero, which is
    /// only where a pad that has just been reset sits.
    count: u3 = 0,
    th_mclk: u64 = 0,

    /// TH's level: high while it is an input, since the pad pulls it up.
    fn thHigh(p: *const Pad) bool {
        return p.ctrl & th_bit == 0 or p.data & th_bit != 0;
    }

    /// Every button reads low when pressed, so the byte is inverted on the way
    /// out.
    ///
    /// With TH low the pad grounds D2 and D3 outright — they read as pressed
    /// whatever the stick is doing, which is how a ROM tells a pad from an
    /// empty port. Reporting the real left/right there instead breaks any
    /// driver that ORs the two halves together: left and right then never
    /// register at all, while every other button still works.
    pub fn read(p: *const Pad) u8 {
        const b = p.buttons;
        const th = p.thHigh();
        var low: u16 = if (th)
            b & pad_bits // C B R L D U
        else
            (b & (btn_up | btn_down)) | btn_left | btn_right | ((b & (btn_a | btn_start)) >> 2);
        if (p.six) {
            if (th and p.count == 3) low = (b & (btn_b | btn_c)) | (b >> 8); // C B M X Y Z
            if (!th and p.count == 3) low |= dir_bits; // S A 0 0 0 0
            if (!th and p.count == 4) low &= ~dir_bits; // S A 1 1 1 1
        }
        return @truncate((if (th) th_bit else 0) | (~low & pad_bits));
    }

    pub fn writeData(p: *Pad, val: u8, mclk: u64) void {
        const was = p.thHigh();
        p.data = val;
        p.edge(was, mclk);
    }

    pub fn writeCtrl(p: *Pad, val: u8, mclk: u64) void {
        const was = p.thHigh();
        p.ctrl = val;
        p.edge(was, mclk);
    }

    /// Both registers decide TH's level, so both go through this: a six-button
    /// pad counts the falling edges, and forgets a poll left half finished
    /// rather than resuming it as part of the next one. A game polling once a
    /// frame is 16 ms between polls and microseconds inside one, which is what
    /// makes every frame's poll start from the top.
    fn edge(p: *Pad, was: bool, mclk: u64) void {
        if (mclk -| p.th_mclk > pad_reset_mclk) p.count = 0;
        p.th_mclk = mclk;
        if (was and !p.thHigh()) p.count = if (p.count >= 4) 1 else p.count + 1;
    }
};

pub const Genesis = struct {
    rom: []const u8,
    /// Mutable because the VDP stalls it: a full FIFO or a DMA off the 68k
    /// bus holds the CPU by pushing its cycle count forward.
    cpu: *Cpu,
    /// What the slot adds to those ROM bytes: backup RAM and the banking
    /// mapper, both of which answer inside the cartridge's address window.
    cart: Cart = .{},
    /// Which machine $A10001 says this is. Read off the cartridge rather than
    /// chosen in the options: unlike the video standard, a game's region check
    /// is asking about the console it is plugged into, not about timing.
    domestic: bool = false,
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

    /// The two controller ports. The third one is an expansion connector with
    /// nothing in it, so it has no `Pad`.
    pads: [2]Pad = @splat(.{}),

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

    /// A machine with a cartridge in the slot. The header is read once, here:
    /// everything the slot answers with afterwards is in `cart`.
    pub fn init(rom: []const u8, cpu: *Cpu) Genesis {
        return .{ .rom = rom, .cpu = cpu, .cart = .init(rom), .domestic = romIsDomestic(rom) };
    }

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
            rom_lo...rom_hi => g.cart.read8(g.rom, addr),
            zram_lo...zram_hi => g.zram[addr & zram_mask],
            ym_port_lo...ym_port_hi => g.y.status(),
            io_lo...io_hi => g.ioRead(addr),
            // Bit 0 low means the 68k has the bus; this model grants it the
            // instant it's requested, so it only ever reads busreq back.
            busreq_lo...busreq_hi => if (g.z80_busreq) 0x00 else 0x01,
            vdp_data_lo...vdp_hv_hi => {
                const w = g.read16(addr & ~@as(u24, 1));
                return @truncate(if (addr & 1 != 0) w else w >> 8);
            },
            ram_lo...ram_hi => g.ram[addr & ram_mask],
            else => 0xFF,
        };
    }

    pub fn read16(g: *Genesis, addr: u24) u16 {
        return switch (addr) {
            rom_lo...rom_hi => g.cart.read16(g.rom, addr),
            zram_lo...zram_hi => rd16(&g.zram, addr & zram_mask),
            vdp_data_lo...vdp_data_hi => g.v.readData(),
            vdp_ctrl_lo...vdp_ctrl_hi => g.v.readStatus(g.now()),
            vdp_hv_lo...vdp_hv_hi => g.v.hvCounter(g.now()),
            ram_lo...ram_hi => rd16(&g.ram, addr & ram_mask),
            // Everything else on this bus is a byte-wide device, and answers
            // a word read with the same byte in both halves.
            else => @as(u16, g.read8(addr)) << 8 | g.read8(addr),
        };
    }

    pub fn write8(g: *Genesis, addr: u24, val: u8) void {
        switch (addr) {
            rom_lo...rom_hi => g.cart.write8(addr, val),
            zram_lo...zram_hi => g.zram[addr & zram_mask] = val,
            io_lo...io_hi => g.ioWrite(addr, val),
            ym_port_lo...ym_port_hi => g.y.write(@truncate(addr), val),
            busreq_lo...busreq_hi => g.z80_busreq = val & 1 != 0,
            z80_reset_lo...z80_reset_hi => g.writeZ80Reset(val),
            time_lo...time_hi => g.cart.writeTime(addr, val),
            tmss_lo...tmss_hi => {},
            // A byte write to a VDP port still presents a full word, with the
            // byte in both halves.
            vdp_data_lo...vdp_hv_hi => g.write16(addr & ~@as(u24, 1), @as(u16, val) << 8 | val),
            // The PSG hangs off the low byte of the bus only, so it hears
            // $C00011 and ignores the even address beside it.
            psg_port_lo...psg_port_hi => if (addr & 1 != 0) g.p.write(val),
            ram_lo...ram_hi => g.ram[addr & ram_mask] = val,
            else => {},
        }
    }

    pub fn write16(g: *Genesis, addr: u24, val: u16) void {
        switch (addr) {
            rom_lo...rom_hi => g.cart.write16(addr, val),
            zram_lo...zram_hi => wr16(&g.zram, addr & zram_mask, val),
            // The cartridge's own registers hang off the low byte of the bus,
            // the same way the PSG does.
            time_lo...time_hi => g.cart.writeTime(addr | 1, @truncate(val)),
            vdp_data_lo...vdp_data_hi => g.stallUntil(g.v.writeData(g.now(), val)),
            vdp_ctrl_lo...vdp_ctrl_hi => {
                g.v.writeControl(g.now(), val);
                if (g.v.dma_request) g.dmaFrom68k();
            },
            // The H/V counter is read-only, and swallowing the write here
            // keeps it out of the `else` arm, which would bounce it back and
            // forth with `write8` forever.
            vdp_hv_lo...vdp_hv_hi => {},
            // Word writes reach the PSG too, and it still only sees D0-D7.
            psg_port_lo...psg_port_hi => g.p.write(@truncate(val)),
            ram_lo...ram_hi => wr16(&g.ram, addr & ram_mask, val),
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
        return switch (addr & io_mask) {
            io_version => version_no_expansion |
                @as(u8, if (g.domestic) 0 else version_export) |
                @as(u8, if (g.v.pal) version_pal else 0),
            io_data1 => g.pads[0].read(),
            io_data2 => g.pads[1].read(),
            // Nothing is plugged into the expansion port: every line floats high.
            io_data3 => pad_bits,
            io_ctrl1 => g.pads[0].ctrl,
            io_ctrl2 => g.pads[1].ctrl,
            else => 0x00,
        };
    }

    fn ioWrite(g: *Genesis, addr: u24, val: u8) void {
        const mclk = g.now();
        switch (addr & io_mask) {
            io_data1 => g.pads[0].writeData(val, mclk),
            io_ctrl1 => g.pads[0].writeCtrl(val, mclk),
            io_data2 => g.pads[1].writeData(val, mclk),
            io_ctrl2 => g.pads[1].writeCtrl(val, mclk),
            else => {},
        }
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

    fn z80VdpAddr(addr: u16) u24 {
        return vdp_data_lo | (@as(u24, addr) & z80_vdp_mask);
    }

    pub fn z80Read8(g: *Genesis, addr: u16) u8 {
        return switch (addr) {
            0...z80_ram_hi => g.zram[addr & zram_mask],
            z80_ym_lo...z80_ym_hi => g.y.status(),
            z80_vdp_lo...z80_vdp_hi => g.read8(z80VdpAddr(addr)),
            z80_window_lo...z80_window_hi => g.read8(g.z80BankAddr(addr)),
            else => 0xFF,
        };
    }

    pub fn z80Write8(g: *Genesis, addr: u16, val: u8) void {
        switch (addr) {
            0...z80_ram_hi => g.zram[addr & zram_mask] = val,
            z80_ym_lo...z80_ym_hi => g.y.write(@truncate(addr), val),
            // Loaded LSB-first: each write shifts the new bit into bit 8.
            z80_bank_lo...z80_bank_hi => g.z80_bank = (g.z80_bank >> 1) | (@as(u9, val & 1) << 8),
            z80_vdp_lo...z80_vdp_hi => g.write8(z80VdpAddr(addr), val),
            z80_window_lo...z80_window_hi => g.write8(g.z80BankAddr(addr), val),
            else => {},
        }
    }

    /// Nothing on the Genesis is wired to the Z80's IORQ pins; every chip a
    /// sound driver touches is memory-mapped instead.
    pub fn z80In(g: *Genesis, port: u16) u8 {
        _ = .{ g, port };
        return 0xFF;
    }
    pub fn z80Out(g: *Genesis, port: u16, val: u8) void {
        _ = .{ g, port, val };
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

test "a Japan-only cartridge gets a domestic machine on the version register" {
    var c = Cpu{};
    var rom: [0x200]u8 = @splat(0);
    @memcpy(rom[region_field..][0..region_field_len], "J   ");
    var g = Genesis.init(&rom, &c);

    try testing.expect(g.domestic);
    try testing.expectEqual(@as(u8, 0x20), g.read8(0xA10001)); // export bit clear

    // A cart that also runs overseas is happy on the export machine, so it
    // gets one — the same rule the PAL side uses.
    @memcpy(rom[region_field..][0..region_field_len], "JUE ");
    g = Genesis.init(&rom, &c);
    try testing.expect(!g.domestic);
    try testing.expectEqual(@as(u8, 0xA0), g.read8(0xA10001));
}

test "the header's region field, in both encodings, picks the machine" {
    // Field, then the machine it asks for. Only a cart that lists one region
    // gets that region's machine; anything multi-region gets export NTSC.
    const cases = .{
        .{ "J   ", true, false },
        .{ "1   ", true, false }, // hex digit: Japan only
        .{ "U   ", false, false },
        .{ "E   ", false, true }, // a letter, not the hex digit 14
        .{ "8   ", false, true }, // overseas PAL only
        .{ "JU  ", false, false }, // Japan and overseas NTSC
        .{ "9   ", false, false }, // Japan and overseas PAL
        .{ "JUE ", false, false },
        .{ "F   ", false, false }, // every region: NTSC wins
    };

    var rom: [0x200]u8 = @splat(0);
    inline for (cases) |c| {
        @memcpy(rom[region_field..][0..region_field_len], c[0]);
        try testing.expectEqual(c[1], romIsDomestic(&rom));
        try testing.expectEqual(c[2], romIsPal(&rom));
    }

    const too_short = rom[0..16];
    try testing.expect(!romIsDomestic(too_short));
    try testing.expect(!romIsPal(too_short));
}

test "ioWrite roundtrips pad data and ctrl" {
    var c = Cpu{};
    var g = Genesis{ .rom = &.{}, .cpu = &c };

    g.write8(0xA10003, 0x55);
    try testing.expectEqual(@as(u8, 0x55), g.pads[0].data);
    g.write8(0xA10009, 0x40);
    try testing.expectEqual(@as(u8, 0x40), g.pads[0].ctrl);
}

test "controller: TH driven high reads face buttons, TH driven low reads Start/A" {
    var p = Pad{ .ctrl = 0x40 }; // TH configured as an output
    p.buttons = btn_c | btn_left | btn_a | btn_start;

    p.data = 0x40; // TH high: C,B,Right,Left,Down,Up
    const th_high = p.read();
    try testing.expectEqual(@as(u8, 0x40), th_high & 0x40); // TH echoed back
    try testing.expectEqual(@as(u8, 0), th_high & btn_c); // pressed -> bit low
    try testing.expectEqual(@as(u8, 0), th_high & btn_left); // pressed -> bit low
    try testing.expectEqual(@as(u8, btn_up | btn_down | btn_right | btn_b), th_high & 0x3F);

    p.data = 0x00; // TH low: Start,A,0,0,Down,Up
    const th_low = p.read();
    try testing.expectEqual(@as(u8, 0), th_low & 0x40);
    try testing.expectEqual(@as(u8, 0), th_low & 0x10); // A -> bit4 low
    try testing.expectEqual(@as(u8, 0), th_low & 0x20); // Start -> bit5 low
    // D2 and D3 are grounded by the pad itself, so they read pressed even
    // though only Left is held: this is the "a pad is plugged in" signature.
    try testing.expectEqual(@as(u8, 0), th_low & 0x0C);
}

test "the second port is a pad of its own, and the third is empty" {
    var c = Cpu{};
    var g = Genesis{ .rom = &.{}, .cpu = &c };
    g.write8(0xA1000B, 0x40); // TH an output on port 2
    g.write8(0xA10005, 0x40); // ...driven high
    g.pads[0].buttons = btn_c | btn_x; // player 1's buttons stay on port 1
    g.pads[1].six = true;
    g.pads[1].buttons = btn_start | btn_left;

    try testing.expectEqual(@as(u8, 0x40), g.read8(0xA1000B));
    try testing.expectEqual(@as(u8, 0), g.read8(0xA10005) & btn_left);
    try testing.expectEqual(@as(u8, btn_c), g.read8(0xA10005) & btn_c);
    try testing.expectEqual(@as(u8, pad_bits), g.read8(0xA10007));
}

test "controller: TH configured as an input always reads the TH-high state" {
    var p = Pad{ .buttons = btn_up };
    p.ctrl = 0x00; // TH is an input
    p.data = 0x00; // irrelevant while TH is an input

    const got = p.read();
    try testing.expectEqual(@as(u8, 0x40), got & 0x40);
    try testing.expectEqual(@as(u8, 0), got & btn_up);
}

/// The eight reads of one poll, TH driven high then low four times over, which
/// is the whole of the six-button protocol.
fn pollPad(p: *Pad, mclk: u64) [8]u8 {
    var out: [8]u8 = undefined;
    for (&out, 0..) |*byte, i| {
        p.writeData(if (i % 2 == 0) th_bit else 0, mclk);
        byte.* = p.read();
    }
    return out;
}

/// Up, Start, X and Z held: one button from each of the four groups a poll
/// reports, which is what makes the eight answers below tell each other apart.
const poll_buttons = btn_up | btn_start | btn_x | btn_z;

/// What those eight reads say, in order, with `poll_buttons` held. A button
/// reads low, so a bit that is *clear* is one that is pressed.
const poll_expected = [8]u8{
    0x7E, // 1  -1CBRLDU, Up down
    0x12, // 2  -0SA00DU, Start down, D2/D3 grounded
    0x7E, // 3
    0x12, // 4
    0x7E, // 5
    0x10, // 6  -0SA0000, every direction forced low: "I am a six-button pad"
    0x7A, // 7  -1CBMXYZ, X and Z down
    0x1F, // 8  -0SA1111, every direction forced high
};

test "a six-button pad answers its extra reads, and starts over on the ninth" {
    var p = Pad{ .ctrl = th_bit, .six = true, .buttons = poll_buttons };

    try testing.expectEqual(poll_expected, pollPad(&p, 0));
    // The counter cycles rather than sticking, so a second poll with no pause
    // between them is the same eight answers again.
    try testing.expectEqual(poll_expected, pollPad(&p, 0));
}

test "a three-button pad never leaves its two halves" {
    var p = Pad{ .ctrl = th_bit, .buttons = poll_buttons };

    // The counter still runs; nothing reads it. So reads 6-8 are reads 1-3
    // over again, and X and Z are in none of them.
    const poll = pollPad(&p, 0);
    for (poll, 0..) |byte, i| try testing.expectEqual(poll_expected[i % 2], byte);
}

test "a six-button pad forgets a poll left half finished" {
    var p = Pad{ .ctrl = th_bit, .six = true, .buttons = poll_buttons };

    // Three falling edges in, which is where the extra reads come from...
    for (0..6) |i| p.writeData(if (i % 2 == 0) th_bit else 0, 0);
    try testing.expectEqual(@as(u3, 3), p.count);
    try testing.expectEqual(poll_expected[5], p.read());

    // ...and a game that goes away for longer than the pad's RC timeout finds
    // it back at the top instead of half way through.
    p.writeData(th_bit, pad_reset_mclk + 1);
    p.writeData(0, pad_reset_mclk + 2);
    try testing.expectEqual(@as(u3, 1), p.count);
    try testing.expectEqual(poll_expected[1], p.read());
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
    // is the bug this pins: the PSG drowning out the music.
    const ratio = @as(f64, @floatFromInt(psg_pp)) / @as(f64, @floatFromInt(fm_pp));
    try testing.expect(ratio > 0.15 and ratio < 0.30);
}

test "backup RAM answers on the cartridge bus once $A130F1 switches it in" {
    var c = Cpu{};
    var rom: [0x200]u8 = @splat(0xAB);
    @memcpy(rom[0x1B0..][0..2], "RA");
    std.mem.writeInt(u32, rom[0x1B4..][0..4], 0x20_0001, .big);
    std.mem.writeInt(u32, rom[0x1B8..][0..4], 0x20_FFFF, .big);
    var g = Genesis.init(&rom, &c);
    g.cart.sram_on = false; // as an oversized cart with this header powers up

    g.write8(0x20_0001, 0x42);
    try testing.expectEqual(@as(u8, 0xFF), g.read8(0x20_0001)); // past this ROM

    g.write8(0xA1_30F1, 0x01);
    g.write8(0x20_0001, 0x42);
    try testing.expectEqual(@as(u8, 0x42), g.read8(0x20_0001));
    try testing.expect(g.cart.sram_dirty);
}

test "the $A130F3 mapper is reachable as a word write, on the low byte" {
    var c = Cpu{};
    const rom = [_]u8{0x11} ** 0x1000;
    var g = Genesis.init(&rom, &c);

    g.write16(0xA1_30F2, 0x0003); // slot 1 <- page 3
    try testing.expectEqual(@as(u8, 3), g.cart.banks[1]);
}

test "TMSS writes are accepted and dropped" {
    var c = Cpu{};
    var g = Genesis.init(&.{}, &c);

    g.write16(0xA1_4000, 0x5345); // "SE"
    g.write16(0xA1_4002, 0x4741); // "GA"
    g.write16(0xA1_4100, 0x0001); // the VDP lock this machine does not have
    try testing.expectEqual(@as(u8, 0xFF), g.read8(0xA1_4000));
}
