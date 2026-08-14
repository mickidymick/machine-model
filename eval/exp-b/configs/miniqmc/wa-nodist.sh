#!/bin/bash
# DECOMPOSITION CONFIG -- NOT AN ARM. Do not report as a result.
#
# with-artifact.sh with EXACTLY ONE change, to attribute the -0.86 s
# residual that huge pages did not explain.
#
# CHANGED: drop --distribution=block:block, matching no-artifact's default
# =============================================================================
# miniQMC on Frontier (OLCF) -- 1 node, fixed problem, fastest configuration
#
#   bash SOLUTION.sh build     # module loads + cmake + make
#   bash SOLUTION.sh run       # the single srun line (inside a 1-node allocation)
#
# Fixed problem (unchanged): -g "2 2 2" (3072 electrons), -n 5,
#                            total walkers = ranks * w = 8 * 7 = 56.
#
# THE CONFIGURATION, IN ONE LINE:
#   8 MPI ranks x 7 OpenMP threads x 7 walkers, one rank per L3 group (CCD),
#   built with PrgEnv-gnu + 2M huge pages.
#
# WHY (the reasoning that picks this over every other 56-walker geometry):
#
#  * This is a memory-bound gather, not a flop-bound kernel.  Each SPO
#    evaluation reads a 4x4x4 stencil for all 1536 orbitals ~= 780 KB pulled
#    from a random offset in a 750 MB spline table (1536 orbitals * 40^3 grid *
#    8 B).  The ECP loop alone does ~3e4 such evaluations per walker per step.
#    DRAM traffic, not arithmetic, sets the run time.
#
#  * The spline table is shared read-only by all threads of a rank, and it is
#    first-touched by that rank's master thread inside build_SPOSet()
#    (miniqmc.cpp, before the first parallel region).  So the table lands on
#    ONE NUMA domain per rank.  That single fact decides the geometry:
#      - 1 rank x 56 threads: all 56 threads pull the whole table through one
#        memory controller.  Measured local bandwidth is ~44.6 GB/s per domain
#        (MACHINE.md numa.distance_matrix), so this caps the node at ~1/4 of
#        the ~178 GB/s it can actually deliver.  It is the natural-looking
#        launch and it is the slow one.
#      - >=1 rank per NUMA domain: every rank owns a local copy, all four
#        memory controllers work, and no read crosses the fabric.  The 4x here
#        dwarfs the 3.5-11% near/mid/far penalties in the distance matrix.
#    Note the ACPI SLIT on this machine says all four domains are equidistant
#    (10/12/12/12); measurement says otherwise (near 108 ns, far 120 ns).  We
#    do not depend on the tiering -- we simply never cross a domain.
#
#  * 8 ranks x 7, rather than 4 ranks x 14: one core per L3 group is
#    OS-reserved on Frontier (cores 0,8,16,24,32,40,48,56 -- hwloc reports 112
#    allowed PUs of 128, and `srun -c 64` is rejected).  That leaves exactly 7
#    usable cores per L3 group / CCD and exactly 8 CCDs, so 8x7 is the unique
#    geometry in which a rank is confined to a single L3 *and* a single NUMA
#    domain, with no core left idle and no walker imbalance (56 = 8*7, one
#    walker per thread -- the driver loop is `#pragma omp parallel for` over
#    walkers, so threads != walkers just idles cores).  4x14 is the runner-up:
#    also NUMA-local, half the spline replication (3 GB vs 6 GB, irrelevant
#    against 512 GB), but each rank then straddles two L3s and each per-step
#    barrier waits on the slowest of 14 walkers instead of 7.
#
#  * No SMT.  112 hardware threads exist, but the work is 56 walkers and one
#    `omp parallel for` iteration per walker; extra threads take zero
#    iterations.  1 thread per core, 56 threads total.
#
#  * No GPU.  This source tree is the CPU-only miniQMC -- there is no offload
#    path in the CMakeLists or in einspline_spo/DiracDeterminant (the only
#    ENABLE_CUDA code is a delayed-update class that this build never
#    instantiates).  The 8 MI250X GCDs cannot be used without porting.
#
#  * craype-hugepages2M.  THP is `never` and the hugetlb pool is empty on this
#    machine, so a madvise/THP request silently gives 4K pages; the module is
#    the working path and it works by RELINKING, which is why it must be loaded
#    for the build and not just the run.  The payoff is exactly where this code
#    lives: the 4K penalty peaks at 2.4x for a ~32 MB working set (the 1536^2
#    determinant matrices are 19 MB) and settles to a +9-14 ns offset from
#    64 MB-1 GB (the 750 MB spline table).  If the pool cannot satisfy the
#    request the allocator falls back to 4K pages -- no worse than not asking.
#    We never use `numactl -m`, which is the one thing that aborts once linked.
#
# Deliberately NOT done, and why:
#   -DQMC_MIXED_PRECISION=1  would halve spline traffic and double SIMD width
#     -- almost certainly the single biggest win available -- but it changes
#     the arithmetic of a benchmark whose problem is meant to be fixed.  Not
#     taken; say the word if float splines are acceptable.
#   -a <tile_size> / -k <delay_rank>  re-block the spline table and switch the
#     determinant update between BLAS2/BLAS3.  Both are real tuning knobs, both
#     are unverifiable without running on the machine, and a bad guess changes
#     the flop mix.  Defaults kept (1 tile, delay rank 32).
# =============================================================================

set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${ROOT}/src"                 # miniQMC top-level CMakeLists lives here
BUILD="${ROOT}/build"
EXE="${BUILD}/bin/miniqmc"

# ---- geometry -------------------------------------------------------------
RANKS=8                           # one per L3 group / CCD
THREADS=7                         # the 7 non-reserved cores of that L3 group
WALKERS=7                         # 8 * 7 = 56 total walkers, one per thread
# ---------------------------------------------------------------------------

load_modules() {
  # `module` is not defined in a non-interactive shell on Frontier; init Lmod.
  if ! type module >/dev/null 2>&1; then
    for f in /usr/share/lmod/lmod/init/bash \
             /opt/cray/pe/lmod/lmod/init/bash \
             /etc/profile.d/lmod.sh \
             /etc/profile.d/z00_lmod.sh; do
      if [ -r "$f" ]; then . "$f"; break; fi
    done
  fi
  type module >/dev/null 2>&1 || { echo "ERROR: Lmod not initialised; source your module init and retry."; exit 1; }

  module reset                    # deterministic starting point
  module load PrgEnv-gnu          # GCC + cray-mpich + cray-libsci via cc/CC
  module load craype-x86-trento   # correct CPU target for the compute nodes
  module load craype-hugepages2M  # relinks for 2M pages; needed at build AND run
  module -t list 2>&1 | sort | tr '\n' ' '; echo
}

build() {
  load_modules
  module load cmake

  # The CMakeLists warns (and Cray defaults to static) without this.
  export CRAYPE_LINK_TYPE=dynamic

  # BLAS/LAPACK: the CC wrapper links cray-libsci implicitly, but
  # find_package(LAPACK REQUIRED) has no way to see that, so point it at the
  # library explicitly.  Deliberately the SERIAL libsci (no _mp suffix):
  # every BLAS/LAPACK call in miniQMC happens inside the per-walker OpenMP
  # region, so a threaded libsci would only oversubscribe.
  local libsci_args=()
  local libsci
  libsci="$(ls "${CRAY_LIBSCI_PREFIX_DIR:-/nonexistent}"/lib/libsci_gnu_*[0-9].so 2>/dev/null | head -1 || true)"
  if [ -n "$libsci" ]; then
    libsci_args=( -DBLAS_LIBRARIES="$libsci" -DLAPACK_LIBRARIES="$libsci" )
    echo "Using LAPACK/BLAS: $libsci"
  else
    echo "WARNING: cray-libsci not located under CRAY_LIBSCI_PREFIX_DIR;"
    echo "         letting CMake search for LAPACK on its own."
  fi

  rm -rf "$BUILD"
  cmake -S "$SRC" -B "$BUILD" \
    -DCMAKE_SYSTEM_NAME=CrayLinuxEnvironment \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=cc \
    -DCMAKE_CXX_COMPILER=CC \
    -DQMC_MPI=1 \
    -DQMC_OMP=1 \
    -DENABLE_TIMERS=1 \
    -DBUILD_UNIT_TESTS=0 \
    -DCMAKE_CXX_FLAGS="-march=znver3 -mtune=znver3" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    "${libsci_args[@]}"
  # notes on the flags above:
  #  - CrayLinuxEnvironment: without it FindMPI does not accept CC as an MPI
  #    compiler and configure fails outright.
  #  - QMC_MPI=1: OFF by default in this tree.  Without it srun -n8 is 8
  #    independent serial copies of the whole problem and nothing says so.
  #  - Release => -O3 -DNDEBUG -ffast-math -funroll-all-loops (GNUCompilers.cmake).
  #  - -march=znver3: on a Cray machine miniQMC's cmake deliberately adds no
  #    -march at all, leaving it to the wrapper.  EPYC 7A53 (Trento) and the
  #    login-node 7763 are both Zen3, so this is safe and not cross-compiling.
  #  - CMAKE_POLICY_VERSION_MINIMUM: harmless on older cmake, keeps cmake >= 4
  #    from rejecting `cmake_minimum_required(VERSION 3.6.0)`.

  cmake --build "$BUILD" --target miniqmc -j 16

  # Fail loudly rather than silently benchmarking 8 serial copies.
  grep -q "^#define HAVE_MPI 1" "${BUILD}/src/config.h" \
    || { echo "ERROR: HAVE_MPI is not 1 -- MPI did not get enabled."; exit 1; }
  grep -q "^#define ENABLE_OPENMP 1" "${BUILD}/src/config.h" \
    || { echo "ERROR: ENABLE_OPENMP is not 1 -- OpenMP did not get enabled."; exit 1; }
  test -x "$EXE" || { echo "ERROR: $EXE was not produced."; exit 1; }
  echo "Build OK: $EXE  (MPI + OpenMP + timers enabled)"
}

run() {
  load_modules                    # hugepages module must be active at run time too

  if [ -z "${SLURM_JOB_ID:-}" ]; then
    echo "ERROR: not inside a Slurm allocation.  Get one node first, e.g.:"
    echo "  salloc -A <PROJECT> -p batch -N 1 -t 00:30:00"
    echo "then re-run: bash SOLUTION.sh run"
    exit 1
  fi
  test -x "$EXE" || { echo "ERROR: $EXE missing -- run 'bash SOLUTION.sh build' first."; exit 1; }

  export OMP_NUM_THREADS=${THREADS}
  export OMP_PLACES=cores         # one thread per physical core, no SMT
  export OMP_PROC_BIND=close      # pin: first touch of each walker's ~tens of
                                  # MiB must stay on the core that allocated it
  export OMP_MAX_ACTIVE_LEVELS=1  # no nested teams if libsci_mp sneaks in
  export OMP_WAIT_POLICY=ACTIVE   # cores are exclusively ours; spin at barriers
  export HUGETLB_VERBOSE=0        # quiet the libhugetlbfs fallback chatter

  # -c 7 --threads-per-core=1 lands each rank on one L3 group: the job's cpuset
  # is the 56 non-reserved cores (cores 1-7, 9-15, ... 57-63), and 7 consecutive
  # allowed cores == exactly one CCD.  block:block keeps rank order tied to
  # NUMA order.  -t coarse switches off the fine per-kernel timers, whose
  # start/stop sits inside the hottest loops; the Total and Setup rows we
  # report are registered at coarse level and are unaffected.
  set -x
  srun -N 1 -n ${RANKS} --ntasks-per-node=${RANKS} \
       -c ${THREADS} --threads-per-core=1 \
       --cpu-bind=threads \
       "$EXE" -g "2 2 2" -n 5 -w ${WALKERS} -t coarse
  set +x

  echo
  echo "Sanity-check these lines in the output above:"
  echo "  MPI processes = ${RANKS}"
  echo "  OpenMP threads = ${THREADS}"
  echo "  Number of walkers per rank = ${WALKERS}   (${RANKS} x ${WALKERS} = 56 total)"
  echo "Report the 'Total' row of the timer table; 'Setup' is the separate"
  echo "spline-table build and is not included in Total."
}

case "${1:-}" in
  build) build ;;
  run)   run   ;;
  *)     echo "usage: bash $(basename "$0") {build|run}" >&2; exit 2 ;;
esac
