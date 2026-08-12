#!/bin/sh
# Fetches the freely distributable test ROM used by test/system_test.zig
# into roms/ (gitignored). Pinned to a release tag so the bytes, and the
# frame hashes pinned in the test, never change.
#
# Cave Story MD: open-source Genesis port of Cave Story (MIT-style, freely
# distributable). https://github.com/andwn/cave-story-md
#
# VDPFIFOTesting: Nemesis' VDP conformance ROM, the reference for FIFO timing,
# DMA busy flags, and port access. Read by `zig build vdpfifo`.
# http://nemesis.hacking-cult.org/MegaDrive/Roms/Test/Mine/VDP/
set -eu
cd "$(dirname "$0")/.."

url=https://github.com/andwn/cave-story-md/releases/download/v0.8.8/doukutsu-en.gen
sha256=053ed9009b47512972d7fd0954f3c251774422be8be6eb8df90f39fe22b50061
out=roms/doukutsu-en.gen

mkdir -p roms
[ -f "$out" ] || curl -fsSL -o "$out" "$url"
echo "$sha256  $out" | sha256sum -c -

# Distributed only as a zip, and only from the author's site: no release tag to
# pin, so the checksum is the pin. Verified before extracting, not after.
vdp_url=http://nemesis.hacking-cult.org/MegaDrive/Roms/Test/Mine/VDP/VDPFIFOTesting.zip
vdp_zip_sha256=6bb1354be1bb05afa8bcb8a276ab7ba5126fb743bc091b50404c7ad353345e6a
vdp_sha256=8b0ed3944893d679cdb625d6c6fee57f6e07cb117136cc1c212bcc9793bcfefa
vdp_out=roms/VDPFIFOTesting.bin

if [ ! -f "$vdp_out" ]; then
    # `zig build vdpfifo` skips itself when the ROM is missing, so a runner
    # without unzip is not a reason to fail the build the Cave Story fetch
    # above is guarding.
    if ! command -v unzip >/dev/null; then
        echo "unzip not found; skipping $vdp_out" >&2
        exit 0
    fi
    # One person's HTTP site with no mirror, so an outage there must not turn
    # every pull request red: the conformance step skips instead.
    if ! curl -fsSL -o roms/vdpfifo.zip "$vdp_url"; then
        echo "could not fetch $vdp_url; skipping $vdp_out" >&2
        rm -f roms/vdpfifo.zip
        exit 0
    fi
    echo "$vdp_zip_sha256  roms/vdpfifo.zip" | sha256sum -c -
    unzip -qojd roms roms/vdpfifo.zip VDPFIFOTesting/VDPFIFOTesting.bin
    rm roms/vdpfifo.zip
fi
echo "$vdp_sha256  $vdp_out" | sha256sum -c -
