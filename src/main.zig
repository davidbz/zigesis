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
const scheduler = @import("scheduler");
const vdp = @import("vdp");
const audio = @import("audio");
const config = @import("config");
const input = @import("input");
const snow = @import("snow");
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

fn windowH(scale: u8) c_int {
    return vdp.height_v28 * @as(c_int, scale);
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
fn startMachine(g: *Genesis, c: *Cpu, rom: []const u8, cfg: Config, opts: Opts) void {
    c.* = .{};
    g.* = .{ .rom = rom, .cpu = c, .z80_trace = opts.trace_z80 };
    g.y.ladder = opts.ladder;
    g.y.mute = opts.mute;
    g.v.pal = switch (cfg.region) {
        .auto => genesis.romIsPal(rom),
        .ntsc => false,
        .pal => true,
    };
    Core.reset(c, g);
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
        rom = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(max_rom_bytes)) catch |err| {
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

    try windowed(io, gpa, g, &c, &cfg, cfg_path, opts, &rom, replay_path, record_path);
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
    // Cropped to the mode the machine ended the run in: the buffer is
    // always allocated for the largest one.
    const shot = rl.ImageFromImage(fbImage(g), .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(g.v.frameWidth()),
        .height = @floatFromInt(g.v.frameHeight()),
    });
    defer rl.UnloadImage(shot);
    _ = rl.ExportImage(shot, shot_path.ptr);
    report(g, c, frames);
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

fn report(g: *const Genesis, c: *const Cpu, frames: u32) void {
    _ = g;
    std.debug.print("{d} frames, {d} cycles ({d:.2}s emulated), pc={x:0>6} sr={x:0>4} halted={}\n", .{
        frames, c.cycles, @as(f64, @floatFromInt(c.cycles)) / scheduler.cpu_hz, c.pc, c.sr.toInt(), c.halted,
    });
}

/// The window, the frame loop, and the shell: idle snow with no cartridge,
/// the picture with one, and the menu over either.
fn windowed(
    io: std.Io,
    gpa: std.mem.Allocator,
    g: *Genesis,
    c: *Cpu,
    cfg: *Config,
    cfg_path: []const u8,
    opts: Opts,
    rom: *?[]u8,
    replay_path: ?[]const u8,
    record_path: ?[]const u8,
) !void {
    const replay: ?Replay = if (replay_path) |p| .{
        .log = try std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(max_replay_bytes)),
    } else null;
    defer if (replay) |r| gpa.free(r.log);
    var record: ?std.ArrayList(u8) = if (record_path == null) null else .empty;
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

    var ui = shell.Ui{};
    var applied_scale = cfg.scale;
    var applied_fullscreen = false;
    var target_fps: c_int = -1;
    var frames: u32 = 0;
    var quit = false;
    while (!rl.WindowShouldClose() and !quit and !c.halted) {
        switch (shell.update(&ui, cfg, rom.* != null)) {
            .none => {},
            .quit => quit = true,
            .reset => if (rom.*) |image| startMachine(g, c, image, cfg.*, opts),
            .load => |p| {
                const image = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(max_rom_bytes)) catch |err| {
                    ui.status("cannot load {s}: {t}", .{ p, err });
                    continue;
                };
                if (rom.*) |old| gpa.free(old);
                rom.* = image;
                startMachine(g, c, image, cfg.*, opts);
                ui.status("{s}: {d} KiB", .{ p, image.len >> 10 });
                frames = 0;
            },
        }
        if (ui.dirty) {
            saveConfig(io, cfg_path, cfg.*) catch |err| ui.status("cannot save options: {t}", .{err});
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

        const running = rom.* != null and !ui.open and !ui.paused;
        if (running) {
            if (replay) |r| g.buttons = r.buttons(frames) else g.buttons = input.buttons(cfg.keys, 0, keyDown);
            g.buttons2 = input.buttons(cfg.keys, 1, keyDown);
            if (record) |*r| try r.append(gpa, g.buttons);
            scheduler.runFrame(g, c);
            frames += 1;
        } else {
            g.buttons = 0;
            g.buttons2 = 0;
        }

        // Idle and paused frames have no audio to pace against, so the timer
        // takes over; a running game hands pacing back to the ring buffer.
        const want_fps: c_int = if (!running) idle_fps else if (has_audio) 0 else if (g.v.pal) pal_fps else ntsc_fps;
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

        if (!running or !has_audio) continue; // nothing is reading the mixer
        drainAudio(g, stream);
        paceToAudio(g, io);
    }

    if (record) |*r| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = record_path.?, .data = r.items });
        std.debug.print("recorded {d} frames of input to {s}\n", .{ r.items.len, record_path.? });
    }
    report(g, c, frames);
}

/// The window is a TV: whatever the source is putting out gets stretched to
/// fill it. H32's 256 pixels and H40's 320 are the same width of glass, and
/// so are 224 lines and 240.
fn drawPicture(tex: rl.Texture, w: f32, h: f32) void {
    rl.DrawTexturePro(
        tex,
        .{ .x = 0, .y = 0, .width = w, .height = h },
        .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(rl.GetScreenWidth()),
            .height = @floatFromInt(rl.GetScreenHeight()),
        },
        .{ .x = 0, .y = 0 },
        0,
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    );
}
