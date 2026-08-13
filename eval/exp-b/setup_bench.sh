#!/bin/bash
# Fetch benchmark source into pristine-*/ at a PINNED commit.
#
#   ./eval/exp-b/setup_bench.sh miniqmc
#
# The source is deliberately NOT committed to this repo. Vendoring it created
# nested .git directories that git cannot track, and it would have put ~100 MB
# of third-party code in a repo whose actual content is the harness. Pinning the
# commit does the real job the vendoring was meant to do: every arm, on every
# machine, on every rerun, builds byte-identical source, and the paper can name
# the exact revision.
#
# build_all.sh copies pristine-*/ into each arm tree before every build, so this
# runs once per machine.
set -eu
D=$(cd "$(dirname "$0")" && pwd)
BENCH=${1:-miniqmc}

case "$BENCH" in
  miniqmc)
    URL=https://github.com/QMCPACK/miniqmc.git
    # Pinned 2026-08-13. develop @ "Merge pull request #269 from ye-luo/update-catch2".
    PIN=5ed650c8c390884d6a84f002be2bbfa103b7df3e
    DEST="$D/pristine-miniqmc"
    ;;
  *) echo "unknown benchmark: $BENCH" >&2; exit 1 ;;
esac

if [ -d "$DEST" ]; then
  have=$(git -C "$DEST" rev-parse HEAD 2>/dev/null || echo none)
  if [ "$have" = "$PIN" ]; then
    echo "$BENCH already at pinned commit $PIN"; exit 0
  fi
  echo "$DEST is at $have, not the pin -- replacing"
  rm -rf "$DEST"
fi

echo "cloning $BENCH ..."
git clone --quiet "$URL" "$DEST"
git -C "$DEST" checkout --quiet "$PIN"

got=$(git -C "$DEST" rev-parse HEAD)
[ "$got" = "$PIN" ] || { echo "PIN MISMATCH: got $got, wanted $PIN" >&2; exit 1; }

# .git must stay: miniQMC's CMake generates git-rev.h from it, and the build
# fails outright without it. Found the hard way.
echo "$BENCH pinned at $got"
echo "stray build objects (must be 0): $(find "$DEST" -name '*.o' | wc -l)"
