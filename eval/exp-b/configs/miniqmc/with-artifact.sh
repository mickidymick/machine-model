#!/bin/bash
###############################################################################
# miniQMC on Frontier (OLCF) -- build recipe + single run command
#
#   bash SOLUTION.sh build     # module loads + cmake + make
#   bash SOLUTION.sh run       # the srun line
#
# CONFIGURATION COMMITTED TO:
#   4 nodes x 4 MPI ranks/node x 14 OpenMP threads x 14 walkers/rank
#   = 16 ranks x 14 walkers = 224 walkers, exactly 1 walker per physical core.
#
# WHY (the short version; details at each decision below):
#   * This checkout is the CPU-ONLY miniQMC (src/README.md: "This is the CPU
#     only version ... OpenMP offload version is in the OMP_offload branch").
#     There is no GPU code path, so the 8 MI250X GCDs are irrelevant here and
#     the job is a pure CPU MPI+OpenMP job. Do not add --gpu-bind/--gpus-per-node.
#   * Frontier gives 56 allocatable cores/node (one core per L3 region is
#     OS-reserved: 0,8,16,24,32,40,48,56). 4 nodes x 56 = 224 = the fixed
#     walker count. So 1 walker per core is exactly achievable with 4 nodes,
#     and every core does exactly one walker's work -> perfect load balance.
#   * The 750 MB spline coefficient table is allocated and filled by each
#     rank's MASTER thread before any parallel region (miniqmc.cpp:362), and
#     is then SHARED read-only by every walker in that rank (einspline_spo.hpp
#     view constructor copies pointers, not data). Under Linux first-touch that
#     puts the whole table in ONE NUMA domain per rank. Therefore each rank
#     must live inside one NUMA domain, or most of its threads read the hottest
#     data remotely through a single memory controller. NPS4 + 56 usable cores
#     => 14 cores per NUMA domain => -c 14, 4 ranks/node. This is the geometry
#     the machine briefing independently verified ("-c 14 confines each rank to
#     one NUMA domain. Placement verified per rank.").
###############################################################################

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${HERE}/src"
BUILD_DIR="${HERE}/build"

# Set this (or SBATCH_ACCOUNT/SALLOC_ACCOUNT) only if you run `run` from a login
# node without an existing allocation. Inside an allocation it is ignored.
ACCOUNT="${ACCOUNT:-${SBATCH_ACCOUNT:-${SALLOC_ACCOUNT:-}}}"

###############################################################################
# modules -- identical for build and run.
#
# craype-hugepages2M MUST be loaded for the build: on Frontier it works by
# RELINKING the binary, not by a runtime flag, and THP is set to "never" with an
# empty hugetlb pool, so every other route to large pages fails silently. The
# hot data here is a 750 MB read-only spline table plus a ~19 MB inverse matrix
# per determinant per walker -- 4 KB pages blow past TLB reach on both. Keeping
# the module loaded at run time as well is what supplies HUGETLB_* to the
# relinked binary.
###############################################################################
load_modules() {
  module reset

  # PrgEnv-gnu, NOT the default PrgEnv-cray. This is a correctness issue, not a
  # taste one: CMakeLists.txt:226 tests CMAKE_CXX_COMPILER_ID against "Cray"
  # BEFORE "Clang", so CCE (which CMake reports as Cray/CrayClang) sets
  # COMPILER=Cray -- and there is no CrayCompilers.cmake in the include chain at
  # line 243-255. The build then falls through to a mere WARNING with
  # ENABLE_OPENMP=0, so -fopenmp is never added. Utilities/Configuration.h:41
  # quietly substitutes stub omp_* functions, every "#pragma omp parallel for"
  # over walkers is ignored, and every "#pragma omp simd" in the spline kernels
  # (Numerics/Spline2/MultiBspline.hpp) is dropped. You get a serial,
  # unvectorised binary that runs and prints a perfectly normal timer table.
  # PrgEnv-gnu reports "GNU", picks up CMake/GNUCompilers.cmake, and gets
  # -fopenmp plus -ffast-math -funroll-all-loops -finline-limit=1000.
  module load PrgEnv-gnu
  module load craype-x86-trento   # Zen3 target for the CC wrapper
  module load cray-libsci         # BLAS/LAPACK, auto-linked by CC
  module load craype-hugepages2M
  module load cmake

  # CMakeLists.txt:195 warns if this is unset; dynamic linking keeps library
  # resolution simple and is the default the project expects.
  export CRAYPE_LINK_TYPE=dynamic
}

###############################################################################
build() {
  load_modules

  # Start clean. A CMakeCache from a different PrgEnv is the classic failure
  # here, and CMakeLists.txt:210 tells you to empty the build folder anyway.
  rm -rf "${BUILD_DIR}"
  mkdir -p "${BUILD_DIR}"

  cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
    -DCMAKE_SYSTEM_NAME=CrayLinuxEnvironment \
    -DCMAKE_CXX_COMPILER=CC \
    -DCMAKE_C_COMPILER=cc \
    -DCMAKE_BUILD_TYPE=Release \
    -DQMC_MPI=1 \
    -DQMC_OMP=1 \
    -DENABLE_TIMERS=1 \
    -DBLA_VENDOR=All \
    -DCMAKE_CXX_FLAGS="-march=znver3 -mtune=znver3"

  # Notes on the cmake line:
  #
  # -DCMAKE_SYSTEM_NAME=CrayLinuxEnvironment, -DQMC_MPI=1
  #     Both mandated by PROBLEM.md. Side effect worth knowing: setting
  #     CMAKE_SYSTEM_NAME makes CMAKE_CROSSCOMPILING TRUE, which suppresses
  #     MPI_DETERMINE_LIBRARY_VERSION (CMakeLists.txt:285) and leaves
  #     MPI_CXX_LIBRARY_VERSION_STRING empty. The unquoted IF() at line 294 that
  #     then dereferences it is harmless -- verified against cmake 3.18, it
  #     evaluates false rather than erroring.
  #
  # -DCMAKE_CXX_FLAGS="-march=znver3 -mtune=znver3"
  #     This is the single biggest codegen lever and it is NOT applied for you.
  #     CMake/GNUCompilers.cmake:36 explicitly skips -march on Cray machines
  #     ("It's a cray machine. Don't do anything"), delegating the target to the
  #     craype-x86-* module. That delegation is correct when craype-x86-trento is
  #     loaded, but it is silent when it isn't -- and the fallback is generic
  #     x86-64, i.e. SSE2, no FMA, on kernels that are explicitly
  #     "#pragma omp simd" over 1536 splines. Passing it explicitly makes AVX2+FMA
  #     unconditional. EPYC 7A53 "Trento" is Zen3, so znver3 is the right target;
  #     it agrees with what craype-x86-trento sets, so there is no conflict.
  #
  # -DENABLE_TIMERS=1
  #     Left ON deliberately. Setting it to 0 would compile out NewTimer::start
  #     and stop entirely (NewTimer.h:348) and would be marginally faster -- but
  #     TimerManager.print() would then report 0.0 for every row including
  #     Total, which is the number you asked for. Not a real option.
  #
  # -DBLA_VENDOR=All
  #     Skips the pointless Intel-MKL probe (CMakeLists.txt:365) and goes
  #     straight to the vendor-agnostic search, whose first attempt is the
  #     implicitly-linked case -- which is exactly right on Cray, where the CC
  #     wrapper links libsci for you. Sanity check below.
  #
  # QMC_MIXED_PRECISION is left at its default 0 (double). Turning it on would
  # halve the spline table and double the SIMD width -- easily the largest single
  # speedup available -- but it changes the numerics of the QMC, not the
  # configuration of the machine, so it is not the same computation. Flagging it
  # rather than taking it.

  # Build only the miniqmc target: the other three drivers and the catch2 unit
  # tests are always added to the default target and are not needed.
  make -C "${BUILD_DIR}" -j 16 miniqmc

  echo
  echo "=== verify before you trust the run ==="
  echo "These three lines must be right; all three fail SILENTLY if they aren't:"
  grep -E "ENABLE_OPENMP|HAVE_MPI" "${BUILD_DIR}/src/config.h" || true
  echo "  ^ expect: #define ENABLE_OPENMP 1   and   #define HAVE_MPI 1"
  echo "Binary: ${BUILD_DIR}/bin/miniqmc"
  ls -l "${BUILD_DIR}/bin/miniqmc"
}

###############################################################################
run() {
  load_modules

  # --- OpenMP ---------------------------------------------------------------
  export OMP_NUM_THREADS=14          # = walkers per rank = cores per NUMA domain
  export OMP_PLACES=cores
  export OMP_PROC_BIND=close
  # Pinning is load-bearing, not hygiene. Walker iw is built by thread iw in the
  # init loop (miniqmc.cpp:379) and worked on by thread iw in the MC loop
  # (line 408) -- two separate parallel regions relying on static scheduling
  # being consistent. Each walker's ~38 MB of inverse matrices is first-touched
  # by its owning thread. Let threads migrate between the two regions and that
  # locality is lost.

  export OMP_MAX_ACTIVE_LEVELS=1
  export OMP_NESTED=false
  # Also load-bearing. DelayedUpdate.h:176 calls getNextLevelNumThreads() and,
  # if it comes back > 1 while MKL is absent (it is -- BlasThreadingEnv is a
  # no-op without MKL, so NestedThreadingSupported() is false), takes a branch
  # that opens its OWN "#pragma omp parallel" inside the per-walker region. With
  # every core already running a walker that is a 14x oversubscription on the
  # hottest GEMM in the code. Forcing one active level makes it return 1 and
  # take the serial-BLAS path, which is what we want.

  export OMP_WAIT_POLICY=passive     # only 5 barriers all run; don't spin
  export OMP_STACKSIZE=32M           # cheap insurance, a segfault costs the run

  # Deliberately NOT setting --mem-bind / numactl -m. First-touch plus a rank
  # confined to one NUMA domain already places the pages locally, and the
  # machine briefing records that the craype-hugepages allocator ABORTS under an
  # explicit memory bind because the module provisions only the local pool. The
  # marginal gain is not worth an abort mode.

  # --- launch ---------------------------------------------------------------
  # -N 4 -n 16 --ntasks-per-node=4 : 4 ranks/node, one per NUMA domain.
  # --cpus-per-task=14             : 14 allocatable cores per NUMA domain
  #                                  (56 allocatable / 4). Slurm's block order
  #                                  over the allocatable set lands rank 0 on
  #                                  cores 1-7,9-15 (NUMA 0), rank 1 on
  #                                  17-23,25-31 (NUMA 1), rank 2 on
  #                                  33-39,41-47 (NUMA 2), rank 3 on
  #                                  49-55,57-63 (NUMA 3) -- one domain each.
  # --threads-per-core=1           : no SMT. There are exactly 224 walkers and
  #                                  224 cores, so a second hardware thread per
  #                                  core would have no walker to run; this also
  #                                  removes any ambiguity about whether -c
  #                                  counts cores or hardware threads.
  # -m block:block                 : make the task->core mapping explicit rather
  #                                  than relying on the default.
  #
  # No MPI tuning of any kind: miniqmc.cpp calls MPI only for size()/root().
  # There is not a single communication call inside the timed region, so NIC
  # policy, message sizes and the whole Slingshot story are irrelevant here.
  local SRUN_ALLOC=()
  if [[ -z "${SLURM_JOB_ID:-}" ]]; then
    echo "No Slurm allocation detected; requesting one (4 nodes, 10 min)." >&2
    echo "10 min x 4 nodes = 40 node-minutes, inside the 60 node-minute budget." >&2
    if [[ -z "${ACCOUNT}" ]]; then
      echo "ERROR: set ACCOUNT=<your project id> (or run inside salloc/sbatch):" >&2
      echo "  salloc -A <project> -N 4 -t 10 -p batch" >&2
      exit 2
    fi
    SRUN_ALLOC=(-A "${ACCOUNT}" -p batch -t 10)
  fi

  cd "${HERE}"
  srun ${SRUN_ALLOC[@]+"${SRUN_ALLOC[@]}"} \
    -N 4 -n 16 --ntasks-per-node=4 \
    --cpus-per-task=14 --threads-per-core=1 \
    --cpu-bind=threads -m block:block \
    "${BUILD_DIR}/bin/miniqmc" -g "2 2 2" -n 5 -w 14 -t coarse

  # -g "2 2 2" -n 5 : fixed by PROBLEM.md. 3072 electrons, 1536 orbitals.
  # -w 14           : 16 ranks x 14 = 224 walkers exactly, as required, and
  #                   equal to OMP_NUM_THREADS so the static-scheduled loop
  #                   gives every thread exactly one walker.
  # -t coarse       : drops the fine-grained timers only. Every row you asked
  #                   about still prints -- Total, Setup, Diffusion,
  #                   Pseudopotential and the rest are all registered at coarse
  #                   level (miniqmc.cpp:312). What it removes is the per-
  #                   electron instrumentation inside the wavefunction
  #                   components (Determinant::ratio, Single-Particle Orbitals,
  #                   the Jastrow timers), whose start/stop does two std::map
  #                   lookups on the master thread of every rank
  #                   (NewTimer.h:415) and so sits directly on the critical path
  #                   at the end-of-step barrier. Worth a couple of percent.
  #                   Drop this flag if you want the full timer breakdown and
  #                   would rather pay for it.
}

###############################################################################
# Reading the result: the "Total" row is rank 0's own wall time and it INCLUDES
# Initialization (Timer_Total starts at miniqmc.cpp:374, before the init loop
# that inverts two 1536x1536 matrices per walker). "Setup" -- building the
# 750 MB spline table -- is outside Total, as you said. All 16 ranks do
# identical work and never synchronise, so rank 0's Total is representative.
# Expect the run itself to be on the order of a minute or two.
###############################################################################

case "${1:-}" in
  build) build ;;
  run)   run ;;
  *)     echo "usage: bash $(basename "${BASH_SOURCE[0]}") {build|run}" >&2; exit 2 ;;
esac
