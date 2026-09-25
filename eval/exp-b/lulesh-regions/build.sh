#!/bin/bash
# Build LULESH with per-phase PAPI counters. Login node, once, with papi loaded:
#
#   module load papi && ./eval/exp-b/lulesh-regions/build.sh
#
# -> eval/exp-b/bin/lulesh-regions-omp   (and -mpi, the no-OpenMP variant)
#
# GROUND-TRUTH INSTRUMENT ONLY -- see regions.h. The patch is applied to a temp
# copy of pristine-lulesh; the pristine tree the arms receive is never touched.
#
# Same compiler, flags and environment as build_spread.sh, so the instrumented
# binary differs from lulesh-omp by the markers alone. Do NOT unload rocm here
# just because it links HIP: lulesh-omp was built with it loaded, and matching
# that matters more than a clean link (the HIP runtime is never called).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
EXPB=$(dirname "$HERE")
SRC="$EXPB/pristine-lulesh"
OUT="$EXPB/bin"

[ -d "$SRC" ] || { echo "no source at $SRC -- run setup_bench.sh lulesh first" >&2; exit 1; }
mkdir -p "$OUT"

CXX_BASE="${RG_CXX:-CC} -DUSE_MPI=${RG_USE_MPI:-1}"
# Frontier's papi module sets no PAPI_DIR: the Cray CC wrapper adds PAPI's
# include and lib paths itself once the module is loaded, so plain -lpapi is
# right there (frontier/Makefile relies on the same thing). An explicit
# PAPI_DIR/PAPI_ROOT, e.g. a manual install, is honoured when set.
PAPI_DIR=${PAPI_DIR:-${PAPI_ROOT:-}}
if [ -n "$PAPI_DIR" ]; then
  PAPI_FLAGS="-I$PAPI_DIR/include"
  PAPI_LIBS="-L$PAPI_DIR/lib -Wl,-rpath,$PAPI_DIR/lib -lpapi"
else
  PAPI_FLAGS=""
  PAPI_LIBS="-lpapi"
fi

build() {
  variant=$1; extra=$2
  tree=$(mktemp -d "${TMPDIR:-/tmp}/lulesh-regions-${variant}.XXXXXX")
  cp "$SRC"/*.cc "$SRC"/*.h "$SRC"/Makefile "$tree/"
  cp "$HERE/regions.h" "$tree/"
  ( cd "$tree"
    patch -p1 --quiet < "$HERE/lulesh-regions.patch"
    # A patch that half-applied would leave a binary that runs and reports a
    # subset of regions. Refuse it: 16 markers is the count the patch carries.
    n=$(grep -c 'rg_mark(\|rg_init()\|rg_finish(' lulesh.cc)
    [ "$n" -eq 16 ] || { echo "patch applied $n of 16 markers" >&2; exit 1; }
    make -B \
      CXX="$CXX_BASE" \
      CXXFLAGS="-g -O3 $extra -I. -Wall $PAPI_FLAGS" \
      LDFLAGS="-g -O3 $extra $PAPI_LIBS" \
      >"$OUT/build_regions_${variant}.log" 2>&1
  ) || { echo "BUILD FAILED ($variant) -- tail of $OUT/build_regions_${variant}.log:" >&2
         tail -5 "$OUT/build_regions_${variant}.log" >&2
         echo "(papi.h or -lpapi not found usually means: module load papi)" >&2; exit 1; }
  cp "$tree/lulesh2.0" "$OUT/lulesh-regions-$variant"
  rm -rf "$tree"
  echo "built $OUT/lulesh-regions-$variant"
}

build omp "-fopenmp"
build mpi "-Wno-unknown-pragmas"   # the omp pragmas in regions.h compile away
