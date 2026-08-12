//! Save states (DESIGN.md §8). Every chip is a plain struct owned by value, so
//! a state is a small header followed by the bytes of `Genesis` and of the
//! 68000's `Cpu` — no per-field serialization to forget a field in.
//!
//! Two things in there are not machine state: the cartridge the machine was
//! handed and the CPU it points at. Both are restored over the loaded bytes.
//!
//! A state is only readable by the build that wrote it. Zig promises no field
//! order between compilations, and `layout` says so out loud: it is a hash of
//! every field's name, type and offset, so a state from another build is
//! refused instead of loaded as garbage. `version` is the same refusal for
//! changes a layout hash cannot see, like a field that keeps its shape and
//! changes its meaning.

const std = @import("std");
const genesis = @import("genesis");

const Genesis = genesis.Genesis;
const Cpu = genesis.Cpu;

pub const magic = "ZGST";
pub const version: u32 = 1;

pub const Header = extern struct {
    magic: [4]u8 = magic.*,
    version: u32 = version,
    layout: u64 = layout,
    genesis_size: u32 = @sizeOf(Genesis),
    cpu_size: u32 = @sizeOf(Cpu),
};

/// What a state file weighs, and what `read` insists on being handed.
pub const size = @sizeOf(Header) + @sizeOf(Genesis) + @sizeOf(Cpu);

pub const Error = error{ NotAState, WrongVersion };

pub fn write(g: *const Genesis, c: *const Cpu, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(std.mem.asBytes(&Header{}));
    try w.writeAll(std.mem.asBytes(g));
    try w.writeAll(std.mem.asBytes(c));
}

pub fn read(bytes: []const u8, g: *Genesis, c: *Cpu) Error!void {
    if (bytes.len != size) return error.NotAState;
    var hdr: Header = undefined;
    @memcpy(std.mem.asBytes(&hdr), bytes[0..@sizeOf(Header)]);
    if (!std.mem.eql(u8, &hdr.magic, magic)) return error.NotAState;
    if (hdr.version != version or hdr.layout != layout) return error.WrongVersion;
    if (hdr.genesis_size != @sizeOf(Genesis) or hdr.cpu_size != @sizeOf(Cpu)) return error.WrongVersion;

    const rom = g.rom;
    const cpu = g.cpu;
    @memcpy(std.mem.asBytes(g), bytes[@sizeOf(Header)..][0..@sizeOf(Genesis)]);
    @memcpy(std.mem.asBytes(c), bytes[@sizeOf(Header) + @sizeOf(Genesis) ..][0..@sizeOf(Cpu)]);
    g.rom = rom;
    g.cpu = cpu;
}

const layout: u64 = blk: {
    @setEvalBranchQuota(100_000);
    var sig: []const u8 = "";
    for (.{ Genesis, Cpu }) |T| {
        sig = sig ++ @typeName(T);
        for (std.meta.fields(T)) |f| {
            sig = sig ++ std.fmt.comptimePrint("{s}:{s}@{d};", .{ f.name, @typeName(f.type), @offsetOf(T, f.name) });
        }
    }
    break :blk std.hash.Fnv1a_64.hash(sig);
};

// ------------------------------------------------------------------- tests
// The round trip through a whole running machine is in
// `test/system_test.zig`, which has a ROM to run. What is checkable here is
// the refusing.

const testing = std.testing;

test "a state round-trips a machine's bytes and leaves its wiring alone" {
    var c = Cpu{};
    const rom = [_]u8{0xAB} ** 4;
    const g = try testing.allocator.create(Genesis);
    defer testing.allocator.destroy(g);
    g.* = .init(&rom, &c);
    g.ram[0x100] = 0x42;
    g.v.vram[0x20] = 0x99;

    var buf: [size]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(g, &c, &w);

    var other = Cpu{ .pc = 0xDEAD };
    g.* = .init(&.{}, &other);
    try read(&buf, g, &other);

    try testing.expectEqual(@as(u8, 0x42), g.ram[0x100]);
    try testing.expectEqual(@as(u8, 0x99), g.v.vram[0x20]);
    try testing.expectEqual(@as(u32, 0), other.pc);
    // The cartridge and the CPU the machine is wired to are this run's, not
    // the saved run's.
    try testing.expectEqual(@as(usize, 0), g.rom.len);
    try testing.expectEqual(&other, g.cpu);
}

test "a state from somewhere else is refused, not loaded" {
    var c = Cpu{};
    const g = try testing.allocator.create(Genesis);
    defer testing.allocator.destroy(g);
    g.* = .init(&.{}, &c);

    var buf: [size]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try write(g, &c, &w);

    try testing.expectError(error.NotAState, read(buf[0 .. size - 1], g, &c));
    var bad = buf;
    bad[0] = 'X';
    try testing.expectError(error.NotAState, read(&bad, g, &c));
    bad = buf;
    bad[@offsetOf(Header, "layout")] +%= 1;
    try testing.expectError(error.WrongVersion, read(&bad, g, &c));
}
