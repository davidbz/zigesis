//! Master-clock accounting and per-scanline stepping: runs the 68000 for a
//! line's worth of cycles, delivers VBlank/HBlank interrupts at the right
//! lines, and hands each line to the VDP to render.
//!
//! Step granularity is the scanline: run the 68k for a line's worth of
//! cycles, tick the VDP, deliver interrupts, repeat. See DESIGN.md §3.3.

const std = @import("std");
const m68k = @import("m68k");
const vdp = @import("vdp");
const genesis = @import("genesis");

const Genesis = genesis.Genesis;
const Cpu = genesis.Cpu;
const Core = genesis.Core;
const Z80Core = genesis.Z80Core;

const mclk_per_cpu = genesis.mclk_per_cpu;
const mclk_per_z80 = genesis.mclk_per_z80;
const mclk_per_line = genesis.mclk_per_line;
const lines_per_frame = genesis.lines_per_frame;

/// The 68000's effective clock, derived from the master clock and its divider.
pub const cpu_hz = 53_693_175.0 / @as(f64, mclk_per_cpu);

const vint_level: u3 = 6;
const hint_level: u3 = 4;

pub fn runFrame(g: *Genesis, c: *Cpu) void {
    g.line = 0;
    while (g.line < lines_per_frame) : (g.line += 1) {
        runZ80Line(g);

        // The H-int counter reloads throughout blanking and counts down
        // once per line over the active display.
        if (g.line > vdp.height) {
            g.v.hint_counter = g.v.hintReload();
        } else if (g.v.hint_counter == 0) {
            g.v.hint_counter = g.v.hintReload();
            g.v.hint_irq = true;
        } else g.v.hint_counter -= 1;

        g.mclk_debt += mclk_per_line;
        const budget = g.mclk_debt / mclk_per_cpu;
        g.mclk_debt %= mclk_per_cpu;
        g.line_start = c.cycles;
        runLine(g, c, budget);

        if (g.line < vdp.height) g.v.renderLine(g.line);
        if (g.line == vdp.height) {
            g.v.in_vblank = true;
            g.v.vint_flag = true;
            g.v.vint_irq = true;
            g.z80_int_pending = true;
        }
        if (g.line == lines_per_frame - 1) g.v.in_vblank = false;
    }
    g.frame +%= 1;
}

/// The Z80's share of a line's master clock, run only while it's free (not
/// held in reset or busreq): held time earns no debt, so releasing it
/// doesn't burst-execute a backlog of cycles it never really had.
fn runZ80Line(g: *Genesis) void {
    if (g.z80_reset or g.z80_busreq) return;

    g.zclk_debt += mclk_per_line;
    const budget = g.zclk_debt / mclk_per_z80;
    g.zclk_debt %= mclk_per_z80;

    const end = g.z.cycles + budget;
    while (g.z.cycles < end) {
        if (g.z80_int_pending and Z80Core.interrupt(&g.z, g, .{ .int = true })) g.z80_int_pending = false;
        if (g.z80_trace) traceZ80(g);
        Z80Core.step(&g.z, g);
    }
}

fn traceZ80(g: *Genesis) void {
    std.debug.print("[f{d} l{d} t{d}] z80 pc={x:0>4} op={x:0>2} af={x:0>4} bc={x:0>4} de={x:0>4} hl={x:0>4} sp={x:0>4}\n", .{
        g.frame,  g.line,   g.z.cycles, g.z.pc,   g.z80Read8(g.z.pc),
        g.z.af(), g.z.bc(), g.z.de(),   g.z.hl(), g.z.sp,
    });
}

fn runLine(g: *Genesis, c: *Cpu, budget: u64) void {
    const end = c.cycles + budget;
    while (c.cycles < end and !c.halted) {
        const level: u3 = if (g.v.vint_irq and g.v.vintEnabled())
            vint_level
        else if (g.v.hint_irq and g.v.hintEnabled())
            hint_level
        else
            0;
        Core.setIpl(c, level);
        const mask_before = c.sr.ipl;
        Core.step(c, g);
        // ponytail: the acknowledge is inferred rather than driven — the
        // core has no ack hook, so an interrupt counts as taken once the
        // mask has risen to its level and PC has landed on the handler the
        // autovector names. The VDP is the only source, so nothing else is
        // in a position to fake that.
        if (level != 0 and mask_before < level and c.sr.ipl == level and
            c.pc == vectorFor(g, level))
        {
            if (level == vint_level) g.v.vint_irq = false else g.v.hint_irq = false;
        }
    }
}

fn vectorFor(g: *Genesis, level: u3) u32 {
    const at: u24 = @intCast(m68k.Exception.autovector(level).vectorAddr());
    return @as(u32, g.read16(at)) << 16 | g.read16(at + 2);
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

// SP = 0x00FFFF00 (a RAM address, for the stack), PC = 0x00000008, then a
// BRA.b -2 at 8: the CPU spins on one instruction forever without ever
// touching VDP registers, so vint/hint stay disabled and nothing but the
// scheduler's own bookkeeping is under test.
const spin_rom = [_]u8{
    0x00, 0xFF, 0xFF, 0x00,
    0x00, 0x00, 0x00, 0x08,
    0x60, 0xFE,
};

fn spinGenesis(c: *Cpu) Genesis {
    var g = Genesis{ .rom = &spin_rom, .cpu = c };
    Core.reset(c, &g);
    return g;
}

test "mclk_debt carries the sub-cycle remainder so a frame's clock does not drift" {
    var c = Cpu{};
    var g = spinGenesis(&c);

    // 3420 mclk/line * 262 lines/frame = 896,040 mclk, not a whole multiple
    // of the 68000's /7 divider: the remainder must be carried into the next
    // frame rather than dropped, or the emulated clock runs fast.
    const mclk_per_frame = mclk_per_line * lines_per_frame;

    runFrame(&g, &c);
    try testing.expectEqual(@as(u64, mclk_per_frame % mclk_per_cpu), g.mclk_debt);

    runFrame(&g, &c);
    try testing.expectEqual(@as(u64, (2 * mclk_per_frame) % mclk_per_cpu), g.mclk_debt);
}

test "runFrame raises VBlank once per frame and leaves it pending until the CPU takes it" {
    var c = Cpu{};
    var g = spinGenesis(&c);

    try testing.expect(!g.v.vint_flag);
    runFrame(&g, &c);

    // Set at line 224 and left for the CPU to see (nothing here reads the
    // status register or enables the interrupt, so both stay pending).
    try testing.expect(g.v.vint_flag);
    try testing.expect(g.v.vint_irq);
    // ...and the blanking window itself has closed again by the frame's end.
    try testing.expect(!g.v.in_vblank);
}
