//! zigesis — Sega Genesis / Mega Drive emulator entry point.
//!
//!     zig build run -Doptimize=ReleaseFast              # roms/Sonic-the-Hedgehog.bin
//!     zig build run -- roms/other.bin
//!     zig build run -- --shot 600 shot.png              # headless: N frames, then a PNG
//!     zig build run -- --trace-z80                      # Z80 instruction trace to stderr
//!     zig build run -- --volume 50                      # 0-100, default 100
//!
//! Owns raylib: window, texture upload, audio stream, input polling, and
//! the headless --shot path. Everything under `genesis`, `scheduler`,
//! `vdp` and `audio` is plain data and functions with no knowledge of any
//! of this.
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

const default_rom = "roms/Sonic-the-Hedgehog.bin";
const scale = 3;
const audio_sample_size = 16; // s16
const audio_channels = 2;

/// Frame pacing targets this much buffered audio: short enough not to add
/// noticeable input lag, long enough to absorb a slow frame without the
/// stream underrunning. This is the "audio-driven" pacing DESIGN.md §6.2
/// calls for: sleep when there's a surplus, run flat out when there isn't.
const audio_target_ms = 50;
/// One drain covers at most this many frames — comfortably more than the
/// ~800 a single 60Hz video frame produces at 48kHz, even after a stall.
const audio_chunk_frames = 4096;

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

/// Drains whatever the mixer has ready into raylib's stream, only when it's
/// asked for more: matches the polling pattern raylib's own audio-stream
/// example uses, so no callback thread or synchronization is needed.
fn drainAudio(g: *Genesis, stream: rl.AudioStream) void {
    if (!rl.IsAudioStreamProcessed(stream)) return;

    var pcm: [audio_chunk_frames]audio.Frame = undefined;
    var n: usize = 0;
    while (n < pcm.len) : (n += 1) pcm[n] = g.audio.pop() orelse break;
    if (n > 0) rl.UpdateAudioStream(stream, &pcm, @intCast(n));
}

/// Sleeps off any surplus once the ring buffer is comfortably ahead of
/// playback; falling behind (buffer below target, or empty) runs the next
/// frame immediately instead, so the emulator catches back up on its own.
fn paceToAudio(g: *Genesis, io: std.Io) void {
    const buffered_ms = g.audio.len * 1000 / audio.sample_rate;
    if (buffered_ms <= audio_target_ms) return;
    const surplus_ms: i64 = @intCast(buffered_ms - audio_target_ms);
    io.sleep(.fromMilliseconds(surplus_ms), .awake) catch {};
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.skip();
    var path: []const u8 = default_rom;
    var shot_frames: ?u32 = null;
    var shot_path: [:0]const u8 = "shot.png";
    var trace_z80 = false;
    var volume_pct: u8 = 100;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--shot")) {
            shot_frames = try std.fmt.parseInt(u32, args.next() orelse "60", 10);
            if (args.next()) |p| shot_path = p;
        } else if (std.mem.eql(u8, arg, "--trace-z80")) {
            trace_z80 = true;
        } else if (std.mem.eql(u8, arg, "--volume")) {
            volume_pct = @min(100, try std.fmt.parseInt(u8, args.next() orelse "100", 10));
        } else path = arg;
    }

    const image = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
        std.debug.print("cannot read {s}: {t}\n", .{ path, err });
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
        path, image.len >> 10, c.pc, c.a[7],
    });

    var frames: u32 = 0;
    if (shot_frames) |n| {
        // Headless: no window, no GL — ExportImage only touches the pixels.
        while (frames < n and !c.halted) : (frames += 1) scheduler.runFrame(g, &c);
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

        rl.InitAudioDevice();
        defer rl.CloseAudioDevice();
        const stream = rl.LoadAudioStream(audio.sample_rate, audio_sample_size, audio_channels);
        defer rl.UnloadAudioStream(stream);
        rl.PlayAudioStream(stream);

        while (!rl.WindowShouldClose() and !c.halted) : (frames += 1) {
            pollInput(g);
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
            drainAudio(g, stream);
            paceToAudio(g, io);
        }
    }

    std.debug.print("{d} frames, {d} cycles ({d:.2}s emulated), pc={x:0>6} sr={x:0>4} halted={}\n", .{
        frames, c.cycles, @as(f64, @floatFromInt(c.cycles)) / scheduler.cpu_hz, c.pc, c.sr.toInt(), c.halted,
    });
}
