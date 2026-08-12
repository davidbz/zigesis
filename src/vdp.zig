//! Sega Genesis VDP (315-5313) — enough of one to draw a game, and enough of
//! one to tell the truth about its own state while it does.
//!
//! Knows nothing about the 68000 or the bus: `genesis.zig` forwards port
//! accesses here and runs the one DMA mode that needs to read the 68k bus.
//! Nearly every port entry point takes `now`, the master clock: half of what
//! this chip reports is *when* rather than *what*: the FIFO drains on access
//! slots, DMA runs out of the same slot budget, and the H counter is a
//! position in the line. `mclk_per_line` divides the master clock exactly, so
//! `now / mclk_per_line` is the line and `now % mclk_per_line` the position
//! in it.
//!
//! Rendering is per scanline, which is what line-scroll effects (water
//! surfaces, title-screen wobble) need and no more.
//!
//! The picture's size is a mode, not a constant: 256 or 320 across, 224 or
//! 240 down, doubled down again by the interlaced double-resolution mode.
//! `fb` is allocated for the largest of those and the active corner of it is
//! what `frameWidth`/`frameHeight` describe.

const std = @import("std");

/// The framebuffer's allocation: H40, V30, double-resolution interlace.
pub const max_width = 320;
pub const max_height = 480;

const width_h32 = 256;
const width_h40 = 320;
/// Public because the frontend sizes its window off the ordinary NTSC picture,
/// whatever mode the machine is actually in.
pub const height_v28 = 224;
const height_v30 = 240;

/// The VDP's own clock: 3420 master clocks a line, 262 lines a frame (NTSC),
/// 313 (PAL). The line is the same length in both: PAL is slower by having
/// more of them.
pub const mclk_per_line = 3420;
pub const lines_per_frame = 262;
const lines_per_frame_pal = 313;

const vram_size = 0x10000;
const vram_mask = vram_size - 1;
/// 64 nine-bit colours, held here in the bus's BBB0GGG0RRR0 packing.
const cram_entries = 64;
const cram_mask = cram_entries - 1;
/// 40 eleven-bit scroll values, but the chip decodes 64 of them: the 24 above
/// the visible ones are the data cache reads come back out of.
const vsram_words = 64;
const vsram_mask = vsram_words - 1;
const vsram_visible = 40;
const vsram_bits: u16 = 0x7FF;
const cram_bits: u16 = 0x0EEE;

/// Status register bits, as the 68000 reads them.
const st_pal: u16 = 0x0001;
const st_dma: u16 = 0x0002;
const st_hblank: u16 = 0x0004;
const st_vblank: u16 = 0x0008;
const st_odd: u16 = 0x0010;
const st_collision: u16 = 0x0020;
const st_overflow: u16 = 0x0040;
const st_vint: u16 = 0x0080;
const st_fifo_full: u16 = 0x0100;
const st_fifo_empty: u16 = 0x0200;

/// Register 0 bit 1 freezes the H/V counter at the value it had when the bit
/// was set; light-gun games and a few logo effects read it back.
const hvc_latch_bit: u8 = 0x02;

/// External access slots the VDP grants per line, which is the rate the FIFO
/// drains and DMA advances at. Refresh and rendering take the rest.
const slots_active_h32 = 16;
const slots_active_h40 = 18;
const slots_blank_h32 = 166;
const slots_blank_h40 = 204;

/// How much of the sprite table the VDP gets through: entries per frame, and
/// how many of them plus how many of their pixels fit on one line. Past
/// either line limit the rest of the sprites are simply not drawn, which is
/// the flicker every busy Genesis screen has.
const sprites_h32 = 64;
const sprites_h40 = 80;
const sprites_line_h32 = 16;
const sprites_line_h40 = 20;

/// Where in an active line each of those slots actually falls, in master
/// clocks: they are spread unevenly around the pattern and sprite fetches, so
/// a write's wait state is the gap to the next real slot rather than the
/// average. Measured values, from Genesis Plus GX's `vdp_ctrl.c`.
///
/// Extended a line past the end, because a write queued late in one line
/// drains on the next line's slots.
const slots_h32 = extendSlots(&.{
    230,  510,  810,  970,  1130, 1450, 1610, 1770,
    2090, 2250, 2410, 2730, 2890, 3050, 3350, 3370,
});
const slots_h40 = extendSlots(&.{
    352,  820,  948,  1076, 1332, 1460, 1588, 1844, 1972,
    2100, 2356, 2484, 2612, 2868, 2996, 3124, 3364, 3380,
});

/// A single write is only ever booked a couple of slots past the last one, so
/// the first few slots of the following line are all the overrun needed.
const slot_overrun = 12;

fn extendSlots(comptime line: []const u32) [line.len + slot_overrun]u32 {
    var out: [line.len + slot_overrun]u32 = undefined;
    for (line, 0..) |t, i| out[i] = t;
    for (0..slot_overrun) |i| out[line.len + i] = mclk_per_line + line[i];
    return out;
}

/// The FIFO is four words deep on every revision.
const fifo_len = 4;

/// Where in the line the HBlank status flag goes up and comes down again.
const hblank_start_h32 = 280;
const hblank_end_h32 = 860;
const hblank_start_h40 = 228;
const hblank_end_h40 = 872;

/// The H counter counts two pixels at a time and skips a block in the middle
/// of blanking, so it is a ramp from 0 with one jump in it.
const hc_counts_h32 = 171;
const hc_counts_h40 = 211;
const hc_jump_from_h32: u16 = 0x93;
const hc_jump_to_h32: u16 = 0xE9;
const hc_jump_from_h40: u16 = 0xB6;
const hc_jump_to_h40: u16 = 0xE4;

/// The V counter runs past the frame's last line and then repeats a block at
/// the top of its range, so line 235 NTSC reads back as 0xE5. PAL has more
/// lines to give away and does it later — and later again in V30, which is
/// why V30 on an NTSC machine (same 0xEA) rolls.
const vc_max_ntsc: u32 = 0xEA;
const vc_max_pal_v28: u32 = 0x102;
const vc_max_pal_v30: u32 = 0x10A;

/// CRAM holds 3 bits per channel; the DAC's ladder is not linear.
const level: [8]u8 = .{ 0, 52, 87, 116, 144, 172, 206, 255 };

/// A name-table entry and a sprite's attribute word share this layout.
const attr_pattern: u16 = 0x07FF;
const attr_hflip: u16 = 0x0800;
const attr_vflip: u16 = 0x1000;
const attr_palette: u16 = 0x6000;
const attr_palette_shift = 13;
const attr_priority: u16 = 0x8000;

/// Palette 3's last two colours, which shadow/highlight mode turns from
/// colours into operators on the pixel underneath.
const op_highlight: u8 = 0x3E;
const op_shadow: u8 = 0x3F;

/// One layer's contribution to a pixel: a 6-bit CRAM index plus its priority
/// bit. An index whose low nibble is zero is transparent.
const Pix = struct {
    pal: u8 = 0,
    pri: bool = false,

    fn visible(p: Pix) bool {
        return p.pal & 0xF != 0;
    }
};

/// The CRAM index a pattern's colour lands on: the attribute word picks one of
/// the four 16-colour palettes.
fn palIndex(attr: u16, c: u8) u8 {
    return @as(u8, @truncate((attr & attr_palette) >> attr_palette_shift)) << 4 | c;
}

pub const Vdp = struct {
    vram: [vram_size]u8 = @splat(0),
    cram: [cram_entries]u16 = @splat(0),
    vsram: [vsram_words]u16 = @splat(0),
    regs: [24]u8 = @splat(0),

    /// True once the first word of a two-word control write has arrived.
    /// Reading either port abandons the half-finished write.
    pending: bool = false,
    /// A15-A14 of the address, which only the second control word carries.
    addr_latch: u16 = 0,
    addr: u16 = 0,
    code: u6 = 0,

    /// The write FIFO: the data words themselves, and the master clock each
    /// one reaches its destination at. The write itself lands immediately —
    /// what is modelled here is when the chip *admits* to being done, which
    /// is what the status register's empty/full bits report and what stalls
    /// the 68000 on a full FIFO.
    fifo: [fifo_len]u16 = @splat(0),
    fifo_time: [fifo_len]u64 = @splat(0),
    fifo_idx: u2 = 0,

    /// A fill DMA is armed, waiting for the data write that carries its byte.
    fill_armed: bool = false,
    /// A 68k → VDP transfer was requested. The bus owner runs it and clears
    /// this, since only it can read the source.
    dma_request: bool = false,
    /// When the DMA in progress finishes, and whether one is.
    dma_end: u64 = 0,
    dma_busy: bool = false,

    /// Frozen H/V counter, while register 0 bit 1 asks for one.
    hvc_latch: ?u16 = null,

    /// 50 Hz, 313 lines: the machine's region, which only the VDP and the
    /// version register at $A10001 can see.
    pal: bool = false,
    /// Which field of an interlaced frame is being drawn. Always false when
    /// the display is progressive.
    odd: bool = false,

    /// Status bits 6 and 5, both set by rendering and cleared by reading the
    /// status register: more sprites (or sprite pixels) on a line than the
    /// VDP can fetch, and two sprites overlapping on one.
    sprite_overflow: bool = false,
    sprite_collision: bool = false,

    /// Status bit 7. Set at vblank, cleared by reading the status register.
    vint_flag: bool = false,
    /// The IPL6 line into the CPU. Same event, different lifetime: only an
    /// interrupt acknowledge clears this one.
    vint_irq: bool = false,
    hint_irq: bool = false,
    hint_counter: u8 = 0,
    in_vblank: bool = false,

    fb: [max_width * max_height]u32 = @splat(0xFF00_0000),

    // ------------------------------------------------------------- registers

    pub fn displayOn(v: *const Vdp) bool {
        return v.regs[1] & 0x40 != 0;
    }
    pub fn vintEnabled(v: *const Vdp) bool {
        return v.regs[1] & 0x20 != 0;
    }
    pub fn hintEnabled(v: *const Vdp) bool {
        return v.regs[0] & 0x10 != 0;
    }
    pub fn hintReload(v: *const Vdp) u8 {
        return v.regs[10];
    }
    fn dmaEnabled(v: *const Vdp) bool {
        return v.regs[1] & 0x10 != 0;
    }
    /// Shadow/highlight mode, which costs every pixel a brightness decision.
    fn shadowHighlight(v: *const Vdp) bool {
        return v.regs[12] & 0x08 != 0;
    }
    /// The CRAM entry drawn wherever no layer is visible.
    fn backdrop(v: *const Vdp) u8 {
        return v.regs[7] & 0x3F;
    }
    /// 320 pixels across instead of 256, which changes the access-slot budget
    /// and the H counter along with the picture.
    pub fn h40(v: *const Vdp) bool {
        return v.regs[12] & 0x01 != 0;
    }
    /// Mode 5 (Genesis) rather than mode 4 (Master System). Mode 4 has no
    /// second control word and cannot reach registers 11 and up.
    fn mode5(v: *const Vdp) bool {
        return v.regs[1] & 0x04 != 0;
    }
    /// Interlace: the two fields are drawn half a line apart, and in mode 2
    /// they carry different pictures — 448 lines instead of 224, which is
    /// what the two-player split-screen games use.
    fn interlaced(v: *const Vdp) bool {
        return v.regs[12] & 0x02 != 0;
    }
    fn im2(v: *const Vdp) bool {
        return v.regs[12] & 0x06 == 0x06;
    }
    /// The picture's size, and the buffer's: `fb` is `max_width` wide
    /// whatever the mode, so a row starts every `max_width` pixels.
    pub fn frameWidth(v: *const Vdp) u32 {
        return if (v.h40()) width_h40 else width_h32;
    }
    pub fn activeHeight(v: *const Vdp) u32 {
        return if (v.regs[1] & 0x08 != 0) height_v30 else height_v28;
    }
    pub fn frameHeight(v: *const Vdp) u32 {
        return v.activeHeight() * @as(u32, if (v.im2()) 2 else 1);
    }
    pub fn linesPerFrame(v: *const Vdp) u32 {
        return if (v.pal) lines_per_frame_pal else lines_per_frame;
    }
    /// The next frame's field. Progressive display has only the one.
    pub fn nextField(v: *Vdp) void {
        v.odd = v.interlaced() and !v.odd;
    }
    /// Added to `addr` after every data-port access.
    fn autoInc(v: *const Vdp) u8 {
        return v.regs[15];
    }

    fn word(v: *const Vdp, addr: u32) u16 {
        const a = addr & 0xFFFE;
        return @as(u16, v.vram[a]) << 8 | v.vram[a | 1];
    }

    // ----------------------------------------------------------- access slots

    fn blanked(v: *const Vdp) bool {
        return v.in_vblank or !v.displayOn();
    }

    fn accessSlots(v: *const Vdp) u64 {
        if (v.h40()) return if (v.blanked()) slots_blank_h40 else slots_active_h40;
        return if (v.blanked()) slots_blank_h32 else slots_active_h32;
    }

    fn slotTable(v: *const Vdp) []const u32 {
        return if (v.h40()) &slots_h40 else &slots_h32;
    }

    /// A VRAM access is a byte wide, so a word costs two slots. The invalid
    /// codes 0, 8 and 9 write nothing but cost the same two.
    fn byteAccess(v: *const Vdp) bool {
        return v.code & 0x06 == 0;
    }

    fn fifoEmpty(v: *const Vdp, now: u64) bool {
        return now >= v.fifo_time[v.fifo_idx -% 1];
    }

    fn fifoFull(v: *const Vdp, now: u64) bool {
        return now < v.fifo_time[v.fifo_idx];
    }

    /// Books the slot the entry about to be pushed will be written out on:
    /// the first slot after the entry ahead of it in the queue, plus a second
    /// one when the access is byte-wide.
    fn fifoBook(v: *Vdp, now: u64) void {
        const start = @max(now, v.fifo_time[v.fifo_idx -% 1]);
        const base = now - now % mclk_per_line;
        const rel = start - base;
        const table = v.slotTable();
        var slot: usize = 0;
        while (slot < table.len - 1 and rel >= table[slot]) slot += 1;
        v.fifo_time[v.fifo_idx] = base + table[@min(slot + @intFromBool(v.byteAccess()), table.len - 1)];
    }

    // ------------------------------------------------------------------ ports

    pub fn writeControl(v: *Vdp, now: u64, val: u16) void {
        if (v.pending) {
            v.pending = false;
            v.addr_latch = (val & 3) << 14;
            v.addr = v.addr_latch | (v.addr & 0x3FFF);
            v.code = @truncate((v.code & 0x03) | ((val >> 2) & 0x3C));
            // Bit 5 of the code asks for DMA; reg 1 bit 4 has to allow it.
            if (v.code & 0x20 != 0 and v.dmaEnabled()) v.startDma(now);
            return;
        }
        // The first word lands in the address and code registers on its own,
        // whether or not a second one ever follows — and a register write is
        // still a write to this port, so it moves them too.
        v.addr = v.addr_latch | (val & 0x3FFF);
        v.code = @truncate((v.code & 0x3C) | (val >> 14));
        if (val & 0xC000 == 0x8000) { // register write, one word
            v.writeReg(now, (val >> 8) & 0x1F, @truncate(val));
        } else {
            v.pending = v.mode5(); // mode 4 has no second control word
        }
    }

    /// Register index bit 5 (data bit 13) is masked off before it gets here,
    /// so $8000 and $A000 both write register 0.
    fn writeReg(v: *Vdp, now: u64, reg: u16, val: u8) void {
        if (!v.mode5() and reg > 10) return;
        if (reg >= v.regs.len) return;
        const changed = v.regs[reg] ^ val;
        v.regs[reg] = val;
        if (reg == 0 and changed & hvc_latch_bit != 0) {
            v.hvc_latch = if (val & hvc_latch_bit != 0) v.hvCounterAt(now) else null;
        }
    }

    /// Reading the status abandons a half-finished control write, and reports
    /// the FIFO and DMA as they stand at `now`.
    pub fn readStatus(v: *Vdp, now: u64) u16 {
        v.pending = false;
        if (v.dma_busy and now >= v.dma_end) v.dma_busy = false;

        var s: u16 = 0;
        if (v.pal) s |= st_pal;
        if (v.dma_busy) s |= st_dma;
        if (v.hblank(now)) s |= st_hblank;
        if (v.blanked()) s |= st_vblank;
        if (v.odd) s |= st_odd;
        if (v.sprite_collision) s |= st_collision;
        if (v.sprite_overflow) s |= st_overflow;
        if (v.vint_flag) s |= st_vint;
        if (v.fifoEmpty(now)) s |= st_fifo_empty else if (v.fifoFull(now)) s |= st_fifo_full;
        v.vint_flag = false;
        v.sprite_collision = false;
        v.sprite_overflow = false;
        return s;
    }

    fn hblank(v: *const Vdp, now: u64) bool {
        const pos = now % mclk_per_line;
        const start: u64 = if (v.h40()) hblank_start_h40 else hblank_start_h32;
        const end: u64 = if (v.h40()) hblank_end_h40 else hblank_end_h32;
        return pos >= start and pos < end;
    }

    /// A data-port write. Returns the master clock the 68000 has to wait for
    /// when the FIFO is full, or 0 when it can carry on.
    pub fn writeData(v: *Vdp, now: u64, val: u16) u64 {
        v.pending = false;
        var stall: u64 = 0;
        // Only worth queueing during the active display. Blanked, the VDP
        // grants ten times the slots and the FIFO never backs up.
        if (!v.blanked()) {
            if (v.fifoFull(now)) stall = v.fifo_time[v.fifo_idx];
            v.fifoBook(now);
        }
        v.busWrite(val);
        if (!v.fill_armed) return stall;
        v.fill_armed = false;
        v.dmaFill(now);
        return stall;
    }

    /// A data-port read is answered out of the read buffer the address and
    /// code registers point at, with no queueing: only writes go through the
    /// FIFO.
    pub fn readData(v: *Vdp) u16 {
        v.pending = false;
        // Bits the target does not drive come back off the bus, which is
        // still holding whatever the next FIFO entry has in it.
        const open = v.fifo[v.fifo_idx];
        const val: u16 = switch (v.code & 0x1F) {
            0x00 => v.word(v.addr),
            0x04 => v.readVsram() | (open & ~vsram_bits),
            0x08 => v.cram[(v.addr >> 1) & cram_mask] | (open & ~cram_bits),
            0x0C => v.vram[v.addr ^ 1] | (open & 0xFF00), // undocumented 8-bit VRAM read
            else => open,
        };
        v.addr +%= v.autoInc();
        return val;
    }

    fn readVsram(v: *const Vdp) u16 {
        const i = (v.addr >> 1) & vsram_mask;
        // The decoder only reaches 40 entries; past them it wraps to the first.
        return v.vsram[if (i >= vsram_visible) 0 else i] & vsram_bits;
    }

    /// One write to wherever the code points, then the auto-increment. The
    /// data word stays in the FIFO ring either way, since reads of anything
    /// the target does not drive come back out of it.
    pub fn busWrite(v: *Vdp, val: u16) void {
        v.fifo[v.fifo_idx] = val;
        v.fifo_idx +%= 1;
        switch (v.code & 0x0F) {
            1 => { // VRAM. An odd address swaps the two halves.
                const a = v.addr & 0xFFFE;
                const swap = v.addr & 1 != 0;
                v.vram[a] = @truncate(if (swap) val else val >> 8);
                v.vram[a | 1] = @truncate(if (swap) val >> 8 else val);
            },
            3 => v.cram[(v.addr >> 1) & cram_mask] = val & cram_bits,
            5 => v.vsram[(v.addr >> 1) & vsram_mask] = val,
            else => {},
        }
        v.addr +%= v.autoInc();
    }

    // -------------------------------------------------------------------- DMA

    pub fn dmaLength(v: *const Vdp) u32 {
        const len = @as(u32, v.regs[20]) << 8 | v.regs[19];
        return if (len == 0) 0x10000 else len;
    }

    /// Source address in 68k space: registers 21-23 hold it in words.
    pub fn dmaSource(v: *const Vdp) u32 {
        const w = @as(u32, v.regs[23] & 0x7F) << 16 | @as(u32, v.regs[22]) << 8 | v.regs[21];
        return w << 1;
    }

    pub const DmaKind = enum { transfer, fill, copy };

    /// DMA units per line, which is the access-slot budget adjusted for how
    /// many slots a unit of each kind actually costs. Matches the measured
    /// table in Genesis Plus GX's `vdp_ctrl.c`.
    fn dmaRate(v: *const Vdp, kind: DmaKind) u64 {
        const slots = v.accessSlots();
        return switch (kind) {
            // A word into VRAM is two byte-wide accesses. Into CRAM or VSRAM
            // it is one, but with the display off each refresh slot costs
            // another one.
            .transfer => if (v.byteAccess()) slots >> 1 else switch (slots) {
                slots_blank_h32 => 161,
                slots_blank_h40 => 198,
                else => slots,
            },
            .fill => slots - 1, // one slot per byte, less refresh
            .copy => slots >> 1, // a read and a write per byte
        };
    }

    /// ponytail: the rate is sampled once, at the DMA's start, so a transfer
    /// that straddles the end of blanking runs at the wrong speed for its
    /// tail. Meter it a line at a time (as GPGX does) if a game turns out to
    /// care.
    pub fn dmaMclk(v: *const Vdp, kind: DmaKind, units: u64) u64 {
        return units * mclk_per_line / v.dmaRate(kind);
    }

    pub fn dmaBusyUntil(v: *Vdp, end: u64) void {
        v.dma_busy = true;
        v.dma_end = end;
    }

    /// The source registers count up as the transfer runs and are left where
    /// it ended; the length registers are counted down to zero. Both are what
    /// a game reads back to see the DMA it just asked for actually happened.
    pub fn dmaDone(v: *Vdp) void {
        const src = @as(u16, v.regs[22]) << 8 | v.regs[21];
        const end = src +% (@as(u16, v.regs[20]) << 8 | v.regs[19]);
        v.regs[21] = @truncate(end);
        v.regs[22] = @truncate(end >> 8);
        v.regs[19] = 0;
        v.regs[20] = 0;
    }

    fn startDma(v: *Vdp, now: u64) void {
        switch (@as(u2, @truncate(v.regs[23] >> 6))) {
            0, 1 => v.dma_request = true, // 68k → VDP; the bus owner runs it
            2 => {
                // Armed, but nothing happens and nothing can clear the busy
                // flag until the data write carrying the fill byte arrives.
                v.fill_armed = true;
                v.dmaBusyUntil(std.math.maxInt(u64));
            },
            3 => v.dmaCopy(now),
        }
    }

    /// The byte written to the data port fills VRAM; CRAM and VSRAM fill from
    /// the oldest FIFO entry instead, which is stale data the game did not
    /// write here and is exactly what hardware does.
    fn dmaFill(v: *Vdp, now: u64) void {
        var len = v.dmaLength();
        // The data-port write that triggered the fill costs two slots of its
        // own before the fill proper starts.
        v.dmaBusyUntil(now + v.dmaMclk(.fill, len + 2));
        switch (v.code & 0x0F) {
            1 => {
                const b: u8 = @truncate(v.fifo[v.fifo_idx -% 1] >> 8);
                while (len > 0) : (len -= 1) {
                    v.vram[v.addr ^ 1] = b;
                    v.addr +%= v.autoInc();
                }
            },
            3 => {
                const d = v.fifo[v.fifo_idx] & cram_bits;
                while (len > 0) : (len -= 1) {
                    v.cram[(v.addr >> 1) & cram_mask] = d;
                    v.addr +%= v.autoInc();
                }
            },
            5 => {
                const d = v.fifo[v.fifo_idx];
                while (len > 0) : (len -= 1) {
                    v.vsram[(v.addr >> 1) & vsram_mask] = d;
                    v.addr +%= v.autoInc();
                }
            },
            // An invalid target writes nothing but still walks the address.
            else => v.addr +%= @truncate(v.autoInc() *% len),
        }
        v.dmaDone();
    }

    fn dmaCopy(v: *Vdp, now: u64) void {
        var src: u16 = @as(u16, v.regs[22]) << 8 | v.regs[21];
        var len = v.dmaLength();
        v.dmaBusyUntil(now + v.dmaMclk(.copy, len));
        while (len > 0) : (len -= 1) {
            v.vram[v.addr ^ 1] = v.vram[src ^ 1];
            src +%= 1;
            v.addr +%= v.autoInc();
        }
        v.dmaDone();
    }

    // ------------------------------------------------------------ H/V counter

    pub fn hvCounter(v: *const Vdp, now: u64) u16 {
        return v.hvc_latch orelse v.hvCounterAt(now);
    }

    fn hvCounterAt(v: *const Vdp, now: u64) u16 {
        const lines = v.linesPerFrame();
        const line = (now / mclk_per_line) % lines;
        var vc = if (line > v.vcMax()) line -% lines else line;
        // Interlaced, the counter's low bit reports its ninth instead.
        if (v.interlaced()) vc = (vc & ~@as(u64, 1)) | (vc >> 8 & 1);
        return @as(u16, @truncate(vc)) << 8 | v.hCounter(now % mclk_per_line);
    }

    fn vcMax(v: *const Vdp) u64 {
        if (!v.pal) return vc_max_ntsc;
        return if (v.activeHeight() == height_v30) vc_max_pal_v30 else vc_max_pal_v28;
    }

    fn hCounter(v: *const Vdp, pos: u64) u8 {
        const counts: u64 = if (v.h40()) hc_counts_h40 else hc_counts_h32;
        const from: u16 = if (v.h40()) hc_jump_from_h40 else hc_jump_from_h32;
        const to: u16 = if (v.h40()) hc_jump_to_h40 else hc_jump_to_h32;
        const i: u16 = @truncate(pos * counts / mclk_per_line);
        return @truncate(if (i <= from) i else i + (to - from - 1));
    }

    // ---------------------------------------------------------------- drawing

    /// What the pixel's palette entry is worth once the shadow/highlight
    /// operators have had their say. Both are a one-bit shift of every
    /// channel, which is all the DAC can do.
    const Shade = enum { shadow, normal, highlight };

    fn color(v: *const Vdp, idx: u8, shade: Shade) u32 {
        const c = v.cram[idx & cram_mask];
        const r = shadeLevel((c >> 1) & 7, shade);
        const g = shadeLevel((c >> 5) & 7, shade);
        const b = shadeLevel((c >> 9) & 7, shade);
        // Little-endian R8G8B8A8, which is what the texture upload wants.
        return 0xFF00_0000 | @as(u32, b) << 16 | @as(u32, g) << 8 | r;
    }

    fn shadeLevel(c: u16, shade: Shade) u8 {
        return switch (shade) {
            .normal => level[c],
            .shadow => level[c >> 1],
            .highlight => level[(c >> 1) + 4],
        };
    }

    /// One pixel out of a pattern. Patterns are 8x8 and 32 bytes, except in
    /// the double-resolution interlaced mode where they are 8x16 and 64 —
    /// twice the pattern for the same 64 KiB, so the index loses a bit.
    fn patternPixel(v: *const Vdp, index: u16, x: u32, y: u32) u8 {
        const base: u32 = if (v.im2())
            (@as(u32, index) & (attr_pattern >> 1)) * 64
        else
            (@as(u32, index) & attr_pattern) * 32;
        const b = v.vram[(base + y * 4 + x / 2) & vram_mask];
        return if (x & 1 == 0) b >> 4 else b & 0xF;
    }

    /// One pixel out of the tile a name-table entry points at. `y` is the row
    /// within the cell, which interlace mode 2 splits between the two fields.
    fn tilePixel(v: *const Vdp, entry_addr: u32, x: u32, y: u32) Pix {
        const e = v.word(entry_addr);
        const rows: u32 = if (v.im2()) 16 else 8;
        const py = if (v.im2()) y * 2 + @intFromBool(v.odd) else y;
        const tx = if (e & attr_hflip != 0) 7 - x else x;
        const ty = if (e & attr_vflip != 0) rows - 1 - py else py;
        const c = v.patternPixel(e, tx, ty);
        return .{ .pal = palIndex(e, c), .pri = e & attr_priority != 0 };
    }

    /// One dimension of the plane-size register (16), in cells. 2 is an
    /// invalid encoding; 64 is the sane reading.
    fn planeCells(bits: u2) u32 {
        return switch (bits) {
            0 => 32,
            3 => 128,
            else => 64,
        };
    }

    fn planeRow(v: *const Vdp, line: u32, plane: u32, out: []Pix) void {
        const cells_w = planeCells(@truncate(v.regs[16]));
        const cells_h = planeCells(@truncate(v.regs[16] >> 4));
        const nt: u32 = if (plane == 0)
            @as(u32, v.regs[2] & 0x38) << 10
        else
            @as(u32, v.regs[4] & 0x7) << 13;

        const hs_table: u32 = @as(u32, v.regs[13] & 0x3F) << 10;
        const hs_entry: u32 = switch (v.regs[11] & 3) {
            0 => 0, // one value for the whole screen
            1 => (line & 7) * 4, // the odd "first eight lines" mode
            2 => (line & ~@as(u32, 7)) * 4, // per cell row
            else => line * 4, // per line
        };
        const hscroll = v.word(hs_table + hs_entry + plane * 2) & 0x3FF;
        const per_column = v.regs[11] & 4 != 0;

        for (out, 0..) |*px, i| {
            const x: u32 = @intCast(i);
            const vs = if (per_column)
                v.vsram[(x / 16 * 2 + plane) % vsram_visible]
            else
                v.vsram[plane];
            const ys = (line + vs) & (cells_h * 8 - 1);
            const xs = (x -% hscroll) & (cells_w * 8 - 1);
            px.* = v.tilePixel(nt + (ys / 8 * cells_w + xs / 8) * 2, xs & 7, ys & 7);
        }
    }

    /// The window replaces plane A wherever it covers, and never scrolls. Its
    /// name table is as wide as the display and aligned to its own size, so
    /// H40 has to drop a bit of the base address that H32 keeps.
    fn applyWindow(v: *const Vdp, line: u32, out: []Pix) void {
        const wx = @as(u32, v.regs[17] & 0x1F) * 16;
        const wy = @as(u32, v.regs[18] & 0x1F) * 8;
        const rows = if (v.regs[18] & 0x80 != 0) line >= wy else line < wy;
        const cells: u32 = if (v.h40()) 64 else 32;
        const nt: u32 = @as(u32, v.regs[3] & @as(u8, if (v.h40()) 0x3C else 0x3E)) << 10;
        for (out, 0..) |*px, i| {
            const x: u32 = @intCast(i);
            const cols = if (v.regs[17] & 0x80 != 0) x >= wx else x < wx;
            if (!rows and !cols) continue;
            px.* = v.tilePixel(nt + (line / 8 * cells + x / 8) * 2, x & 7, line & 7);
        }
    }

    /// The sprite layer, in link-list order and under the two budgets the
    /// fetcher works to: so many sprites on a line, and so many of their
    /// pixels. Running out of either drops the rest of the list, which is
    /// what makes a crowded screen flicker.
    fn spriteRow(v: *Vdp, line: u32, out: []Pix) void {
        const table: u32 = @as(u32, v.regs[5] & @as(u8, if (v.h40()) 0x7E else 0x7F)) << 9;
        const max_entries: u32 = if (v.h40()) sprites_h40 else sprites_h32;
        const max_line: u32 = if (v.h40()) sprites_line_h40 else sprites_line_h32;
        const max_pixels: u32 = @intCast(out.len);

        var pixels: u32 = 0;
        var on_line: u32 = 0;
        var link: u32 = 0;
        var seen: u32 = 0;
        while (seen < max_entries) : (seen += 1) {
            const e = table + link * 8;
            // Interlace mode 2 doubles the vertical resolution of the sprite
            // position too, so its Y is in fields rather than lines.
            const ypos = v.word(e) & @as(u16, if (v.im2()) 0x3FF else 0x1FF);
            const top = @as(i32, if (v.im2()) ypos >> 1 else ypos) - 128;
            const sz = v.vram[(e + 2) & vram_mask];
            const cells_w: u32 = (sz >> 2 & 3) + 1;
            const cells_h: u32 = (sz & 3) + 1;
            const dy = @as(i32, @intCast(line)) - top;
            if (dy >= 0 and dy < cells_h * 8) {
                on_line += 1;
                if (on_line > max_line) {
                    v.sprite_overflow = true;
                    break;
                }
                const x = v.word(e + 6) & 0x1FF;
                // A sprite at X=0 masks everything behind it on the line, but
                // only once another sprite has already spent pixels there.
                if (x == 0 and pixels > 0) break;
                v.spriteCells(v.word(e + 4), @as(i32, x) - 128, @intCast(dy), cells_w, cells_h, out, max_pixels - pixels);
                pixels += cells_w * 8;
                if (pixels >= max_pixels) {
                    v.sprite_overflow = true;
                    break;
                }
            }
            link = v.vram[(e + 3) & vram_mask] & 0x7F;
            if (link == 0) break;
        }
    }

    fn spriteCells(
        v: *Vdp,
        attr: u16,
        left: i32,
        dy: u32,
        cells_w: u32,
        cells_h: u32,
        out: []Pix,
        budget: u32,
    ) void {
        const first: u16 = attr & attr_pattern;
        const pri = attr & attr_priority != 0;
        const cell_rows: u32 = if (v.im2()) 16 else 8;
        const py = if (v.im2()) dy * 2 + @intFromBool(v.odd) else dy;
        const row = if (attr & attr_vflip != 0) cells_h * cell_rows - 1 - py else py;

        // The budget cuts the sprite off mid-way, on- or off-screen alike:
        // the fetcher spends its pixels either way.
        for (0..@min(cells_w * 8, budget)) |i| {
            const sx = left + @as(i32, @intCast(i));
            const col: u32 = if (attr & attr_hflip != 0) cells_w * 8 - 1 - @as(u32, @intCast(i)) else @intCast(i);
            // Sprite tiles run down each column before moving right.
            const tile = first +% @as(u16, @truncate(col / 8 * cells_h + row / cell_rows));
            const c = v.patternPixel(tile, col & 7, row % cell_rows);
            if (c == 0) continue;
            if (sx < 0 or sx >= @as(i32, @intCast(out.len))) continue;
            const dst = &out[@intCast(sx)];
            if (dst.visible()) { // first sprite down the link list wins
                v.sprite_collision = true;
                continue;
            }
            dst.* = .{ .pal = palIndex(attr, c), .pri = pri };
        }
    }

    /// Which layer owns the pixel: sprites over plane A over plane B, high
    /// priority before low, the backdrop when nothing is visible at all.
    fn topPixel(v: *const Vdp, layers: [3]Pix) u8 {
        for (layers) |p| if (p.visible() and p.pri) return p.pal;
        for (layers) |p| if (p.visible()) return p.pal;
        return v.backdrop();
    }

    /// A pixel no plane claims priority on is drawn at half brightness, and
    /// palette 3's last two colours stop being colours: they operate on the
    /// pixel underneath and are not themselves drawn, which is why `sprite` is
    /// taken by pointer. A high-priority sprite pixel is always full brightness.
    fn shadeOf(on: bool, ca: Pix, cb: Pix, sprite: *Pix) Shade {
        if (!on) return .normal;
        const dim: Shade = if (ca.pri or cb.pri) .normal else .shadow;
        switch (sprite.pal) {
            op_highlight => {
                sprite.* = .{};
                return if (dim == .shadow) .normal else .highlight;
            },
            // Shadowing an already-shadowed pixel changes nothing.
            op_shadow => {
                sprite.* = .{};
                return .shadow;
            },
            else => {},
        }
        if (sprite.visible() and sprite.pri) return .normal;
        return dim;
    }

    pub fn renderLine(v: *Vdp, line: u32) void {
        const w = v.frameWidth();
        // Interlaced double resolution weaves the two fields into one buffer,
        // so a field's line 1 is the picture's line 2 or 3.
        const y = if (v.im2()) line * 2 + @intFromBool(v.odd) else line;
        const row = v.fb[y * max_width ..][0..w];
        if (!v.displayOn()) {
            @memset(row, v.color(v.backdrop(), .normal));
            return;
        }

        var pa: [max_width]Pix = @splat(.{});
        var pb: [max_width]Pix = @splat(.{});
        var ps: [max_width]Pix = @splat(.{});
        const a = pa[0..w];
        const b = pb[0..w];
        const s = ps[0..w];
        v.planeRow(line, 1, b);
        v.planeRow(line, 0, a);
        v.applyWindow(line, a);
        v.spriteRow(line, s);

        const sh = v.shadowHighlight();
        for (row, a, b, s) |*out, ca, cb, cs| {
            var sprite = cs;
            const shade = shadeOf(sh, ca, cb, &sprite);
            out.* = v.color(v.topPixel(.{ sprite, ca, cb }), shade);
        }
    }
};

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// Mode 5, display on, DMA allowed: the state every test below starts from,
/// since mode 4 locks out most of the registers.
fn testVdp() Vdp {
    var v = Vdp{};
    v.regs[1] = 0x54; // display on, DMA enabled, mode 5
    return v;
}

test "control port: register writes, address latch, and a fill" {
    var v = testVdp();

    v.writeControl(0, 0x8F02); // reg 15 (auto-increment) = 2
    try testing.expectEqual(@as(u8, 2), v.regs[15]);

    // Two-word write: VRAM write at $C000.
    v.writeControl(0, 0x4000);
    v.writeControl(0, 0x0003);
    try testing.expectEqual(@as(u16, 0xC000), v.addr);
    try testing.expectEqual(@as(u6, 1), v.code);

    _ = v.writeData(0, 0x1234);
    try testing.expectEqual(@as(u8, 0x12), v.vram[0xC000]);
    try testing.expectEqual(@as(u8, 0x34), v.vram[0xC001]);
    try testing.expectEqual(@as(u16, 0xC002), v.addr);

    // Arm a fill of 4 words at $D000: reg 23 selects it.
    v.writeControl(0, 0x9304); // length low = 4
    v.writeControl(0, 0x9400); // length high
    v.writeControl(0, 0x9780); // source high: fill
    v.writeControl(0, 0x5000);
    v.writeControl(0, 0x0083); // VRAM write + DMA
    try testing.expect(v.fill_armed);
    _ = v.writeData(0, 0xAB00);
    try testing.expect(!v.fill_armed);
    // The data write itself lands at $D000; the fill runs on from there, one
    // byte per step at the odd side of each address.
    try testing.expectEqual(@as(u8, 0xAB), v.vram[0xD000]);
    try testing.expectEqual(@as(u8, 0xAB), v.vram[0xD003]);
    try testing.expectEqual(@as(u8, 0xAB), v.vram[0xD009]); // 4th, inc 2
    try testing.expectEqual(@as(u8, 0x00), v.vram[0xD00B]); // and no further
    try testing.expectEqual(@as(u32, 0x10000), v.dmaLength()); // reset to 0
}

test "the first control word lands on its own, without waiting for the second" {
    var v = testVdp();
    v.writeControl(0, 0x9F00); // reg 31: masked to reg 15, and not a real one
    v.writeControl(0, 0x7123);

    // Address low bits and code bits 0-1 are updated by the first word alone.
    try testing.expectEqual(@as(u16, 0x3123), v.addr);
    try testing.expectEqual(@as(u6, 1), v.code);
    try testing.expect(v.pending);

    // ...and reading either port abandons the write that is half-arrived.
    _ = v.readStatus(0);
    try testing.expect(!v.pending);
}

test "register writes: bit 13 is masked and mode 4 locks registers 11 and up" {
    var v = Vdp{}; // mode 4: reg 1 bit 2 clear
    v.writeControl(0, 0xA702); // bit 13 set: still register 7
    try testing.expectEqual(@as(u8, 2), v.regs[7]);

    v.writeControl(0, 0x8B03); // reg 11 in mode 4: ignored
    try testing.expectEqual(@as(u8, 0), v.regs[11]);
    v.writeControl(0, 0x8104); // mode 5 from here on
    v.writeControl(0, 0x8B03);
    try testing.expectEqual(@as(u8, 3), v.regs[11]);

    // A register write is still a control-port write: the address and the low
    // two code bits move with it.
    try testing.expectEqual(@as(u16, 0x0B03), v.addr);
    try testing.expectEqual(@as(u6, 2), v.code);
}

test "the FIFO fills at the access-slot rate and reports itself" {
    var v = testVdp();
    v.regs[12] = 0x01; // H40
    v.writeControl(0, 0x4000);
    v.writeControl(0, 0x0000); // VRAM write at 0

    try testing.expectEqual(@as(u16, st_fifo_empty), v.readStatus(0) & 0x300);

    // Four words back to back, each two slots wide because VRAM is byte-wide.
    for (0..fifo_len) |_| _ = v.writeData(0, 0xFFFF);
    try testing.expectEqual(@as(u16, st_fifo_full), v.readStatus(0) & 0x300);

    // A fifth stalls the CPU until the oldest entry has been written out,
    // which is the line's second access slot.
    try testing.expectEqual(@as(u64, slots_h40[1]), v.writeData(0, 0xFFFF));

    // ...and once the whole queue has drained, empty again.
    try testing.expectEqual(@as(u16, st_fifo_empty), v.readStatus(2 * mclk_per_line) & 0x300);
}

test "DMA fill reaches CRAM and VSRAM, out of the oldest FIFO entry" {
    var v = testVdp();
    v.writeControl(0, 0x8F02); // auto-increment 2
    v.writeControl(0, 0x9302); // length 2
    v.writeControl(0, 0x9400);
    v.writeControl(0, 0x9780); // fill

    // A fill into CRAM or VSRAM takes its data from the *oldest* FIFO entry,
    // three words back, which is stale data the game never meant to write —
    // and is exactly what hardware does. Fill the ring so it is known.
    v.writeControl(0, 0xC000);
    v.writeControl(0, 0x0000); // CRAM write at 0
    _ = v.writeData(0, 0x0EEE);
    _ = v.writeData(0, 0x0222);
    _ = v.writeData(0, 0x0444);

    v.writeControl(0, 0xC010);
    v.writeControl(0, 0x0080); // CRAM write + DMA at entry 8
    _ = v.writeData(0, 0x0666);

    try testing.expectEqual(@as(u16, 0x0666), v.cram[8]); // the write itself
    try testing.expectEqual(@as(u16, 0x0EEE), v.cram[9]); // ...then the fill
    try testing.expectEqual(@as(u16, 0x0EEE), v.cram[10]);

    // Same again into VSRAM, where the whole word survives.
    v.writeControl(0, 0x9302);
    v.writeControl(0, 0x9400);
    v.writeControl(0, 0x9780);
    v.writeControl(0, 0x4004);
    v.writeControl(0, 0x0090); // VSRAM write + DMA at entry 2
    _ = v.writeData(0, 0x0111);

    try testing.expectEqual(@as(u16, 0x0111), v.vsram[2]);
    try testing.expectEqual(@as(u16, 0x0222), v.vsram[3]);
    try testing.expectEqual(@as(u16, 0x0222), v.vsram[4]);
}

test "read targets: VRAM, VSRAM, CRAM, the 8-bit VRAM read, and open bus" {
    var v = testVdp();
    v.vram[0x100] = 0x12;
    v.vram[0x101] = 0x34;
    v.cram[1] = 0x0246;
    v.vsram[1] = 0x123;

    v.writeControl(0, 0x0100);
    v.writeControl(0, 0x0000); // VRAM read at $100
    try testing.expectEqual(@as(u16, 0x1234), v.readData());

    v.writeControl(0, 0x0002);
    v.writeControl(0, 0x0010); // VSRAM read at 2
    try testing.expectEqual(@as(u16, 0x123), v.readData() & vsram_bits);

    v.writeControl(0, 0x0002);
    v.writeControl(0, 0x0020); // CRAM read at 2
    try testing.expectEqual(@as(u16, 0x0246), v.readData() & cram_bits);

    // Code $0C: one byte from the *adjacent* VRAM address, high bits off the
    // bus, which is still holding the last word written through the FIFO.
    v.fifo[v.fifo_idx] = 0xAB00;
    v.writeControl(0, 0x0100);
    v.writeControl(0, 0x0030);
    try testing.expectEqual(@as(u16, 0xAB34), v.readData());
}

test "the H/V counter ramps, jumps, and freezes when register 0 asks it to" {
    var v = testVdp();
    v.regs[12] = 0x01; // H40

    try testing.expectEqual(@as(u16, 0), v.hvCounter(0));
    // Line 10, a third of the way in: V in the high byte, H ramping below.
    const at = 10 * mclk_per_line + mclk_per_line / 3;
    try testing.expectEqual(@as(u8, 10), @as(u8, @truncate(v.hvCounter(at) >> 8)));
    const h = @as(u8, @truncate(v.hvCounter(at)));
    try testing.expect(h > 0x40 and h < 0x60);

    // Past the jump the counter is up in the 0xE4-0xFF block.
    const late = 10 * mclk_per_line + mclk_per_line - 10;
    try testing.expect(@as(u8, @truncate(v.hvCounter(late))) >= hc_jump_to_h40);

    // The V counter repeats a block at the top rather than running to 262.
    const wrapped = 250 * mclk_per_line;
    try testing.expectEqual(@as(u8, 250 - lines_per_frame + 256), @as(u8, @truncate(v.hvCounter(wrapped) >> 8)));

    // Latched: the same value however much later it is read.
    v.writeControl(at, 0x8000 | @as(u16, hvc_latch_bit));
    const frozen = v.hvCounter(at);
    try testing.expectEqual(frozen, v.hvCounter(at + 5 * mclk_per_line));
    v.writeControl(at, 0x8000); // and free-running again
    try testing.expect(v.hvCounter(at + 5 * mclk_per_line) != frozen);
}

test "a plane pixel comes out the colour the name table and CRAM say" {
    var v = Vdp{};
    v.regs[1] = 0x40; // display on
    v.regs[4] = 0x07; // plane B up at $E000, out of the way
    v.regs[13] = 0x20; // H-scroll table at $8000, likewise
    v.regs[16] = 0x01; // 64x32 cells
    v.cram[0x11] = 0x0EEE; // palette 1, colour 1: white

    // Name table for plane A at 0, tile 1, palette 1, high priority.
    v.vram[0] = 0x20 | 0x80;
    v.vram[1] = 0x01;
    v.vram[32] = 0x11; // tile 1, row 0: two pixels of colour 1

    v.renderLine(0);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), v.fb[0]);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), v.fb[1]);
    try testing.expectEqual(v.color(0, .normal), v.fb[2]); // transparent → backdrop
}

test "interlace mode 2 weaves two fields of 8x16 patterns into one picture" {
    var v = Vdp{};
    v.regs[1] = 0x44; // display on, mode 5
    v.regs[12] = 0x07; // H40, interlace mode 2
    v.regs[4] = 0x07; // plane B up at $E000, out of the way
    v.regs[13] = 0x20; // H-scroll table at $8000, likewise
    v.regs[16] = 0x01; // 64x32 cells
    v.cram[1] = 0x000E;
    v.cram[2] = 0x0E00;

    v.vram[1] = 0x01; // plane A cell 0: tile 1
    v.vram[64] = 0x11; // tile 1 is 64 bytes here: row 0 is colour 1...
    v.vram[68] = 0x22; // ...and row 1, the other field's, is colour 2

    try testing.expectEqual(@as(u32, 448), v.frameHeight());
    v.renderLine(0);
    try testing.expectEqual(v.color(1, .normal), v.fb[0]);

    v.nextField();
    v.renderLine(0);
    // The second field's line 0 is the picture's line 1, not line 0 again.
    try testing.expectEqual(v.color(1, .normal), v.fb[0]);
    try testing.expectEqual(v.color(2, .normal), v.fb[max_width]);
}

test "the picture's size is a mode, not a constant" {
    var v = testVdp();
    try testing.expectEqual(@as(u32, 256), v.frameWidth()); // H32
    try testing.expectEqual(@as(u32, 224), v.frameHeight());
    try testing.expectEqual(@as(u32, 262), v.linesPerFrame());

    v.regs[12] = 0x01; // H40
    v.regs[1] |= 0x08; // V30
    try testing.expectEqual(@as(u32, 320), v.frameWidth());
    try testing.expectEqual(@as(u32, 240), v.frameHeight());

    v.regs[12] |= 0x06; // interlace mode 2: two fields, two pictures
    try testing.expectEqual(@as(u32, 480), v.frameHeight());
    v.nextField();
    try testing.expect(v.odd);
    v.regs[12] &= ~@as(u8, 0x06);
    v.nextField(); // progressive again: only ever the one field
    try testing.expect(!v.odd);

    v.pal = true;
    try testing.expectEqual(@as(u32, 313), v.linesPerFrame());
    try testing.expect(v.readStatus(0) & st_pal != 0);
}

/// Fills a sprite table at $8000 with `n` 8x8 sprites of tile 1, all on line
/// 0 and eight pixels apart, linked in order. `mask_at` gets X=0 instead,
/// which is what a masking sprite is.
fn spriteLine(v: *Vdp, n: u16, mask_at: ?u16) void {
    v.regs[5] = 0x40; // $8000 >> 9
    @memset(v.vram[32..64], 0x11); // tile 1: solid colour 1
    for (0..n) |i| {
        const e = 0x8000 + i * 8;
        v.vram[e] = 0;
        v.vram[e + 1] = 128; // line 0
        v.vram[e + 2] = 0; // one cell square
        v.vram[e + 3] = if (i + 1 < n) @truncate(i + 1) else 0;
        v.vram[e + 4] = 0;
        v.vram[e + 5] = 1; // tile 1, palette 0, low priority
        const idx: u16 = @truncate(i);
        const x: u16 = if (idx == (mask_at orelse 0xFFFF)) 0 else 128 + idx * 8;
        v.vram[e + 6] = @truncate(x >> 8);
        v.vram[e + 7] = @truncate(x);
    }
}

test "a line only fits so many sprites, and one at X=0 masks the rest" {
    var v = testVdp();
    v.cram[1] = 0x0EEE;
    const white = v.color(1, .normal);

    // H32 stops at sixteen sprites a line and says so in the status register.
    spriteLine(&v, 17, null);
    v.renderLine(0);
    try testing.expect(v.sprite_overflow);
    try testing.expectEqual(white, v.fb[15 * 8]);
    try testing.expectEqual(v.color(0, .normal), v.fb[16 * 8]); // never fetched
    try testing.expect(v.readStatus(0) & st_overflow != 0);
    try testing.expect(!v.sprite_overflow); // and the read cleared it

    // The third sprite sits at X=0, so the fourth is never drawn either.
    v.regs[12] = 0x01; // H40, where sixteen sprites are not yet a limit
    spriteLine(&v, 4, 2);
    v.renderLine(0);
    try testing.expectEqual(white, v.fb[8]);
    try testing.expectEqual(v.color(0, .normal), v.fb[24]);
    try testing.expect(!v.sprite_overflow);
}

test "shadow and highlight dim the picture, and two sprite colours undim it" {
    var v = testVdp();
    v.regs[12] = 0x09; // H40, shadow/highlight on
    v.cram[0] = 0x0888; // a mid grey: 144 normal, 87 shadowed, 206 highlit

    // Nothing on either plane claims priority, so the backdrop is shadowed.
    v.renderLine(0);
    try testing.expectEqual(@as(u8, 87), @as(u8, @truncate(v.fb[0])));

    // Palette 3 colour 14 is the highlight operator: it is not drawn, it
    // undoes the shadow. Colour 15 is the shadow operator, and shadowing an
    // already-shadowed pixel changes nothing.
    spriteLine(&v, 1, null);
    @memset(v.vram[32..64], 0xEE); // tile 1: solid colour 14
    v.vram[0x8004] = 0x60; // palette 3
    v.renderLine(0);
    try testing.expectEqual(@as(u8, 144), @as(u8, @truncate(v.fb[0])));

    @memset(v.vram[32..64], 0xFF); // colour 15
    v.renderLine(0);
    try testing.expectEqual(@as(u8, 87), @as(u8, @truncate(v.fb[0])));

    // Turned off, palette 3 colour 14 is only ever a colour.
    v.regs[12] = 0x01;
    v.cram[0x3E] = 0x000E;
    @memset(v.vram[32..64], 0xEE);
    v.renderLine(0);
    try testing.expectEqual(v.color(0x3E, .normal), v.fb[0]);
}
