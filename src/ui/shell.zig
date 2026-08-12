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
};

const Page = enum { root, load, options, video, audio, keys, save_slots, load_slots };

const Act = union(enum) {
    goto: Page,
    back,
    close,
    reset,
    quit,
    scale,
    fullscreen,
    region,
    audio_on,
    volume,
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
    .{ .label = "Back", .act = .back },
};

const video_items = [_]Item{
    .{ .label = "Window scale", .act = .scale },
    .{ .label = "Fullscreen", .act = .fullscreen },
    .{ .label = "Region", .act = .region },
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

pub const Ui = struct {
    open: bool = false,
    paused: bool = false,
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
    card_title: [48:0]u8 = @splat(0),
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
    if (pressed(cfg, .menu)) {
        ui.open = true;
        ui.goto(.root);
    } else if (pressed(cfg, .open)) {
        ui.open = true;
        ui.goto(.load);
        ui.browser.reload();
    } else if (pressed(cfg, .pause)) {
        ui.paused = !ui.paused;
    } else if (pressed(cfg, .fullscreen)) {
        cfg.fullscreen = !cfg.fullscreen;
        ui.dirty = true;
    } else if (pressed(cfg, .reset)) {
        return .reset;
    } else if (pressed(cfg, .next_slot)) {
        ui.slot = (ui.slot + 1) % slots;
        ui.status("state slot {d}", .{ui.slot});
    } else if (has_rom and pressed(cfg, .save_state)) {
        return .{ .save_state = ui.slot };
    } else if (has_rom and pressed(cfg, .load_state)) {
        return .{ .load_state = ui.slot };
    } else if (has_rom and pressed(cfg, .quick_save)) {
        return .{ .save_state = quick_slot };
    } else if (has_rom and pressed(cfg, .quick_load)) {
        return .{ .load_state = quick_slot };
    } else if (!has_rom and rl.GetKeyPressed() != 0) {
        // The idle screen asks for any key; the menu is what any key gets.
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
            ui.goto(if (ui.page == .video or ui.page == .audio or ui.page == .keys) .options else .root);
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
        .audio_on => cfg.audio = !cfg.audio,
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

/// Text size follows the window so the menu is readable at 1x (a 256-pixel
/// window) and not comical at 4x or fullscreen.
fn fontSize() c_int {
    return @max(10, @divTrunc(rl.GetScreenHeight(), 22));
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
    const room = rl.GetScreenHeight() - topY() - rowHeight();
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
    if (ui.status_until > rl.GetTime()) {
        const fs = fontSize();
        rl.DrawText(&ui.status_text, half(fs), rl.GetScreenHeight() - fs * 2, fs, hilite);
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
    const small = @max(10, @divTrunc(fs * 3, 4));
    const pad = half(small);
    const marquee = rowHeight() + pad;

    const x = half(rl.GetScreenWidth());
    const y = topY() - pad;
    const w = rl.GetScreenWidth() - x - fs;
    const h = marquee + pad + rowHeight() * @as(c_int, @intCast(ui.card_n + 1));

    // Nothing is allowed out of the cabinet: a long title is cut off at the
    // edge of the panel rather than drawn across the menu.
    rl.BeginScissorMode(x, y, w, h);
    defer rl.EndScissorMode();

    rl.DrawRectangle(x, y, w, h, panel);
    rl.DrawRectangle(x, y, w, marquee, hilite);
    rl.DrawText(&ui.card_title, x + pad, y + half(marquee - fs), fs, ink);
    rl.DrawRectangleLines(x, y, w, h, hilite);

    var line = y + marquee + pad;
    rl.DrawText(&ui.card_sub, x + pad, line, small, dim);
    line += rowHeight();

    for (ui.card[0..ui.card_n]) |*row| {
        rl.DrawText(&row.label, x + pad, line, small, dim);
        // Values hang off the right edge like a score, which lines them up
        // without the font having to be fixed-width. It is not.
        const width = rl.MeasureText(&row.value, small);
        rl.DrawText(&row.value, x + w - pad - width, line, small, switch (row.tone) {
            .plain => fg,
            .good => good,
            .bad => bad,
        });
        line += rowHeight();
    }
}

fn drawRow(y: c_int, selected: bool) void {
    if (!selected) return;
    rl.DrawRectangle(0, y - 2, rl.GetScreenWidth(), rowHeight(), .{ .r = 255, .g = 255, .b = 255, .a = 30 });
}

fn valueText(act: Act, cfg: *const Config, ui: *const Ui, buf: []u8) ?[:0]const u8 {
    return switch (act) {
        .scale => std.fmt.bufPrintZ(buf, "{d}x", .{cfg.scale}) catch null,
        .fullscreen => if (cfg.fullscreen) "on" else "off",
        .region => switch (cfg.region) {
            .auto => "auto",
            .ntsc => "NTSC",
            .pal => "PAL",
        },
        .audio_on => if (cfg.audio) "on" else "off",
        .volume => std.fmt.bufPrintZ(buf, "{d}%", .{cfg.volume}) catch null,
        .bind => |action| blk: {
            if (ui.rebind == action) break :blk "press a key...";
            var name: [16]u8 = undefined;
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

/// The idle screen's caption. The snow itself is `snow.zig`, drawn by
/// `main.zig` as a texture.
pub fn drawIdlePrompt() void {
    const fs = fontSize();
    const text = "Press any key";
    const w = rl.MeasureText(text, fs);
    const x = @divTrunc(rl.GetScreenWidth() - w, 2);
    const y = @divTrunc(rl.GetScreenHeight(), 2) - fs;
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

test "the cartridge card holds what fits and cuts the rest" {
    var ui = Ui{};
    cardStart(&ui, "SONIC THE HEDGEHOG", "(C)SEGA 1991.APR");
    try std.testing.expectEqualStrings("SONIC THE HEDGEHOG", std.mem.sliceTo(&ui.card_title, 0));
    try std.testing.expectEqualStrings("(C)SEGA 1991.APR", std.mem.sliceTo(&ui.card_sub, 0));

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
