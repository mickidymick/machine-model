#!/bin/bash
# Build the two LULESH binaries the spread probe needs. Login node, once.
#
#   ./eval/exp-b/build_spread.sh
#
# TWO binaries, because LULESH's force summation is a COMPILE-time choice as
# much as a runtime one. Built with -fopenmp and run at more than one thread,
# IntegrateStressForElems (lulesh.cc:514) and CalcFBHourglassForceForElems
# (lulesh.cc:736) allocate fx/fy/fz_elem at 8*numElem doubles each and gather
# through nodeElemCornerList -- ~192 B per element per array, on top of a
# ~2 KB/element/cycle baseline. Built WITHOUT it, that path does not exist.
#
# So "MPI-only" has to mean a binary compiled without OpenMP, not merely
# OMP_NUM_THREADS=1. Comparing the two is half of what the probe is for.
set -eu

D=$(cd "$(dirname "$0")" && pwd)
SRC="$D/pristine-lulesh"
OUT="$D/bin"

[ -d "$SRC" ] || { echo "no source at $SRC -- run setup_bench.sh lulesh first" >&2; exit 1; }
mkdir -p "$OUT"

source /usr/share/lmod/lmod/init/bash 2>/dev/null || true

# The Cray wrapper is the MPI compiler here; -DUSE_MPI=1 is LULESH's own switch.
CXX_BASE="CC -DUSE_MPI=1"

build() {
  variant=$1; extra=$2
  tree=$(mktemp -d "${TMPDIR:-/tmp}/lulesh-${variant}.XXXXXX")
  cp "$SRC"/*.cc "$SRC"/*.h "$SRC"/Makefile "$tree/"
  ( cd "$tree"
    make -B \
      CXX="$CXX_BASE" \
      CXXFLAGS="-g -O3 $extra -I. -Wall" \
      LDFLAGS="-g -O3 $extra" \
      >"$OUT/build_${variant}.log" 2>&1
  ) || { echo "BUILD FAILED ($variant) -- see $OUT/build_${variant}.log" >&2; exit 1; }
  cp "$tree/lulesh2.0" "$OUT/lulesh-$variant"
  rm -rf "$tree"
  echo "built $OUT/lulesh-$variant"
}

build mpi ""
build omp "-fopenmp"

# Verify the distinction actually took. A silent fallback to one binary built
# twice would make the whole probe measure nothing -- and it would look fine.
if cmp -s "$OUT/lulesh-mpi" "$OUT/lulesh-omp"; then
  echo "FAIL: the two binaries are byte-identical. -fopenmp did not take." >&2
  exit 1
fi
if ! nm -C "$OUT/lulesh-omp" 2>/dev/null | grep -qi 'omp_\|GOMP\|__kmpc'; then
  echo "FAIL: lulesh-omp has no OpenMP runtime symbols." >&2
  exit 1
fi
if nm -C "$OUT/lulesh-mpi" 2>/dev/null | grep -qi 'GOMP_parallel\|__kmpc_fork'; then
  echo "FAIL: lulesh-mpi contains OpenMP fork symbols; it was built threaded." >&2
  exit 1
fi

echo
echo "OK -- two distinct binaries in $OUT"
