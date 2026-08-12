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
/// pad n's bindings are the eight entries at `n * pad_count`.
pub const Action = enum {
    up,
    down,
    left,
    right,
    b,
    c,
    a,
    start,
    p2_up,
    p2_down,
    p2_left,
    p2_right,
    p2_b,
    p2_c,
    p2_a,
    p2_start,
    menu,
    pause,
    reset,
    fullscreen,
    open,

    pub const count = @typeInfo(Action).@"enum".fields.len;
    /// Buttons on one pad; actions past `pads * pad_count` are hotkeys.
    pub const pad_count = @intFromEnum(Action.start) + 1;
    pub const pads = 2;

    /// The `Genesis.buttons` bit this action holds down, or 0 for a hotkey.
    pub fn padMask(a: Action) u8 {
        const i = @intFromEnum(a);
        return if (i < pads * pad_count) @as(u8, 1) << @intCast(i % pad_count) else 0;
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
            .p2_up => "P2 Up",
            .p2_down => "P2 Down",
            .p2_left => "P2 Left",
            .p2_right => "P2 Right",
            .p2_b => "P2 Button B",
            .p2_c => "P2 Button C",
            .p2_a => "P2 Button A",
            .p2_start => "P2 Start",
            .menu => "Menu",
            .pause => "Pause",
            .reset => "Reset",
            .fullscreen => "Fullscreen",
            .open => "Open ROM",
        };
    }
};

pub const Bindings = [Action.count]u32;

/// The PoC's keys (arrows, A/S/D, Enter) plus the hotkeys §5.1 asks for.
/// Escape is the menu, so raylib's exit-on-escape has to be turned off.
/// Pad 2 ships unbound: two players on one keyboard is a choice, not a
/// default, and an unbound pad reads as "nothing pressed".
pub const defaults: Bindings = blk: {
    var b: Bindings = @splat(0);
    b[@intFromEnum(Action.up)] = key_up;
    b[@intFromEnum(Action.down)] = key_down;
    b[@intFromEnum(Action.left)] = key_left;
    b[@intFromEnum(Action.right)] = key_right;
    b[@intFromEnum(Action.a)] = 'A';
    b[@intFromEnum(Action.b)] = 'S';
    b[@intFromEnum(Action.c)] = 'D';
    b[@intFromEnum(Action.start)] = key_enter;
    b[@intFromEnum(Action.menu)] = key_escape;
    b[@intFromEnum(Action.pause)] = 'P';
    b[@intFromEnum(Action.reset)] = key_f5;
    b[@intFromEnum(Action.fullscreen)] = key_f11;
    b[@intFromEnum(Action.open)] = 'O';
    break :blk b;
};

const key_escape = 256;
const key_enter = 257;
const key_right = 262;
const key_left = 263;
const key_down = 264;
const key_up = 265;
const key_f5 = 294;
const key_f11 = 300;

/// Pad `pad`'s byte for this frame. `down` is the host's keyboard, which is
/// raylib's `IsKeyDown` and nothing else — passing it in is what keeps the
/// window out of this file.
pub fn buttons(b: Bindings, pad: usize, down: *const fn (u32) bool) u8 {
    var out: u8 = 0;
    const base = pad * Action.pad_count;
    for (0..Action.pad_count) |i| {
        if (b[base + i] != 0 and down(b[base + i])) out |= @as(u8, 1) << @intCast(i);
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
    .{ "TAB", 258 },
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
    .{ "F2", 291 },
    .{ "F3", 292 },
    .{ "F4", 293 },
    .{ "F5", key_f5 },
    .{ "F6", 295 },
    .{ "F7", 296 },
    .{ "F8", 297 },
    .{ "F9", 298 },
    .{ "F10", 299 },
    .{ "F11", key_f11 },
    .{ "F12", 301 },
    .{ "LSHIFT", 340 },
    .{ "LCTRL", 341 },
    .{ "LALT", 342 },
    .{ "RSHIFT", 344 },
    .{ "RCTRL", 345 },
    .{ "RALT", 346 },
};

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
    try std.testing.expectEqual(@as(u8, 0), Action.menu.padMask());
}

test "bindings turn held keys into a pad byte, per pad" {
    const held = struct {
        fn down(key: u32) bool {
            return key == 'A' or key == key_up or key == 'K';
        }
    }.down;
    var b = defaults;
    try std.testing.expectEqual(genesis.btn_a | genesis.btn_up, buttons(b, 0, &held));
    // Pad 2 is unbound out of the box, and an unbound key is never held.
    try std.testing.expectEqual(@as(u8, 0), buttons(b, 1, &held));
    b[@intFromEnum(Action.p2_start)] = 'K';
    try std.testing.expectEqual(genesis.btn_start, buttons(b, 1, &held));
    try std.testing.expectEqual(genesis.btn_a | genesis.btn_up, buttons(b, 0, &held));
}

test "every key name round-trips" {
    var buf: [16]u8 = undefined;
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
