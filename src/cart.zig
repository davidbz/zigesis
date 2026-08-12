//! The cartridge slot (DESIGN.md §8): backup-RAM header parsing, battery-backed
//! SRAM, and the $A130F3 banking mapper the few oversized carts use.
//!
//! The ROM bytes live in `Genesis` and are passed in here; this struct is only
//! what the slot *adds* to them — which is also exactly the part that has to
//! survive a save state and a reset.

const std = @import("std");

/// The backup-RAM header, 16 bytes at $1B0: "RA", a type byte, then the first
/// and last address the RAM answers at, each a longword.
const header_at = 0x1B0;
const header_len = 0x10;
const sram_magic = "RA";
const sram_start_at = header_at + 4;
const sram_end_at = header_at + 8;

/// The widest window a cartridge can open onto backup RAM. Every address in
/// the window gets a byte of its own, including the ones an 8-bit chip cannot
/// really answer — a byte-wide cart just leaves half of them untouched, which
/// is what every other emulator's .srm holds too.
pub const sram_bytes = 64 << 10;
const sram_mask = sram_bytes - 1;
/// Backup RAM that was never written reads as all ones, so a game looking for
/// its own magic there sees "no save" rather than a save made of zeros.
pub const sram_erased = 0xFF;

/// $A130F1-$A130FF, the "TIME" registers: SRAM control, then seven bank slots.
/// Slot 0 is always the ROM's own first 512 KiB and has no register.
const time_mask = 0xFF;
const time_sram = 0xF1;
const sram_on_bit = 0x01;
const sram_ro_bit = 0x02;

const bank_slots = 8;
const bank_shift = 19; // 512 KiB a slot, eight of them over the 4 MiB window
const bank_mask = (1 << bank_shift) - 1;
const identity_banks = blk: {
    var b: [bank_slots]u8 = undefined;
    for (&b, 0..) |*slot, i| slot.* = i;
    break :blk b;
};

pub const Cart = struct {
    sram: [sram_bytes]u8 = @splat(sram_erased),
    /// The window the header asks for, inclusive. Runs backwards when the
    /// cartridge has no backup RAM at all, which is how `sramAt` says no.
    sram_start: u24 = 1,
    sram_end: u24 = 0,
    /// $A130F1: whether SRAM is switched in over the ROM, and whether it is
    /// write protected while it is.
    sram_on: bool = false,
    sram_ro: bool = false,
    /// Set by every SRAM write, cleared by the frontend once it has written
    /// the file back out.
    sram_dirty: bool = false,
    /// 512 KiB pages, one per slot: the identity map until a game writes one.
    banks: [bank_slots]u8 = identity_banks,

    pub fn init(rom: []const u8) Cart {
        var c = Cart{};
        if (rom.len < header_at + header_len) return c;
        if (!std.mem.eql(u8, rom[header_at..][0..sram_magic.len], sram_magic)) return c;

        c.sram_start = @truncate(rd32(rom, sram_start_at) & ~@as(u32, 1));
        c.sram_end = @truncate(rd32(rom, sram_end_at) | 1);
        // Headers lie: a window that runs backwards, or past the 64 KiB there
        // is room for, gets the 64 KiB there is room for.
        if (c.sram_end <= c.sram_start or c.sram_end - c.sram_start >= sram_bytes) {
            c.sram_end = c.sram_start +| sram_mask;
        }
        // A window past the end of the ROM shares the bus with nothing, so it
        // needs no switching. The carts that do overlap their own ROM are the
        // ones that drive $A130F1 themselves.
        c.sram_on = c.sram_start >= rom.len;
        return c;
    }

    fn sramAt(c: *const Cart, addr: u24) bool {
        return c.sram_on and addr >= c.sram_start and addr <= c.sram_end;
    }

    /// Which ROM byte an address in the cartridge window actually names. The
    /// caller has already decoded the window, so the slot index fits.
    fn romAddr(c: *const Cart, addr: u24) u32 {
        const slot: u3 = @truncate(addr >> bank_shift);
        return (@as(u32, c.banks[slot]) << bank_shift) | (addr & bank_mask);
    }

    pub fn read8(c: *const Cart, rom: []const u8, addr: u24) u8 {
        if (c.sramAt(addr)) return c.sram[addr & sram_mask];
        const a = c.romAddr(addr);
        return if (a < rom.len) rom[a] else 0xFF;
    }

    pub fn read16(c: *const Cart, rom: []const u8, addr: u24) u16 {
        if (c.sramAt(addr)) return @as(u16, c.read8(rom, addr)) << 8 | c.read8(rom, addr +% 1);
        const a = c.romAddr(addr);
        if (a + 1 >= rom.len) return 0xFFFF;
        return std.mem.readInt(u16, rom[a..][0..2], .big);
    }

    /// Only SRAM is writable out here; a write to ROM goes nowhere, as it
    /// does on a board with no RAM chip in the socket.
    pub fn write8(c: *Cart, addr: u24, val: u8) void {
        if (!c.sramAt(addr) or c.sram_ro) return;
        c.sram[addr & sram_mask] = val;
        c.sram_dirty = true;
    }

    pub fn write16(c: *Cart, addr: u24, val: u16) void {
        c.write8(addr, @truncate(val >> 8));
        c.write8(addr +% 1, @truncate(val));
    }

    /// A write to $A130F1-$A130FF: the SRAM control byte, or one of the seven
    /// bank slots at every odd address above it.
    pub fn writeTime(c: *Cart, addr: u24, val: u8) void {
        const reg = addr & time_mask;
        if (reg == time_sram) {
            c.sram_on = val & sram_on_bit != 0;
            c.sram_ro = val & sram_ro_bit != 0;
            return;
        }
        if (reg < time_sram or reg & 1 == 0) return;
        c.banks[(reg - time_sram) >> 1] = val;
    }
};

fn rd32(mem: []const u8, addr: usize) u32 {
    return std.mem.readInt(u32, mem[addr..][0..4], .big);
}

// ------------------------------------------------------------------- tests

const testing = std.testing;

/// A ROM big enough to hold a header, with every 512 KiB page stamped with
/// its own number so a bank switch is visible in one byte.
fn fakeRom(buf: []u8, sram: bool) []const u8 {
    @memset(buf, 0);
    for (buf, 0..) |*b, i| b.* = @truncate(i >> bank_shift);
    if (!sram) return buf;
    @memcpy(buf[header_at..][0..2], sram_magic);
    buf[header_at + 2] = 0xF8; // odd bytes only, the common encoding
    std.mem.writeInt(u32, buf[sram_start_at..][0..4], 0x20_0001, .big);
    std.mem.writeInt(u32, buf[sram_end_at..][0..4], 0x20_FFFF, .big);
    return buf;
}

test "the backup-RAM header names a window, and no header names none" {
    var buf: [0x400]u8 = undefined;
    const c = Cart.init(fakeRom(&buf, true));
    try testing.expectEqual(@as(u24, 0x20_0000), c.sram_start);
    try testing.expectEqual(@as(u24, 0x20_FFFF), c.sram_end);
    // The window starts past this 1 KiB ROM, so nothing has to switch it in.
    try testing.expect(c.sram_on);

    const plain = Cart.init(fakeRom(&buf, false));
    try testing.expect(plain.sram_start > plain.sram_end);
    try testing.expect(!plain.sramAt(0x20_0000));
    try testing.expect(!Cart.init("").sram_on);
}

test "SRAM overlapping its own ROM stays off until $A130F1 switches it in" {
    var buf: [0x400]u8 = undefined;
    const rom = fakeRom(&buf, true);
    var c = Cart.init(rom);
    c.sram_on = false; // as a 4 MiB cart with the same header powers up

    c.write8(0x20_0001, 0x42);
    try testing.expect(!c.sram_dirty); // the write went nowhere

    c.writeTime(0xA1_30F1, sram_on_bit);
    c.write8(0x20_0001, 0x42);
    try testing.expect(c.sram_dirty);
    try testing.expectEqual(@as(u8, 0x42), c.read8(rom, 0x20_0001));
    try testing.expectEqual(@as(u8, sram_erased), c.read8(rom, 0x20_0003));

    // Read-only: the byte already there survives the write.
    c.writeTime(0xA1_30F1, sram_on_bit | sram_ro_bit);
    c.write8(0x20_0001, 0x99);
    try testing.expectEqual(@as(u8, 0x42), c.read8(rom, 0x20_0001));
    // Switched back out, the address is the cartridge's again — past the end
    // of this small one, so an empty bus.
    c.writeTime(0xA1_30F1, 0);
    try testing.expectEqual(@as(u8, 0xFF), c.read8(rom, 0x20_0001));
}

test "a word access to SRAM carries both of its bytes" {
    var buf: [0x400]u8 = undefined;
    const rom = fakeRom(&buf, true);
    var c = Cart.init(rom);

    c.write16(0x20_1000, 0xBEEF);
    try testing.expectEqual(@as(u16, 0xBEEF), c.read16(rom, 0x20_1000));
    try testing.expectEqual(@as(u8, 0xEF), c.read8(rom, 0x20_1001));
}

test "the $A130F3 mapper swaps 512 KiB pages under the top seven slots" {
    const buf = try testing.allocator.alloc(u8, 4 << 20); // too big for the stack
    defer testing.allocator.free(buf);
    const rom = fakeRom(buf, false);
    var c = Cart.init(rom);

    // Untouched, every slot reads its own page.
    try testing.expectEqual(@as(u8, 0), c.read8(rom, 0));
    try testing.expectEqual(@as(u8, 7), c.read8(rom, 0x38_0000));

    c.writeTime(0xA1_30F3, 5); // slot 1 <- page 5
    c.writeTime(0xA1_30FF, 2); // slot 7 <- page 2
    try testing.expectEqual(@as(u8, 5), c.read8(rom, 0x08_0000));
    try testing.expectEqual(@as(u8, 2), c.read8(rom, 0x38_0000));
    try testing.expectEqual(@as(u8, 0), c.read8(rom, 0x00_0000)); // slot 0 is fixed

    // The even addresses between the registers are not registers.
    c.writeTime(0xA1_30F4, 1);
    try testing.expectEqual(@as(u8, 5), c.read8(rom, 0x08_0000));
    // A page past the end of the ROM reads as an empty bus, not as a crash.
    c.writeTime(0xA1_30F3, 200);
    try testing.expectEqual(@as(u8, 0xFF), c.read8(rom, 0x08_0000));
    try testing.expectEqual(@as(u16, 0xFFFF), c.read16(rom, 0x08_0000));
}
