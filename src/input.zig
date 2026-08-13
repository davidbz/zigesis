//! Controllers and key bindings: which host key drives which pad button and
//! which emulator hotkey.
//!
//! The key codes are raylib's, which are GLFW's, which are ASCII for the
//! printable keys — but nothing here calls raylib. `main.zig` is still the
//! only file that asks a keyboard anything; this one only says what an answer
//! means. The name table is what makes the config file human-editable: a
//! binding is written as `UP` or `F11`, not as 265 or 300.

const std = @import("std");
const genesis = @import("genesis");

/// Everything a key can be bound to. Both pads' buttons come first, each in
/// `Genesis.buttons` order, so `padMask` is a shift rather than a switch and
/// pad n's bindings are the twelve entries at `n * pad_count`.
pub const Action = enum {
    up,
    down,
    left,
    right,
    b,
    c,
    a,
    start,
    z,
    y,
    x,
    mode,
    p2_up,
    p2_down,
    p2_left,
    p2_right,
    p2_b,
    p2_c,
    p2_a,
    p2_start,
    p2_z,
    p2_y,
    p2_x,
    p2_mode,
    menu,
    pause,
    reset,
    fullscreen,
    open,
    save_state,
    load_state,
    next_slot,
    quick_save,
    quick_load,
    fast_forward,
    frame_advance,
    screenshot,
    scanlines,

    pub const count = @typeInfo(Action).@"enum".fields.len;
    /// Buttons on one pad; actions past `pads * pad_count` are hotkeys.
    pub const pad_count = @intFromEnum(Action.mode) + 1;
    pub const pads = 2;

    /// The `Genesis.buttons` bit this action holds down, or 0 for a hotkey.
    pub fn padMask(a: Action) u16 {
        const i = @intFromEnum(a);
        return if (i < pads * pad_count) @as(u16, 1) << @intCast(i % pad_count) else 0;
    }

    pub fn label(a: Action) [:0]const u8 {
        return switch (a) {
            .up => "P1 Up",
            .down => "P1 Down",
            .left => "P1 Left",
            .right => "P1 Right",
            .b => "P1 Button B",
            .c => "P1 Button C",
            .a => "P1 Button A",
            .start => "P1 Start",
            .z => "P1 Button Z",
            .y => "P1 Button Y",
            .x => "P1 Button X",
            .mode => "P1 Mode",
            .p2_up => "P2 Up",
            .p2_down => "P2 Down",
            .p2_left => "P2 Left",
            .p2_right => "P2 Right",
            .p2_b => "P2 Button B",
            .p2_c => "P2 Button C",
            .p2_a => "P2 Button A",
            .p2_start => "P2 Start",
            .p2_z => "P2 Button Z",
            .p2_y => "P2 Button Y",
            .p2_x => "P2 Button X",
            .p2_mode => "P2 Mode",
            .menu => "Menu",
            .pause => "Pause",
            .reset => "Reset",
            .fullscreen => "Fullscreen",
            .open => "Open ROM",
            .save_state => "Save State",
            .load_state => "Load State",
            .next_slot => "Next State Slot",
            .quick_save => "Quicksave",
            .quick_load => "Quickload",
            .fast_forward => "Fast Forward",
            .frame_advance => "Frame Advance",
            .screenshot => "Screenshot",
            .scanlines => "Scanlines",
        };
    }
};

pub const Bindings = [Action.count]u32;

/// The PoC's keys (arrows, A/S/D, Enter) plus X/Y/Z and the hotkeys §5.1 asks
/// for. Escape is the menu, so raylib's exit-on-escape has to be turned off.
/// Pad 2 ships unbound: two players on one keyboard is a choice, not a
/// default, and an unbound pad reads as "nothing pressed". So does Mode, which
/// a handful of games read and no default key is worth a conflict over.
pub const defaults: Bindings = blk: {
    var b: Bindings = @splat(0);
    b[@intFromEnum(Action.up)] = key_up;
    b[@intFromEnum(Action.down)] = key_down;
    b[@intFromEnum(Action.left)] = key_left;
    b[@intFromEnum(Action.right)] = key_right;
    b[@intFromEnum(Action.a)] = 'A';
    b[@intFromEnum(Action.b)] = 'S';
    b[@intFromEnum(Action.c)] = 'D';
    // The six-button pad's top row sits above A/B/C, so its keys do too. They
    // do nothing until a port is set to a six-button pad in the options.
    b[@intFromEnum(Action.x)] = 'Q';
    b[@intFromEnum(Action.y)] = 'W';
    b[@intFromEnum(Action.z)] = 'E';
    b[@intFromEnum(Action.start)] = key_enter;
    b[@intFromEnum(Action.menu)] = key_escape;
    b[@intFromEnum(Action.pause)] = 'P';
    b[@intFromEnum(Action.reset)] = key_f5;
    b[@intFromEnum(Action.fullscreen)] = key_f11;
    b[@intFromEnum(Action.open)] = 'O';
    b[@intFromEnum(Action.save_state)] = key_f2;
    b[@intFromEnum(Action.next_slot)] = key_f3;
    b[@intFromEnum(Action.load_state)] = key_f4;
    b[@intFromEnum(Action.quick_save)] = key_f6;
    b[@intFromEnum(Action.quick_load)] = key_f7;
    b[@intFromEnum(Action.fast_forward)] = key_tab;
    b[@intFromEnum(Action.frame_advance)] = key_f8;
    b[@intFromEnum(Action.screenshot)] = key_f12;
    b[@intFromEnum(Action.scanlines)] = ' ';
    break :blk b;
};

const key_escape = 256;
const key_enter = 257;
const key_right = 262;
const key_left = 263;
const key_down = 264;
const key_up = 265;
const key_tab = 258;
const key_f2 = 291;
const key_f3 = 292;
const key_f4 = 293;
const key_f5 = 294;
const key_f6 = 295;
const key_f7 = 296;
const key_f8 = 297;
const key_f11 = 300;
const key_f12 = 301;

/// Pad `pad`'s byte for this frame. `down` is the host's keyboard, which is
/// raylib's `IsKeyDown` and nothing else — passing it in is what keeps the
/// window out of this file.
pub fn buttons(b: Bindings, pad: usize, down: *const fn (u32) bool) u16 {
    var out: u16 = 0;
    const base = pad * Action.pad_count;
    for (0..Action.pad_count) |i| {
        if (b[base + i] != 0 and down(b[base + i])) out |= @as(u16, 1) << @intCast(i);
    }
    return out;
}

/// True when two actions share a key, which the rebinding UI highlights.
pub fn conflicts(b: Bindings, a: Action) bool {
    const key = b[@intFromEnum(a)];
    if (key == 0) return false;
    for (b, 0..) |other, i| {
        if (other == key and i != @intFromEnum(a)) return true;
    }
    return false;
}

/// Keys with a name worth writing down. Everything else round-trips as a
/// decimal code, which is ugly in the config file but never wrong.
const named = [_]struct { []const u8, u32 }{
    .{ "NONE", 0 },
    .{ "SPACE", 32 },
    .{ "ESC", key_escape },
    .{ "ENTER", key_enter },
    .{ "TAB", key_tab },
    .{ "BACKSPACE", 259 },
    .{ "INSERT", 260 },
    .{ "DELETE", 261 },
    .{ "RIGHT", key_right },
    .{ "LEFT", key_left },
    .{ "DOWN", key_down },
    .{ "UP", key_up },
    .{ "PAGEUP", 266 },
    .{ "PAGEDOWN", 267 },
    .{ "HOME", 268 },
    .{ "END", 269 },
    .{ "F1", 290 },
    .{ "F2", key_f2 },
    .{ "F3", key_f3 },
    .{ "F4", key_f4 },
    .{ "F5", key_f5 },
    .{ "F6", key_f6 },
    .{ "F7", key_f7 },
    .{ "F8", key_f8 },
    .{ "F9", 298 },
    .{ "F10", 299 },
    .{ "F11", key_f11 },
    .{ "F12", key_f12 },
    .{ "LSHIFT", 340 },
    .{ "LCTRL", 341 },
    .{ "LALT", 342 },
    .{ "RSHIFT", 344 },
    .{ "RCTRL", 345 },
    .{ "RALT", 346 },
};

/// Enough for every name in the table and for the decimal fallback an
/// unnamed code round-trips as, which is what `keyName` needs a buffer for.
pub const max_key_name = 16;

/// Writes the key's name into `buf` and returns it. Printable codes are
/// their own name, so `A` is "A" and `[` is "[".
pub fn keyName(key: u32, buf: []u8) []const u8 {
    for (named) |n| {
        if (n[1] == key) return n[0];
    }
    if (key > ' ' and key < 127) {
        buf[0] = @intCast(key);
        return buf[0..1];
    }
    return std.fmt.bufPrint(buf, "{d}", .{key}) catch "?";
}

pub fn keyCode(name: []const u8) ?u32 {
    for (named) |n| {
        if (std.mem.eql(u8, n[0], name)) return n[1];
    }
    if (name.len == 1) return name[0];
    return std.fmt.parseInt(u32, name, 10) catch null;
}

test "pad bits line up with the machine's button byte" {
    try std.testing.expectEqual(genesis.btn_up, Action.up.padMask());
    try std.testing.expectEqual(genesis.btn_a, Action.a.padMask());
    try std.testing.expectEqual(genesis.btn_start, Action.start.padMask());
    // The six-button pad's four, in the order its extra read reports them.
    try std.testing.expectEqual(genesis.btn_z, Action.z.padMask());
    try std.testing.expectEqual(genesis.btn_y, Action.y.padMask());
    try std.testing.expectEqual(genesis.btn_x, Action.x.padMask());
    try std.testing.expectEqual(genesis.btn_mode, Action.mode.padMask());
    try std.testing.expectEqual(genesis.btn_mode, Action.p2_mode.padMask());
    try std.testing.expectEqual(@as(u16, 0), Action.menu.padMask());
}

test "bindings turn held keys into a pad byte, per pad" {
    const held = struct {
        fn down(key: u32) bool {
            return key == 'A' or key == key_up or key == 'K' or key == 'Q';
        }
    }.down;
    var b = defaults;
    const p1 = genesis.btn_a | genesis.btn_up | genesis.btn_x;
    try std.testing.expectEqual(p1, buttons(b, 0, &held));
    // Pad 2 is unbound out of the box, and an unbound key is never held.
    try std.testing.expectEqual(@as(u16, 0), buttons(b, 1, &held));
    b[@intFromEnum(Action.p2_start)] = 'K';
    try std.testing.expectEqual(genesis.btn_start, buttons(b, 1, &held));
    try std.testing.expectEqual(p1, buttons(b, 0, &held));
}

test "every key name round-trips, and fits the buffer they are written to" {
    var buf: [max_key_name]u8 = undefined;
    for (named) |n| try std.testing.expect(n[0].len <= max_key_name);
    for (defaults) |key| {
        try std.testing.expectEqual(key, keyCode(keyName(key, &buf)).?);
    }
    // The unnamed ones fall back to decimal, and that has to survive too.
    try std.testing.expectEqual(@as(u32, 348), keyCode(keyName(348, &buf)).?);
}

test "conflicts are found in both directions" {
    var b = defaults;
    try std.testing.expect(!conflicts(b, .up));
    b[@intFromEnum(Action.pause)] = b[@intFromEnum(Action.a)];
    try std.testing.expect(conflicts(b, .pause));
    try std.testing.expect(conflicts(b, .a));
}
