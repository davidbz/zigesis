//! zigesis — Sega Genesis / Mega Drive emulator entry point.
//!
//!     zig build run -Doptimize=ReleaseFast -- path/to/rom.bin
//!     zig build run                                     # no ROM: the snow idles
//!     zig build run -- rom.bin --shot 600 shot.png      # headless: N frames, then a PNG
//!     zig build run -- rom.bin --trace-z80              # Z80 instruction trace to stderr
//!     zig build run -- rom.bin --volume 50              # 0-100, overrides the config file
//!     zig build run -- rom.bin --pal                    # a 50 Hz PAL machine
//!     zig build run -- rom.bin --record in.log          # save one button byte per frame
//!     zig build run -- rom.bin --shot 900 --wav out.wav    # headless: dump the mixed audio
//!     zig build run -- rom.bin --replay in.log --shot 600 --hash
//!
//! `--record`/`--replay` make a run reproducible (DESIGN.md §6.3): the only
//! nondeterminism in the machine is the controller, so a byte per frame is the
//! whole input history. `--hash` prints the framebuffer and audio hashes the
//! regression suite pins, so re-pinning them is a copy-paste.
//!
//! Owns raylib: window, texture upload, the audio stream, input polling, and
//! the headless --shot path. Everything under `genesis`, `scheduler`, `vdp`
//! and `audio` is plain data and functions with no knowledge of any of this.
//!
//! The headless path deliberately never reads the config file: a regression
//! run must not depend on what is in someone's options.
//!
//! Keys are configurable (Escape opens the menu); the defaults are arrows,
//! A/S/D = A/B/C, Enter = Start.

const std = @import("std");
const genesis = @import("genesis");
const cart = @import("cart");
const scheduler = @import("scheduler");
const vdp = @import("vdp");
const audio = @import("audio");
const config = @import("config");
const input = @import("input");
const snow = @import("snow");
const state = @import("state");
const shell = @import("ui/shell.zig");

const rl = @cImport(@cInclude("raylib.h"));

const Genesis = genesis.Genesis;
const Cpu = genesis.Cpu;
const Core = genesis.Core;
const Config = config.Config;

/// Only used when there's no audio device to pace against; NTSC's 262 lines of
/// 3420 mclk are really 59.92 Hz, and raylib's timer can't express the fraction.
const ntsc_fps = 60;
/// PAL's 313 lines of the same 3420 are 49.7 Hz.
const pal_fps = 50;
/// What the idle snow screen costs: one small texture upload per frame.
const idle_fps = 60;
/// Emulated frames per drawn one while the fast-forward key is held. The draw
/// rate stays capped at the video rate, so this is the speed-up exactly.
const fast_forward_frames = 4;

/// How long a dirty backup RAM waits before it is written back to its file.
/// A game touches its save many times in a row, and the file is 64 KiB.
const sram_write_seconds = 5;

/// One byte per frame at ~60 Hz, so this is a bit over three hours of input.
const max_replay_bytes = 1 << 20;
const max_rom_bytes = 8 << 20;
const max_config_bytes = 64 << 10;

const audio_sample_size = 16; // s16
const audio_channels = 2;
/// raylib zero-pads a short `UpdateAudioStream`, so a sub-buffer is refilled
/// all at once or not at all. ~43 ms is small enough to keep latency sane and
/// comfortably above any device period size raylib would round it up to.
const audio_chunk_frames = 2048;
/// Frame pacing target: enough queued audio to ride out a slow frame without
/// underrunning, little enough that input still feels attached. This fill
/// level is the clock the emulator runs on (DESIGN.md §6.2) — surplus means
/// sleep, deficit means run flat out.
const audio_target_frames = 2 * audio_chunk_frames;

/// A recorded input log: one byte of `Genesis.buttons` per frame, no header.
/// Past the end replays as no buttons held, so a log shorter than the run
/// still reproduces up to where it stops.
const Replay = struct {
    log: []const u8,

    fn buttons(r: Replay, frame: u32) u8 {
        return if (frame < r.log.len) r.log[frame] else 0;
    }
};

/// The command-line switches that are not options: debugging knobs and the
/// headless plumbing, none of which belong in the config file.
const Opts = struct {
    trace_z80: bool = false,
    ladder: bool = false,
    mute: [6]bool = @splat(false),
};

/// Hashes the framebuffer and the resampled audio the same way
/// `test/system_test.zig` does, so `--hash` output can be pasted straight into
/// the pinned checkpoints there.
const Hasher = struct {
    audio: std.hash.Wyhash = .init(0),
    samples: u64 = 0,

    fn take(h: *Hasher, s: audio.Frame) void {
        h.audio.update(std.mem.asBytes(&s));
        h.samples += 1;
    }

    fn report(h: *Hasher, g: *const Genesis, frames: u32) void {
        std.debug.print("frame {d} fb={x:0>16} audio={x:0>16} samples={d}\n", .{
            frames,
            std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&g.v.fb)),
            h.audio.final(),
            h.samples,
        });
    }
};

/// Minimal 44-byte canonical WAV header for 16-bit stereo PCM.
fn writeWav(io: std.Io, path: []const u8, pcm: []const audio.Frame) !void {
    const bytes = std.mem.sliceAsBytes(pcm);
    var hdr: [44]u8 = undefined;
    @memcpy(hdr[0..4], "RIFF");
    std.mem.writeInt(u32, hdr[4..8], @intCast(36 + bytes.len), .little);
    @memcpy(hdr[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, hdr[16..20], 16, .little);
    std.mem.writeInt(u16, hdr[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, hdr[22..24], audio_channels, .little);
    std.mem.writeInt(u32, hdr[24..28], audio.sample_rate, .little);
    std.mem.writeInt(u32, hdr[28..32], audio.sample_rate * audio_channels * audio_sample_size / 8, .little);
    std.mem.writeInt(u16, hdr[32..34], audio_channels * audio_sample_size / 8, .little);
    std.mem.writeInt(u16, hdr[34..36], audio_sample_size, .little);
    @memcpy(hdr[36..40], "data");
    std.mem.writeInt(u32, hdr[40..44], @intCast(bytes.len), .little);

    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(&hdr);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

/// The window is sized for the widest, shortest mode there is; everything
/// else is stretched into it (see `drawPicture`).
fn windowW(scale: u8) c_int {
    return vdp.max_width * @as(c_int, scale);
}

/// The picture plus the status bar under it. `shell.barHeight` derives itself
/// from the window rather than the scale, so this only has to leave it about
/// the right room.
fn windowH(scale: u8) c_int {
    const bar_share = 10; // what `shell.barHeight` comes out at, as a fraction
    const picture = vdp.height_v28 * @as(c_int, scale);
    return picture + @divTrunc(picture, bar_share);
}

fn keyDown(key: u32) bool {
    return rl.IsKeyDown(@intCast(key));
}

/// Hands raylib a full sub-buffer whenever it has one free and the mixer has
/// one ready. Polling like this is the pattern raylib's own audio-stream
/// example uses, so there is no callback thread to synchronize with.
fn drainAudio(g: *Genesis, stream: rl.AudioStream) void {
    while (g.audio.ready() >= audio_chunk_frames and rl.IsAudioStreamProcessed(stream)) {
        var pcm: [audio_chunk_frames]audio.Frame = undefined;
        for (&pcm) |*frame| frame.* = g.audio.pop().?;
        rl.UpdateAudioStream(stream, &pcm, pcm.len);
    }
}

/// Sleeps off the surplus once the mixer is further ahead of playback than
/// the target; being behind returns immediately, so the emulator catches up
/// on its own without ever needing to skip a frame.
fn paceToAudio(g: *Genesis, io: std.Io) void {
    if (g.audio.ready() <= audio_target_frames) return;

    const surplus_ms = (g.audio.ready() - audio_target_frames) * std.time.ms_per_s / audio.sample_rate;
    io.sleep(.fromMilliseconds(@intCast(surplus_ms)), .awake) catch {};
}

/// Power-on, and also what the Reset menu entry does: every chip back to its
/// reset state with the cartridge still in the slot. Not the 68000's reset
/// line — that would keep work RAM, and no game notices the difference.
///
/// Backup RAM does not survive this, because it is a battery, not a chip: the
/// caller writes it out and reads it back around the call (`flushSram`).
fn startMachine(g: *Genesis, c: *Cpu, rom: []const u8, cfg: Config, opts: Opts) void {
    c.* = .{};
    g.* = .init(rom, c);
    g.z80_trace = opts.trace_z80;
    g.y.ladder = opts.ladder;
    g.y.mute = opts.mute;
    g.v.pal = switch (cfg.region) {
        .auto => genesis.romIsPal(rom),
        .ntsc => false,
        .pal => true,
    };
    Core.reset(c, g);
}

/// Every ROM the frontend loads comes through here, so a copier dump is a
/// plain image by the time anything else sees it.
fn readRom(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const image = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_rom_bytes));
    if (!cart.interleaved(image)) return image;
    return gpa.realloc(image, cart.deinterleave(image));
}

/// Save states and backup RAM live beside the ROM, with an extension *added*
/// rather than replaced: `game.bin.srm`, `game.bin.st0`. Two ROMs of the
/// same name in different formats then never share a file.
fn keepPath(buf: []u8, path: []const u8) []const u8 {
    const n = @min(path.len, buf.len);
    @memcpy(buf[0..n], path[0..n]);
    return buf[0..n];
}

fn sidecarPath(buf: []u8, rom_path: []const u8, comptime fmt: []const u8, args: anytype) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    try w.writeAll(rom_path);
    try w.print(fmt, args);
    return w.buffered();
}

/// Backup RAM is read once when the cartridge goes in. A short file fills the
/// front of the window and leaves the rest erased, which is what a game that
/// grew its save format sees on real hardware too.
fn loadSram(io: std.Io, g: *Genesis, rom_path: []const u8) void {
    var buf: [shell.max_path]u8 = undefined;
    const path = sidecarPath(&buf, rom_path, ".srm", .{}) catch return;
    _ = std.Io.Dir.cwd().readFile(io, path, &g.cart.sram) catch return;
    g.cart.sram_dirty = false;
}

fn flushSram(io: std.Io, g: *Genesis, rom_path: []const u8) !void {
    if (!g.cart.sram_dirty) return;
    var buf: [shell.max_path]u8 = undefined;
    const path = try sidecarPath(&buf, rom_path, ".srm", .{});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = &g.cart.sram });
    g.cart.sram_dirty = false;
}

/// The card the pause menu shows over the picture: what the cartridge header
/// says about itself, plus what the file it came out of turned out to be.
/// Built when the cartridge goes in, because none of it changes while the
/// game plays.
fn describeRom(ui: *shell.Ui, g: *const Genesis, rom: []const u8, rom_path: []const u8) void {
    const info = cart.info(rom);
    var title_buf: [shell.max_card_title]u8 = undefined;
    shell.cardStart(
        ui,
        // Homebrew and bad dumps leave the title blank; the filename is then
        // the only name the thing has, and the marquee has to say something.
        if (info.title.len != 0) cart.squeezed(&title_buf, info.title) else std.fs.path.basename(rom_path),
        info.copyright,
    );
    shell.cardRow(ui, "FILE", .plain, "{s}", .{std.fs.path.basename(rom_path)});
    shell.cardRow(ui, "SERIAL", .plain, "{s}", .{info.serial});
    // The default raylib font is ASCII, so no bullets or dashes fancier than
    // what a keyboard has.
    shell.cardRow(ui, "REGION", .plain, "{s} / {s}", .{
        info.region,
        if (g.v.pal) "PAL 50Hz" else "NTSC 60Hz",
    });
    shell.cardRow(ui, "DEVICES", .plain, "{s}", .{info.devices});
    shell.cardRow(ui, "SIZE", .plain, "{d} KiB", .{rom.len >> 10});
    if (info.checksum == 0) {
        // Homebrew often never fills the field in, and a dump that sums to
        // nothing has not failed a check nobody made.
        shell.cardRow(ui, "CHECKSUM", .plain, "NOT SET", .{});
    } else {
        const ok = info.checksumOk();
        shell.cardRow(ui, "CHECKSUM", if (ok) .good else .bad, "{x:0>4} {s}", .{
            info.checksum,
            if (ok) "OK" else "BAD",
        });
    }
    if (g.cart.sram_end > g.cart.sram_start) {
        shell.cardRow(ui, "BACKUP", .plain, "{d} KiB", .{(@as(u32, g.cart.sram_end) - g.cart.sram_start + 1) >> 10});
    } else {
        shell.cardRow(ui, "BACKUP", .plain, "NONE", .{});
    }
}

fn saveState(io: std.Io, g: *const Genesis, c: *const Cpu, rom_path: []const u8, slot: u8) !void {
    var buf: [shell.max_path]u8 = undefined;
    const path = try sidecarPath(&buf, rom_path, ".st{d}", .{slot});
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var out: [4096]u8 = undefined;
    var w = f.writer(io, &out);
    try state.write(g, c, &w.interface);
    try w.interface.flush();
}

/// What the slot pages show: when each slot was written, or 0 for a slot with
/// no file. A slot that cannot be statted reads as empty, which is what it is
/// as far as loading it goes.
fn refreshStamps(io: std.Io, ui: *shell.Ui, rom_path: ?[]const u8) void {
    ui.stamps = @splat(0);
    ui.stamps_dirty = false;
    const rom = rom_path orelse return;
    var buf: [shell.max_path]u8 = undefined;
    for (&ui.stamps, 0..) |*stamp, slot| {
        const path = sidecarPath(&buf, rom, ".st{d}", .{slot}) catch continue;
        const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        stamp.* = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
    }
}

/// Wall clock, not `rl.GetTime()`: the ages on the slot pages are measured
/// against file timestamps, which are the same clock.
fn nowSeconds(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

fn loadState(io: std.Io, gpa: std.mem.Allocator, g: *Genesis, c: *Cpu, rom_path: []const u8, slot: u8) !void {
    var buf: [shell.max_path]u8 = undefined;
    const path = try sidecarPath(&buf, rom_path, ".st{d}", .{slot});
    const bytes = try gpa.alloc(u8, state.size);
    defer gpa.free(bytes);
    try state.read(try std.Io.Dir.cwd().readFile(io, path, bytes), g, c);
}

/// XDG on Linux, `%APPDATA%` on Windows, and the working directory when the
/// environment says nothing — options are worth persisting, not worth failing
/// a launch over.
fn configPath(gpa: std.mem.Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_CONFIG_HOME")) |dir| return std.fs.path.join(gpa, &.{ dir, "zigesis", "config.ini" });
    if (env.get("HOME")) |dir| return std.fs.path.join(gpa, &.{ dir, ".config", "zigesis", "config.ini" });
    if (env.get("APPDATA")) |dir| return std.fs.path.join(gpa, &.{ dir, "zigesis", "config.ini" });
    return gpa.dupe(u8, "zigesis.ini");
}

fn saveConfig(io: std.Io, path: []const u8, cfg: Config) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.write(&w);
    try cwd.writeFile(io, .{ .sub_path = path, .data = w.buffered() });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    var path: ?[]const u8 = null;
    var shot_frames: ?u32 = null;
    var shot_path: [:0]const u8 = "shot.png";
    var record_path: ?[]const u8 = null;
    var replay_path: ?[]const u8 = null;
    var want_hash = false;
    var wav_path: ?[]const u8 = null;
    var mute_list: ?[]const u8 = null;
    var opts = Opts{};
    // CLI overrides of persisted options, applied after the config file is
    // read and never written back: a flag is for this run.
    var volume_arg: ?u8 = null;
    var pal_arg = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--shot")) {
            shot_frames = try std.fmt.parseInt(u32, args.next() orelse "60", 10);
        } else if (std.mem.eql(u8, arg, "--trace-z80")) {
            opts.trace_z80 = true;
        } else if (std.mem.eql(u8, arg, "--volume")) {
            volume_arg = @min(100, try std.fmt.parseInt(u8, args.next() orelse "100", 10));
        } else if (std.mem.eql(u8, arg, "--record")) {
            record_path = args.next() orelse return error.MissingRecordPath;
        } else if (std.mem.eql(u8, arg, "--replay")) {
            replay_path = args.next() orelse return error.MissingReplayPath;
        } else if (std.mem.eql(u8, arg, "--wav")) {
            wav_path = args.next() orelse return error.MissingWavPath;
        } else if (std.mem.eql(u8, arg, "--pal")) {
            pal_arg = true;
        } else if (std.mem.eql(u8, arg, "--hash")) {
            want_hash = true;
        } else if (std.mem.eql(u8, arg, "--ladder")) {
            opts.ladder = true;
        } else if (std.mem.eql(u8, arg, "--mute")) {
            mute_list = args.next() orelse return error.MissingMuteList;
        } else if (path == null) {
            path = arg;
        } else shot_path = arg; // second positional: where --shot writes its PNG
    }

    // Channels are named 1-6 the way the register map and every tracker names
    // them; anything else in the list is a typo worth reporting.
    if (mute_list) |list| {
        var it = std.mem.tokenizeAny(u8, list, ", ");
        while (it.next()) |field| {
            const ch = std.fmt.parseInt(u8, field, 10) catch return error.BadMuteList;
            if (ch < 1 or ch > opts.mute.len) return error.BadMuteList;
            opts.mute[ch - 1] = true;
        }
    }

    var c = Cpu{};
    // A megabyte of VDP and RAM: too much for the stack.
    const g = try gpa.create(Genesis);
    defer gpa.destroy(g);
    g.* = .{ .rom = &.{}, .cpu = &c };

    var rom: ?[]u8 = null;
    defer if (rom) |r| gpa.free(r);
    if (path) |p| {
        rom = readRom(io, gpa, p) catch |err| {
            std.debug.print("cannot read {s}: {t}\n", .{ p, err });
            return err;
        };
    }

    if (shot_frames) |n| {
        var cfg = Config{};
        if (volume_arg) |v| cfg.volume = v;
        if (pal_arg) cfg.region = .pal;
        const image = rom orelse {
            std.debug.print("--shot needs a ROM\n", .{});
            return error.NoRomGiven;
        };
        startMachine(g, &c, image, cfg, opts);
        g.audio.volume_pct = cfg.volume;
        return headless(io, gpa, g, &c, n, shot_path, .{
            .replay = replay_path,
            .record = record_path,
            .wav = wav_path,
            .hash = want_hash,
        });
    }

    const cfg_path = try configPath(gpa, init.environ_map);
    defer gpa.free(cfg_path);
    var cfg: Config = blk: {
        const text = std.Io.Dir.cwd().readFileAlloc(io, cfg_path, gpa, .limited(max_config_bytes)) catch {
            // Nothing there yet: write the defaults out, so there is a file to
            // hand-edit without having to change something in the menu first.
            saveConfig(io, cfg_path, .{}) catch |err| std.debug.print("cannot write {s}: {t}\n", .{ cfg_path, err });
            break :blk .{};
        };
        defer gpa.free(text);
        break :blk Config.parse(text);
    };
    if (volume_arg) |v| cfg.volume = v;
    if (pal_arg) cfg.region = .pal;
    if (rom) |image| startMachine(g, &c, image, cfg, opts);

    try windowed(io, gpa, g, &c, &cfg, opts, &rom, .{
        .config = cfg_path,
        .rom = path,
        .replay = replay_path,
        .record = record_path,
    });
}

const HeadlessArgs = struct {
    replay: ?[]const u8,
    record: ?[]const u8,
    wav: ?[]const u8,
    hash: bool,
};

/// No window and no GL: `ExportImage` only touches pixels, so this runs on a
/// CI box with no display.
fn headless(
    io: std.Io,
    gpa: std.mem.Allocator,
    g: *Genesis,
    c: *Cpu,
    n: u32,
    shot_path: [:0]const u8,
    args: HeadlessArgs,
) !void {
    const replay: ?Replay = if (args.replay) |p| .{
        .log = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(max_replay_bytes)) catch |err| {
            std.debug.print("cannot read replay {s}: {t}\n", .{ p, err });
            return err;
        },
    } else null;
    defer if (replay) |r| gpa.free(r.log);

    var record: ?std.ArrayList(u8) = if (args.record == null) null else .empty;
    defer if (record) |*r| r.deinit(gpa);

    var hasher = Hasher{};
    var pcm: std.ArrayList(audio.Frame) = .empty;
    defer pcm.deinit(gpa);

    var frames: u32 = 0;
    while (frames < n and !c.halted) : (frames += 1) {
        if (replay) |r| g.buttons = r.buttons(frames);
        if (record) |*r| try r.append(gpa, g.buttons);
        scheduler.runFrame(g, c);
        // Drained every frame so the fixed-size ring never drops a sample,
        // exactly as the windowed loop and the regression suite drain it.
        // One loop, however many consumers: draining per consumer means the
        // first one to run empties the ring and every other one gets
        // nothing. `--shot N --hash --wav out.wav` wrote a 44-byte WAV.
        while (g.audio.pop()) |s| {
            if (args.hash) hasher.take(s);
            if (args.wav != null) try pcm.append(gpa, s);
        }
    }
    if (args.hash) hasher.report(g, frames);
    if (args.wav) |p| {
        try writeWav(io, p, pcm.items);
        std.debug.print("wrote {d} frames of audio to {s}\n", .{ pcm.items.len, p });
    }
    if (record) |*r| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args.record.?, .data = r.items });
        std.debug.print("recorded {d} frames of input to {s}\n", .{ r.items.len, args.record.? });
    }
    const shot = shotImage(g);
    defer rl.UnloadImage(shot);
    _ = rl.ExportImage(shot, shot_path.ptr);
    report(c, frames);
}

/// The picture as a file wants it: cropped to the mode the machine is in,
/// since the buffer is always allocated for the largest one.
fn shotImage(g: *Genesis) rl.Image {
    return rl.ImageFromImage(fbImage(g), .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(g.v.frameWidth()),
        .height = @floatFromInt(g.v.frameHeight()),
    });
}

fn fbImage(g: *Genesis) rl.Image {
    return .{
        .data = &g.v.fb,
        .width = vdp.max_width,
        .height = vdp.max_height,
        .mipmaps = 1,
        .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
    };
}

fn report(c: *const Cpu, frames: u32) void {
    std.debug.print("{d} frames, {d} cycles ({d:.2}s emulated), pc={x:0>6} sr={x:0>4} halted={}\n", .{
        frames, c.cycles, @as(f64, @floatFromInt(c.cycles)) / scheduler.cpu_hz, c.pc, c.sr.toInt(), c.halted,
    });
}

const WindowedArgs = struct {
    config: []const u8,
    rom: ?[]const u8,
    replay: ?[]const u8,
    record: ?[]const u8,
};

/// The window, the frame loop, and the shell: idle snow with no cartridge,
/// the picture with one, and the menu over either.
fn windowed(
    io: std.Io,
    gpa: std.mem.Allocator,
    g: *Genesis,
    c: *Cpu,
    cfg: *Config,
    opts: Opts,
    rom: *?[]u8,
    args: WindowedArgs,
) !void {
    const replay: ?Replay = if (args.replay) |p| .{
        .log = try std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(max_replay_bytes)),
    } else null;
    defer if (replay) |r| gpa.free(r.log);
    var record: ?std.ArrayList(u8) = if (args.record == null) null else .empty;
    defer if (record) |*r| r.deinit(gpa);

    rl.InitWindow(windowW(cfg.scale), windowH(cfg.scale), "zigesis — Genesis");
    if (!rl.IsWindowReady()) {
        // Closing a window that never opened is a segfault, so leave first.
        std.debug.print("no window (no display?); try --shot N out.png instead\n", .{});
        return error.NoDisplay;
    }
    defer rl.CloseWindow();
    rl.SetExitKey(rl.KEY_NULL); // Escape is the menu key, not the quit key

    const tex = rl.LoadTextureFromImage(fbImage(g));
    var flakes = snow.Snow{};
    var snow_px: [snow.width * snow.height]u32 = @splat(0xFF00_0000);
    const snow_tex = rl.LoadTextureFromImage(.{
        .data = &snow_px,
        .width = snow.width,
        .height = snow.height,
        .mipmaps = 1,
        .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
    });

    // The stream, not the vsync, paces the loop while a game runs: no
    // SetTargetFPS, just `paceToAudio` below.
    rl.InitAudioDevice();
    defer rl.CloseAudioDevice();
    // Without a device nothing ever drains the mixer, so the ring sits full
    // and `paceToAudio` would sleep the loop down to a crawl. Fall back to
    // timer pacing and keep the picture running.
    const has_audio = rl.IsAudioDeviceReady();
    if (!has_audio) std.debug.print("no audio device; pacing on the frame timer instead\n", .{});
    rl.SetAudioStreamBufferSizeDefault(audio_chunk_frames);
    const stream = rl.LoadAudioStream(audio.sample_rate, audio_sample_size, audio_channels);
    defer rl.UnloadAudioStream(stream);
    rl.PlayAudioStream(stream);

    // Where this ROM's own files go. It outlives the `Request.load` slice it
    // is copied from, which points into the shell's own buffer.
    var path_buf: [shell.max_path]u8 = undefined;
    var path: ?[]const u8 = if (args.rom) |p| keepPath(&path_buf, p) else null;
    if (path) |p| loadSram(io, g, p);

    var ui = shell.Ui{};
    if (rom.*) |image| if (path) |p| describeRom(&ui, g, image, p);
    var sram_next: f64 = 0;
    var applied_scale = cfg.scale;
    var applied_fullscreen = false;
    var target_fps: c_int = -1;
    var frames: u32 = 0;
    var quit = false;
    while (!rl.WindowShouldClose() and !quit and !c.halted) {
        switch (shell.update(&ui, cfg, rom.* != null)) {
            .none => {},
            .quit => quit = true,
            // Backup RAM is a battery: it survives a reset, so it goes out to
            // disk and comes back in around the machine being rebuilt.
            .reset => if (rom.*) |image| {
                if (path) |p| flushSram(io, g, p) catch |err| ui.status("cannot save SRAM: {t}", .{err});
                startMachine(g, c, image, cfg.*, opts);
                if (path) |p| loadSram(io, g, p);
                // A reset is how a region change takes effect, so the card's
                // NTSC/PAL line can be stale by now.
                if (path) |p| describeRom(&ui, g, image, p);
            },
            .load => |p| {
                const image = readRom(io, gpa, p) catch |err| {
                    ui.status("cannot load {s}: {t}", .{ p, err });
                    continue;
                };
                if (path) |old| flushSram(io, g, old) catch |err| ui.status("cannot save SRAM: {t}", .{err});
                if (rom.*) |old| gpa.free(old);
                rom.* = image;
                path = keepPath(&path_buf, p);
                startMachine(g, c, image, cfg.*, opts);
                loadSram(io, g, path.?);
                describeRom(&ui, g, image, path.?);
                ui.status("{s}: {d} KiB", .{ p, image.len >> 10 });
                ui.stamps_dirty = true; // a different ROM's slots
                frames = 0;
            },
            .save_state => |slot| if (path) |p| {
                var name: [shell.max_slot_name]u8 = undefined;
                if (saveState(io, g, c, p, slot)) {
                    ui.status("saved {s}", .{shell.slotName(slot, &name)});
                } else |err| ui.status("cannot save {s}: {t}", .{ shell.slotName(slot, &name), err });
                ui.stamps_dirty = true;
            },
            .load_state => |slot| if (path) |p| {
                var name: [shell.max_slot_name]u8 = undefined;
                if (loadState(io, gpa, g, c, p, slot)) {
                    ui.status("loaded {s}", .{shell.slotName(slot, &name)});
                } else |err| ui.status("cannot load {s}: {t}", .{ shell.slotName(slot, &name), err });
            },
            // Numbered by frame, so holding the key down never overwrites the
            // shot before it and the order they were taken in is the order
            // they sort in.
            .screenshot => if (path) |p| {
                var buf: [shell.max_path]u8 = undefined;
                const shot_path = std.fmt.bufPrintZ(&buf, "{s}.{d}.png", .{ p, frames }) catch continue;
                const shot = shotImage(g);
                defer rl.UnloadImage(shot);
                if (rl.ExportImage(shot, shot_path.ptr)) {
                    ui.status("wrote {s}", .{shot_path});
                } else ui.status("cannot write {s}", .{shot_path});
            },
        }
        // The bar shows the quicksave's age too, so this is every frame now,
        // not just while the menu is up. Only the stat of the nine files
        // waits for something to have changed.
        ui.now = nowSeconds(io);
        if (ui.stamps_dirty) refreshStamps(io, &ui, path);
        if (ui.dirty) {
            saveConfig(io, args.config, cfg.*) catch |err| ui.status("cannot save options: {t}", .{err});
            ui.dirty = false;
        }
        if (cfg.fullscreen != applied_fullscreen) {
            rl.ToggleBorderlessWindowed();
            applied_fullscreen = cfg.fullscreen;
        }
        if (!cfg.fullscreen and cfg.scale != applied_scale) {
            rl.SetWindowSize(windowW(cfg.scale), windowH(cfg.scale));
            applied_scale = cfg.scale;
        }
        // The mixer is where the volume knob lives, so muted is volume 0.
        g.audio.volume_pct = if (cfg.audio) cfg.volume else 0;
        // A game writes its save a byte at a time, so the file is rewritten
        // at most this often while it plays, and once more on the way out.
        if (g.cart.sram_dirty and rl.GetTime() >= sram_next) {
            if (path) |p| flushSram(io, g, p) catch |err| ui.status("cannot save SRAM: {t}", .{err});
            sram_next = rl.GetTime() + sram_write_seconds;
        }

        const running = rom.* != null and !ui.open and (!ui.paused or ui.step);
        if (running) {
            // A paused machine owes exactly one frame; a fast-forwarded one
            // runs several per drawn frame. Either way the recording still
            // gets one byte per emulated frame, so a replay of it is a replay.
            const steps: u32 = if (ui.step) 1 else if (ui.fast) fast_forward_frames else 1;
            for (0..steps) |_| {
                if (replay) |r| g.buttons = r.buttons(frames) else g.buttons = input.buttons(cfg.keys, 0, keyDown);
                g.buttons2 = input.buttons(cfg.keys, 1, keyDown);
                if (record) |*r| try r.append(gpa, g.buttons);
                scheduler.runFrame(g, c);
                frames += 1;
                // Drained inside the loop: the ring holds well under a
                // fast-forwarded burst, so it has to go out as it is made.
                if (has_audio) drainAudio(g, stream);
            }
            ui.step = false;
        } else {
            g.buttons = 0;
            g.buttons2 = 0;
        }
        ui.pad = g.buttons;

        // Idle and paused frames have no audio to pace against, so the timer
        // takes over; a running game hands pacing back to the ring buffer.
        // Fast-forward paces on the timer too: capping the *drawn* frames at
        // the video rate is what makes it a fixed multiple of full speed
        // rather than as fast as the box happens to be.
        const video_fps: c_int = if (g.v.pal) pal_fps else ntsc_fps;
        const want_fps: c_int = if (!running) idle_fps else if (has_audio and !ui.fast) 0 else video_fps;
        if (want_fps != target_fps) {
            rl.SetTargetFPS(want_fps);
            target_fps = want_fps;
        }

        rl.BeginDrawing();
        if (rom.* != null) {
            rl.UpdateTexture(tex, &g.v.fb);
            drawPicture(tex, @floatFromInt(g.v.frameWidth()), @floatFromInt(g.v.frameHeight()));
        } else {
            flakes.step(&snow_px);
            rl.UpdateTexture(snow_tex, &snow_px);
            drawPicture(snow_tex, snow.width, snow.height);
            shell.drawIdlePrompt();
        }
        shell.draw(&ui, cfg);
        rl.EndDrawing();

        // Nothing is reading the mixer when idle, and fast-forward is the one
        // case where outrunning the device is the point.
        if (!running or !has_audio or ui.fast) continue;
        paceToAudio(g, io);
    }

    if (path) |p| flushSram(io, g, p) catch |err| std.debug.print("cannot save SRAM: {t}\n", .{err});
    if (record) |*r| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args.record.?, .data = r.items });
        std.debug.print("recorded {d} frames of input to {s}\n", .{ r.items.len, args.record.? });
    }
    report(c, frames);
}

/// The window is a TV: whatever the source is putting out gets stretched to
/// fill it. H32's 256 pixels and H40's 320 are the same width of glass, and
/// so are 224 lines and 240. The glass is the window less the status bar.
fn drawPicture(tex: rl.Texture, w: f32, h: f32) void {
    rl.DrawTexturePro(
        tex,
        .{ .x = 0, .y = 0, .width = w, .height = h },
        .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(rl.GetScreenWidth()),
            .height = @floatFromInt(rl.GetScreenHeight() - shell.barHeight()),
        },
        .{ .x = 0, .y = 0 },
        0,
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    );
}
