//! SingleStepTests/z80 conformance runner.
//!
//!     tools/fetch_z80_tests.sh          # once, clones the test data into testdata/z80/
//!     zig build z80-sst                 # run everything
//!     zig build z80-sst -- 00           # only files whose name contains "00"
//!
//! Unlike the m68k suite this reads plain JSON directly: the opcode bytes
//! (prefix included) live in `initial.ram` at `pc`, so no per-file DD/FD/CB/ED
//! bookkeeping is needed here — load ram, step once, compare.
//!
//! Two tiers gate: final architectural state (registers, flags, memory, and
//! the single I/O access an IN/OUT case makes) and total T-states.

const std = @import("std");
const z80 = @import("z80");

const Cpu = z80.Cpu;
const Core = z80.Core(TrackedBus);

const test_dir = "testdata/z80/v1";
const ram_bytes = 0x10000;

const RamWord = [2]u16;
/// `[port, data, "r"|"w"]`, as recorded by the reference implementation.
const PortEntry = struct { u16, u8, []const u8 };

const State = struct {
    pc: u16,
    sp: u16,
    a: u8,
    b: u8,
    c: u8,
    d: u8,
    e: u8,
    f: u8,
    h: u8,
    l: u8,
    i: u8,
    r: u8,
    ei: u8,
    wz: u16,
    ix: u16,
    iy: u16,
    af_: u16,
    bc_: u16,
    de_: u16,
    hl_: u16,
    im: u2,
    q: u8,
    iff1: u8,
    iff2: u8,
    ram: []const RamWord,
};

const TestCase = struct {
    name: []const u8,
    initial: State,
    final: State,
    /// Total T-states: only its length is used.
    cycles: []const std.json.Value,
    ports: ?[]const PortEntry = null,
};

// -------------------------------------------------------------------- bus

/// Flat 64 KiB memory plus the single I/O access (at most one per
/// instruction, on this decode table) that IN/OUT/block-IO opcodes make.
/// Written addresses are remembered so `reset` can undo just those between
/// cases instead of re-zeroing all 64 KiB ~1.6M times (same fix as z68k).
const TrackedBus = struct {
    mem: [ram_bytes]u8 = undefined,
    /// Fed to the next `z80In` call; set from the case's recorded read.
    io_return: u8 = 0,
    io_access: ?IoAccess = null,
    dirty: [64]u16 = undefined,
    dirty_len: usize = 0,

    const IoAccess = struct { port: u16, data: u8, write: bool };

    fn poke(b: *TrackedBus, addr: u16, v: u8) void {
        b.mem[addr] = v;
        if (b.dirty_len < b.dirty.len) {
            b.dirty[b.dirty_len] = addr;
            b.dirty_len += 1;
        }
    }

    /// Undo everything the previous case touched. A full overflow of `dirty`
    /// (can't happen with one instruction plus a case's initial ram, but
    /// correctness shouldn't depend on that) falls back to the full clear.
    fn reset(b: *TrackedBus) void {
        if (b.dirty_len == b.dirty.len) {
            @memset(&b.mem, 0);
        } else {
            for (b.dirty[0..b.dirty_len]) |a| b.mem[a] = 0;
        }
        b.dirty_len = 0;
        b.io_access = null;
        b.io_return = 0;
    }

    pub fn z80Read8(b: *TrackedBus, addr: u16) u8 {
        return b.mem[addr];
    }
    pub fn z80Write8(b: *TrackedBus, addr: u16, v: u8) void {
        b.poke(addr, v);
    }
    pub fn z80In(b: *TrackedBus, port: u16) u8 {
        b.io_access = .{ .port = port, .data = b.io_return, .write = false };
        return b.io_return;
    }
    pub fn z80Out(b: *TrackedBus, port: u16, v: u8) void {
        b.io_access = .{ .port = port, .data = v, .write = true };
    }
};

/// State image -> Cpu. `ei`/`q` are read via a nonzero test, not bit0: the
/// suite's raw values are not clean booleans, and `!= 0` was verified at
/// 1000/1000 against the SCF corpus (`37.json`). `p` (an NMOS interrupt-race
/// artifact this core deliberately doesn't model) has no home here.
fn load(s: *const State, bus: *TrackedBus) Cpu {
    var c = Cpu{};
    c.a = s.a;
    c.b = s.b;
    c.c = s.c;
    c.d = s.d;
    c.e = s.e;
    c.h = s.h;
    c.l = s.l;
    c.f = z80.Flags.fromInt(s.f);
    c.sp = s.sp;
    c.pc = s.pc;
    c.ix = s.ix;
    c.iy = s.iy;
    c.i = s.i;
    c.r = s.r;
    c.wz = s.wz;
    c.af_ = s.af_;
    c.bc_ = s.bc_;
    c.de_ = s.de_;
    c.hl_ = s.hl_;
    c.im = @enumFromInt(s.im);
    c.iff1 = s.iff1 != 0;
    c.iff2 = s.iff2 != 0;
    c.q = s.q != 0;
    c.ei_delay = s.ei != 0;
    for (s.ram) |w| bus.poke(w[0], @truncate(w[1]));
    return c;
}

// ----------------------------------------------------------------- comparing

const Mismatch = struct {
    at: At,
    expected: u32,
    actual: u32,

    const At = union(enum) {
        a,
        b,
        c,
        d,
        e,
        h,
        l,
        f,
        sp,
        pc,
        ix,
        iy,
        i,
        r,
        wz,
        af_,
        bc_,
        de_,
        hl_,
        im,
        iff1,
        iff2,
        q,
        ei,
        ram: u16,
        io,
    };

    pub fn format(m: Mismatch, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (m.at) {
            .ram => |addr| try w.print("ram@{x:0>4}", .{addr}),
            inline else => |_, tag| try w.writeAll(@tagName(tag)),
        }
        try w.print(" expected {x:0>4}, got {x:0>4}", .{ m.expected, m.actual });
    }
};

fn compare(s: *const State, c: *const Cpu, bus: *const TrackedBus, ports: ?[]const PortEntry) ?Mismatch {
    if (c.a != s.a) return .{ .at = .a, .expected = s.a, .actual = c.a };
    if (c.b != s.b) return .{ .at = .b, .expected = s.b, .actual = c.b };
    if (c.c != s.c) return .{ .at = .c, .expected = s.c, .actual = c.c };
    if (c.d != s.d) return .{ .at = .d, .expected = s.d, .actual = c.d };
    if (c.e != s.e) return .{ .at = .e, .expected = s.e, .actual = c.e };
    if (c.h != s.h) return .{ .at = .h, .expected = s.h, .actual = c.h };
    if (c.l != s.l) return .{ .at = .l, .expected = s.l, .actual = c.l };
    if (c.f.toInt() != s.f) return .{ .at = .f, .expected = s.f, .actual = c.f.toInt() };
    if (c.sp != s.sp) return .{ .at = .sp, .expected = s.sp, .actual = c.sp };
    if (c.pc != s.pc) return .{ .at = .pc, .expected = s.pc, .actual = c.pc };
    if (c.ix != s.ix) return .{ .at = .ix, .expected = s.ix, .actual = c.ix };
    if (c.iy != s.iy) return .{ .at = .iy, .expected = s.iy, .actual = c.iy };
    if (c.i != s.i) return .{ .at = .i, .expected = s.i, .actual = c.i };
    if (c.r != s.r) return .{ .at = .r, .expected = s.r, .actual = c.r };
    if (c.wz != s.wz) return .{ .at = .wz, .expected = s.wz, .actual = c.wz };
    if (c.af_ != s.af_) return .{ .at = .af_, .expected = s.af_, .actual = c.af_ };
    if (c.bc_ != s.bc_) return .{ .at = .bc_, .expected = s.bc_, .actual = c.bc_ };
    if (c.de_ != s.de_) return .{ .at = .de_, .expected = s.de_, .actual = c.de_ };
    if (c.hl_ != s.hl_) return .{ .at = .hl_, .expected = s.hl_, .actual = c.hl_ };
    if (@intFromEnum(c.im) != s.im) return .{ .at = .im, .expected = s.im, .actual = @intFromEnum(c.im) };
    if (c.iff1 != (s.iff1 != 0)) return .{ .at = .iff1, .expected = s.iff1, .actual = @intFromBool(c.iff1) };
    if (c.iff2 != (s.iff2 != 0)) return .{ .at = .iff2, .expected = s.iff2, .actual = @intFromBool(c.iff2) };
    if (c.q != (s.q != 0)) return .{ .at = .q, .expected = s.q, .actual = @intFromBool(c.q) };
    if (c.ei_delay != (s.ei != 0)) return .{ .at = .ei, .expected = s.ei, .actual = @intFromBool(c.ei_delay) };

    for (s.ram) |w| {
        const addr = w[0];
        const got = bus.mem[addr];
        if (got != w[1]) return .{ .at = .{ .ram = addr }, .expected = w[1], .actual = got };
    }

    if (ports) |ps| for (ps) |p| {
        const want_write = p[2].len > 0 and p[2][0] == 'w';
        const io = bus.io_access orelse return .{ .at = .io, .expected = p[1], .actual = 0 };
        if (io.port != p[0] or io.data != p[1] or io.write != want_write)
            return .{ .at = .io, .expected = p[1], .actual = io.data };
    };
    return null;
}

// ------------------------------------------------------------------- driver

const Tally = struct {
    total: usize = 0,
    state_ok: usize = 0,
    cycles_ok: usize = 0,

    fn add(t: *Tally, other: Tally) void {
        t.total += other.total;
        t.state_ok += other.state_ok;
        t.cycles_ok += other.cycles_ok;
    }

    fn clean(t: Tally) bool {
        return t.state_ok == t.total and t.cycles_ok == t.total;
    }
};

/// Prints the first failure of each kind in a file and then goes quiet: a
/// broken opcode almost always fails the same way across all 1000 cases.
const Reporter = struct {
    file: []const u8,
    state_shown: bool = false,
    cycles_shown: bool = false,

    fn stateFailure(rep: *Reporter, tc: TestCase, m: Mismatch) void {
        if (rep.state_shown) return;
        rep.state_shown = true;
        std.debug.print("  {s}: first failure in \"{s}\": {f}\n", .{ rep.file, tc.name, m });
    }

    fn cycleFailure(rep: *Reporter, tc: TestCase, actual: u64) void {
        if (rep.cycles_shown) return;
        rep.cycles_shown = true;
        std.debug.print("  {s}: first cycle miss in \"{s}\": expected {d}, got {d}\n", .{
            rep.file, tc.name, tc.cycles.len, actual,
        });
    }
};

fn runFile(gpa: std.mem.Allocator, src: []const u8, name: []const u8) !Tally {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const cases = try std.json.parseFromSliceLeaky(
        []const TestCase,
        arena_state.allocator(),
        src,
        .{ .ignore_unknown_fields = true },
    );

    var tally = Tally{};
    var rep = Reporter{ .file = name };
    var bus = TrackedBus{};
    @memset(&bus.mem, 0); // once per file; per-case cleanup is bus.reset()

    for (cases) |tc| {
        bus.reset();
        if (tc.ports) |ps| for (ps) |p| {
            if (p[2].len > 0 and p[2][0] == 'r') bus.io_return = p[1];
        };

        var c = load(&tc.initial, &bus);
        Core.step(&c, &bus);

        tally.total += 1;
        if (compare(&tc.final, &c, &bus, tc.ports)) |m| {
            rep.stateFailure(tc, m);
            continue;
        }
        tally.state_ok += 1;
        if (c.cycles == tc.cycles.len) {
            tally.cycles_ok += 1;
        } else {
            rep.cycleFailure(tc, c.cycles);
        }
    }
    return tally;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const filter: ?[]const u8 = args.next();

    var dir = std.Io.Dir.cwd().openDir(io, test_dir, .{ .iterate = true }) catch |err| {
        std.debug.print(
            "cannot open {s}: {t}\nRun tools/fetch_z80_tests.sh first.\n",
            .{ test_dir, err },
        );
        return err;
    };
    defer dir.close(io);

    var total = Tally{};
    var files: usize = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (filter) |f| {
            if (std.mem.indexOf(u8, entry.name, f) == null) continue;
        }

        const src = dir.readFileAlloc(io, entry.name, gpa, .limited(256 << 20)) catch |err| {
            std.debug.print("  {s}: {t}\n", .{ entry.name, err });
            continue;
        };
        defer gpa.free(src);

        const t = runFile(gpa, src, entry.name) catch |err| {
            std.debug.print("  {s}: {t}\n", .{ entry.name, err });
            continue;
        };
        if (!t.clean()) std.debug.print("  {s:<24} state {d:>5}/{d:<5} cycles {d:>5}\n", .{
            entry.name, t.state_ok, t.total, t.cycles_ok,
        });
        total.add(t);
        files += 1;
    }

    if (files == 0) {
        std.debug.print("no test files matched. Run tools/fetch_z80_tests.sh first.\n", .{});
        return error.NoTests;
    }

    std.debug.print(
        \\
        \\{d} files, {d} cases
        \\  state:  {d}/{d}
        \\  cycles: {d}/{d}
        \\
    , .{
        files,           total.total,
        total.state_ok,  total.total,
        total.cycles_ok, total.total,
    });
    if (!total.clean()) return error.ConformanceFailed;
}

// -------------------------------------------------------------------- tests

test "reset undoes dirtied bytes, full clear on tracker overflow" {
    var bus = TrackedBus{};
    @memset(&bus.mem, 0);
    bus.poke(0x10, 0xAA);
    bus.reset();
    try std.testing.expectEqual(@as(u8, 0), bus.mem[0x10]);
    try std.testing.expectEqual(@as(usize, 0), bus.dirty_len);

    for (0..bus.dirty.len) |i| bus.poke(@intCast(i), 1);
    bus.poke(0x2000, 1); // overflows the tracker: reset must still clear it
    bus.reset();
    try std.testing.expectEqual(@as(u8, 0), bus.mem[0x2000]);
}

test "load maps the ei/q nonzero convention and skips p" {
    var bus = TrackedBus{};
    @memset(&bus.mem, 0);
    const s = State{
        .pc = 0,
        .sp = 0,
        .a = 1,
        .b = 0,
        .c = 0,
        .d = 0,
        .e = 0,
        .f = 0,
        .h = 0,
        .l = 0,
        .i = 0,
        .r = 0,
        .ei = 1,
        .wz = 0,
        .ix = 0,
        .iy = 0,
        .af_ = 0,
        .bc_ = 0,
        .de_ = 0,
        .hl_ = 0,
        .im = 0,
        .q = 200, // not a clean bit0 boolean upstream; must be read as nonzero
        .iff1 = 1,
        .iff2 = 0,
        .ram = &.{.{ 0x10, 0xAB }},
    };
    const c = load(&s, &bus);
    try std.testing.expect(c.ei_delay);
    try std.testing.expect(c.q);
    try std.testing.expect(c.iff1);
    try std.testing.expect(!c.iff2);
    try std.testing.expectEqual(@as(u8, 0xAB), bus.mem[0x10]);
}

test "compare reports the first mismatching field" {
    var bus = TrackedBus{};
    @memset(&bus.mem, 0);
    var s = State{
        .pc = 0,
        .sp = 0,
        .a = 0,
        .b = 0,
        .c = 0,
        .d = 0,
        .e = 0,
        .f = 0,
        .h = 0,
        .l = 0,
        .i = 0,
        .r = 0,
        .ei = 0,
        .wz = 0,
        .ix = 0,
        .iy = 0,
        .af_ = 0,
        .bc_ = 0,
        .de_ = 0,
        .hl_ = 0,
        .im = 0,
        .q = 0,
        .iff1 = 0,
        .iff2 = 0,
        .ram = &.{},
    };
    var c = Cpu{};
    try std.testing.expectEqual(@as(?Mismatch, null), compare(&s, &c, &bus, null));

    c.b = 0x42;
    try std.testing.expectEqual(Mismatch.At.b, compare(&s, &c, &bus, null).?.at);

    c.b = 0;
    s.ram = &.{.{ 0x20, 0x99 }};
    try std.testing.expectEqual(Mismatch.At{ .ram = 0x20 }, compare(&s, &c, &bus, null).?.at);
}
