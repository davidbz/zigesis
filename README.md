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
- **M2 — PSG and the audio pipeline: done.** A from-scratch SN76489 core,
  a resampling mixer and ring buffer with no allocation and no raylib
  import, and a raylib `AudioStream` frontend whose frame pacing is driven
  by the ring buffer's fill level rather than a fixed target FPS.
- **M3 and later** (YM2612, VDP completion, save states, debug tooling,
  compatibility pass) are not started.

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
```

## Running

zigesis needs a Genesis ROM image; it does not ship with one. Commercial ROMs
are never distributed by this project — supply your own legally obtained
copy.

```
zig build run -Doptimize=ReleaseFast   # roms/Sonic-the-Hedgehog.bin
zig build run -- path/to/other.bin     # a specific ROM
zig build run -- --shot 600 shot.png   # headless: run N frames, write a PNG
zig build run -- --trace-z80           # Z80 instruction trace to stderr
zig build run -- --volume 50           # 0-100, default 100
```

Controls: arrow keys for the d-pad, A/S/D for buttons A/B/C, Enter for
Start.

## Testing

```
zig build test
```

Runs, per module: VDP, Z80, PSG, audio mixer, `genesis` (memory map and
bus), and `scheduler` (timing and interrupts) unit tests, plus two small
Z80 conformance-harness unit tests. It also runs the headless frame-hash
and audio-hash regression suite (`test/system_test.zig`), which boots
`roms/Sonic-the-Hedgehog.bin` and checks the framebuffer and resampled PSG
output against pinned hashes at a few fixed frames — this ROM is never
committed, so the test looks for it in the gitignored `roms/` directory
and skips cleanly when it is absent (always true in CI).

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
divider of it (68000 at mclk/7, Z80 at mclk/15). `scheduler.zig` steps both
CPUs a scanline's worth of cycles at a time, carrying the sub-cycle
remainder so a frame's timing does not drift. Full detail in `DESIGN.md`
section 3.3.

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
  psg.zig             SN76489 PSG: tone/noise channels, attenuation
  audio.zig           mixing, resampling, the ring buffer that feeds raylib
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
  fetch_z80_tests.sh  fetches the Z80 conformance corpus into testdata/
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

Audio (for M3, the YM2612, not yet implemented):

- [Nuked-OPN2](https://github.com/nukeykt/Nuked-OPN2) — die-shot-accurate
  YM2612/YM3438 core, the ground truth for FM synthesis validation.
- [ymfm](https://github.com/aaronsgiles/ymfm) — a clean modern FM core
  family.

See `DESIGN.md` section 11 for the complete, annotated reference list.

## License

MIT. See [`LICENSE`](LICENSE).
