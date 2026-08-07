//! Sega Genesis VDP (315-5313) — enough of one to draw a game.
//!
//! Knows nothing about the 68000 or the bus: `genesis.zig` forwards port
//! accesses here and runs the one DMA mode that needs to read the 68k bus.
//! Rendering is per scanline, which is what line-scroll effects (water
//! surfaces, title-screen wobble) need and no more.
//!
//! Deliberately absent: shadow/highlight, interlace, H32 mode, the per-line
//! sprite/pixel limits and sprite masking. Most games never touch them, and
//! each is a self-contained addition to the pixel loop below (see M4 in
//! DESIGN.md).

const std = @import("std");

pub const width = 320; // H40 only
pub const height = 224;

/// CRAM holds 3 bits per channel; the DAC's ladder is not linear.
const level: [8]u8 = .{ 0, 52, 87, 116, 144, 172, 206, 255 };

/// One layer's contribution to a pixel: a 6-bit CRAM index plus its priority
/// bit. An index whose low nibble is zero is transparent.
const Pix = struct {
    pal: u8 = 0,
    pri: bool = false,

    fn visible(p: Pix) bool {
        return p.pal & 0xF != 0;
    }
};

pub const Vdp = struct {
    vram: [0x10000]u8 = @splat(0),
    cram: [64]u16 = @splat(0),
    vsram: [40]u16 = @splat(0),
    regs: [24]u8 = @splat(0),

    /// First word of a two-word control write, once one has arrived.
    latch: ?u16 = null,
    addr: u16 = 0,
    code: u6 = 0,
    /// A fill DMA is armed, waiting for the data write that carries its byte.
    fill_armed: bool = false,
    /// A 68k → VDP transfer was requested. The bus owner runs it and clears
    /// this, since only it can read the source.
    dma_request: bool = false,

    /// Status bit 7. Set at vblank, cleared by reading the status register.
    vint_flag: bool = false,
    /// The IPL6 line into the CPU. Same event, different lifetime: only an
    /// interrupt acknowledge clears this one.
    vint_irq: bool = false,
    hint_irq: bool = false,
    hint_counter: u8 = 0,
    in_vblank: bool = false,

    fb: [width * height]u32 = @splat(0xFF00_0000),

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
    /// Added to `addr` after every data-port access.
    fn autoInc(v: *const Vdp) u8 {
        return v.regs[15];
    }

    fn word(v: *const Vdp, addr: u32) u16 {
        const a = addr & 0xFFFE;
        return @as(u16, v.vram[a]) << 8 | v.vram[a | 1];
    }

    // ------------------------------------------------------------------ ports

    pub fn writeControl(v: *Vdp, val: u16) void {
        if (v.latch) |first| {
            v.latch = null;
            v.addr = (first & 0x3FFF) | (@as(u16, val & 3) << 14);
            v.code = @truncate(((first >> 14) & 3) | ((val >> 2) & 0x3C));
            // Bit 5 of the code asks for DMA; reg 1 bit 4 has to allow it.
            if (v.code & 0x20 != 0 and v.regs[1] & 0x10 != 0) v.startDma();
            return;
        }
        if (val & 0xE000 == 0x8000) { // register write, one word
            const reg = (val >> 8) & 0x1F;
            if (reg < v.regs.len) v.regs[reg] = @truncate(val);
            return;
        }
        v.latch = val;
    }

    /// Reading the status also abandons a half-finished control write.
    pub fn readStatus(v: *Vdp) u16 {
        v.latch = null;
        // Bits 10-15 are open bus on hardware; FIFO reads empty and DMA idle
        // because both finish instantly here.
        var s: u16 = 0x3400 | 0x0200;
        if (v.in_vblank) s |= 0x08;
        if (v.vint_flag) s |= 0x80;
        v.vint_flag = false;
        return s;
    }

    pub fn writeData(v: *Vdp, val: u16) void {
        v.writeTarget(val);
        if (!v.fill_armed) return;
        v.fill_armed = false;
        const b: u8 = @truncate(val >> 8);
        var len = v.dmaLength();
        while (len > 0) : (len -= 1) {
            v.vram[v.addr ^ 1] = b;
            v.addr +%= v.autoInc();
        }
        v.dmaDone();
    }

    pub fn readData(v: *Vdp) u16 {
        const val: u16 = switch (v.code & 0xF) {
            0 => v.word(v.addr),
            4 => v.vsram[(v.addr >> 1) % v.vsram.len],
            8 => v.cram[(v.addr >> 1) & 0x3F],
            else => 0,
        };
        v.addr +%= v.autoInc();
        return val;
    }

    /// One data write to wherever the code points, then the auto-increment.
    /// Also the write side of a 68k → VDP transfer.
    pub fn writeTarget(v: *Vdp, val: u16) void {
        switch (v.code & 0xF) {
            1 => { // VRAM. An odd address swaps the two halves.
                const a = v.addr & 0xFFFE;
                const swap = v.addr & 1 != 0;
                v.vram[a] = @truncate(if (swap) val else val >> 8);
                v.vram[a | 1] = @truncate(if (swap) val >> 8 else val);
            },
            3 => v.cram[(v.addr >> 1) & 0x3F] = val & 0x0EEE,
            5 => v.vsram[(v.addr >> 1) % v.vsram.len] = val & 0x3FF,
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

    pub fn dmaDone(v: *Vdp) void {
        v.regs[19] = 0;
        v.regs[20] = 0;
    }

    fn startDma(v: *Vdp) void {
        switch (@as(u2, @truncate(v.regs[23] >> 6))) {
            0, 1 => v.dma_request = true, // 68k → VDP; the bus owner runs it
            2 => v.fill_armed = true, // VRAM fill, once its byte arrives
            3 => v.dmaCopy(),
        }
    }

    // ponytail: every DMA lands instantly, with no FIFO stall and no bus
    // arbitration. Meter them against the cycle budget if a game turns out to
    // depend on the CPU being held off.
    fn dmaCopy(v: *Vdp) void {
        var src: u16 = @as(u16, v.regs[22]) << 8 | v.regs[21];
        var len = v.dmaLength();
        while (len > 0) : (len -= 1) {
            v.vram[v.addr] = v.vram[src];
            src +%= 1;
            v.addr +%= v.autoInc();
        }
        v.dmaDone();
    }

    // ---------------------------------------------------------------- drawing

    fn color(v: *const Vdp, idx: u8) u32 {
        const c = v.cram[idx & 0x3F];
        const r = level[(c >> 1) & 7];
        const g = level[(c >> 5) & 7];
        const b = level[(c >> 9) & 7];
        // Little-endian R8G8B8A8, which is what the texture upload wants.
        return 0xFF00_0000 | @as(u32, b) << 16 | @as(u32, g) << 8 | r;
    }

    /// One pixel out of the tile a name-table entry points at.
    fn tilePixel(v: *const Vdp, entry_addr: u32, x: u32, y: u32) Pix {
        const e = v.word(entry_addr);
        const tx = if (e & 0x800 != 0) 7 - x else x;
        const ty = if (e & 0x1000 != 0) 7 - y else y;
        const b = v.vram[(@as(u32, e & 0x7FF) * 32 + ty * 4 + tx / 2) & 0xFFFF];
        const c: u8 = if (tx & 1 == 0) b >> 4 else b & 0xF;
        return .{ .pal = @as(u8, @truncate(e >> 13 & 3)) << 4 | c, .pri = e & 0x8000 != 0 };
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

    fn planeRow(v: *const Vdp, line: u32, plane: u32, out: *[width]Pix) void {
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
                v.vsram[(x / 16 * 2 + plane) % v.vsram.len]
            else
                v.vsram[plane];
            const ys = (line + vs) & (cells_h * 8 - 1);
            const xs = (x -% hscroll) & (cells_w * 8 - 1);
            px.* = v.tilePixel(nt + (ys / 8 * cells_w + xs / 8) * 2, xs & 7, ys & 7);
        }
    }

    /// The window replaces plane A wherever it covers, and never scrolls.
    fn applyWindow(v: *const Vdp, line: u32, out: *[width]Pix) void {
        const wx = @as(u32, v.regs[17] & 0x1F) * 16;
        const wy = @as(u32, v.regs[18] & 0x1F) * 8;
        const rows = if (v.regs[18] & 0x80 != 0) line >= wy else line < wy;
        const nt: u32 = @as(u32, v.regs[3] & 0x3C) << 10; // H40 drops bit 1
        for (out, 0..) |*px, i| {
            const x: u32 = @intCast(i);
            const cols = if (v.regs[17] & 0x80 != 0) x >= wx else x < wx;
            if (!rows and !cols) continue;
            px.* = v.tilePixel(nt + (line / 8 * 64 + x / 8) * 2, x & 7, line & 7);
        }
    }

    fn spriteRow(v: *const Vdp, line: u32, out: *[width]Pix) void {
        const table: u32 = @as(u32, v.regs[5] & 0x7E) << 9; // H40 drops bit 0
        var link: u32 = 0;
        var seen: u32 = 0;
        while (seen < 80) : (seen += 1) {
            const e = table + link * 8;
            const top = @as(i32, v.word(e) & 0x3FF) - 128;
            const sz = v.vram[(e + 2) & 0xFFFF];
            const cells_w: u32 = (sz >> 2 & 3) + 1;
            const cells_h: u32 = (sz & 3) + 1;
            const dy = @as(i32, @intCast(line)) - top;
            if (dy >= 0 and dy < cells_h * 8) {
                const attr = v.word(e + 4);
                const left = @as(i32, v.word(e + 6) & 0x1FF) - 128;
                v.spriteCells(attr, left, @intCast(dy), cells_w, cells_h, out);
            }
            link = v.vram[(e + 3) & 0xFFFF] & 0x7F;
            if (link == 0) break;
        }
    }

    fn spriteCells(
        v: *const Vdp,
        attr: u16,
        left: i32,
        dy: u32,
        cells_w: u32,
        cells_h: u32,
        out: *[width]Pix,
    ) void {
        const first: u32 = attr & 0x7FF;
        const pal: u8 = @as(u8, @truncate(attr >> 13 & 3)) << 4;
        const pri = attr & 0x8000 != 0;
        const row = if (attr & 0x1000 != 0) cells_h * 8 - 1 - dy else dy;

        for (0..cells_w * 8) |i| {
            const sx = left + @as(i32, @intCast(i));
            if (sx < 0 or sx >= width) continue;
            const dst = &out[@intCast(sx)];
            if (dst.visible()) continue; // first sprite down the link list wins
            const col: u32 = if (attr & 0x800 != 0) cells_w * 8 - 1 - @as(u32, @intCast(i)) else @intCast(i);
            // Sprite tiles run down each column before moving right.
            const tile = first + col / 8 * cells_h + row / 8;
            const b = v.vram[(tile * 32 + (row & 7) * 4 + (col & 7) / 2) & 0xFFFF];
            const c: u8 = if (col & 1 == 0) b >> 4 else b & 0xF;
            if (c == 0) continue;
            dst.* = .{ .pal = pal | c, .pri = pri };
        }
    }

    pub fn renderLine(v: *Vdp, line: u32) void {
        const row = v.fb[line * width ..][0..width];
        const backdrop = v.color(v.regs[7] & 0x3F);
        if (!v.displayOn()) {
            @memset(row, backdrop);
            return;
        }

        var a: [width]Pix = @splat(.{});
        var b: [width]Pix = @splat(.{});
        var s: [width]Pix = @splat(.{});
        v.planeRow(line, 1, &b);
        v.planeRow(line, 0, &a);
        v.applyWindow(line, &a);
        v.spriteRow(line, &s);

        for (row, a, b, s) |*out, pa, pb, ps| {
            out.* = if (ps.visible() and ps.pri)
                v.color(ps.pal)
            else if (pa.visible() and pa.pri)
                v.color(pa.pal)
            else if (pb.visible() and pb.pri)
                v.color(pb.pal)
            else if (ps.visible())
                v.color(ps.pal)
            else if (pa.visible())
                v.color(pa.pal)
            else if (pb.visible())
                v.color(pb.pal)
            else
                backdrop;
        }
    }
};

test "control port: register writes, address latch, and a fill" {
    var v = Vdp{};

    v.writeControl(0x8F02); // reg 15 (auto-increment) = 2
    try std.testing.expectEqual(@as(u8, 2), v.regs[15]);

    // Two-word write: VRAM write at $C000.
    v.writeControl(0x4000);
    v.writeControl(0x0003);
    try std.testing.expectEqual(@as(u16, 0xC000), v.addr);
    try std.testing.expectEqual(@as(u6, 1), v.code);

    v.writeData(0x1234);
    try std.testing.expectEqual(@as(u8, 0x12), v.vram[0xC000]);
    try std.testing.expectEqual(@as(u8, 0x34), v.vram[0xC001]);
    try std.testing.expectEqual(@as(u16, 0xC002), v.addr);

    // Arm a fill of 4 words at $D000: reg 1 must allow DMA, reg 23 selects it.
    v.writeControl(0x8114);
    v.writeControl(0x9304); // length low = 4
    v.writeControl(0x9400); // length high
    v.writeControl(0x9780); // source high: fill
    v.writeControl(0x5000);
    v.writeControl(0x0083); // VRAM write + DMA
    try std.testing.expect(v.fill_armed);
    v.writeData(0xAB00);
    try std.testing.expect(!v.fill_armed);
    // The data write itself lands at $D000; the fill runs on from there, one
    // byte per step at the odd side of each address.
    try std.testing.expectEqual(@as(u8, 0xAB), v.vram[0xD000]);
    try std.testing.expectEqual(@as(u8, 0xAB), v.vram[0xD003]);
    try std.testing.expectEqual(@as(u8, 0xAB), v.vram[0xD009]); // 4th, inc 2
    try std.testing.expectEqual(@as(u8, 0x00), v.vram[0xD00B]); // and no further
    try std.testing.expectEqual(@as(u32, 0x10000), v.dmaLength()); // reset to 0
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
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), v.fb[0]);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), v.fb[1]);
    try std.testing.expectEqual(v.color(0), v.fb[2]); // transparent → backdrop
}
