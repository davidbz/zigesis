# zigesis

A Sega Genesis / Mega Drive emulator, written in Zig.

It emulates the whole machine: the 68000 and Z80 CPUs, the VDP (video chip),
both sound chips, controllers, save states, and cartridge saves — plus a
small, friendly desktop app to play games in.

zigesis doesn't ship with any games. You'll need your own legally obtained
ROM files to play anything.

## What it can do

- Plays retail Genesis/Mega Drive cartridges, NTSC and PAL, with accurate
  video and sound.
- Save states (8 slots + a quicksave), cartridge battery saves, and
  configurable key bindings for two controllers (3- or 6-button).
- Drag-and-drop or menu-based ROM loading, pause, fast-forward, frame
  advance, screenshots, fullscreen, and a CRT-style scanline overlay.
- Fast enough to fast-forward, and deterministic enough to record and
  replay a run frame-for-frame.

A few things aren't supported: Sega CD, 32X, and some of the more exotic
cartridge chips (like SSF2's mapper or EEPROM saves).

## Getting started

You'll need [Zig](https://ziglang.org/) 0.16.0.

On Linux you'll also need a few system libraries so [raylib](https://www.raylib.com/)
can open a window:

```
sudo apt-get install libgl1-mesa-dev libx11-dev libxrandr-dev \
  libxinerama-dev libxcursor-dev libxi-dev libasound2-dev
```

(macOS and Windows don't need anything extra.)

Then build it:

```
zig build
```

And run it, pointing at your ROM:

```
zig build run -- path/to/rom.bin
```

Started without a ROM, zigesis idles on a snow screen until you drop one on
the window or pick one from the menu.

## Controls

| Key | Does |
|-----|------|
| Arrows | D-pad |
| A / S / D | Buttons A / B / C |
| Q / W / E | Buttons X / Y / Z (6-button pad only) |
| Enter | Start |
| Esc | Menu (and back out of it) |
| O | Load ROM |
| P | Pause |
| F2 | Save state to the current slot |
| F3 | Next state slot (0-7) |
| F4 | Load state from the current slot |
| F5 | Soft reset |
| F6 | Quicksave |
| F7 | Quickload |
| F8 | Advance one frame (and pause) |
| F11 | Fullscreen |
| F12 | Screenshot |
| Tab (held) | Fast-forward, 4x |

Every key is rebindable from Options → Keys, including a second controller
(unbound by default). The menu works with arrow keys + Enter, or the mouse.

Save states and cartridge saves are written next to the ROM file
(`game.bin.st0`, `game.bin.srm`, and so on), and screenshots land there too.

## References

zigesis is built on top of [z68k](https://github.com/davidbz/z68k) and
[z80](https://github.com/davidbz/z80), conformance-tested 68000 and Z80 cores,
and leans on some excellent community research:

- [Plutiedev](https://plutiedev.com) — memory map, VDP, Z80 banking, and
  I/O reference.
- Charles MacDonald's Genesis hardware notes and `genvdp.txt` — the
  classic reference for VDP register and DMA behavior.
- [SMS Power](https://www.smspower.org/Development/SN76489) — the SN76489
  (PSG) reference.
- [Nuked-OPN2](https://github.com/nukeykt/Nuked-OPN2) — die-shot-accurate
  YM2612/YM3438 core, used to validate the FM sound emulation.
- [ymfm](https://github.com/aaronsgiles/ymfm) — a clean modern FM core
  family.

## License

MIT. See [`LICENSE`](LICENSE).
