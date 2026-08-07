#!/bin/sh
# Fetches the freely distributable test ROM used by test/system_test.zig
# into roms/ (gitignored). Pinned to a release tag so the bytes, and the
# frame hashes pinned in the test, never change.
#
# Cave Story MD: open-source Genesis port of Cave Story (MIT-style, freely
# distributable). https://github.com/andwn/cave-story-md
set -eu
cd "$(dirname "$0")/.."

url=https://github.com/andwn/cave-story-md/releases/download/v0.8.8/doukutsu-en.gen
sha256=053ed9009b47512972d7fd0954f3c251774422be8be6eb8df90f39fe22b50061
out=roms/doukutsu-en.gen

mkdir -p roms
[ -f "$out" ] || curl -fsSL -o "$out" "$url"
echo "$sha256  $out" | sha256sum -c -
