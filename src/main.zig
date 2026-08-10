//! zigesis — Sega Genesis / Mega Drive emulator entry point.
//!
//!     zig build run -Doptimize=ReleaseFast -- path/to/rom.bin
//!     zig build run -- rom.bin --shot 600 shot.png      # headless: N frames, then a PNG
//!     zig build run -- rom.bin --trace-z80              # Z80 instruction trace to stderr
//!     zig build run -- rom.bin --volume 50              # 0-100, default 100
//!     zig build run -- rom.bin --record in.log          # save one button byte per frame
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
//! Keys: arrows, A/S/D = A/B/C, Enter = Start.

const std = @import("std");
const genesis = @import("genesis");
const scheduler = @import("scheduler");
const vdp = @import("vdp");
const audio = @import("audio");

const rl = @cImport(@cInclude("raylib.h"));

const Genesis = genesis.Genesis;
const Cpu = genesis.Cpu;
const Core = genesis.Core;

const scale = 3;

/// Only used when there's no audio device to pace against; NTSC's 262 lines of
/// 3420 mclk are really 59.92 Hz, and raylib's timer can't express the fraction.
const ntsc_fps = 60;

/// One byte per frame at ~60 Hz, so this is a bit over three hours of input.
const max_replay_bytes = 1 << 20;

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

/// Hashes the framebuffer and the resampled audio the same way
/// `test/system_test.zig` does, so `--hash` output can be pasted straight into
/// the pinned checkpoints there.
const Hasher = struct {
    audio: std.hash.Wyhash = .init(0),
    samples: u64 = 0,

    fn takeAudio(h: *Hasher, g: *Genesis) void {
        while (g.audio.pop()) |s| : (h.samples += 1) h.audio.update(std.mem.asBytes(&s));
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

fn pollInput(g: *Genesis) void {
    var b: u8 = 0;
    if (rl.IsKeyDown(rl.KEY_UP)) b |= genesis.btn_up;
    if (rl.IsKeyDown(rl.KEY_DOWN)) b |= genesis.btn_down;
    if (rl.IsKeyDown(rl.KEY_LEFT)) b |= genesis.btn_left;
    if (rl.IsKeyDown(rl.KEY_RIGHT)) b |= genesis.btn_right;
    if (rl.IsKeyDown(rl.KEY_A)) b |= genesis.btn_a;
    if (rl.IsKeyDown(rl.KEY_S)) b |= genesis.btn_b;
    if (rl.IsKeyDown(rl.KEY_D)) b |= genesis.btn_c;
    if (rl.IsKeyDown(rl.KEY_ENTER)) b |= genesis.btn_start;
    g.buttons = b;
}

/// Hands raylib a full sub-buffer whenever it has one free and the mixer has
/// one ready. Polling like this is the pattern raylib's own audio-stream
/// example uses, so there is no callback thread to synchronize with.
fn drainAudio(g: *Genesis, stream: rl.AudioStream) void {
    while (g.audio.len >= audio_chunk_frames and rl.IsAudioStreamProcessed(stream)) {
        var pcm: [audio_chunk_frames]audio.Frame = undefined;
        for (&pcm) |*frame| frame.* = g.audio.pop().?;
        rl.UpdateAudioStream(stream, &pcm, pcm.len);
    }
}

/// Sleeps off the surplus once the mixer is further ahead of playback than
/// the target; being behind returns immediately, so the emulator catches up
/// on its own without ever needing to skip a frame.
fn paceToAudio(g: *Genesis, io: std.Io) void {
    if (g.audio.len <= audio_target_frames) return;

    const surplus_ms = (g.audio.len - audio_target_frames) * std.time.ms_per_s / audio.sample_rate;
    io.sleep(.fromMilliseconds(@intCast(surplus_ms)), .awake) catch {};
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
    var trace_z80 = false;
    var volume_pct: u8 = 100;
    var record_path: ?[]const u8 = null;
    var replay_path: ?[]const u8 = null;
    var want_hash = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--shot")) {
            shot_frames = try std.fmt.parseInt(u32, args.next() orelse "60", 10);
        } else if (std.mem.eql(u8, arg, "--trace-z80")) {
            trace_z80 = true;
        } else if (std.mem.eql(u8, arg, "--volume")) {
            volume_pct = @min(100, try std.fmt.parseInt(u8, args.next() orelse "100", 10));
        } else if (std.mem.eql(u8, arg, "--record")) {
            record_path = args.next() orelse return error.MissingRecordPath;
        } else if (std.mem.eql(u8, arg, "--replay")) {
            replay_path = args.next() orelse return error.MissingReplayPath;
        } else if (std.mem.eql(u8, arg, "--hash")) {
            want_hash = true;
        } else if (path == null) {
            path = arg;
        } else shot_path = arg; // second positional: where --shot writes its PNG
    }

    const rom_path = path orelse {
        std.debug.print("usage: zigesis <rom> [out.png] [--shot N] [--trace-z80] " ++
            "[--volume 0-100] [--record FILE] [--replay FILE] [--hash]\n", .{});
        return error.NoRomGiven;
    };
    const image = std.Io.Dir.cwd().readFileAlloc(io, rom_path, gpa, .limited(8 << 20)) catch |err| {
        std.debug.print("cannot read {s}: {t}\n", .{ rom_path, err });
        return err;
    };
    defer gpa.free(image);

    var c = Cpu{};
    // A megabyte of VDP and RAM: too much for the stack.
    const g = try gpa.create(Genesis);
    defer gpa.destroy(g);
    g.* = .{ .rom = image, .cpu = &c, .z80_trace = trace_z80 };
    g.audio.volume_pct = volume_pct;

    Core.reset(&c, g);
    std.debug.print("{s}: {d} KiB, reset pc={x:0>6} sp={x:0>8}\n", .{
        rom_path, image.len >> 10, c.pc, c.a[7],
    });

    const replay: ?Replay = if (replay_path) |p| .{
        .log = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(max_replay_bytes)) catch |err| {
            std.debug.print("cannot read replay {s}: {t}\n", .{ p, err });
            return err;
        },
    } else null;
    defer if (replay) |r| gpa.free(r.log);

    var record: ?std.ArrayList(u8) = if (record_path == null) null else .empty;
    defer if (record) |*r| r.deinit(gpa);

    var hasher = Hasher{};
    var frames: u32 = 0;
    if (shot_frames) |n| {
        // Headless: no window, no GL — ExportImage only touches the pixels.
        while (frames < n and !c.halted) : (frames += 1) {
            if (replay) |r| g.buttons = r.buttons(frames);
            scheduler.runFrame(g, &c);
            // Drained every frame so the fixed-size ring never drops a sample,
            // exactly as the windowed loop and the regression suite drain it.
            if (want_hash) hasher.takeAudio(g);
        }
        if (want_hash) hasher.report(g, frames);
        _ = rl.ExportImage(.{
            .data = &g.v.fb,
            .width = vdp.width,
            .height = vdp.height,
            .mipmaps = 1,
            .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
        }, shot_path.ptr);
    } else {
        rl.InitWindow(vdp.width * scale, vdp.height * scale, "zigesis — Genesis");
        if (!rl.IsWindowReady()) {
            // Closing a window that never opened is a segfault, so leave first.
            std.debug.print("no window (no display?); try --shot N out.png instead\n", .{});
            return error.NoDisplay;
        }
        defer rl.CloseWindow();
        const tex = rl.LoadTextureFromImage(.{
            .data = &g.v.fb,
            .width = vdp.width,
            .height = vdp.height,
            .mipmaps = 1,
            .format = rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
        });

        // The stream, not the vsync, paces the loop from here on: no
        // SetTargetFPS, just `paceToAudio` below.
        rl.InitAudioDevice();
        defer rl.CloseAudioDevice();
        // Without a device nothing ever drains the mixer, so the ring sits
        // full and `paceToAudio` would sleep the loop down to a crawl. Fall
        // back to timer pacing and keep the picture running.
        const has_audio = rl.IsAudioDeviceReady();
        if (!has_audio) {
            std.debug.print("no audio device; pacing on the frame timer instead\n", .{});
            rl.SetTargetFPS(ntsc_fps);
        }
        rl.SetAudioStreamBufferSizeDefault(audio_chunk_frames);
        const stream = rl.LoadAudioStream(audio.sample_rate, audio_sample_size, audio_channels);
        defer rl.UnloadAudioStream(stream);
        rl.PlayAudioStream(stream);

        while (!rl.WindowShouldClose() and !c.halted) : (frames += 1) {
            if (replay) |r| g.buttons = r.buttons(frames) else pollInput(g);
            if (record) |*r| try r.append(gpa, g.buttons);
            scheduler.runFrame(g, &c);
            rl.UpdateTexture(tex, &g.v.fb);
            rl.BeginDrawing();
            rl.DrawTexturePro(
                tex,
                .{ .x = 0, .y = 0, .width = vdp.width, .height = vdp.height },
                .{ .x = 0, .y = 0, .width = vdp.width * scale, .height = vdp.height * scale },
                .{ .x = 0, .y = 0 },
                0,
                .{ .r = 255, .g = 255, .b = 255, .a = 255 },
            );
            rl.EndDrawing();
            if (!has_audio) continue; // the mixer just drops; nothing reads it
            drainAudio(g, stream);
            paceToAudio(g, io);
        }
    }

    if (record) |*r| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = record_path.?, .data = r.items });
        std.debug.print("recorded {d} frames of input to {s}\n", .{ r.items.len, record_path.? });
    }

    std.debug.print("{d} frames, {d} cycles ({d:.2}s emulated), pc={x:0>6} sr={x:0>4} halted={}\n", .{
        frames, c.cycles, @as(f64, @floatFromInt(c.cycles)) / scheduler.cpu_hz, c.pc, c.sr.toInt(), c.halted,
    });
}
