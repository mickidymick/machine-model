#!/bin/bash
# DECOMPOSITION CONFIG -- NOT AN ARM. Do not report this as a result.
#
# no-artifact.sh with ONE line added: `module load craype-hugepages2M`.
#
# The two arms converged on the same geometry (8 ranks x 7 threads x 7 walkers),
# the same -t coarse, the same -march=znver3 and the same compiler. They differ
# on huge pages, which is the mechanism this experiment pre-registered:
#   no-artifact  CONSIDERED AND REJECTED the module -- "this code is
#                bandwidth-bound, not TLB-latency-bound, so the payoff is
#                small", plus "I cannot verify the module exists from
#                off-machine and a failed module load would break the build".
#   with-artifact TOOK it, citing the measured 2.4x page-size penalty at a
#                ~32 MB working set against the 19 MB determinant matrices.
#
#   no-artifact  minus  no-artifact-hugepages  =  the huge-page effect alone
#
# If that difference accounts for the whole arm gap, the artifact's contribution
# on this benchmark is exactly one measured fact, and we can say so precisely
# rather than gesturing at a bundle of differences.
# =============================================================================
# miniQMC on Frontier (OLCF) -- 1 node, 56 walkers, -g "2 2 2", -n 5
#
#   bash SOLUTION.sh build     # module loads + cmake + make   (login node)
#   bash SOLUTION.sh run       # the single srun line          (inside an allocation)
#
# Allocation this expects (Frontier defaults are exactly right -- do NOT pass -S):
#
#   #SBATCH -N 1
#   #SBATCH -t 00:20:00
#   #SBATCH -A <project>
#   # core specialization stays at the Frontier default of -S 8
#
# CONFIGURATION CHOSEN: 8 MPI ranks x 7 OpenMP threads x 7 walkers/rank = 56 walkers
# Rationale is inline below at each decision point.
# =============================================================================

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"
BUILD_DIR="${SCRIPT_DIR}/build"
EXE="${BUILD_DIR}/bin/miniqmc"

# -----------------------------------------------------------------------------
# build()
# -----------------------------------------------------------------------------
build() {
  set -e

  # --- Programming environment --------------------------------------------
  # PrgEnv-gnu, not the Frontier default PrgEnv-cray. Two reasons:
  #
  #  1. Correctness of the build, not taste. This CMakeLists dispatches on
  #     CMAKE_CXX_COMPILER_ID and tests "Cray" BEFORE "Clang"
  #     (src/CMakeLists.txt:218-237). Modern CMake reports CCE as "CrayClang",
  #     which matches "Cray" first -> COMPILER=Cray -> no CMake/*Compilers.cmake
  #     file is included -> -fopenmp is NEVER added, and the whole benchmark
  #     silently builds single-threaded. Only a MESSAGE(WARNING) marks it.
  #     PrgEnv-gnu gives ID "GNU" -> CMake/GNUCompilers.cmake -> -fopenmp plus
  #     -O3 -ffast-math -funroll-all-loops -finline-limit=1000 -Drestrict=...
  #     PrgEnv-amd (ID "Clang") would also be safe; GCC is the more heavily
  #     tested path for CPU miniQMC/QMCPACK and I would rather not gamble on
  #     the compiler-ID string here.
  #
  #  2. cray-libsci comes with PrgEnv-gnu and the CC wrapper links it
  #     implicitly, which is what the LAPACK detection below relies on.
  module load PrgEnv-gnu

  # OLCF's cmake module; system cmake (>=3.20) also satisfies the project's
  # 3.6 minimum, so do not let a missing module abort the build.
  module load cmake 2>/dev/null || echo "NOTE: no cmake module; using $(command -v cmake)"

  # src/CMakeLists.txt:195 warns if this is unset. Dynamic linking keeps the
  # implicit-libsci link working and library search sane.
  export CRAYPE_LINK_TYPE=dynamic

  # ADDED BY THE DECOMPOSITION CONFIG -- the only change from no-artifact.sh.
  module load craype-hugepages2M

  # Considered and rejected: craype-hugepages2M. The hot kernel streams 64
  # contiguous ~12 KB coefficient chunks per spline evaluation, so page walks
  # overlap with the DRAM traffic they precede -- this code is bandwidth-bound,
  # not TLB-latency-bound, so the payoff is small. Against that, I cannot
  # verify the module exists from off-machine and a failed module load would
  # break the build outright. Not worth it.

  rm -rf "${BUILD_DIR}"
  mkdir -p "${BUILD_DIR}"
  cd "${BUILD_DIR}"

  cmake \
    -DCMAKE_SYSTEM_NAME=CrayLinuxEnvironment \
    -DCMAKE_C_COMPILER=cc \
    -DCMAKE_CXX_COMPILER=CC \
    -DCMAKE_BUILD_TYPE=Release \
    -DQMC_MPI=1 \
    -DQMC_OMP=1 \
    -DBLA_VENDOR=All \
    -DCMAKE_CXX_FLAGS="-march=znver3 -mtune=znver3" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    "${SRC_DIR}"

  # Notes on the flags above:
  #
  # -DCMAKE_SYSTEM_NAME=CrayLinuxEnvironment : required (FindMPI otherwise
  #   refuses to accept CC as an MPI compiler). Side effect worth knowing:
  #   it makes CMAKE_CROSSCOMPILING=TRUE, so src/CMakeLists.txt:285-287 skips
  #   MPI_DETERMINE_LIBRARY_VERSION and the MVAPICH2/OpenMPI version checks
  #   below it degenerate to no-ops. Verified locally that this does not error.
  #
  # -DQMC_MPI=1 : OFF by default here; without it srun -n8 is 8 independent
  #   serial copies of the whole problem.
  #
  # -DCMAKE_CXX_FLAGS="-march=znver3" : NOT redundant. CMake/GNUCompilers.cmake
  #   explicitly skips its -march=native logic when CRAYPE_VERSION is set
  #   ("It's a cray machine. Don't do anything"), so without this the einspline
  #   and Jastrow kernels compile for a generic x86-64 baseline -- no AVX2, no
  #   FMA. Frontier's EPYC 7A53 "Trento" is Zen 3, hence znver3.
  #
  # -DBLA_VENDOR=All : skips the pointless Intel-MKL probe and goes straight to
  #   FindBLAS/FindLAPACK's "implicitly linked" check, which is the path that
  #   succeeds on Cray (the CC wrapper already links libsci, so BLAS_LIBRARIES
  #   comes back empty and correct). BLAS here is dgemv/dger/skinny-dgemm on
  #   the 1536x1536 inverse plus one getrf/getri per walker at startup -- all
  #   bandwidth-bound, where libsci and OpenBLAS are a wash. Using libsci
  #   avoids depending on a versioned openblas module that may be renamed.
  #
  # -DCMAKE_POLICY_VERSION_MINIMUM=3.5 : insurance in case the cmake module is
  #   4.x, which rejects this project's cmake_minimum_required(3.6.0) idioms.
  #   Harmless (one "unused variable" note) on older cmake.

  # Only the target we actually run. Skips the other three drivers and all the
  # Catch unit-test binaries.
  make -j16 miniqmc

  echo
  echo "Built: ${EXE}"
}

# -----------------------------------------------------------------------------
# run()
# -----------------------------------------------------------------------------
run() {
  set -e

  module load PrgEnv-gnu

  # --- Geometry: 8 ranks x 7 threads x 7 walkers = 56 walkers ---------------
  #
  # Frontier gives a job 56 of the node's 64 cores: low-noise mode pins system
  # processes to core 0, and the default core specialization (-S 8) reserves
  # the first core of each of the 8 L3 regions. So the allocatable cores are
  # 1-7, 9-15, 17-23, ... 57-63 -- exactly 7 per L3 region, 8 regions,
  # 2 regions per NUMA domain.
  #
  # 56 walkers on 56 cores means one walker per core is the only sane target,
  # and miniqmc.cpp's ONLY parallel loop is "#pragma omp parallel for" over
  # walkers (miniqmc.cpp:408). So threads-per-rank must equal walkers-per-rank:
  # extra threads idle, extra walkers serialize. That fixes ranks x threads =
  # ranks x walkers = 56 and leaves the split as the real choice.
  #
  # 8 x 7 wins over the alternatives (4x14, 14x4, 56x1) because:
  #
  #  * It lands one MPI rank exactly on one L3 region. No OpenMP team straddles
  #    a cache region, and it is the layout OLCF documents and verifies
  #    (their Example 1: -n8 -c7 puts rank 0 on HWT 001-007, rank 1 on 009-015,
  #    and so on). Zero binding ambiguity.
  #
  #  * The 786 MB spline coefficient table (1536 orbitals x 40^3 x 8 B) is
  #    shared read-only by all walkers in a rank -- einspline_spo's view
  #    constructor copies pointers, not data (einspline_spo.hpp:84-100). Its
  #    first touch happens in an omp parallel for (BsplineAllocator.hpp:171),
  #    so with a rank confined to one L3 region every page lands in that rank's
  #    own NUMA domain. Going the other way, 1 rank x 56 threads would first-
  #    touch the whole table from one NUMA domain and make 3/4 of the node's
  #    spline reads remote -- and this benchmark is DRAM-bandwidth-bound
  #    (~786 KB of coefficients read per spline evaluation, ~15k evaluations
  #    per walker per step), so that would hurt badly.
  #
  #  * 56 ranks x 1 walker would instead replicate the spline table 56 times
  #    (44 GB) and serialize its construction inside each rank, inflating Setup
  #    sevenfold for no gain in the timed region.
  #
  # MPI cost of the split is nil either way: Communicate.cpp only does
  # MPI_Init/rank/size, and miniqmc.cpp never communicates. Ranks are
  # independent, so there is no cross-rank barrier to amplify imbalance.

  export OMP_NUM_THREADS=7
  export OMP_PLACES=threads      # 7 threads, 7 allowed HW threads -> 1:1, unambiguous
  export OMP_PROC_BIND=close     # all 7 places are one L3 region, so close == spread
  export OMP_MAX_ACTIVE_LEVELS=1 # keep threaded libsci serial when BLAS is called
  export OMP_NESTED=false        # from inside the walker loop (no MKL here, so
                                 # BlasThreadingEnv is a no-op and can't do it)
  export OMP_WAIT_POLICY=active  # cores are dedicated; spin at the step barriers

  # --- The run --------------------------------------------------------------
  #
  # -c 7 with --threads-per-core=1 means 7 *physical* cores per rank. Passing
  # --threads-per-core=1 explicitly rather than relying on the default protects
  # against an allocation made with --threads-per-core=2, where -c would flip
  # to counting hardware threads and pack each rank onto 3.5 cores.
  #
  # No -m distribution flag: Slurm's default already fills one L3 region per
  # rank at -c 7, which is what the OLCF example demonstrates. Overriding it
  # can only make things worse.
  #
  # -t coarse : measurement setting, not a workload change. The default "fine"
  # activates the per-evaluation timers inside the hot path -- the
  # "Single-Particle Orbitals" timer wraps every spline evaluation
  # (einspline_spo.hpp:158,183) and Determinant::ratio/spoval/spovgl wrap every
  # determinant call. Each start/stop does a cpu_clock() plus two std::map
  # lookups keyed on a stack key. Only the master thread records
  # (NewTimer.h:305-317), so with "fine" thread 0 becomes the straggler and the
  # other 6 threads wait for it at the end-of-step barrier -- the overhead is
  # paid by the whole team. "coarse" deactivates exactly those fine-level
  # timers and changes nothing about the computation. Total and Setup are both
  # coarse-level and are still printed.
  #
  # Everything else is left at its default (-N 1 substep, -k 32 delayed-update
  # rank, no -j three-body Jastrow, no -m meshfactor). Those knobs change the
  # operation count, so touching them would not be the same benchmark.

  srun -N 1 -n 8 -c 7 --threads-per-core=1 --cpu-bind=threads \
    "${EXE}" -g "2 2 2" -n 5 -w 7 -t coarse
}

# -----------------------------------------------------------------------------
case "${1:-}" in
  build) build ;;
  run)   run   ;;
  *)     echo "usage: bash $(basename "$0") {build|run}" >&2; exit 1 ;;
esac
