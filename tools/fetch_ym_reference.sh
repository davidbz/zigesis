#!/bin/sh
# Fetches Nuked-OPN2, the die-shot-accurate YM3438 reference, into
# testdata/nuked-opn2/ (gitignored). It is LGPL-2.1 and used only by
# test/ym_nuked_test.zig, which build.zig skips entirely when the directory is
# absent. https://github.com/nukeykt/Nuked-OPN2
#
# Pinned to a commit, and each file checksummed: the differential test asserts
# bit-exact agreement, so a reference that moves underneath it would look like
# a regression here.
set -eu
cd "$(dirname "$0")/.."

rev=335747d78cb0abbc3b55b004e62dad9763140115
base=https://raw.githubusercontent.com/nukeykt/Nuked-OPN2/$rev
out=testdata/nuked-opn2

mkdir -p "$out"
for f in \
    "8fa385546f0f2d1c975d097002af00cd729ae2ae097c068e9c883ce08ddf3a76 ym3438.c" \
    "8e60e35f77049d0e600ad1a47bfc3dfc8b832483e614104473a83c1f33cd7189 ym3438.h" \
    "20c17d8b8c48a600800dfd14f95d5cb9ff47066a9641ddeab48dc54aec96e331 LICENSE"
do
    sha256=${f% *}
    name=${f#* }
    [ -f "$out/$name" ] || curl -fsSL -o "$out/$name" "$base/$name"
    echo "$sha256  $out/$name" | sha256sum -c -
done

echo "run: zig build ym-nuked"
