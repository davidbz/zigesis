# zigesis: Sega Genesis / Mega Drive Emulator

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
(`examples/genesis.zig`, `examples/genesis_vdp.zig`) and boots retail
cartridge images with per-scanline video, controller input, interrupts, and
frame timing. Treat it as reference-quality starting material, not throwaway code.

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

- YM2612 FM synthesizer (done in M3).
- SN76489 PSG (done in M2).
- Audio output of any kind (done in M2).
- VDP rendering: shadow/highlight, interlace, H32 mode (256px), per-line
  sprite/pixel limits, sprite masking, PAL (V30/240-line) timing (done in M4).
- VDP port and DMA timing (done in M4): there is no FIFO, so the status
  register's empty/full/DMA-busy bits are constants; DMA of every mode
  completes instantly with no bus locking and no slot stealing; fill reaches
  VRAM only; reads from most code values return 0; there is no HV counter
  latch and no VSRAM data cache. This is invisible to games that only write
  during vblank and fatal to the ones that do not.
- Save states, SRAM cartridge saves, mappers, options UI, key configuration.

## 3. Architecture

### 3.1 Repository layout

New repository (working name `zigesis`) consuming z68k as a Zig package
dependency. Do not fork the CPU into this repo.

```
zigesis/
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
    fetch_ym_reference.sh # Nuked-OPN2, the FM differential reference
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
  exists. Center a single line of text: "Press any key", which opens the
  menu — dropping a ROM on the window works too. The snow is
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
48 kHz into a ring buffer; the drop from a chip rate to 48 kHz needs a real
antialias filter, not interpolation — see the note under §9 M2;
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
  around zero, prominent in low-volume PCM),
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
- Mappers: plain =< 4 MiB ROMs need none. The 0xA130F3-0xA130FF banking
  mapper the few oversized carts use is the only one worth adding, and only
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
Acceptance: retail cartridge images boot and play as in the PoC; `zig build test`
boots a freely distributable homebrew ROM headless and matches pinned frame
hashes; no raylib symbol is reachable from emulation modules.

`vdp`, `genesis` and `scheduler` are separate Zig modules with no path to
raylib in their import graph, so the no-raylib-in-emulation rule is enforced
by the build graph, not just convention — only `main.zig` imports it.
`test/system_test.zig` boots Cave Story MD, a freely distributable
open-source homebrew fetched by `tools/fetch_test_roms.sh` and pinned to a
release tag; it skips cleanly when the ROM has not been fetched.

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

### M2: PSG and the audio pipeline — done

Deliverables: SN76489 core; mixing/resampling/ring-buffer pipeline;
raylib AudioStream output; audio-driven frame pacing; volume option.
Acceptance: PSG-only audio (SFX in many games, full music in some) plays
clean and pitch-correct; emulator speed locks to audio without drift over
a 10-minute headless run; a pinned-hash audio regression test (hash of N
resampled samples for a scripted input log) passes.

`src/psg.zig` is a from-scratch SN76489: three tone channels plus noise,
white and periodic LFSR modes, noise clocked either off a fixed divider or
off tone channel 2, the Sega variant's tone-period-0 behaviour (counter
loaded with 1, not stopped — drum patches clock their noise off a
period-0 tone 3), a shift register that advances on the rising edge of the
noise generator's square alone (so the noise runs at half the rate its period
suggests), and a comptime 2 dB attenuation table scaled against the FM's level
rather than to fill an i16 on its own — the two chips are mixed on the board,
where a full-volume PSG channel is about a fifth of a full-scale FM channel.
Tone frequency comes out as clock/(32 × period) by construction, which is the
divider trap §7 warns about.

`src/audio.zig` owns a fixed-size `Mixer`: a polyphase windowed-sinc
decimator into a fixed-size ring buffer, no allocation and no raylib import.
The rate conversion is an exact integer fraction (48000 × 240 output ticks
per 53693175 master clocks) with its remainder carried across calls like
`mclk_debt`, so a run of any length emits exactly the right sample count
and resamples to the same bytes on every machine. The filter is designed in
floating point at comptime and shipped as a Q15 integer table, so nothing
floating point runs in the frame path.

This started as a boxcar — average the native samples an output sample
covers — because that is one add and §6.2 asked only for interpolation. It
is not enough. A boxcar's first null lands on the output rate rather than
on Nyquist, so everything a square wave puts above 24 kHz folds back into
the audible band at frequencies unrelated to the note. Measured on PSG
square waves, the worst audible alias sat 33 dB under the fundamental for a
3.5 kHz note and 46 dB under for 440 Hz — which is why it was the high
beeps that sounded wrong. The sinc bank puts both at 76 dB and better.

`scheduler.zig` steps the PSG at mclk/240 with its own carried `pclk_debt`,
ungated by Z80 BUSREQ/RESET — the chip is on the VDP die and runs off the
system clock whatever the Z80 is doing. This was once-per-line at M2 and is
per Z80 instruction since M3.

`main.zig` is the only consumer of raylib's `AudioStream`: it polls
`IsAudioStreamProcessed`, hands over a whole sub-buffer at a time (raylib
zero-pads a short update), and paces the frame loop off the ring's fill
level instead of `SetTargetFPS` — surplus means sleep, deficit means run
flat out. `--volume N` (0-100) scales samples in the mixer.

Wiring the PSG up also fixed a live bug: the Z80's window at $7F00-$7FFF
was masked to $C00000-$C0000F, so a sound driver's PSG writes at $7F11
landed on the VDP data port and corrupted CRAM. The window is 32 bytes
wide, and the pinned frame hashes moved with the fix.

### M3: YM2612 — done

Deliverables: FM core (phase generator, envelope generator, operators,
algorithms, LFO, timers, channel 6 DAC mode); stereo panning; ladder-effect
option; per-channel mute (debug); integration at the correct divider.
Acceptance: FM-heavy soundtracks are recognizably
correct in pitch, tempo, and instrument character; DAC drums/voices play;
register-log comparison against Nuked-OPN2 shows matching envelope shapes
on a test bank; audio regression hashes pinned.

`src/ym2612.zig` is a from-scratch six-channel four-operator FM core: a
comptime sine and exponent table pair in the chip's log domain, phase
generator with detune and multiple, key-scaled rates, the eight-state
envelope generator including SSG-EG's four looping shapes, all eight
algorithms with the three feedback taps, the AM/PM LFO, both timers with
their overflow flags and CSM-less mode bits, per-channel stereo panning,
channel 6's DAC, the analogue ladder as an option, and per-channel mute.
State is one struct of arrays over 24 slots; `step()` returns one stereo
sample per 144 chip clocks, the same 24-slot pass the die makes.

Verification is differential rather than by ear: `test/ym_nuked_test.zig`
drives the same register log into this core and into Nuked-OPN2 and diffs
the output sample by sample. Nuked is LGPL and test-only, so
`tools/fetch_ym_reference.sh` fetches it (commit-pinned, checksummed) into
gitignored `testdata/nuked-opn2/` and `build.zig` skips the whole step when
it is absent: `zig build ym-nuked` prints the report, `zig build test`
includes it when the reference is there. Measured, over 32768 samples each:

| Case | Deviation from Nuked |
|---|---|
| single operator, all 8 detunes, panning, DAC (ladder on and off) | exact |
| LFO, all 8 frequencies, AM and PM | exact |
| algorithms 0-7 | max 0.04%, rms 0.001% of full scale |
| envelope banks (attack/decay/sustain/release sweeps) | ≤ 0.14 dB per window |
| SSG-EG modes 0-7 | exact except mode 2, 0.70 dB |
| timer A and B overflow counts | 191/191, 47/47 |

Three deviations are known and deliberate. This model produces a sample per
144 clocks where Nuked produces one per clock, so its output leads by three
samples on write-driven cases; the harness aligns for it and reports the
lead. The sustain knee is `>=` here and `==` on the die, which only differs
when a register write moves the sustain level past a level the envelope has
already passed. And a SSG-EG turnaround makes a one-sample click whose
amplitude lands on a different point of the operator's sine here, which is
all of mode 2's 0.70 dB.

Two hardware details cost most of the debugging and are worth naming. The
LFO prescaler is *masked* with its limit, not compared against it
(`(count & limit) == limit`), which is the same thing counting up from zero
and a different thing after a mid-sweep frequency change — that alone was
the whole LFO mismatch. And the envelope counter's twelfth-bit carry is
added back on the next sample, so the counter gains a tick every wrap;
without it the envelopes drift apart over seconds rather than milliseconds.

`scheduler.zig` now steps both sound chips per Z80 instruction rather than
per line, so a driver's DAC writes land a few microseconds from where they
were written; the YM2612 runs at mclk/1008 (the 68000's mclk/7 divided by
the chip's 144 clocks per sample, ≈53.3 kHz) with its own carried
`yclk_debt`. The mixer resamples both chips independently onto the same
output frames, so the two rates need no common divisor. 68000-side writes
still land at line granularity — slice `runLine` the same way if a game ever
streams PCM from the 68k side.

`--ladder` enables the analogue ladder effect and `--mute 1,2,6` silences
channels by name, both for debugging a suspect instrument.

### M4: VDP completion

Two halves, and the second one is not optional: what the VDP *draws*, and how
its ports *behave*.

Rendering deliverables: shadow/highlight, H32 mode, interlace (including the
double-resolution mode used by two-player split-screen games), per-line
sprite and pixel limits, sprite masking, PAL (313-line, V30) timing, region
selection.

Conformance deliverables: a real FIFO, with the status register's empty,
full, and DMA-busy bits driven by it instead of returned as constants; DMA
metered against the cycle budget, holding the 68000 off and stealing slots
rather than completing between two instructions; DMA fill and copy to all
three memories, not VRAM alone; the full read-target matrix including the
8-bit VRAM target and read-target switching; the HV counter latch behind
register 0 bit 1; the VSRAM data cache; control-port partial-write and
write-pending semantics.

Acceptance: a curated screenshot suite (title screens and known-tricky
scenes across around 10 games, both H32 and H40, NTSC and PAL) matches
pinned hashes; interlaced double-resolution mode renders; overdraw-heavy
scenes flicker like hardware instead of showing extra sprites; and
VDPFIFOTesting is walkable to its last page with every remaining failure
written down and justified, against the baseline recorded below.

The conformance half is sequenced first. Adding rendering features on top of
a VDP whose ports lie about their state means pinning screenshot hashes to
behaviour that is still wrong underneath, and re-pinning all of them once the
FIFO lands.

#### VDPFIFOTesting score (measured 2026-08-11, conformance half done)

Nemesis' VDP conformance ROM, fetched by `tools/fetch_test_roms.sh`, is the
scoreboard for this milestone. It self-reports on screen, and `zig build
vdpfifo` reads that report back out:

```
zig build vdpfifo -Doptimize=ReleaseFast
```

The ROM draws its text one tile per character from a font uploaded in ASCII
order, so a name table entry *is* the character code and the screen can be read
as text without going near a pixel. `test/vdpfifo.zig` boots it headless and
walks all 22 pages in about 10,000 frames (a quarter of a minute), pressing
Start whenever the picture has held still for 400 frames — a page's tests take
between 900 and 1800 frames, results are drawn as they come in, and a press
that arrives while they run is missed, so "stopped changing" is the only
reliable cue that a page has finished.

Each page's failure count is pinned in that file and the step exits non-zero
when one moves, in either direction: this is the regression gate on the ports,
and re-pinning is a deliberate act rather than a re-blessed hash.

**111 of 122, up from 4 of 29 at the end of M2**, where pages 5 onward did not
render at all. Cumulative pass/fail as the ROM reports it:

| Page | Tests | Result | Was |
|------|--------|----------|--------|
| 1 | 1-9 | 9 / 9 | 0 / 9 |
| 2 | 10-16 | 15 / 16 | 0 / 16 |
| 3 | 17-19 | 18 / 19 | 1 / 19 |
| 4 | 20-29 | 28 / 29 | 4 / 29 |
| 5 | 30-34 | 30 / 34 | unreadable |
| 6 | 35-41 | 30 / 41 | unreadable |
| 7-22 | 42-122 | 111 / 122 | unreadable |

Pages 7 to 22 are the DMA transfer, fill, and copy matrices over every target,
CD4 value, and auto-increment: all 81 pass. The eleven failures are three
clusters, and each is a modelling ceiling rather than a loose end:

- **16. FIFO wait states.** The FIFO is a timing model, not a queue: the write
  lands in memory immediately and only its read-out slot is booked
  (`vdp.zig`'s `fifoBook`, off the measured slot tables), which is what drives
  the empty/full bits and the 68000's stall. The stall granularity is a whole
  slot, so the sub-slot wait-state counts this test measures come out wrong.
  Genesis Plus GX takes the same shortcut. Fixing it means draining the queue
  on a schedule instead of writing through, which buys nothing any game can
  see.
- **31-33. Data-port writes during a DMA fill** (VRAM, CRAM, VSRAM). A fill
  runs to completion inside the control-port write that triggers it, so a data
  write "during" the fill is serviced after all of it rather than interleaved
  with it. The busy flag and end time are still metered.
- **35-41. The seven DMA busy flag tests.** The flag is a start/end pair
  around work that has already happened, so it reports the right total
  duration but not the hardware's edges — in particular when register 1's DMA
  enable bit is toggled mid-operation, or when a DMA is triggered with it
  clear. Driving these properly needs DMA stepped a slot at a time from the
  scheduler rather than run atomically.

What the conformance half changed, all in `vdp.zig` unless noted: a four-entry
FIFO with read-out slots off the measured H32/H40 tables, driving the status
register's empty and full bits and stalling the 68000 through
`genesis.stallUntil`; DMA metered off the access-slot budget, with the 68000
held for the whole of a 68k-bus transfer and the source registers advanced;
fill and copy to all three memories, taking their data where hardware does
(VRAM from the last FIFO entry, CRAM and VSRAM from the oldest); the full read
target matrix including the 8-bit VRAM read at code `01100`, with untouched
bits coming back off the FIFO as open bus; the VSRAM data cache at 64 words;
the H/V counter moved onto the master clock with the real ramp and its jump,
plus the register 0 bit 1 latch; and the control port's partial-write, mode-4
register lockout, bit-13 masking, and write-pending semantics.

The scheduler now carries an absolute master clock (`genesis.mclk`, advanced
3420 per line and never reset) because every one of those answers is a
question about *when*, not just what.

#### The rendering half (done 2026-08-12)

The picture's size stopped being a constant. `vdp.fb` is allocated for the
largest mode there is — 320 by 480, H40 and V30 with the double-resolution
interlace — and `frameWidth`/`frameHeight` say how much of it the machine is
using this frame. Everything downstream reads those: `main.zig` crops its
`--shot` PNG to them and stretches the same rectangle over a fixed window,
the way a TV does, and the scanline loop in `scheduler.zig` asks the VDP for
its line count and active height per line rather than compiling them in.

What landed:

- **H32.** 256 pixels, 64 sprites in the table and 16 on a line, and the
  narrower window and sprite tables that go with it — in H40 the VDP ignores
  a bit of both base addresses, and H32 does not.
- **Sprite limits and masking.** Sprites are dropped once a line has 20 of
  them (16 in H32) or 320 pixels of them (256), which is the flicker every
  crowded Genesis screen has, and status bit 6 says so. A sprite at X=0 masks
  everything behind it on the line once another sprite has spent pixels
  there. Sprite-on-sprite overlap sets the collision bit.
- **Shadow/highlight.** A pixel neither plane claims priority on is drawn at
  half brightness; palette 3's colours 14 and 15 stop being colours and
  become operators that lift a pixel back to normal or push it down, and a
  high-priority sprite pixel is always at full brightness. All three shades
  are the same one-bit shift of each 3-bit channel the DAC does.
- **Interlace.** Mode 1 changes nothing but the odd-field flag. Mode 2 weaves
  the two fields into one buffer (a field's line 1 is the picture's line 2 or
  3) and reads 8x16 patterns, which cost the pattern index its top bit.
- **PAL and region.** `--pal` gives 313 lines, the status register's PAL bit,
  the later V-counter wrap (and the later one again in V30), and a PAL
  machine at `$A10001` — which is the one a game actually reads. Cave Story
  MD switches itself to V30 when it sees it, which is the end-to-end proof
  that all four of those agree.

Verified by unit tests in `vdp.zig` (geometry, the two sprite limits and the
X=0 mask, each shadow/highlight operator, the interlaced weave) and by
re-running VDPFIFOTesting: still **111 of 122**, the same eleven failures, so
none of this disturbed the ports.

The acceptance suite above asks for pinned hashes across ten games, and §2
forbids committing or fetching a ROM that cannot be redistributed: the two
cannot both hold. What is pinned in `test/system_test.zig` is the two ROMs
the fetch script can get — Cave Story MD at four checkpoints and
VDPFIFOTesting page 1. The rest was checked by eye against locally-owned
cartridge images and is not in the suite, because a hash nobody else can
reproduce is not a regression test.

Ceilings worth naming, all in `vdp.zig`:

- Sprite masking has one documented special case this does not model: an X=0
  sprite masks even as the first on its line if the *previous* line hit a
  sprite limit. It needs the parser's per-line state carried forward, and no
  game is known to depend on it.
- No fetchable ROM exercises H32 or interlace, so unit tests are the whole
  check on both. The interlace weave in particular is written from Genesis
  Plus GX's behaviour, not measured.
- Sprites are fetched for the line being drawn, not the line ahead, so a
  sprite table written mid-line takes effect a line early.

### M5: Frontend shell — done 2026-08-12

Deliverables: idle snow screen; ROM loading via drag-and-drop, dialog, and
CLI; menu system of section 5.2; key rebinding UI; config persistence;
window scale/fullscreen; pause/reset.
Acceptance: every option in section 5.1 "required" except save states is
reachable from the menu, works, and survives restart via the config file;
the snow idles at negligible CPU.

Four files, and the split between them is the build graph's rule from §4
rather than taste: `input.zig` (what a key means), `config.zig` (what the
file says), and `ui/snow.zig` (pixels in an array) are data modules with no
path to raylib, and `ui/shell.zig` is the only file besides `main.zig` that
includes `raylib.h`. Two `@cImport`s of the same header inside one module
agree on their types, so no wrapper file was needed.

**Bindings.** `input.Action` is one enum covering both pads and every hotkey,
with the sixteen pad buttons first in `Genesis.buttons` bit order so
`padMask` is a shift and pad *n*'s bindings are the eight entries at
`n * pad_count`. `input.buttons(keys, pad, down)` takes the host keyboard as
a function pointer, which is what keeps the window out of the file. Pad 2
ships unbound — two players on one keyboard is a choice, not a default — and
an unbound key reads as never held, so the second port answers "nothing
pressed" until someone binds it. The genesis side grew the port to match:
`buttons2`/`pad2_ctrl`/`pad2_data`, `$A10005`/`$A1000B`, and one shared
`padByte` decoder for both ports, with the third port left reading as empty.

**The config file** is `key = value` text at
`$XDG_CONFIG_HOME/zigesis/config.ini` (then `$HOME/.config`, then `%APPDATA%`,
then next to the exe), written on every change the menu makes and written
once at first launch so there is something to hand-edit. Bindings go out as
names (`UP`, `F11`, `NONE`) via a table that round-trips, with unnamed codes
falling back to decimal: ugly in the file, never wrong. Unknown keys are
ignored and values clamped, but a file whose `version` line is missing or not
ours is ignored *whole* — these are settings, and defaults are a fine answer.
The headless path deliberately never reads it, so a regression run cannot be
perturbed by someone's volume setting.

**Menu.** Raylib primitives, no widget library: a static `Item` table per
page, `update` mutating the `Config` in place and handing back what it cannot
do itself (`load`, `reset`, `quit`) as a `Request`. Keyboard and mouse both
work, hover only moves the selection when the mouse actually moved (a pointer
lying over the list otherwise fights the arrow keys), and the font and row
height derive from `GetScreenHeight()` so the menu is legible at 1x and not
comical fullscreen. Long pages scroll, which the keys page needs: 22 rows.

**Load ROM is a file browser, not a system dialog.** Raylib has none, and a
native one is a dependency per platform for one button; the browser is
raylib's own `LoadDirectoryFiles` filtered to ROM extensions, directories
first, with a `..` row, reusing the menu's list rendering. Drag-and-drop and
the CLI argument reach the same `startMachine`.

**Region** is auto/NTSC/PAL, and `auto` reads the cartridge header's field at
`$1F0`, which has two encodings in the wild (the letters `JUE` or a single
hex-digit bitmask; `E` is ambiguous between them and is read as the letter).
Changing region resets, because timing is chosen when the machine starts and
running on at the old rate would be a lie.

**Pacing.** A running game is still paced by the audio ring (§7); idle,
paused, and no-audio-device frames have nothing draining the mixer, so
`SetTargetFPS` takes over. The snow is a 160x120 texture stretched over
whatever the window is, so its cost does not grow with the window: 60,000
frames of `Snow.step` in 0.450 s ReleaseFast, 7.5 µs a frame, about 0.05% of
one core at 60 fps. The rest of an idle frame is one texture upload and one
quad.

Tested: the pad bit order against `genesis.btn_*`, held keys to pad byte for
both pads, every key name's round trip, conflicting bindings, config
write-then-parse identity, junk and foreign files, the header's region field
in both encodings, the second port and the empty third, list scrolling,
value clamping and region wrap, and that every action has a row on the keys
page. 111 tests green.

Ceilings, and one thing that cannot be checked here:

- The devcontainer has X sockets but no authorisation and no screenshot
  tool, so the window path exits through its `NoDisplay` guard. Everything
  above the drawing calls is unit-tested; the drawing itself was not seen
  running in this environment. Config persistence *was* verified end to end
  by running the binary with `XDG_CONFIG_HOME` pointed at a scratch dir.
- Escape cancels a rebind and backs out of every page, so Escape is not
  bindable. That is the price of it always being the way out.
- Rebinding takes the next key with no conflict check; the keys page paints
  a duplicate red and leaves it, since a deliberate double-bind is legal.
- Save states are M6, so Save State and Load State are not on the root menu
  yet — §5.2's tree lists them and this ships the other five entries.

### M6: Save states and cartridge persistence

Deliverables: versioned save states with slots, menu entries, and hotkeys;
SRAM saves with header parsing; the 0xA130F3 banking mapper; TMSS write
acceptance.
Acceptance: save/load round-trips mid-gameplay are bit-identical under the
deterministic replay harness (save, run N frames, load, run N frames,
identical hashes); an SRAM-backed game retains progress across restarts; a
bank-switched cart boots and switches banks.

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
- Non-redistributable ROMs are never committed or fetched; tests that need them
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
