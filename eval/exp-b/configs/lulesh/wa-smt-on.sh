#!/bin/bash
# DECOMPOSITION CONFIG -- NOT AN ARM. Do not report as a result.
#
# with-artifact.sh with ONE change: SMT ON (8 ranks x 14 threads = 112 hardware
# threads, against the arm's 8 x 7 = 56).
#
# WHY: the with-artifact arm turned SMT off citing cpu.smt_benefit -- it
# classified LULESH as the bandwidth-saturated regime that LOSES 5%. This tests
# whether that classification was right. If this config is much faster than the
# arm, our own SMT claim was MISAPPLIED to this workload, which is a
# claim-quality failure needing a sharper measured_under -- a completely
# different problem from the attention failure, and needing a different fix.
# =============================================================================
# LULESH 2.0 on Frontier (OLCF) -- 1 node, 8 x 45^3 = 729,000 elements, 500 cycles
#
#   bash SOLUTION.sh build     # module loads + compile
#   bash SOLUTION.sh run       # the single srun line (needs an allocation:
#                              #   salloc -A <proj> -N 1 -t 20 -p batch
#                              # or run it from inside a batch script)
#
# CONFIGURATION CHOSEN, AND WHY (see MACHINE.md references in each note):
#
#   8 MPI ranks x 7 OpenMP threads = 56 cores, -s 45 -i 500.
#
#   * Why 8 ranks and not 1 rank x 56 threads (the other legal cube <= 56 cores):
#     LULESH initialises every array SERIALLY (lulesh-init.cc: the Domain ctor
#     loops are plain for-loops; only SetupThreadSupportStructures is thread
#     aware).  With first-touch placement that means one rank's entire ~80 MB
#     working set is pinned to the NUMA domain of the initialising thread.
#     Frontier is NPS4 and MACHINE.md measures ~44.5 GB/s per domain
#     (numa.distance_matrix local 44582 MB/s; loaded_latency_knee peak 44521
#     MB/s from 27 threads on domain 0).  A 1-rank/56-thread job would drive all
#     56 threads against ONE domain's controllers -- ~25% of the node's memory
#     bandwidth -- for a code that is dominated by streaming through element and
#     node arrays.  8 ranks put 2 ranks in each of the 4 NUMA domains, so every
#     rank first-touches its own domain and all four controllers are used.
#
#   * Why 7 threads/rank: 56 usable cores, not 64.  One core per L3 group is
#     OS-reserved (MACHINE.md cpu.core_inventory: reserved 0,8,16,24,32,40,48,56;
#     `-c 56` is the ceiling and anything higher is rejected).  That leaves 7
#     usable cores in each of the 8 L3/CCD groups, so `-n 8 -c 7` lands exactly
#     one rank per L3 region -- each rank's 7 threads share one 32 MB L3 and one
#     NUMA domain, with zero straddling.  This is also the binding MACHINE.md's
#     own collective_scaling runs used (-c 7 --threads-per-core=2 --cpu-bind=threads).
#     27 ranks (-s 30) is the other legal cube but 27 does not divide 8 CCDs or
#     4 NUMA domains: ranks would straddle L3/NUMA boundaries, 2 cores would idle,
#     and the halo surface-to-volume ratio rises.  8 is the clean choice.
#
#   * Why --threads-per-core=1 (SMT OFF, 56 threads not 112):
#     MACHINE.md cpu.smt_benefit is regime-dependent: latency-bound kernels gain
#     +70-78%, the BANDWIDTH-SATURATED stream kernel loses 5.0%.  LULESH sweeps
#     element and node arrays contiguously with regular stencil neighbours (a
#     ~700 MB node-wide footprint including the numElem*8 hourglass temporaries),
#     i.e. throughput-bound streaming, which is the arm that LOSES.  Committing
#     to SMT off.
#
#   * Why NOT craype-hugepages2M:
#     MACHINE.md cost.page_size_penalty exists only where BOTH hold: working set
#     past TLB reach AND an access pattern that defeats prefetch (dependent
#     random).  LULESH's sweeps are contiguous and prefetchable, so the mechanism
#     is absent -- and the doc records a measured case of exactly this mistake:
#     an agent matched a streaming kernel to that curve, enabled huge pages, and
#     paid 2.7% (p=3e-10).  The penalty inverted outside its regime.  Left off.
#
#   * Why PrgEnv-gnu:
#     MACHINE.md pitfall prgenv-cray-drops-openmp -- the default PrgEnv-cray
#     identifies as "CrayClang" and can be silently dropped by build systems that
#     then set no -fopenmp at all, costing a factor of the thread count with a
#     clean-looking build.  We also drive the Makefile directly rather than CMake
#     (the shipped CMakeLists asks for cmake_minimum_required(VERSION 3.0), which
#     modern CMake rejects, and CMake on Cray then needs the
#     CMAKE_SYSTEM_NAME=CrayLinuxEnvironment workaround).  build() verifies
#     libgomp is actually linked instead of trusting a clean compile.
#
#   * No -ffast-math: it would change floating-point semantics of the physics.
#     -fno-math-errno is used instead -- it lets sqrt/fabs vectorise without
#     altering any result.
#
#   * I/O: none.  Nothing is written to /tmp (MACHINE.md: /tmp is RAM here), and
#     no -v/viz.  Storage tiers are irrelevant to this run.
# =============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src"
EXE="$SRC/lulesh2.0"

# Fixed problem: 8 ranks x 45^3 = 729,000 elements, 500 cycles.
RANKS=8
SIZE=45
ITERS=500
THREADS=14         # DECOMPOSITION: 8 ranks x 14 = 112 HW threads (SMT ON)

load_modules() {
  # `bash SOLUTION.sh ...` is non-interactive, so Lmod may not be initialised.
  if ! type module >/dev/null 2>&1; then
    for f in /etc/profile.d/lmod.sh /etc/profile.d/z00_lmod.sh \
             /usr/share/lmod/lmod/init/bash; do
      [ -r "$f" ] && . "$f" && break
    done
  fi
  module load PrgEnv-gnu
  module load craype-x86-trento          # Frontier compute node: EPYC 7A53 (Zen3)
  module load cray-mpich
  # Deliberately NOT loaded (see header): craype-hugepages2M.  Unload it if the
  # calling environment brought it in, since it takes effect by relinking.
  module unload craype-hugepages2M 2>/dev/null || true
  module list 2>&1 || true
}

build() {
  load_modules

  # Trento is Zen3.  Fall back if the module's gcc predates -march=znver3.
  local ARCH="-march=znver3 -mtune=znver3"
  if ! CC $ARCH -x c++ -c /dev/null -o /dev/null 2>/dev/null; then
    echo "NOTE: -march=znver3 unsupported by this compiler; using -march=native"
    ARCH="-march=native"
  fi

  local CXXFLAGS="-O3 $ARCH -fopenmp -fno-math-errno -funroll-loops -DNDEBUG -I."
  local LDFLAGS="-O3 -fopenmp"

  cd "$SRC"
  make clean || true
  make -j5 CXX="CC -DUSE_MPI=1" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS"

  # Do not trust a clean build: confirm OpenMP really got linked in.
  if ldd "$EXE" | grep -q libgomp; then
    echo "OK: OpenMP (libgomp) linked."
  else
    echo "ERROR: libgomp not linked -- the binary would run single-threaded." >&2
    exit 1
  fi
  echo "Built $EXE"
}

run() {
  load_modules

  export OMP_NUM_THREADS=$THREADS
  export OMP_PLACES=threads              # DECOMPOSITION: SMT on
  export OMP_PROC_BIND=close             # keep a rank's threads on its own L3/CCD
  export OMP_WAIT_POLICY=ACTIVE          # ~40 parallel regions x 500 cycles: keep
                                         # workers spinning, one thread per core so
                                         # there is nothing to oversubscribe
  export OMP_STACKSIZE=32M

  srun -N 1 -n $RANKS -c $THREADS --threads-per-core=2 --cpu-bind=threads \
       "$EXE" -s $SIZE -i $ITERS
  # -> reports "Elapsed time" and "Grind time (us/z/c)" from rank 0.
}

case "${1:-}" in
  build) build ;;
  run)   run ;;
  *) echo "usage: bash $(basename "$0") {build|run}" >&2; exit 2 ;;
esac
