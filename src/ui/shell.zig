//! The frontend shell (DESIGN.md §5.2): the menu, the file browser, and the
//! key-rebinding UI. Raylib primitives only, no widget library.
//!
//! `update` reads the keyboard and mouse and mutates the `Config` in place;
//! anything it cannot do itself — load a ROM, reset the machine, quit — it
//! hands back to `main.zig` as a `Request`. Nothing here touches the emulated
//! machine.

const std = @import("std");
const config = @import("config");
const input = @import("input");

const rl = @cImport(@cInclude("raylib.h"));

const Config = config.Config;
const Action = input.Action;

pub const max_path = 512;
const max_entries = 1024;
const status_seconds = 4;
const rom_extensions = [_][:0]const u8{ ".bin", ".md", ".gen", ".smd", ".68k" };

/// How many numbered save-state slots there are, plus the quicksave, which is
/// one more slot with its own two keys rather than a separate mechanism. So a
/// ROM can grow nine state files beside it, `.st0` through `.st8`.
pub const slots = 8;
pub const quick_slot: u8 = slots;
pub const slot_count = slots + 1;

/// What the menu needs `main.zig` to do.
pub const Request = union(enum) {
    none,
    /// A ROM to load, from the browser or from a drag-and-drop.
    load: [:0]const u8,
    reset,
    quit,
    save_state: u8,
    load_state: u8,
    screenshot,
};

const Page = enum {
    root,
    load,
    options,
    video,
    audio,
    keys,
    save_slots,
    load_slots,

    /// Where a page's Back row goes, and where Escape backs out to.
    fn parent(p: Page) Page {
        return switch (p) {
            .video, .audio, .keys => .options,
            else => .root,
        };
    }
};

const Act = union(enum) {
    goto: Page,
    back,
    close,
    reset,
    quit,
    scale,
    fullscreen,
    region,
    scanlines,
    audio_on,
    volume,
    /// Which pad is in a port, by port index.
    pad: u8,
    bind: Action,
    /// A slot on whichever of the two slot pages is up.
    slot: u8,
};

const Item = struct { label: [:0]const u8, act: Act };

/// How many lines of detail the cartridge card holds, which is as many as
/// `main.zig` has to say about a cartridge.
pub const card_rows = 8;

/// One line of the card: what it is on the left, what the cartridge says on
/// the right, and whether that reading is a good one. A scoreboard, which is
/// how a machine that eats coins would put it.
pub const Row = struct {
    label: [10:0]u8 = @splat(0),
    value: [40:0]u8 = @splat(0),
    tone: Tone = .plain,
};

pub const Tone = enum { plain, good, bad };

const root_items = [_]Item{
    .{ .label = "Resume", .act = .close },
    .{ .label = "Load ROM", .act = .{ .goto = .load } },
    .{ .label = "Save State", .act = .{ .goto = .save_slots } },
    .{ .label = "Load State", .act = .{ .goto = .load_slots } },
    .{ .label = "Options", .act = .{ .goto = .options } },
    .{ .label = "Reset", .act = .reset },
    .{ .label = "Quit", .act = .quit },
};

/// Built once at comptime, like the keys page: every slot, then Back.
const slot_items = blk: {
    var items: [slot_count + 1]Item = undefined;
    for (0..slots) |i| {
        items[i] = .{ .label = std.fmt.comptimePrint("Slot {d}", .{i}), .act = .{ .slot = i } };
    }
    items[quick_slot] = .{ .label = "Quick", .act = .{ .slot = quick_slot } };
    items[slot_count] = .{ .label = "Back", .act = .back };
    break :blk items;
};

const options_items = [_]Item{
    .{ .label = "Video", .act = .{ .goto = .video } },
    .{ .label = "Audio", .act = .{ .goto = .audio } },
    .{ .label = "Keys", .act = .{ .goto = .keys } },
    .{ .label = "Pad 1", .act = .{ .pad = 0 } },
    .{ .label = "Pad 2", .act = .{ .pad = 1 } },
    .{ .label = "Back", .act = .back },
};

const video_items = [_]Item{
    .{ .label = "Window scale", .act = .scale },
    .{ .label = "Fullscreen", .act = .fullscreen },
    .{ .label = "Region", .act = .region },
    .{ .label = "Scanlines", .act = .scanlines },
    .{ .label = "Back", .act = .back },
};

const audio_items = [_]Item{
    .{ .label = "Sound", .act = .audio_on },
    .{ .label = "Volume", .act = .volume },
    .{ .label = "Back", .act = .back },
};

/// Built once at comptime: every action, then Back.
const key_items = blk: {
    var items: [Action.count + 1]Item = undefined;
    for (std.enums.values(Action), 0..) |action, i| {
        items[i] = .{ .label = action.label(), .act = .{ .bind = action } };
    }
    items[Action.count] = .{ .label = "Back", .act = .back };
    break :blk items;
};

/// How much of a cartridge title the card holds, which is also how much of one
/// `main.zig` bothers to squeeze out of the header.
pub const max_card_title = 48;

pub const Ui = struct {
    open: bool = false,
    paused: bool = false,
    /// The fast-forward key is held: `main.zig` runs several frames per drawn
    /// one. Held rather than toggled, so letting go is always the way back.
    fast: bool = false,
    /// One frame owed to the frame-advance key, cleared once it is run.
    step: bool = false,
    page: Page = .root,
    sel: usize = 0,
    /// Set when the menu changes an option, cleared by `main.zig` once the
    /// config file has been rewritten. §5.1: options are written on change.
    dirty: bool = false,
    /// The action waiting for a key press, if the rebinding UI is up.
    rebind: ?Action = null,
    /// The slot the save/load hotkeys use. Not an option: it is where you
    /// are right now, not how you like the emulator set up.
    slot: u8 = 0,
    /// The pad word `main.zig` is handing the machine this frame, which is
    /// what the bar lights up — the buttons the *game* sees, not the keys.
    pad: u16 = 0,
    /// Whether port 1 has a six-button pad in it, which is the only thing the
    /// bar needs to know about it: three more chips to light.
    pad_six: bool = false,
    /// When each slot's file was written, in seconds since the epoch, or 0
    /// for a slot with nothing in it. Filled in by `main.zig` — the shell has
    /// no filesystem and does not know where the ROM lives — whenever
    /// `stamps_dirty` asks, and drawn against `now`, which is the same clock.
    stamps: [slot_count]i64 = @splat(0),
    now: i64 = 0,
    stamps_dirty: bool = true,
    /// The cartridge card on the root page: `main.zig` fills it in when a ROM
    /// goes in, because none of it changes while the game plays. `card_n` of
    /// zero means there is no cartridge and nothing to draw.
    card_title: [max_card_title:0]u8 = @splat(0),
    card_sub: [24:0]u8 = @splat(0),
    card: [card_rows]Row = @splat(.{}),
    card_n: usize = 0,
    browser: Browser = .{},
    path: [max_path:0]u8 = @splat(0),
    status_text: [96:0]u8 = @splat(0),
    status_until: f64 = 0,

    /// A one-line message over the picture for a few seconds — how a load
    /// failure reaches the user, since there is nowhere else for it to go.
    pub fn status(ui: *Ui, comptime fmt: []const u8, args: anytype) void {
        ui.status_text = @splat(0);
        _ = std.fmt.bufPrintZ(&ui.status_text, fmt, args) catch {};
        ui.status_until = rl.GetTime() + status_seconds;
        std.debug.print("{s}\n", .{std.mem.sliceTo(&ui.status_text, 0)});
    }

    fn items(ui: *const Ui) []const Item {
        return switch (ui.page) {
            .root => &root_items,
            .options => &options_items,
            .video => &video_items,
            .audio => &audio_items,
            .keys => &key_items,
            .save_slots, .load_slots => &slot_items,
            .load => &.{}, // the browser draws its own list
        };
    }

    fn goto(ui: *Ui, page: Page) void {
        ui.page = page;
        ui.sel = 0;
        // What is on disk can have changed since the last visit to the page.
        if (page == .save_slots or page == .load_slots) ui.stamps_dirty = true;
    }
};

// ---------------------------------------------------------------- update

pub fn update(ui: *Ui, cfg: *Config, has_rom: bool) Request {
    ui.fast = false; // only `hotkeys` turns it back on, so the menu cancels it
    if (rl.IsFileDropped()) {
        const dropped = rl.LoadDroppedFiles();
        defer rl.UnloadDroppedFiles(dropped);
        if (dropped.count > 0) {
            ui.open = false;
            return .{ .load = copyPath(&ui.path, dropped.paths[0]) };
        }
    }
    if (ui.rebind) |action| return captureKey(ui, cfg, action);
    if (ui.open) return menuKeys(ui, cfg, has_rom);
    return hotkeys(ui, cfg, has_rom);
}

fn hotkeys(ui: *Ui, cfg: *Config, has_rom: bool) Request {
    ui.fast = down(cfg, .fast_forward);
    if (pressed(cfg, .menu)) {
        ui.open = true;
        ui.goto(.root);
        return .none;
    }
    if (pressed(cfg, .open)) {
        ui.open = true;
        ui.goto(.load);
        ui.browser.reload();
        return .none;
    }
    if (pressed(cfg, .pause)) {
        ui.paused = !ui.paused;
        return .none;
    }
    if (pressed(cfg, .fullscreen)) {
        cfg.fullscreen = !cfg.fullscreen;
        ui.dirty = true;
        return .none;
    }
    if (pressed(cfg, .scanlines)) {
        cfg.scanlines = !cfg.scanlines;
        ui.dirty = true;
        // The bar's mark is lit or not; the key it takes is only on the bar
        // when there is room for it, so the toggle says so itself.
        ui.status("scanlines {s}", .{if (cfg.scanlines) "on" else "off"});
        return .none;
    }
    // Advancing a frame means being stopped between frames, so this pauses
    // rather than only working once something else did.
    if (stepped(cfg, .frame_advance)) {
        ui.paused = true;
        ui.step = true;
        return .none;
    }
    if (has_rom and pressed(cfg, .screenshot)) return .screenshot;
    if (pressed(cfg, .reset)) return .reset;
    if (pressed(cfg, .next_slot)) {
        ui.slot = (ui.slot + 1) % slots;
        ui.status("state slot {d}", .{ui.slot});
        return .none;
    }
    if (has_rom) {
        if (pressed(cfg, .save_state)) return .{ .save_state = ui.slot };
        if (pressed(cfg, .load_state)) return .{ .load_state = ui.slot };
        if (pressed(cfg, .quick_save)) return .{ .save_state = quick_slot };
        if (pressed(cfg, .quick_load)) return .{ .load_state = quick_slot };
    }
    // The idle screen asks for any key; the menu is what any key gets.
    if (!has_rom and rl.GetKeyPressed() != 0) {
        ui.open = true;
        ui.goto(.root);
    }
    return .none;
}

/// The rebinding UI: the next key pressed becomes the binding, Escape
/// cancels. Escape is therefore never bindable, which is the price of it
/// being the way out of every other screen.
fn captureKey(ui: *Ui, cfg: *Config, action: Action) Request {
    const key = rl.GetKeyPressed();
    if (key == 0) return .none;
    ui.rebind = null;
    if (key == rl.KEY_ESCAPE) return .none;
    cfg.keys[@intFromEnum(action)] = @intCast(key);
    ui.dirty = true;
    return .none;
}

fn menuKeys(ui: *Ui, cfg: *Config, has_rom: bool) Request {
    if (ui.page == .load) return browserKeys(ui);

    const items = ui.items();
    if (repeat(rl.KEY_DOWN)) ui.sel = (ui.sel + 1) % items.len;
    if (repeat(rl.KEY_UP)) ui.sel = (ui.sel + items.len - 1) % items.len;
    if (hoveredRow(ui.sel, items.len)) |row| ui.sel = row;

    var delta: i32 = 0;
    if (repeat(rl.KEY_RIGHT)) delta = 1;
    if (repeat(rl.KEY_LEFT)) delta = -1;
    if (delta != 0) return adjust(ui, cfg, items[ui.sel].act, delta, has_rom);

    if (rl.IsKeyPressed(rl.KEY_ESCAPE)) {
        if (ui.page == .root) ui.open = false else ui.goto(.root);
        return .none;
    }
    const clicked = rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT) and mouseRow(items.len) != null;
    if (!rl.IsKeyPressed(rl.KEY_ENTER) and !clicked) return .none;

    return switch (items[ui.sel].act) {
        .goto => |page| {
            ui.goto(page);
            if (page == .load) ui.browser.reload();
            return .none;
        },
        .back => {
            ui.goto(ui.page.parent());
            return .none;
        },
        .close => {
            ui.open = false;
            return .none;
        },
        .reset => {
            ui.open = false;
            return .reset;
        },
        .quit => .quit,
        .bind => |action| {
            ui.rebind = action;
            return .none;
        },
        .slot => |n| {
            if (!has_rom) return .none;
            // The slot you picked is the one the hotkeys then use — except
            // the quicksave, which keeps its own two keys.
            if (n != quick_slot) ui.slot = n;
            ui.open = false;
            return if (ui.page == .save_slots) .{ .save_state = n } else .{ .load_state = n };
        },
        // Enter on a value cycles it forward; left/right walk it either way.
        else => |act| adjust(ui, cfg, act, 1, has_rom),
    };
}

fn adjust(ui: *Ui, cfg: *Config, act: Act, delta: i32, has_rom: bool) Request {
    switch (act) {
        .scale => cfg.scale = step(cfg.scale, delta, config.min_scale, config.max_scale),
        .fullscreen => cfg.fullscreen = !cfg.fullscreen,
        .scanlines => cfg.scanlines = !cfg.scanlines,
        .audio_on => cfg.audio = !cfg.audio,
        .pad => |n| cfg.pads[n] = if (cfg.pads[n] == .six) .three else .six,
        .volume => cfg.volume = step(cfg.volume, delta * volume_step, 0, 100),
        .region => {
            const n: i32 = @typeInfo(config.Region).@"enum".fields.len;
            const i: i32 = @intFromEnum(cfg.region);
            cfg.region = @enumFromInt(@mod(i + delta, n));
            ui.dirty = true;
            // Timing is chosen when the machine starts, so a region change
            // is a reset: running on at the old rate would be a lie.
            return if (has_rom) .reset else .none;
        },
        else => return .none,
    }
    ui.dirty = true;
    return .none;
}

const volume_step = 5;

fn step(cur: u8, delta: i32, lo: u8, hi: u8) u8 {
    return @intCast(std.math.clamp(@as(i32, cur) + delta, @as(i32, lo), @as(i32, hi)));
}

fn pressed(cfg: *const Config, action: Action) bool {
    const key = cfg.keys[@intFromEnum(action)];
    return key != 0 and rl.IsKeyPressed(@intCast(key));
}

fn down(cfg: *const Config, action: Action) bool {
    const key = cfg.keys[@intFromEnum(action)];
    return key != 0 and rl.IsKeyDown(@intCast(key));
}

/// Like `pressed`, but a held key keeps firing — for the frame-advance, where
/// holding the key should walk frames the way it walks a menu.
fn stepped(cfg: *const Config, action: Action) bool {
    const key = cfg.keys[@intFromEnum(action)];
    return key != 0 and repeat(@intCast(key));
}

/// Held arrows should walk a list, which is what a menu wants and what
/// `IsKeyPressed` alone does not give.
fn repeat(key: c_int) bool {
    return rl.IsKeyPressed(key) or rl.IsKeyPressedRepeat(key);
}

// --------------------------------------------------------------- browser

/// A file list, not a system dialog: raylib has no dialog, and a native one
/// per platform is three dependencies for one button.
const Browser = struct {
    dir: [max_path:0]u8 = @splat(0),
    list: rl.FilePathList = std.mem.zeroes(rl.FilePathList),
    /// Indices into `list.paths` in display order, with `parent` standing in
    /// for the ".." entry.
    order: [max_entries]u32 = @splat(0),
    n: usize = 0,
    sel: usize = 0,

    const parent = std.math.maxInt(u32);

    fn reload(b: *Browser) void {
        if (b.dir[0] == 0) _ = copyPath(&b.dir, rl.GetWorkingDirectory());
        b.unload();
        b.list = rl.LoadDirectoryFiles(&b.dir);
        b.n = 1;
        b.order[0] = parent;
        for (0..@min(b.list.count, max_entries - 1)) |i| {
            const entry = b.list.paths[i];
            if (!rl.DirectoryExists(entry) and !isRom(entry)) continue;
            b.order[b.n] = @intCast(i);
            b.n += 1;
        }
        std.sort.pdq(u32, b.order[1..b.n], b, lessThan);
        b.sel = 0;
    }

    fn unload(b: *Browser) void {
        if (b.list.count != 0) rl.UnloadDirectoryFiles(b.list);
        b.list = std.mem.zeroes(rl.FilePathList);
    }

    /// Directories first, then names, the way every file list looks.
    fn lessThan(b: *Browser, l: u32, r: u32) bool {
        const ld = rl.DirectoryExists(b.list.paths[l]);
        const rd = rl.DirectoryExists(b.list.paths[r]);
        if (ld != rd) return ld;
        return std.mem.orderZ(u8, b.list.paths[l], b.list.paths[r]) == .lt;
    }

    fn path(b: *const Browser, row: usize) [*:0]const u8 {
        if (b.order[row] == parent) return rl.GetPrevDirectoryPath(&b.dir);
        return b.list.paths[b.order[row]];
    }

    fn name(b: *const Browser, row: usize) [*:0]const u8 {
        return if (b.order[row] == parent) ".." else rl.GetFileName(b.path(row));
    }

    fn isDir(b: *const Browser, row: usize) bool {
        return b.order[row] == parent or rl.DirectoryExists(b.path(row));
    }
};

fn isRom(path: [*:0]const u8) bool {
    for (rom_extensions) |ext| {
        if (rl.IsFileExtension(path, ext)) return true;
    }
    return false;
}

fn browserKeys(ui: *Ui) Request {
    const b = &ui.browser;
    if (b.n == 0) return .none;
    if (repeat(rl.KEY_DOWN)) b.sel = (b.sel + 1) % b.n;
    if (repeat(rl.KEY_UP)) b.sel = (b.sel + b.n - 1) % b.n;
    const wheel = rl.GetMouseWheelMove();
    if (wheel > 0 and b.sel > 0) b.sel -= 1;
    if (wheel < 0 and b.sel + 1 < b.n) b.sel += 1;
    if (hoveredRow(b.sel, b.n)) |row| b.sel = row;

    if (rl.IsKeyPressed(rl.KEY_ESCAPE)) {
        ui.goto(.root);
        b.unload();
        return .none;
    }
    const clicked = rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT) and mouseRow(b.n) != null;
    if (!rl.IsKeyPressed(rl.KEY_ENTER) and !clicked) return .none;

    if (!b.isDir(b.sel)) {
        const chosen = copyPath(&ui.path, b.path(b.sel));
        ui.open = false;
        b.unload();
        return .{ .load = chosen };
    }
    _ = copyPath(&b.dir, b.path(b.sel));
    b.reload();
    return .none;
}

// ------------------------------------------------------------------- card

/// Starts the cartridge card over: the marquee is the game's own name, with
/// whoever put their copyright in the header under it.
pub fn cardStart(ui: *Ui, title: []const u8, sub: []const u8) void {
    setText(ui.card_title[0..], title);
    setText(ui.card_sub[0..], sub);
    ui.card_n = 0;
}

/// Adds a line to the card, up to `card_rows` of them. A value too long for
/// its buffer is cut rather than dropped: half a serial still says something.
pub fn cardRow(ui: *Ui, label: []const u8, tone: Tone, comptime fmt: []const u8, args: anytype) void {
    if (ui.card_n == ui.card.len) return;
    const row = &ui.card[ui.card_n];
    ui.card_n += 1;
    row.* = .{ .tone = tone };
    setText(row.label[0..], label);
    var w = std.Io.Writer.fixed(row.value[0..]);
    w.print(fmt, args) catch {};
}

/// Fills a sentinel-terminated buffer from a slice. The sentinel sits one
/// past the end of what `arr[0..]` covers, so a value that fills the buffer
/// exactly is still terminated.
fn setText(dst: []u8, text: []const u8) void {
    const n = @min(text.len, dst.len);
    @memcpy(dst[0..n], text[0..n]);
    @memset(dst[n..], 0);
}

fn copyPath(dst: anytype, src: [*:0]const u8) [:0]const u8 {
    const text = std.mem.span(src);
    const n = @min(text.len, dst.len - 1);
    @memcpy(dst[0..n], text[0..n]);
    dst[n] = 0;
    return dst[0..n :0];
}

// ------------------------------------------------------------------ draw

const bg = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 200 };
const fg = rl.Color{ .r = 230, .g = 230, .b = 230, .a = 255 };
const dim = rl.Color{ .r = 140, .g = 140, .b = 140, .a = 255 };
const hilite = rl.Color{ .r = 255, .g = 210, .b = 60, .a = 255 };
const bad = rl.Color{ .r = 255, .g = 90, .b = 90, .a = 255 };
const good = rl.Color{ .r = 110, .g = 230, .b = 130, .a = 255 };
/// The cartridge card: a dark cabinet panel, and the near-black the game's
/// name is stencilled onto its lit marquee in.
const panel = rl.Color{ .r = 12, .g = 12, .b = 24, .a = 235 };
const ink = rl.Color{ .r = 20, .g = 16, .b = 0, .a = 255 };
/// The status bar: a lit slate panel rather than a black gutter, and the
/// grey a button is when nobody is holding it.
const bar_top = rl.Color{ .r = 34, .g = 36, .b = 50, .a = 255 };
const bar_bottom = rl.Color{ .r = 14, .g = 14, .b = 22, .a = 255 };
const bar_rule = rl.Color{ .r = 78, .g = 82, .b = 110, .a = 255 };
const chip = rl.Color{ .r = 48, .g = 50, .b = 66, .a = 255 };
/// The control panel the pad is drawn as: the near-black a button is sunk
/// into, the rim of a hole with no button in it, and the halo a held one
/// throws onto the panel around it.
const bezel = rl.Color{ .r = 8, .g = 8, .b = 14, .a = 255 };
const socket_rim = rl.Color{ .r = 30, .g = 31, .b = 42, .a = 255 };
const glow = rl.Color{ .r = 255, .g = 210, .b = 60, .a = 70 };
/// A cabinet's marquee is lit from behind, so the title is warm rather than
/// the flat white of the readouts beside it.
const marquee_ink = rl.Color{ .r = 255, .g = 238, .b = 198, .a = 255 };

/// Below this the default raylib font stops being legible at all, so a 1x
/// window gets a menu that overflows rather than one that cannot be read.
const min_font = 10;
/// Rows of text the window is tall, which is what makes the menu readable at
/// 1x (a 256-pixel window) and not comical at 4x or fullscreen.
const font_rows = 22;

fn fontSize() c_int {
    return @max(min_font, @divTrunc(rl.GetScreenHeight(), font_rows));
}

fn half(v: c_int) c_int {
    return @divTrunc(v, 2);
}

fn rowHeight() c_int {
    return @divTrunc(fontSize() * 3, 2);
}

fn topY() c_int {
    return rowHeight() * 2;
}

fn visibleRows() usize {
    const room = rl.GetScreenHeight() - barHeight() - topY();
    return @intCast(@max(1, @divTrunc(room, rowHeight())));
}

/// Scrolls only when the selection would fall off the bottom, so short lists
/// never move.
fn firstVisible(sel: usize, n: usize, rows: usize) usize {
    if (n <= rows or sel < rows) return 0;
    return @min(sel - rows + 1, n - rows);
}

/// Which list row the pointer is over, counted from the top of the visible
/// window of the list.
fn mouseRow(n: usize) ?usize {
    const m = rl.GetMousePosition();
    const y = @as(c_int, @intFromFloat(m.y)) - topY();
    if (y < 0) return null;
    const row: usize = @intCast(@divTrunc(y, rowHeight()));
    return if (row < @min(n, visibleRows())) row else null;
}

/// Hovering moves the selection, but only when the mouse actually moves:
/// otherwise a pointer left lying over the list fights the arrow keys.
fn hoveredRow(sel: usize, n: usize) ?usize {
    const moved = rl.GetMouseDelta();
    if (moved.x == 0 and moved.y == 0) return null;
    const row = mouseRow(n) orelse return null;
    return firstVisible(sel, n, visibleRows()) + row;
}

pub fn draw(ui: *const Ui, cfg: *const Config) void {
    drawBar(ui, cfg);
    if (ui.status_until > rl.GetTime()) {
        const fs = fontSize();
        rl.DrawText(&ui.status_text, half(fs), rl.GetScreenHeight() - barHeight() - rowHeight(), fs, hilite);
    }
    if (!ui.open) return;

    rl.DrawRectangle(0, 0, rl.GetScreenWidth(), rl.GetScreenHeight(), bg);
    const fs = fontSize();
    const title = switch (ui.page) {
        .root => "zigesis",
        .load => "Load ROM",
        .options => "Options",
        .video => "Video",
        .audio => "Audio",
        .keys => "Keys — Enter to rebind, Esc to cancel",
        .save_slots => "Save State",
        .load_slots => "Load State",
    };
    rl.DrawText(title, half(fs), half(fs), fs, dim);

    if (ui.page == .load) return drawBrowser(ui);

    var buf: [64]u8 = undefined;
    const items = ui.items();
    const first = firstVisible(ui.sel, items.len, visibleRows());
    for (first..@min(items.len, first + visibleRows()), 0..) |i, row| {
        const item = items[i];
        const y = topY() + rowHeight() * @as(c_int, @intCast(row));
        const selected = i == ui.sel;
        drawRow(y, selected);
        rl.DrawText(item.label, fs, y, fs, if (selected) hilite else fg);

        const value = valueText(item.act, cfg, ui, &buf) orelse continue;
        const color: rl.Color = switch (item.act) {
            .bind => |a| if (input.conflicts(cfg.keys, a)) bad else if (selected) hilite else fg,
            else => if (selected) hilite else fg,
        };
        rl.DrawText(value, rl.GetScreenWidth() - fs - rl.MeasureText(value, fs), y, fs, color);
    }
    // Last, so the selection bar runs under the card rather than over it.
    if (ui.page == .root) drawCartridge(ui);
}

/// The right half of the root page: what the cartridge says about itself, as
/// a cabinet would put it — a lit marquee with the game's name, and a
/// scoreboard of readings under it. The root page's rows are all labels with
/// no values, so the whole column is free.
fn drawCartridge(ui: *const Ui) void {
    if (ui.card_n == 0) return;
    const fs = fontSize();
    const small = @max(min_font, @divTrunc(fs * 3, 4));
    const pad = half(small);
    const marquee = rowHeight() + pad;

    const x = half(rl.GetScreenWidth());
    const y = topY() - pad;
    const w = rl.GetScreenWidth() - x - fs;
    const h = marquee + pad + rowHeight() * @as(c_int, @intCast(ui.card_n + 1));

    // Nothing is allowed out of the cabinet: a long reading is cut off at the
    // edge of the panel rather than drawn across the menu.
    {
        rl.BeginScissorMode(x, y, w, h);
        defer rl.EndScissorMode();

        rl.DrawRectangle(x, y, w, h, panel);
        rl.DrawRectangle(x, y, w, marquee, hilite);
        rl.DrawRectangleLines(x, y, w, h, hilite);

        var line = y + marquee + pad;
        rl.DrawText(&ui.card_sub, x + pad, line, small, dim);
        line += rowHeight();

        for (ui.card[0..ui.card_n]) |*row| {
            rl.DrawText(&row.label, x + pad, line, small, dim);
            // Values hang off the right edge like a score, which lines them up
            // without the font having to be fixed-width. It is not. One that
            // is too wide to hang there starts after its label instead and is
            // cut on the right by the panel: sliding further left would put it
            // under the label, and two strings in the same pixels are less
            // readable than either of them alone.
            const width = rl.MeasureText(&row.value, small);
            const label_end = x + pad + rl.MeasureText(&row.label, small) + pad;
            const value_x = @max(label_end, x + w - pad - width);
            rl.DrawText(&row.value, value_x, line, small, switch (row.tone) {
                .plain => fg,
                .good => good,
                .bad => bad,
            });
            line += rowHeight();
        }
    }

    // The name goes last because it brings its own scissor: raylib's is one
    // rectangle rather than a stack, so anything drawn after it would be
    // clipped to the marquee. A title is as long as it likes on a cartridge —
    // half a menu page is not enough for some of them — so it scrolls here for
    // the same reason it scrolls on the status bar.
    const title = std.mem.sliceTo(&ui.card_title, 0);
    drawName(title, x + pad, w - pad * 2, y + half(marquee - fs), fs, ink);
}

fn drawRow(y: c_int, selected: bool) void {
    if (!selected) return;
    rl.DrawRectangle(0, y - 2, rl.GetScreenWidth(), rowHeight(), .{ .r = 255, .g = 255, .b = 255, .a = 30 });
}

fn valueText(act: Act, cfg: *const Config, ui: *const Ui, buf: []u8) ?[:0]const u8 {
    return switch (act) {
        .scale => std.fmt.bufPrintZ(buf, "{d}x", .{cfg.scale}) catch null,
        .fullscreen => if (cfg.fullscreen) "on" else "off",
        .scanlines => if (cfg.scanlines) "on" else "off",
        .region => switch (cfg.region) {
            .auto => "auto",
            .ntsc => "NTSC",
            .pal => "PAL",
        },
        .audio_on => if (cfg.audio) "on" else "off",
        .pad => |n| if (cfg.pads[n] == .six) "6-button" else "3-button",
        .volume => std.fmt.bufPrintZ(buf, "{d}%", .{cfg.volume}) catch null,
        .bind => |action| blk: {
            if (ui.rebind == action) break :blk "press a key...";
            var name: [input.max_key_name]u8 = undefined;
            break :blk std.fmt.bufPrintZ(buf, "{s}", .{input.keyName(cfg.keys[@intFromEnum(action)], &name)}) catch null;
        },
        .slot => |n| stampText(ui.stamps[n], ui.now, buf),
        else => null,
    };
}

/// What a slot's row says on the right: whether there is anything in it, and
/// how old it is. Relative rather than a date — there is no timezone to get
/// wrong, and "2m ago" is the question actually being asked of a save slot.
pub fn stampText(stamp: i64, now: i64, buf: []u8) ?[:0]const u8 {
    if (stamp == 0) return "empty";
    const secs = @max(now - stamp, 0);
    if (secs < 60) return "just now";
    if (secs < 60 * 60) return std.fmt.bufPrintZ(buf, "{d}m ago", .{@divTrunc(secs, 60)}) catch null;
    if (secs < 24 * 60 * 60) return std.fmt.bufPrintZ(buf, "{d}h ago", .{@divTrunc(secs, 60 * 60)}) catch null;
    return std.fmt.bufPrintZ(buf, "{d}d ago", .{@divTrunc(secs, 24 * 60 * 60)}) catch null;
}

/// Enough for the longest name below, which is "quicksave".
pub const max_slot_name = "quicksave".len;

/// How a slot is named in a status line. `main.zig` reports saves and loads
/// there, and "quick" is what F6 wrote, not "slot 8".
pub fn slotName(slot: u8, buf: []u8) []const u8 {
    if (slot == quick_slot) return "quicksave";
    return std.fmt.bufPrint(buf, "slot {d}", .{slot}) catch "slot";
}

fn drawBrowser(ui: *const Ui) void {
    const b = &ui.browser;
    const fs = fontSize();
    const first = firstVisible(b.sel, b.n, visibleRows());
    for (first..@min(b.n, first + visibleRows()), 0..) |i, row| {
        const y = topY() + rowHeight() * @as(c_int, @intCast(row));
        const selected = i == b.sel;
        drawRow(y, selected);
        const color = if (selected) hilite else if (b.isDir(i)) dim else fg;
        rl.DrawText(b.name(i), fs, y, fs, color);
    }
}

// ------------------------------------------------------------------- bar

/// The strip along the bottom of the window: the pad as the machine sees it,
/// what is in the cartridge slot, and what the quicksave keys have to say.
/// `main.zig` sizes the window for it and fits the picture above, so unlike
/// an overlay this never covers the game.
pub fn barHeight() c_int {
    return rowHeight() + half(fontSize());
}

/// The pad's face buttons where they sit on the real six-button pad: X Y Z
/// along the top, A B C under them. Row 0 is the half a three-button pad does
/// not have, which is drawn as an empty socket rather than left out — see
/// `drawPad`.
const face_buttons = [_]struct { action: Action, col: c_int, row: c_int, label: [:0]const u8 }{
    .{ .action = .p1_x, .col = 0, .row = 0, .label = "X" },
    .{ .action = .p1_y, .col = 1, .row = 0, .label = "Y" },
    .{ .action = .p1_z, .col = 2, .row = 0, .label = "Z" },
    .{ .action = .p1_a, .col = 0, .row = 1, .label = "A" },
    .{ .action = .p1_b, .col = 1, .row = 1, .label = "B" },
    .{ .action = .p1_c, .col = 2, .row = 1, .label = "C" },
};

/// The two in the middle of the pad, stacked as they sit on it: MODE above,
/// START below. MODE is row 0, so a three-button pad loses it the same way it
/// loses X/Y/Z.
const pad_pills = [_]struct { action: Action, row: c_int, label: [:0]const u8 }{
    .{ .action = .p1_mode, .row = 0, .label = "MODE" },
    .{ .action = .p1_start, .row = 1, .label = "START" },
};

/// The row a three-button pad does not have. Both tables put it first.
const six_only_row = 0;

/// The cross, as cells of a 3x3 grid. The middle one is the hub: no button
/// under it, and it is what makes the other four read as a d-pad.
const dpad_cells = [_]struct { col: c_int, row: c_int, action: ?Action }{
    .{ .col = 1, .row = 0, .action = .p1_up },
    .{ .col = 0, .row = 1, .action = .p1_left },
    .{ .col = 1, .row = 1, .action = null },
    .{ .col = 2, .row = 1, .action = .p1_right },
    .{ .col = 1, .row = 2, .action = .p1_down },
};

fn held(pad: u16, action: Action) bool {
    return pad & action.padMask() != 0;
}

/// Two key names with a slash between them, plus the terminator: the longest
/// the quicksave hint can get however its two keys are bound.
const quick_hint_buf = 2 * input.max_key_name + 2;

/// About this many characters of the cartridge's name is the least worth
/// showing. A hint that would cut it shorter than that gives way instead.
const name_floor_chars = 4;

/// What the bar says about the quicksave: the two keys that drive it, so
/// nobody has to open the menu to find out which they are. The disk beside
/// them says what they do — see `drawIcon`.
fn quickHint(cfg: *const Config, buf: *[quick_hint_buf]u8) [:0]const u8 {
    var save: [input.max_key_name]u8 = undefined;
    var load: [input.max_key_name]u8 = undefined;
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{
        input.keyName(cfg.keys[@intFromEnum(Action.quick_save)], &save),
        input.keyName(cfg.keys[@intFromEnum(Action.quick_load)], &load),
    }) catch "?";
}

/// One key name, terminated for raylib: `input.keyName` writes a slice, and
/// everything that draws here wants a C string.
const key_hint_buf = input.max_key_name + 1;

fn keyHint(cfg: *const Config, action: Action, buf: *[key_hint_buf]u8) [:0]const u8 {
    var name: [input.max_key_name]u8 = undefined;
    return std.fmt.bufPrintZ(buf, "{s}", .{
        input.keyName(cfg.keys[@intFromEnum(action)], &name),
    }) catch "?";
}

fn drawBar(ui: *const Ui, cfg: *const Config) void {
    const h = barHeight();
    const w = rl.GetScreenWidth();
    const y = rl.GetScreenHeight() - h;
    const fs = @max(min_font, @divTrunc(h * 2, 5));
    const gap = half(fs);
    const ty = y + half(h - fs);

    rl.DrawRectangleGradientV(0, y, w, h, bar_top, bar_bottom);
    // A lit edge over a dark one: two lines are what make the strip read as a
    // panel with a lip rather than as a gutter with a rule on it.
    rl.DrawRectangle(0, y, w, 1, bar_rule);
    rl.DrawRectangle(0, y + 1, w, 1, bezel);

    // The pad is drawn first because where it ends is what the right-hand side
    // has to stay clear of: the hints there give way, the name does not.
    const seam_x = gap + drawPad(gap, y, h, ui.pad, ui.pad_six) + gap;
    drawSeam(seam_x, y, h);
    const name_x = seam_x + fs;
    const floor = name_x + fs * name_floor_chars;

    // Right to left, because everything on this side has a width of its own
    // and the cartridge's name is the one thing that can be cut short.
    var buf: [32]u8 = undefined;
    var right = w - gap;
    if (ui.paused) {
        right = barIcon(right, ty, fs, .pause, hilite);
    } else if (std.fmt.bufPrintZ(&buf, "{d} FPS", .{rl.GetFPS()})) |fps| {
        right = barField(right, ty, fs, fps, fps_field, dim);
    } else |_| {}
    if (!cfg.audio or cfg.volume == 0) right = barIcon(right, ty, fs, .mute, bad);

    var age_buf: [32]u8 = undefined;
    const empty = ui.stamps[quick_slot] == 0;
    if (stampText(ui.stamps[quick_slot], ui.now, &age_buf)) |age| {
        right = barText(right, ty, fs, age, if (empty) dim else good);
    }
    var keys: [quick_hint_buf]u8 = undefined;
    right = barHint(right, floor, ty, fs, .disk, quickHint(cfg, &keys), dim);
    var key: [key_hint_buf]u8 = undefined;
    const fast_key = keyHint(cfg, .fast_forward, &key);
    right = barHint(right, floor, ty, fs, .fast, fast_key, if (ui.fast) hilite else dim);
    var crt_key: [key_hint_buf]u8 = undefined;
    const crt = keyHint(cfg, .scanlines, &crt_key);
    const crt_ink = if (cfg.scanlines) hilite else dim;
    // Three hints and a name do not fit until the window is large, and this
    // one is a toggle: the mark alone still says whether it is on, so it
    // sheds its key rather than dropping off the bar.
    right = if (right - hintWidth(fs, crt) >= floor)
        barHint(right, floor, ty, fs, .crt, crt, crt_ink)
    else
        barIcon(right, ty, fs, .crt, crt_ink);

    const name: [:0]const u8 = if (ui.card_n == 0) "NO CARTRIDGE" else std.mem.sliceTo(&ui.card_title, 0);
    drawName(name, name_x, right - name_x, ty, fs, if (ui.card_n == 0) dim else marquee_ink);
}

/// The groove between the control panel and the marquee. A cabinet is built
/// out of pieces, and the seam is what says which piece is which.
fn drawSeam(x: c_int, y: c_int, h: c_int) void {
    const m = panelMargin(h);
    rl.DrawRectangle(x, y + m, 1, h - m * 2, bezel);
    rl.DrawRectangle(x + 1, y + m, 1, h - m * 2, bar_rule);
}

/// Pixels a scrolling title moves per second, in font sizes: slow enough to
/// read, and tied to the font so it looks the same at 1x and fullscreen.
const marquee_rate = 1.5;
/// The blank between the end of a scrolling title and the copy chasing it.
const marquee_gap_chars = 4;

/// The cartridge's name, scrolled when it does not fit rather than cut off at
/// a letter: a title is the one thing on the bar that can be any length. The
/// second copy is what makes the wrap seamless — it arrives as the first
/// leaves, so there is never a gap the whole box wide.
fn drawName(name: [:0]const u8, x: c_int, box: c_int, y: c_int, fs: c_int, color: rl.Color) void {
    if (box <= 0) return;
    rl.BeginScissorMode(x, y, box, fs);
    defer rl.EndScissorMode();

    const width = rl.MeasureText(name.ptr, fs);
    if (width <= box) return rl.DrawText(name.ptr, x, y, fs, color);

    const span = width + fs * marquee_gap_chars;
    const off = marqueeOffset(rl.GetTime(), span, fs);
    rl.DrawText(name.ptr, x - off, y, fs, color);
    rl.DrawText(name.ptr, x - off + span, y, fs, color);
}

/// How far into its loop a marquee is. Wall-clock driven, which is fine
/// because nothing here is the emulated machine — §6.3's determinism rule is
/// about the core, and this is chrome.
fn marqueeOffset(t: f64, span: c_int, fs: c_int) c_int {
    const travelled = t * marquee_rate * @as(f64, @floatFromInt(fs));
    return @intFromFloat(@mod(travelled, @as(f64, @floatFromInt(span))));
}

/// The frame rate is the one thing on the bar whose text changes every frame,
/// and the whole right-hand side is laid out from its width — so it is drawn
/// in a field wide enough for any reading rather than shrink-wrapped to the
/// digits it happens to have. Uncapped, the reading changes every frame, and
/// a title whose width sits near where its box ends up otherwise flips
/// between scrolling and standing still several times a second.
const fps_field = "9999 FPS";

/// Draws one right-aligned item and hands back the left edge for the next.
fn barText(x: c_int, y: c_int, fs: c_int, text: [:0]const u8, color: rl.Color) c_int {
    const width = rl.MeasureText(text.ptr, fs);
    rl.DrawText(text.ptr, x - width, y, fs, color);
    return x - width - fs;
}

/// Like `barText`, but the item is never narrower than `field`: the text is
/// right-aligned inside it, so what is drawn to its left holds still while it
/// changes.
fn barField(x: c_int, y: c_int, fs: c_int, text: [:0]const u8, field: [:0]const u8, color: rl.Color) c_int {
    _ = barText(x, y, fs, text, color);
    return x - @max(rl.MeasureText(text.ptr, fs), rl.MeasureText(field.ptr, fs)) - fs;
}

/// A key hint: the icon for what the key does and the key itself, drawn as one
/// item. A hint is a reminder and the cartridge's name is what the bar is for,
/// so at 1x, where there is not room for both, one that reaches `floor` stays
/// off rather than crowding the name out.
fn barHint(x: c_int, floor: c_int, y: c_int, fs: c_int, icon: Icon, text: [:0]const u8, color: rl.Color) c_int {
    const width = hintWidth(fs, text);
    if (x - width < floor) return x;
    rl.DrawText(text.ptr, x - rl.MeasureText(text.ptr, fs), y, fs, color);
    drawIcon(x - width, y, fs, icon, color);
    return x - width - fs;
}

fn hintWidth(fs: c_int, text: [:0]const u8) c_int {
    return fs + half(fs) + rl.MeasureText(text.ptr, fs);
}

/// One icon on its own, right-aligned like `barText`.
fn barIcon(x: c_int, y: c_int, fs: c_int, icon: Icon, color: rl.Color) c_int {
    drawIcon(x - fs, y, fs, icon, color);
    return x - fs - fs;
}

const Icon = enum { fast, disk, pause, mute, crt };

/// The bar says more than it has room for in words, and the default font has
/// no glyph for any of these, so they are primitives: two chevrons for
/// fast-forward, a disk for the save slots, two bars for pause, and a speaker
/// with a bite out of it for silence. Drawn in an `fs` box, inset to sit at
/// the weight of the text beside it.
///
/// Triangle vertices go in the winding raylib's own quads use — top-left,
/// bottom-left, then the far point — or backface culling eats them.
fn drawIcon(x: c_int, y: c_int, fs: c_int, icon: Icon, color: rl.Color) void {
    const s = fs - @divTrunc(fs, 4);
    const ix = x + half(fs - s);
    const iy = y + half(fs - s);
    const q = @max(1, @divTrunc(s, 4));
    switch (icon) {
        .fast => {
            const w = half(s);
            for (0..2) |i| {
                const cx = ix + @as(c_int, @intCast(i)) * w;
                rl.DrawTriangle(v2(cx, iy), v2(cx, iy + s), v2(cx + w - 1, iy + half(s)), color);
            }
        },
        // Mostly solid: at a status bar's size a floppy drawn with a real
        // shutter and label loses so much of its square that it reads as a
        // second pause icon. The clipped corner is what carries it, and the
        // label band is detail that only shows up on a big window.
        .disk => {
            rl.DrawRectangle(ix, iy, s, s, color);
            const r = ix + s;
            rl.DrawTriangle(v2(r - q * 2, iy), v2(r, iy + q * 2), v2(r, iy), bar_bottom);
            rl.DrawRectangle(ix + q, iy + s - q * 2, s - q * 2, q, bar_bottom);
        },
        .pause => {
            rl.DrawRectangle(ix, iy, q, s, color);
            rl.DrawRectangle(ix + s - q, iy, q, s, color);
        },
        .mute => {
            rl.DrawRectangle(ix, iy + q, q, s - q * 2, color);
            rl.DrawTriangle(v2(ix + s, iy), v2(ix + q, iy + half(s)), v2(ix + s, iy + s), color);
            rl.DrawLineEx(v2(ix, iy + s), v2(ix + s, iy), @floatFromInt(@max(1, @divTrunc(s, 5))), bar_bottom);
        },
        // The mark for scanlines is scanlines: three stripes with the gaps
        // between them, which is the overlay itself at icon size. A screen
        // drawn around them would be two more strokes and nothing gained.
        .crt => {
            const t = @max(1, @divTrunc(s, 5));
            for (0..3) |i| {
                rl.DrawRectangle(ix, iy + @as(c_int, @intCast(i)) * t * 2, s, t, color);
            }
        },
    }
}

/// The colour of a scanline: black, and light enough that a dark scene keeps
/// its shadow detail. Alpha stripes, not a shader (§5.1).
const scanline_ink = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 90 };

/// Where the stripes sit: `row` device pixels between them, `thick` of that
/// dark, and the dark part at the *bottom* of each row, which is the gap a
/// tube leaves under a line. Null when a source line is under two device
/// pixels tall — there is no gap to darken then, and dimming every other line
/// halves the picture rather than looking like a CRT.
const Stripes = struct { row: f32, thick: f32 };

fn stripes(glass: f32, lines: f32) ?Stripes {
    const row = glass / lines;
    if (row < 2) return null;
    return .{ .row = row, .thick = @max(1, @round(row / 3)) };
}

/// One dark stripe per source line over the glass, which is what a tube's gap
/// between lines looks like.
pub fn drawScanlines(lines: f32) void {
    const glass: f32 = @floatFromInt(rl.GetScreenHeight() - barHeight());
    const s = stripes(glass, lines) orelse return;
    const w: f32 = @floatFromInt(rl.GetScreenWidth());
    var i: f32 = 1;
    while (i <= lines) : (i += 1) {
        rl.DrawRectangleRec(.{ .x = 0, .y = i * s.row - s.thick, .width = w, .height = s.thick }, scanline_ink);
    }
}

fn v2(x: c_int, y: c_int) rl.Vector2 {
    return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
}

/// How much of the bar's height the panel keeps clear of its own edges.
fn panelMargin(h: c_int) c_int {
    return @max(2, @divTrunc(h, 8));
}

/// raylib's built-in font is a ten-pixel bitmap drawn with no filtering, so a
/// size that is not a whole multiple of it lands strokes on half pixels — which
/// at panel size is what turns an X into an H. The letters on the pad are the
/// smallest text in the window and the ones that have to be read at a glance,
/// so they are snapped to that grid rather than fitted exactly.
const font_grid = 10;

fn gridFont(want: c_int) c_int {
    return @max(font_grid, @divTrunc(want, font_grid) * font_grid);
}
/// A round button needs to be about this wide before a letter fits inside it.
/// Below that the panel is lit dots and the layout says which is which — the
/// same thing that says it on the pad itself.
const button_label_floor = 13;

/// The pad, lit by the byte the machine is being handed this frame — which
/// makes it the fastest check there is that a binding does what it says, and
/// during a replay it is the recorded input playing back. Returns its width.
///
/// It is drawn as a cabinet's control panel: the cross, the six buttons in the
/// two rows they sit in on the real thing, and MODE over START between them.
/// A three-button port leaves the top row as empty sockets rather than dropping
/// it, so the panel is the same width either way and nothing to the right of it
/// moves when the option changes.
fn drawPad(x: c_int, y: c_int, h: c_int, pad: u16, six: bool) c_int {
    const m = panelMargin(h);
    const inner = h - m * 2;
    const top = y + m;
    const row_gap = @max(1, @divTrunc(inner, 12));
    const d = @divTrunc(inner - row_gap, 2); // one button, and half the panel tall

    // The cross is one shape, not five tiles: an outlined plus in the panel's
    // grey, with a whole arm lighting at a time. Its arms are drawn over the
    // outline rather than inside it, which is what keeps it a single piece.
    const u = @divTrunc(inner, 3);
    const edge = @max(1, @divTrunc(u, 8));
    drawCross(x - edge, top - edge, u, edge, bezel);
    drawCross(x, top, u, 0, chip);
    for (dpad_cells) |c| {
        const a = c.action orelse continue;
        if (!held(pad, a)) continue;
        rl.DrawRectangle(x + c.col * u, top + c.row * u, u, u, hilite);
    }

    // The top row sits a third of a button to the left of the bottom one: the
    // six are an arc on the real pad, not a grid.
    const col_gap = @max(1, @divTrunc(d, 6));
    const stagger = @divTrunc(d, 3);
    // A panel this small has no room for a letter inside a button, and it drops
    // every word at once rather than keeping the two that would still fit: what
    // is left is a light display, and the layout is what says which light is
    // which — the same thing that says it on the pad itself.
    const labels = d >= button_label_floor;
    const bfs: c_int = if (labels) gridFont(@divTrunc(d * 7, 10)) else 0;
    const face_x = x + u * 3 + m + stagger;
    for (face_buttons) |b| {
        const cx = face_x + b.col * (d + col_gap) - if (b.row == six_only_row) stagger else 0;
        const cy = top + b.row * (d + row_gap);
        const socket = !six and b.row == six_only_row;
        drawButton(cx + half(d), cy + half(d), d, b.label, bfs, held(pad, b.action), socket);
    }

    const pfs: c_int = if (labels) gridFont(@divTrunc(d * 3, 5)) else 0;
    const pill_x = face_x + 3 * (d + col_gap) + m;
    var pill_w: c_int = d * 2; // wide enough to read as a pill with no word in it
    if (labels) for (pad_pills) |p| {
        pill_w = @max(pill_w, rl.MeasureText(p.label.ptr, pfs) + pfs);
    };
    for (pad_pills) |p| {
        const socket = !six and p.row == six_only_row;
        drawPill(pill_x, top + p.row * (d + row_gap), pill_w, d, p.label, pfs, held(pad, p.action), socket);
    }
    return pill_x + pill_w - x;
}

/// The five cells of the cross as one plus-shaped piece, `grow` pixels proud
/// of the `u`-cell grid so the same call draws its outline.
fn drawCross(x: c_int, y: c_int, u: c_int, grow: c_int, color: rl.Color) void {
    const long = u * 3 + grow * 2;
    const wide = u + grow * 2;
    rl.DrawRectangle(x + u, y, wide, long, color);
    rl.DrawRectangle(x, y + u, long, wide, color);
}

/// One round button: sunk into the panel, lit from inside when it is held, and
/// throwing a halo onto the panel while it is. `socket` is a hole with no
/// button in it, which is what a three-button port's top row is — it never
/// lights, whatever the keyboard is doing, because the machine is not being
/// handed that bit either.
fn drawButton(cx: c_int, cy: c_int, d: c_int, label: [:0]const u8, fs: c_int, on: bool, socket: bool) void {
    const r: f32 = @floatFromInt(half(d));
    if (socket) {
        rl.DrawCircle(cx, cy, r, socket_rim);
        rl.DrawCircle(cx, cy, r - @as(f32, @floatFromInt(@max(1, @divTrunc(d, 10)))), bezel);
        return;
    }
    if (on) rl.DrawCircle(cx, cy, r + @as(f32, @floatFromInt(@max(2, @divTrunc(d, 4)))), glow);
    rl.DrawCircle(cx, cy, r, bezel);
    rl.DrawCircle(cx, cy, r - @as(f32, @floatFromInt(@max(1, @divTrunc(d, 8)))), if (on) hilite else chip);
    if (fs > 0) rl.DrawText(label.ptr, cx - half(rl.MeasureText(label.ptr, fs)), cy - half(fs), fs, if (on) ink else fg);
}

/// START and MODE, which are pills on the real pad and carry a word rather
/// than a letter.
fn drawPill(x: c_int, y: c_int, w: c_int, h: c_int, label: [:0]const u8, fs: c_int, on: bool, socket: bool) void {
    const box = rl.Rectangle{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
        .width = @floatFromInt(w),
        .height = @floatFromInt(h),
    };
    rl.DrawRectangleRounded(box, 0.5, 6, if (socket) socket_rim else bezel);
    const inset = @max(1, @divTrunc(h, 8));
    if (socket) {
        rl.DrawRectangleRounded(.{
            .x = box.x + @as(f32, @floatFromInt(inset)),
            .y = box.y + @as(f32, @floatFromInt(inset)),
            .width = box.width - @as(f32, @floatFromInt(inset * 2)),
            .height = box.height - @as(f32, @floatFromInt(inset * 2)),
        }, 0.5, 6, bezel);
        return;
    }
    rl.DrawRectangleRounded(.{
        .x = box.x + @as(f32, @floatFromInt(inset)),
        .y = box.y + @as(f32, @floatFromInt(inset)),
        .width = box.width - @as(f32, @floatFromInt(inset * 2)),
        .height = box.height - @as(f32, @floatFromInt(inset * 2)),
    }, 0.5, 6, if (on) hilite else chip);
    if (fs > 0) rl.DrawText(label.ptr, x + half(w - rl.MeasureText(label.ptr, fs)), y + half(h - fs), fs, if (on) ink else fg);
}

/// The idle screen's caption. The snow itself is `snow.zig`, drawn by
/// `main.zig` as a texture.
pub fn drawIdlePrompt() void {
    const fs = fontSize();
    const text = "Press any key";
    const w = rl.MeasureText(text, fs);
    const x = @divTrunc(rl.GetScreenWidth() - w, 2);
    const y = @divTrunc(rl.GetScreenHeight() - barHeight(), 2) - fs;
    rl.DrawRectangle(x - half(fs), y - half(half(fs)), w + fs, rowHeight(), .{ .r = 0, .g = 0, .b = 0, .a = 160 });
    rl.DrawText(text, x, y, fs, fg);
}

// The menu's arithmetic, which is the part of a UI that can be wrong without
// looking wrong. Everything else here needs a window and a pair of hands.

test "the list scrolls only once the selection would fall off it" {
    try std.testing.expectEqual(@as(usize, 0), firstVisible(0, 3, 10));
    try std.testing.expectEqual(@as(usize, 0), firstVisible(9, 20, 10));
    try std.testing.expectEqual(@as(usize, 1), firstVisible(10, 20, 10));
    try std.testing.expectEqual(@as(usize, 10), firstVisible(19, 20, 10));
}

test "values clamp at their ends and the region wraps" {
    var ui = Ui{};
    var cfg = Config{ .scale = config.max_scale, .volume = 100 };

    _ = adjust(&ui, &cfg, .scale, 1, false);
    try std.testing.expectEqual(config.max_scale, cfg.scale);
    _ = adjust(&ui, &cfg, .scale, -1, false);
    try std.testing.expectEqual(config.max_scale - 1, cfg.scale);
    _ = adjust(&ui, &cfg, .volume, 1, false);
    try std.testing.expectEqual(@as(u8, 100), cfg.volume);
    _ = adjust(&ui, &cfg, .volume, -1, false);
    try std.testing.expectEqual(@as(u8, 100 - volume_step), cfg.volume);
    try std.testing.expect(ui.dirty); // every change is written to disk

    _ = adjust(&ui, &cfg, .region, -1, false);
    try std.testing.expectEqual(config.Region.pal, cfg.region);
    _ = adjust(&ui, &cfg, .region, 1, false);
    try std.testing.expectEqual(config.Region.auto, cfg.region);
    // Changing region restarts the machine, but only if there is one.
    try std.testing.expectEqual(Request.none, adjust(&ui, &cfg, .region, 1, false));
    try std.testing.expectEqual(Request.reset, adjust(&ui, &cfg, .region, 1, true));
}

test "a slot says whether it holds anything, and how old it is" {
    var buf: [32]u8 = undefined;
    const now: i64 = 1_000_000;
    try std.testing.expectEqualStrings("empty", stampText(0, now, &buf).?);
    try std.testing.expectEqualStrings("just now", stampText(now - 59, now, &buf).?);
    try std.testing.expectEqualStrings("1m ago", stampText(now - 60, now, &buf).?);
    try std.testing.expectEqualStrings("59m ago", stampText(now - 3599, now, &buf).?);
    try std.testing.expectEqualStrings("1h ago", stampText(now - 3600, now, &buf).?);
    try std.testing.expectEqualStrings("3d ago", stampText(now - 3 * 86400, now, &buf).?);
    // A file written a second into the future — two clocks, or a copied save
    // — is not "-1m ago".
    try std.testing.expectEqualStrings("just now", stampText(now + 1, now, &buf).?);

    // Every slot on the page has one, quicksave included, and it is the file
    // `main.zig` stats for that row.
    var ui = Ui{ .page = .save_slots };
    ui.stamps[quick_slot] = now - 120;
    ui.now = now;
    const cfg = Config{};
    try std.testing.expectEqual(slot_count + 1, ui.items().len);
    try std.testing.expectEqualStrings("Quick", ui.items()[quick_slot].label);
    try std.testing.expectEqualStrings("2m ago", valueText(ui.items()[quick_slot].act, &cfg, &ui, &buf).?);
    try std.testing.expectEqualStrings("empty", valueText(ui.items()[0].act, &cfg, &ui, &buf).?);
}

test "scanlines stripe every source line, or stay off the picture entirely" {
    // A 224-line picture at 1x, and the 480-line interlace in a 3x window:
    // under two device pixels a row, so there is no gap to draw in.
    try std.testing.expectEqual(@as(?Stripes, null), stripes(224, 224));
    try std.testing.expectEqual(@as(?Stripes, null), stripes(672, 480));

    // 3x and 6x, both H40 V28. The dark part is a third of the row, never
    // thinner than the pixel it has to land on.
    const three = stripes(672, 224).?;
    try std.testing.expectEqual(@as(f32, 3), three.row);
    try std.testing.expectEqual(@as(f32, 1), three.thick);
    const six = stripes(1344, 224).?;
    try std.testing.expectEqual(@as(f32, 6), six.row);
    try std.testing.expectEqual(@as(f32, 2), six.thick);

    // Stripes never touch each other and the last one stops at the bottom of
    // the glass rather than under the status bar. Fullscreen heights are not
    // whole multiples of the line count, so this is checked off a ragged one.
    const glass: f32 = 907;
    const lines: f32 = 240;
    const s = stripes(glass, lines).?;
    try std.testing.expect(s.thick <= s.row);
    try std.testing.expectApproxEqAbs(glass, lines * s.row, 0.01);
    try std.testing.expect(lines * s.row - s.thick >= glass - s.row);
}

test "scanlines are an option, a menu row, and a key" {
    var ui = Ui{};
    var cfg = Config{};
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("off", valueText(.scanlines, &cfg, &ui, &buf).?);

    _ = adjust(&ui, &cfg, .scanlines, 1, false);
    try std.testing.expect(cfg.scanlines);
    try std.testing.expect(ui.dirty); // and so it survives a restart
    try std.testing.expectEqualStrings("on", valueText(.scanlines, &cfg, &ui, &buf).?);
    _ = adjust(&ui, &cfg, .scanlines, -1, false);
    try std.testing.expect(!cfg.scanlines);

    // The row is on the video page, and the key is bound out of the box: the
    // bar hangs its mark on that binding.
    var found = false;
    for (video_items) |item| found = found or item.act == .scanlines;
    try std.testing.expect(found);
    try std.testing.expect(cfg.keys[@intFromEnum(Action.scanlines)] != 0);
}

test "the cartridge card holds what fits and cuts the rest" {
    var ui = Ui{};
    cardStart(&ui, "SUPER TEST GAME", "(C)NOBODY 1991.APR");
    try std.testing.expectEqualStrings("SUPER TEST GAME", std.mem.sliceTo(&ui.card_title, 0));
    try std.testing.expectEqualStrings("(C)NOBODY 1991.APR", std.mem.sliceTo(&ui.card_sub, 0));

    cardRow(&ui, "SERIAL", .plain, "{s}", .{"GM 00001009-00"});
    try std.testing.expectEqual(@as(usize, 1), ui.card_n);
    try std.testing.expectEqualStrings("GM 00001009-00", std.mem.sliceTo(&ui.card[0].value, 0));

    // A value too long for the row is cut, not dropped.
    cardRow(&ui, "FILE", .bad, "{s}", .{"a" ** 80});
    try std.testing.expectEqual(ui.card[1].value.len, std.mem.sliceTo(&ui.card[1].value, 0).len);
    try std.testing.expectEqual(Tone.bad, ui.card[1].tone);

    // The card never grows past the rows it has, and starting over empties it.
    for (0..card_rows * 2) |_| cardRow(&ui, "X", .plain, "y", .{});
    try std.testing.expectEqual(card_rows, ui.card_n);
    cardStart(&ui, "", "");
    try std.testing.expectEqual(@as(usize, 0), ui.card_n);
}

test "every pad button has a light on the bar, and only one" {
    var mask: u16 = 0;
    var lights: usize = 0;
    for (dpad_cells) |c| {
        const action = c.action orelse continue;
        mask |= action.padMask();
        lights += 1;
    }
    for (face_buttons) |b| {
        mask |= b.action.padMask();
        lights += 1;
    }
    for (pad_pills) |p| {
        mask |= p.action.padMask();
        lights += 1;
    }
    try std.testing.expectEqual(@as(u16, 0xFFF), mask);
    try std.testing.expectEqual(@as(usize, 12), lights); // no bit drawn twice

    // A three-button port lights everything but the row it does not have, so
    // what the panel shows is what the machine is being handed.
    var three: u16 = 0;
    for (face_buttons) |b| three |= if (b.row == six_only_row) 0 else b.action.padMask();
    for (pad_pills) |p| three |= if (p.row == six_only_row) 0 else p.action.padMask();
    for (dpad_cells) |c| three |= if (c.action) |a| a.padMask() else 0;
    try std.testing.expectEqual(@as(u16, 0xFF), three);

    const cfg = Config{};
    var buf: [quick_hint_buf]u8 = undefined;
    try std.testing.expectEqualStrings("F6/F7", quickHint(&cfg, &buf));
    try std.testing.expect(held(input.Action.p1_start.padMask(), .p1_start));
    try std.testing.expect(!held(input.Action.p1_start.padMask(), .p1_a));
}

test "a long title scrolls a loop and starts over" {
    const fs = 20;
    const span = 300;
    try std.testing.expectEqual(@as(c_int, 0), marqueeOffset(0, span, fs));

    // Inside the loop it only ever moves left, and it never leaves a gap: the
    // chasing copy is drawn at `span`, so the offset has to stay under it.
    var last: c_int = 0;
    var t: f64 = 0;
    while (t < 60) : (t += 0.1) {
        const off = marqueeOffset(t, span, fs);
        try std.testing.expect(off >= 0 and off < span);
        if (off < last) try std.testing.expect(last > span - fs); // only at the wrap
        last = off;
    }
}

test "every action has a row on the keys page" {
    var ui = Ui{ .page = .keys };
    try std.testing.expectEqual(input.Action.count + 1, ui.items().len);
    for (std.enums.values(input.Action), 0..) |action, i| {
        try std.testing.expectEqual(action, ui.items()[i].act.bind);
    }
    inline for (@typeInfo(Page).@"enum".fields) |field| {
        ui.page = @enumFromInt(field.value);
        try std.testing.expect(ui.items().len > 0 or ui.page == .load);
    }
}
