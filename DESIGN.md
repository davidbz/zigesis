# zgen: Sega Genesis / Mega Drive Emulator

Design document and milestone plan. Audience: coding agents and human contributors.
This document is the source of truth for scope, architecture, and engineering
standards. Read it in full before writing code.

## 1. Goal

Build a complete, playable Sega Genesis / Mega Drive emulator in Zig on top of
the existing 68000 core, [z68k](https://github.com/davidbz/z68k). The CPU core
is finished and conformance-tested (all 317,500 SingleStepTests cases, exact on
architectural state, cycle counts, and data-space bus cycles). This project
supplies the rest of the machine and a small, polished desktop frontend.

A proof of concept already exists on the `genesis` branch of z68k
(`examples/genesis.zig`, `examples/genesis_vdp.zig`) and boots Sonic the
Hedgehog with per-scanline video, controller input, interrupts, and frame
timing. Treat it as reference-quality starting material, not throwaway code.

Reference PoC: https://github.com/davidbz/z68k/tree/genesis

## 2. Current State (what the PoC already provides)

From `examples/genesis.zig`:

- Full memory map: cartridge ROM (0x000000-0x3FFFFF), 64 KiB work RAM
  (0xE00000-0xFFFFFF mirrors), Z80 address space (0xA00000), I/O
  (0xA10000-0xA1001F), Z80 bus request/reset (0xA11100), VDP ports (0xC00000).
- NTSC timing derived from the 53.693175 MHz master clock: 7 mclk per 68k
  cycle, 3420 mclk per scanline, 262 lines per frame, with mclk remainder
  carried across scanlines so frames do not drift.
- 3-button controller with TH-select multiplexing.
- VBlank (level 6) and HBlank (level 4) interrupts, H/V counter.
- Headless mode (`--shot N out.png`) that runs N frames and writes a PNG.
  This is the seed of the regression test strategy; preserve and extend it.

From `examples/genesis_vdp.zig` (VDP 315-5313):

- VRAM/CRAM/VSRAM, control/data ports, address latch, register file.
- All DMA modes: 68k-to-VDP transfer, fill, copy.
- Per-scanline rendering: planes A/B, window plane, sprites, priority,
  per-line and per-cell scrolling, non-linear CRAM DAC levels.
- H40 mode only (320x224).

Deliberately stubbed in the PoC, i.e. the actual work of this project:

- YM2612 FM synthesizer (reads as never-busy).
- SN76489 PSG.
- Audio output of any kind.
- VDP: shadow/highlight, interlace, H32 mode (256px), per-line sprite/pixel
  limits, sprite masking, PAL (V30/240-line) timing.
- Save states, SRAM cartridge saves, mappers, options UI, key configuration.

## 3. Architecture

### 3.1 Repository layout

New repository (working name `zgen`) consuming z68k as a Zig package
dependency. Do not fork the CPU into this repo.

```
zgen/
  build.zig
  build.zig.zon          # deps: z68k, raylib (lazy)
  DESIGN.md              # this file
  src/
    main.zig             # entry point, arg parsing, frontend loop
    genesis.zig          # machine state + bus (memory map, arbitration)
    scheduler.zig        # master-clock accounting, per-line stepping
    vdp.zig              # video display processor
    z80/
      cpu.zig            # architectural state (registers, flags, IFFs)
      decode.zig         # opcode field decomposition, register tables
      flags.zig          # ALU ops and their flag effects
      core.zig           # fetch/decode/execute, Core(comptime Bus)
      root.zig           # barrel module
    ym2612.zig           # FM synthesizer
    psg.zig              # SN76489
    audio.zig            # mixing, resampling, ring buffer to raylib
    input.zig            # controllers, key bindings
    cart.zig             # ROM loading, header parsing, mappers, SRAM
    state.zig            # save-state serialization
    config.zig           # options persistence (TOML or INI on disk)
    ui/
      shell.zig          # window, menu, snow idle screen
      snow.zig
      debug.zig          # overlays: FPS, VDP viewers, trace toggles
  test/
    system_test.zig      # headless frame-hash regression suite
  tools/
    fetch_test_roms.sh   # public-domain test ROMs only
    fetch_z80_tests.sh   # SingleStepTests/z80 conformance corpus
```

### 3.2 Data-oriented design (mandatory)

Every subsystem is a plain struct of data plus free-standing functions (or
methods that are pure state transitions). No hidden state, no allocation
inside the emulation loop, no callbacks between chips.

- All chip state lives in flat, fixed-size structs: `Vdp`, `Z80`, `Ym2612`,
  `Psg`, `Controller`. The whole machine is one `Genesis` struct that owns
  them by value. This is what makes save states trivial: serializing the
  machine is copying these structs (section 8).
- Business logic never lives next to I/O. The VDP renders into a framebuffer
  array; only the frontend touches raylib. The audio chips write samples into
  a buffer; only `audio.zig` talks to the sound device. Emulation code must
  compile and run headless with no raylib import anywhere in its tree.
- Communication between chips is explicit data flow driven by the scheduler:
  the machine reads outputs from one struct and feeds inputs to another. No
  chip holds a pointer into another chip.
- The existing z68k pattern is the model: the CPU knows nothing about the
  Genesis; the machine implements `read8/read16/write8/write16` and passes
  itself as the bus. The Z80 core must follow the same shape.

### 3.3 Timing model

Single-threaded, master-clock driven. The 53.693175 MHz master clock (NTSC)
is the only time base; every component's rate is a named integer divider of
it:

- 68000: mclk / 7 (approximately 7.670 MHz)
- Z80: mclk / 15 (approximately 3.579 MHz)
- YM2612: clocked at the 68000 rate; one internal cycle per 6 chip clocks,
  one stereo sample per 24 internal cycles (144 chip clocks), approximately
  53.267 kHz native sample rate
- PSG: clocked at the Z80 rate; one output step per 16 clocks
- VDP: 3420 mclk per scanline; 262 lines NTSC, 313 lines PAL

Step granularity is the scanline, as in the PoC: run the 68k for a line's
worth of cycles, run the Z80 for its share, tick the sound chips, render the
line, deliver interrupts at the correct lines. Carry mclk remainders exactly
as the PoC does (`mclk_debt`). Finer-than-line synchronization (mid-line VDP
register writes) is out of scope until a game demands it; when it is needed,
handle it by splitting the line at the write, not by rearchitecting.

PAL support means a second set of named timing constants and 50 Hz pacing,
selected from the cartridge header region and overridable in options.

## 4. Engineering Standards (mandatory, enforced in review)

These rules override habit, style preference, and upstream example code.
Reviewers and agents must reject changes that violate them.

1. Separation of business logic and data (DOP). Structs describe state.
   Functions transform state. Rendering/audio/input backends consume state.
   See section 3.2. A function that both mutates chip state and calls a
   raylib function is a defect.
2. Early return. Validate and bail at the top; the happy path stays at the
   lowest indentation. No `else` after a return. Deep nesting is a smell:
   extract a function or invert the condition.
3. No magic numbers. Every address range, register index, bit position,
   divider, and dimension is a named constant (`const vint_level = 6;`,
   `const cram_size = 64;`). Hardware addresses may appear once, at their
   definition site, with a name. Switch arms over the memory map should read
   as names or at minimum sit directly under a comment-free constant table.
4. Fewer comments, readable code. Comments explain hardware behavior that
   the code cannot express (quirks, why a counter reloads at a strange
   value), never what the code does. If a comment restates the line below
   it, delete one of them. Doc comments on public types and entry points are
   fine and short. The PoC's comment density is the ceiling, not the floor.

Additional standing rules:

- No allocations in the per-frame path. Buffers are fixed-size arrays sized
  by named constants.
- Every milestone lands with its tests. A subsystem without a headless test
  is not done.
- `zig fmt` clean, `zig build test` green, CI on every push.

## 5. Product Specification

### 5.1 Scope philosophy

Genesis Plus GX is the feature ceiling to learn from, not to match. It
offers wide cartridge/peripheral support, cheat systems, netplay, shaders,
and per-game overrides. We take the solid core of that experience and stop:

In scope (required):

- Load ROM (file dialog or drag-and-drop onto the window, plus CLI arg).
- Save states: multiple slots, save/load from the menu and via hotkeys.
- Configurable key bindings for both pads and all emulator hotkeys.
- Options persisted to a plain-text config file next to the executable
  (or XDG config dir), human-editable, versioned.
- Pause, reset (soft), region/video-mode selection (auto/NTSC/PAL),
  window scale (1x-4x, integer), fullscreen toggle.
- Audio enable/volume.

Nice to have (only after all required items ship):

- Recent-ROMs list.
- 6-button controller mode.
- Per-channel audio muting (useful for debugging, doubles as a feature).
- Fast-forward and frame-advance hotkeys.
- Screenshot hotkey (already nearly free given `--shot`).
- CRT-style scanline overlay (simple alpha stripes, not shaders).

Explicitly out of scope: netplay, cheats, shader pipelines, Sega CD/32X,
Master System mode, light guns and exotic peripherals, per-game databases.

### 5.2 The window

One window, simple design, no toolbar clutter. States:

- Idle (no ROM loaded): full-window animated static, like a CRT tuned to a
  dead channel. Implementation: refill a small noise texture each frame from
  a fast PRNG (xoshiro or similar), greyscale, subtle horizontal banding and
  a faint rolling bar for flavor; optional low-volume white noise once audio
  exists. Center a single line of text: "Drop a ROM or press O". The snow is
  the identity of the app; make it look good but keep it under ~50 lines of
  code.
- Running: the emulated framebuffer, integer-scaled, letterboxed on aspect
  mismatch, nearest-neighbor.
- Menu open: emulation paused, a plain vertical menu rendered with raylib
  text over a dimmed frame. Menu tree: Resume / Load ROM / Save State (slot
  submenu) / Load State (slot submenu) / Options (keys, video, audio,
  region) / Reset / Quit. Keyboard and mouse navigable. No custom widget
  library; raylib primitives are enough, and raygui is an acceptable single
  dependency if plain primitives get tedious.

Key configuration UI: pick an action, press a key, it rebinds; Escape
cancels; conflicts are highlighted. Bindings live in the config file.

## 6. Technical Requirements

### 6.1 Video

raylib, as in the PoC: one RGBA texture the size of the VDP framebuffer,
`UpdateTexture` once per frame, draw scaled. H32 mode renders 256-wide into
the same pipeline. Keep the PoC's headless path (render N frames, write
PNG) working forever; it is the backbone of regression testing.

Pacing: rely on the audio ring buffer as the master clock once audio exists
(section 6.2); until then, raylib's target FPS at 60 (NTSC) / 50 (PAL) is
acceptable.

### 6.2 Audio

raylib `AudioStream` at 48 kHz stereo, s16.

Pipeline: YM2612 and PSG produce samples at their native rates during
scanline stepping into per-chip buffers; `audio.zig` mixes and resamples to
48 kHz (linear interpolation is sufficient initially) into a ring buffer;
the raylib stream callback drains it. The fill level of the ring buffer is
the sync signal: sleep when far ahead, skip pacing when behind. This is the
standard way to get both smooth audio and correct speed; do not attempt
video-vsync-driven timing with audio bolted on.

### 6.3 Debugability

Built in from the start, compiled in always (runtime-toggled), because this
is how every subsequent milestone gets diagnosed:

- 68k and Z80 instruction tracing to stderr or a file, toggleable at
  runtime and per-CPU, with a cycle/line/frame prefix. z68k's disassembler
  work in its harness is the starting point for the 68k side.
- Deterministic replay: given a ROM and a recorded input log, a run is
  bit-identical. No wall-clock time or PRNG in the emulation core (the snow
  PRNG lives in the frontend). This makes every bug a reproducible bug.
- Frame hashing: headless mode can print a hash of each frame's framebuffer;
  the regression suite pins hashes for known-good ROMs at known frames.
- Debug overlays (F-keys): FPS and timing stats; VDP inspectors that dump
  planes, sprite table, palette, and register file as images or text; audio
  channel scope. These can be crude; they exist to answer "what is the VDP
  being told" in seconds.
- On CPU exception loops or invalid states, print machine context (PC
  history, SR, pending IRQs, VDP status) instead of dying silently.

## 7. Audio Hardware Notes (research summary)

The sound subsystem is the largest missing piece and has the sharpest
accuracy cliffs. Key facts and traps:

- The Z80 is the sound CPU. Games upload a driver into 8 KiB of Z80 RAM and
  the driver programs both sound chips; without a running Z80 there is
  effectively no music in most games. The Z80 reaches the YM2612 and PSG
  through its own memory map and reaches the 68k bus through a banked
  window at 0x8000-0xFFFF with a bank register at 0x6000. Bus request
  (BUSREQ) and reset handshakes at 0xA11100/0xA11200 must gate actual Z80
  execution, not just return canned values as the PoC does.
- YM2612 (FM, 6 channels, 4 operators each): clocked at the 68k clock; the
  envelope/operator pipeline advances once per 6 chip clocks and produces a
  stereo sample every 144 chip clocks (about 53.267 kHz). Channel 6 can be
  switched to DAC mode, which most games use to stream drum/voice PCM from
  the Z80; DAC support is therefore not optional. Timers A/B matter because
  drivers poll them for tempo. Known accuracy hazards, in rough order of
  audibility: correct clock divider (a wrong divider sounds like a chipmunk
  soundtrack and has bitten other emulator authors), envelope rate scaling,
  the "ladder effect" DAC distortion (the discrete YM2612's non-linear gap
  around zero, prominent in low-volume PCM; famous in Streets of Rage),
  SSG-EG envelopes (used by a handful of drivers), busy-flag timing.
  Strategy: implement a straightforward operator/envelope/phase-generator
  core from the documented behavior, validate against Nuked-OPN2 output on
  register logs, and add ladder-effect emulation as a named option.
- SN76489 PSG (inside the VDP die): 3 square channels plus noise, clocked
  at the Z80 clock with a divide-by-16 output step. Small, well documented,
  and the right first audio milestone because it proves the whole pipeline
  (chip, mixing, resampling, ring buffer) with minimal chip complexity.
  Quirks: tone value 0 behaves as a DC/period-1 output (games use it for
  sample playback tricks), the noise channel's LFSR taps and shift width,
  and channel 3 driving the noise period.
- Mixing: FM and PSG levels are combined and low-pass filtered by the
  console's analog stage; a simple first-order low-pass at around 3 kHz
  cutoff exaggerated is wrong, but some gentle filtering (Model 1-ish)
  makes output far less harsh. Make the filter a named option.

## 8. Save States, Cartridges, Persistence

- Save states: because all machine state is plain structs (section 3.2), a
  state is a versioned header plus a straight serialization of `Genesis`.
  Include every chip, the scheduler remainders, and controller latches.
  Bump the version on any struct change; refuse mismatched versions
  cleanly. Slots are files next to the ROM or in a data dir.
- Cartridge SRAM: parse the standard header (0x1B0-0x1BF) for SRAM
  presence/range; back it with a file written on exit and on a debounced
  timer. EEPROM carts are out of scope initially; log and continue.
- Mappers: plain =< 4 MiB ROMs need none. The Super Street Fighter II
  banking mapper (0xA130F3-0xA130FF) is the only one worth adding, and only
  in a late milestone.
- TMSS: later-model consoles require "SEGA" written to 0xA14000; ship with
  TMSS off (no BIOS), but accept and ignore the writes.
- Config file: simple `key = value` text, loaded at startup, written on
  change. No JSON dependency needed.

## 9. Milestones

Each milestone is a shippable deliverable with acceptance criteria. Do them
in order; do not start a milestone with the previous one's tests red. One
milestone per PR-chain, small PRs within it.

### M0: Project scaffold and regression harness — done

Deliverables: new repo consuming z68k and raylib as dependencies; PoC code
ported into the `src/` layout of section 3.1 unchanged in behavior; headless
frame-hash test runner; CI (build, fmt, tests) on Linux/macOS/Windows.
Acceptance: Sonic 1 boots and plays as in the PoC; `zig build test` runs a
headless Sonic boot and matches pinned frame hashes; no raylib symbol is
reachable from emulation modules.

`vdp`, `genesis` and `scheduler` are separate Zig modules with no path to
raylib in their import graph, so the no-raylib-in-emulation rule is enforced
by the build graph, not just convention — only `main.zig` imports it.
`test/system_test.zig` skips cleanly when `roms/` has no ROM (always true in
CI, per §10) and gates on pinned hashes when one is present locally.

### M1: Z80 core and bus integration — done

Deliverables: Z80 CPU core in the z68k style (state struct, host-supplied
bus, per-instruction cycles); wired into the machine with real
BUSREQ/reset semantics, banked 68k-bus window, and correct Z80 memory map;
Z80 tracing. Validate the core against the SingleStepTests z80 suite (same
harness pattern z68k already uses) before wiring it in.
Acceptance: Z80 conformance suite passes; games that hang without a live
Z80 handshake now run; sound drivers execute (verified by trace) even
though no audio is audible yet.

`src/z80/{cpu,decode,flags,core}.zig` follow the `Core(comptime Bus)`
generic shape (state/decode split from logic, same as `z68k`); `zig build
z80-sst` runs the full SingleStepTests/z80 corpus and passes
1,604,000/1,604,000 on both state and cycles (`tools/fetch_z80_tests.sh`
fetches the corpus into the gitignored `testdata/`). `Genesis` owns the Z80
`Cpu` by value and answers its bus (`z80Read8`/`z80Write8`/`z80In`/`z80Out`)
directly; `scheduler.zig` steps it once per scanline with its own
`zclk_debt` (mclk/15) alongside the 68k's, gated on real BUSREQ ($A11100)
and RESET ($A11200) register semantics — held time earns no debt, so
releasing the Z80 doesn't burst-execute a backlog it never had. `--trace-z80`
prints a `[frame line cycle]`-prefixed PC/opcode/register line per Z80
instruction to stderr.

### M2: PSG and the audio pipeline

Deliverables: SN76489 core; mixing/resampling/ring-buffer pipeline;
raylib AudioStream output; audio-driven frame pacing; volume option.
Acceptance: PSG-only audio (SFX in many games, full music in some) plays
clean and pitch-correct; emulator speed locks to audio without drift over
a 10-minute headless run; a pinned-hash audio regression test (hash of N
resampled samples for a scripted input log) passes.

### M3: YM2612

Deliverables: FM core (phase generator, envelope generator, operators,
algorithms, LFO, timers, channel 6 DAC mode); stereo panning; ladder-effect
option; per-channel mute (debug); integration at the correct divider.
Acceptance: Sonic 1 and Streets of Rage 2 soundtracks are recognizably
correct in pitch, tempo, and instrument character; DAC drums/voices play;
register-log comparison against Nuked-OPN2 shows matching envelope shapes
on a test bank; audio regression hashes pinned.

### M4: VDP completion

Deliverables: shadow/highlight, H32 mode, interlace (including double-
resolution mode used by Sonic 2 two-player), per-line sprite and pixel
limits, sprite masking, PAL (313-line, V30) timing, region selection.
Acceptance: a curated screenshot suite (title screens and known-tricky
scenes across around 10 games, both H32 and H40, NTSC and PAL) matches
pinned hashes; Sonic 2 two-player mode renders; overdraw-heavy scenes
flicker like hardware instead of showing extra sprites.

### M5: Frontend shell

Deliverables: idle snow screen; ROM loading via drag-and-drop, dialog, and
CLI; menu system of section 5.2; key rebinding UI; config persistence;
window scale/fullscreen; pause/reset.
Acceptance: every option in section 5.1 "required" except save states is
reachable from the menu, works, and survives restart via the config file;
the snow idles at negligible CPU.

### M6: Save states and cartridge persistence

Deliverables: versioned save states with slots, menu entries, and hotkeys;
SRAM saves with header parsing; SSF2 mapper; TMSS write acceptance.
Acceptance: save/load round-trips mid-gameplay are bit-identical under the
deterministic replay harness (save, run N frames, load, run N frames,
identical hashes); Sonic 3 retains progress across restarts via SRAM;
Super Street Fighter II boots and switches banks.

### M7: Debug tooling

Deliverables: runtime-toggled 68k/Z80 trace with disassembly; VDP
inspectors (planes, sprites, palette, registers); frame advance and
fast-forward; input recording/replay files; audio channel scope.
Acceptance: each tool demonstrated in a short doc with screenshots; replay
files reproduce runs bit-identically across machines.

### M8: Compatibility and polish

Deliverables: run a 25-30 game compatibility list spanning common engines
and known stress cases; fix what is broken or file precise issues (game,
frame, subsystem, suspected cause); nice-to-have features from section 5.1
as time allows; README with screenshots and a feature table.
Acceptance: at least 90 percent of the list is playable start to finish;
every remaining issue has a reproduction via the replay harness.

## 10. Testing Strategy Summary

- CPU cores: SingleStepTests conformance (m68000 already done in z68k; z80
  in M1). Never regress these.
- Machine: deterministic headless runs with pinned frame hashes and audio
  hashes, driven by recorded input logs. Every bug fix adds a case.
- Hardware test ROMs (public domain, fetched by script, never committed):
  Nemesis's VDPFIFOTesting, the 240p Test Suite, MDFourier for audio
  comparison against real-hardware recordings, and community sprite/scroll
  stress ROMs.
- Commercial ROMs are never committed or fetched; tests that need them
  skip cleanly when the file is absent, exactly as z68k's SST suite does.

## 11. References

CPU and machine:

- z68k and its DESIGN.md (prefetch model, testing philosophy):
  https://github.com/davidbz/z68k
- Genesis PoC branch: https://github.com/davidbz/z68k/tree/genesis
- Sega Genesis Software Manual (official developer documentation).
- Plutiedev (memory map, VDP, Z80 banking, I/O): https://plutiedev.com
- Charles MacDonald's Genesis hardware notes and genvdp.txt (VDP register
  and DMA behavior; the classic reference).
- SingleStepTests suites for m68000 and z80:
  https://github.com/SingleStepTests

Audio:

- Nuked-OPN2, die-shot-accurate YM2612/YM3438 core; the ground truth for
  validation and the definitive ladder-effect reference:
  https://github.com/nukeykt/Nuked-OPN2
- ymfm (Aaron Giles), a clean modern FM core family worth reading:
  https://github.com/aaronsgiles/ymfm
- Nemesis's YM2612 research threads on SpritesMind (envelope generator,
  operator pipeline internals): http://gendev.spritesmind.net/forum/
- jsgroth's "Emulating the YM2612" blog series, parts 1-5, including the
  analog/ladder behavior: https://jsgroth.dev/blog/
- clownmdemu FM writeup (practical pitfalls, including the divider trap):
  https://clownacy.wordpress.com/2022/05/25/clownmdemu-fm-audio-emulation/
- SMS Power SN76489 documentation (LFSR taps, tone-0 behavior):
  https://www.smspower.org/Development/SN76489

Whole-system emulators to consult (read for behavior, do not copy code):

- Genesis Plus GX (feature ceiling, accuracy reference):
  https://github.com/ekeeke/Genesis-Plus-GX
- BlastEm (accuracy-focused, excellent timing notes):
  https://github.com/libretro/blastem
- clownmdemu (small, readable, similar single-author scope):
  https://github.com/Clownacy/clownmdemu
