#!/usr/bin/env bash
# Fetch the SingleStepTests/z80 conformance data into testdata/z80/.
#
# The harness reads the upstream .json files directly, so no decode step is
# needed. Roughly 1.6 GB after clone; testdata/ is gitignored.
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -d testdata/z80/.git ]; then
    echo "updating testdata/z80/"
    git -C testdata/z80 pull --ff-only
else
    echo "cloning SingleStepTests/z80 into testdata/z80/ (this is large)"
    git clone --depth 1 https://github.com/SingleStepTests/z80.git testdata/z80
fi

echo "$(find testdata/z80/v1 -name '*.json' | wc -l) test files ready"
echo "run: zig build z80-sst"
