<p align="center">
  <img src="assets/icon.png" alt="" width="128">
</p>

# zigesis

A Sega Genesis / Mega Drive emulator written in Zig.

zigesis is built on top of [z68k](https://github.com/davidbz/z68k), a
conformance-tested Motorola 68000 core, and adds the rest of the machine:
the Z80 sound coprocessor, the VDP, memory map and bus arbitration, and a
small desktop frontend. Full scope, architecture, and engineering standards
are documented in [`DESIGN.md`](DESIGN.md); this file covers what a
contributor or user needs to build, test, and run it.

## Status

In active development, milestone by milestone (see `DESIGN.md` section 9
for the full plan and acceptance criteria):

- **M0 — Project scaffold and regression harness: done.** Memory map, VDP
  (VRAM/CRAM/VSRAM, DMA, per-scanline rendering), controller input,
  interrupts, headless `--shot` mode, and the frame-hash regression test.
- **M1 — Z80 core and bus integration: done.** A from-scratch Z80 core,
  exact on the full SingleStepTests/z80 conformance corpus, wired into the
  machine with real BUSREQ/RESET semantics and the banked 68k-bus window.
- **M2 — PSG and the audio pipeline: done.** A from-scratch SN76489 core, a
  resampling mixer and ring buffer with no allocation and no raylib import,
  and a raylib `AudioStream` frontend paced by the ring's fill level rather
  than a fixed target FPS. PSG sound effects and percussion are audible.
- **M3 — YM2612: done.** A from-scratch six-channel four-operator FM core
  (envelope generator with SSG-EG, all eight algorithms, LFO, timers,
  channel 6 DAC, panning, the analogue ladder, per-channel mute), verified
  sample by sample against Nuked-OPN2: exact on operators, detune, LFO,
  panning and DAC, within 0.04% on the algorithms, within 0.14 dB on
  envelope sweeps. Music and DAC drums play.
- **M4 — VDP completion: done.** Ports first: a real FIFO driving the status
  bits, DMA metered off the access-slot budget, the full read-target matrix,
  the HV counter latch, VSRAM caching. Then rendering: H32, shadow/highlight,
  both interlace modes, per-line sprite and pixel limits with X=0 masking, and
  PAL V30 timing. VDPFIFOTesting scores 111 of 122 (see `DESIGN.md` section 9).
- **M5 — Frontend shell: done.** Idle snow screen, ROM loading by
  drag-and-drop, built-in file browser or command line, a keyboard- and
  mouse-driven menu, rebindable keys for both pads and every hotkey, window
  scale and fullscreen, pause and reset, region auto-detection, and a
  plain-text config file that survives a restart.
- **M6 and later** (save states, debug tooling, compatibility pass) are not
  started.

## Requirements

- [Zig](https://ziglang.org/) 0.16.0 (see `build.zig.zon`).
- To build the `zigesis` executable (not required for the library modules or
  test suites): the system libraries [raylib](https://www.raylib.com/)
  needs to open a window and a GL context. On Linux:

  ```
  sudo apt-get install libgl1-mesa-dev libx11-dev libxrandr-dev \
    libxinerama-dev libxcursor-dev libxi-dev libasound2-dev
  ```

  macOS and Windows runners already have what raylib needs; nothing extra
  to install there.

## Building

```
zig build check    # compile everything, no linking or execution (fast)
zig build          # build the zigesis executable into zig-out/bin/
zig build icon     # redraw assets/icon.png from src/ui/icon.zig
```

## Running

zigesis needs a Genesis ROM image; it does not ship with one and never
distributes one — supply your own legally obtained copy.

```
zig build run -Doptimize=ReleaseFast -- path/to/rom.bin
zig build run -- rom.bin shot.png --shot 600   # headless: run N frames, write a PNG
zig build run -- rom.bin --trace-z80           # Z80 instruction trace to stderr
zig build run -- rom.bin --volume 50           # 0-100, default 100
zig build run -- rom.bin --pal                 # a 50 Hz PAL machine, 313 lines
zig build run -- rom.bin --ladder              # the YM2612's analogue ladder effect
zig build run -- rom.bin --mute 1,2,6          # silence FM channels (6 is the DAC)
zig build run -- rom.bin --record in.log       # save one button byte per frame
zig build run -- rom.bin --replay in.log       # play that input back
zig build run -- rom.bin --shot 900 --wav out.wav  # headless: dump the mixed audio
zig build run -- rom.bin --shot 900 --hash     # print the pinned regression hashes
```

The ROM is the first positional argument and the PNG path the second; flags
may appear in any order. The ROM is optional: started without one, zigesis
idles on a snow screen until a file is dropped on the window or picked from
the menu. `--volume` and `--pal` override the saved options for that run
only.

### Controls

| Key | Does |
|-----|------|
| Arrows | D-pad |
| A / S / D | Buttons A / B / C |
| Enter | Start |
| Esc | Menu (and back out of it) |
| O | Load ROM |
| P | Pause |
| F5 | Soft reset |
| F11 | Fullscreen |

Every one of those is rebindable from Options → Keys, including a second
controller, which ships unbound. The menu takes the arrow keys and Enter or
the mouse; left/right change a value in place.

### Options file

Options are written whenever the menu changes one, to
`$XDG_CONFIG_HOME/zigesis/config.ini` (or `~/.config/zigesis/config.ini`,
`%APPDATA%\zigesis\config.ini`, or `zigesis.ini` beside the executable). It
is plain `key = value` text meant to be hand-edited:

```ini
version = 1
scale = 3
fullscreen = false
region = auto
audio = true
volume = 100
key.up = UP
key.a = A
key.p2_up = NONE
```

Unknown keys are ignored and out-of-range values clamped; a file with a
missing or unrecognised `version` is ignored entirely and the defaults are
used. `region = auto` reads the cartridge header, so a PAL-only game gets a
50 Hz machine without being told.

### Deterministic replay

The controller is the only nondeterminism in the machine, so `--record` writes
one byte of button state per frame and `--replay` feeds it back. A replayed run
is bit-identical across runs, machines, and optimization levels, which makes
every bug a reproducible bug (DESIGN.md §6.3). `--hash` prints the framebuffer
and resampled-audio hashes that `test/system_test.zig` pins, so re-pinning them
after an intentional change is a copy-paste rather than a hand edit:

```
zigesis rom.gen --replay in.log --shot 900 --hash
frame 900 fb=ad0f63028af8ca82 audio=b0f47eaf9aacf8ff samples=720927
```

## Testing

```
zig build test
```

Runs, per module: VDP, Z80, PSG, YM2612, audio mixer, `genesis` (memory map and
bus), `scheduler` (timing and interrupts), and the frontend's `input`,
`config`, `snow` and menu-arithmetic unit tests, plus two small Z80
conformance-harness unit tests. It also runs the headless regression suite
(`test/system_test.zig`), which boots
[Cave Story MD](https://github.com/andwn/cave-story-md) — a freely
distributable open-source homebrew — and checks the framebuffer and the
resampled sound output against pinned hashes. Fetch the ROM once with
`tools/fetch_test_roms.sh` (pinned to a release tag, into the gitignored
`roms/`); the test skips cleanly when it is absent.

### VDP conformance suite

The same script also fetches [Nemesis' VDPFIFOTesting
ROM](http://nemesis.hacking-cult.org/MegaDrive/Roms/Test/Mine/VDP/), the VDP
conformance suite:

```
zig build vdpfifo -Doptimize=ReleaseFast
```

The ROM self-reports on screen, so reading it used to mean walking 22 pages by
hand and squinting at a PNG. It draws its text one tile per character from a
font uploaded in ASCII order, which means a name table entry *is* the
character: `test/vdpfifo.zig` boots the ROM headless, presses Start whenever
the picture stops changing, and prints every page as text with its score. The
run takes about 10,000 frames and a quarter of a minute.

Each page's failure count is pinned in that file, so the step is a regression
gate and not just a printer — it exits non-zero when a page's score moves in
either direction. It is a separate step from `zig build test` because it wants
a release build to be quick. Where the VDP stands, and why the remaining
failures remain, is tabulated in `DESIGN.md` section 9, M4.

### YM2612 differential suite

The FM core is diffed sample by sample against
[Nuked-OPN2](https://github.com/nukeykt/Nuked-OPN2), the die-shot-accurate
reference, over register logs covering operators, algorithms, envelopes,
SSG-EG, the LFO, panning, the DAC, and both timers:

```
tools/fetch_ym_reference.sh   # once: commit-pinned fetch into testdata/nuked-opn2/ (gitignored)
zig build ym-nuked            # run it, with the per-case report
```

Nuked is LGPL-2.1 and test-only, so it is never vendored. `zig build test`
picks the suite up when the reference is present and skips it entirely when
it is not. The measured deviations are tabulated in `DESIGN.md` section 9, M3.

### Z80 conformance suite

The Z80 core is validated against the full
[SingleStepTests](https://github.com/SingleStepTests) z80 corpus
(1,604,000 test cases), the same harness pattern z68k uses for the 68000:

```
tools/fetch_z80_tests.sh   # once: clones the corpus into testdata/z80/ (~1.6 GB, gitignored)
zig build z80-sst          # run it
zig build z80-sst -- 00    # only test files whose name contains "00"
```

This is a separate step from `zig build test` because the corpus is too
large to fetch in ordinary CI runs.

## Architecture

Single-threaded and master-clock driven: the 53.693175 MHz NTSC master
clock is the only time base, and every chip's rate is a named integer
divider of it (68000 at mclk/7, Z80 at mclk/15, PSG at mclk/240, YM2612 at
mclk/1008).
`scheduler.zig` steps the 68000 a scanline's worth of cycles at a time and
the Z80 an instruction at a time, running both sound chips alongside it and
carrying each one's sub-cycle remainder so timing does not drift.
Full detail in `DESIGN.md` section 3.3.

The codebase follows a data-oriented design: every chip is a flat,
fixed-size struct plus free functions, with no allocation in the per-frame
path and no chip holding a pointer into another. The `Genesis` struct owns
every chip by value and implements the bus each CPU core calls into,
mirroring how z68k itself is structured. Full detail in `DESIGN.md`
section 3.2.

```
src/
  main.zig            entry point, argument parsing, the raylib frontend loop
  genesis.zig         machine state and bus: memory map, arbitration, BUSREQ/RESET
  scheduler.zig       master-clock accounting, per-scanline stepping, interrupts
  vdp.zig             video display processor (315-5313)
  psg.zig             SN76489 PSG: tone and noise channels, attenuation
  ym2612.zig          YM2612 FM: operators, envelopes, LFO, timers, DAC
  audio.zig           mixing, resampling, the ring buffer that feeds raylib
  input.zig           key bindings: which host key drives which pad button or hotkey
  config.zig          the options file: parse, write, defaults
  ui/
    shell.zig         menu, file browser, key rebinding (raylib primitives only)
    snow.zig          the idle screen's noise, as pixels in an array
    icon.zig          the app icon, one character per pixel
  z80/
    cpu.zig           architectural state: registers, flags, interrupt latches
    decode.zig        opcode field decomposition, register tables
    flags.zig         ALU operations and their flag effects
    core.zig          fetch/decode/execute; Core(comptime Bus), same shape as z68k
    root.zig          barrel module
test/
  system_test.zig     headless frame-hash and audio-hash regression suite
  z80_sst_test.zig    SingleStepTests/z80 conformance runner
tools/
  export_icon.zig     turns src/ui/icon.zig into assets/icon.png (zig build icon)
  fetch_test_roms.sh  fetches the free test ROMs (regression suite, VDP conformance) into roms/
  fetch_z80_tests.sh  fetches the Z80 conformance corpus into testdata/
  fetch_ym_reference.sh  fetches Nuked-OPN2, the FM reference, into testdata/
```

The Motorola 68000 core itself (`m68k`) is not in this repository — it is
consumed as the [z68k](https://github.com/davidbz/z68k) package dependency
and is out of scope for changes here.

## References

CPU and machine:

- [z68k](https://github.com/davidbz/z68k) — the 68000 core this project
  depends on, and its own `DESIGN.md` for the prefetch model and testing
  philosophy this project follows.
- [Plutiedev](https://plutiedev.com) — memory map, VDP, Z80 banking, and
  I/O reference.
- Charles MacDonald's Genesis hardware notes and `genvdp.txt` — the
  classic reference for VDP register and DMA behavior.
- [SingleStepTests](https://github.com/SingleStepTests) — the m68000 and
  z80 conformance suites both CPU cores are validated against.

Audio:

- [SMS Power](https://www.smspower.org/Development/SN76489) — the SN76489
  reference the PSG core is written from: register format, LFSR taps, and
  the tone-period-0 behaviour.
- [Nuked-OPN2](https://github.com/nukeykt/Nuked-OPN2) — die-shot-accurate
  YM2612/YM3438 core, the ground truth for FM synthesis validation in M3.
- [ymfm](https://github.com/aaronsgiles/ymfm) — a clean modern FM core
  family.

See `DESIGN.md` section 11 for the complete, annotated reference list.

## License

MIT. See [`LICENSE`](LICENSE).
