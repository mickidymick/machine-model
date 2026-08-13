#!/bin/bash
# =============================================================================
#  miniQMC on Frontier (OLCF) -- build + run recipe
#
#  Usage:   bash SOLUTION.sh build      # configure + compile (login node)
#           bash SOLUTION.sh run        # run the benchmark (inside an allocation)
#
#  Fixed problem:  -g "2 2 2"  (3072 electrons), -n 5, 224 walkers total.
#  Geometry chosen: 4 nodes x 8 ranks/node x 7 OpenMP threads x 7 walkers/rank
#                   = 32 ranks x 7 = 224 walkers, exactly 1 walker per core.
#
# -----------------------------------------------------------------------------
#  WHY THIS GEOMETRY  (the short version; details in the comments below)
#
#  The hot kernel is MultiBsplineEval::evaluate_v/_vgh (Numerics/Spline2/
#  MultiBspline.hpp). One single-electron evaluation streams 16*4 contiguous
#  runs of 1536 doubles out of the spline coefficient table -- ~786 KB read per
#  call, with essentially zero reuse between calls (walkers sit at random
#  positions in a 786 MB table: 1536 orbitals * 40^3 grid * 8 B). This code is
#  DRAM-bandwidth bound, not FLOP bound. So the whole configuration is chosen to
#  (a) use every available core on all 4 nodes and (b) make sure every byte of
#  that traffic is served by the memory controller local to the core reading it.
#
#  The decisive detail: the spline table is allocated and filled by ONE thread
#  per rank, serially, in einspline_spo::set() during Setup, and then shared
#  read-only by every walker in that rank (the einspline_spo copy ctor makes a
#  view, Owner=false). Linux first-touch therefore puts the whole 786 MB in the
#  NUMA domain of whatever core did the setup. A Frontier node is NPS4: 4 NUMA
#  domains, 8 L3 regions (2 per NUMA domain), 56 allocatable cores (low-noise
#  mode + default core specialization -S 8 reserve core 0 of each L3 region).
#  With 1 rank/node and 56 threads, all 56 threads would pull every spline byte
#  from a single NUMA domain -- one memory controller doing the work of four.
#  Running one rank per L3 region gives each rank its own copy of the table,
#  first-touched in the NUMA domain its 7 threads actually run on, so all reads
#  are local and all 4 controllers are busy. 8 copies * 786 MB = 6.3 GB/node out
#  of 512 GB, which is free.
#
#  This costs nothing in communication: miniQMC's Communicate class only calls
#  MPI_Init/MPI_Comm_rank/size (Utilities/Communicate.cpp). There is not a
#  single collective inside the timed region -- ranks are fully independent, and
#  the reported "Total" is rank 0's wall time. Rank count is therefore purely a
#  memory-locality decision.
#
#  Rejected alternatives:
#    * 4 nodes x 4 ranks x 14 threads (one rank per NUMA domain): also NUMA
#      correct and a legitimate second choice; 16 x 14 = 224. I picked 8/node
#      because it additionally keeps each OpenMP team inside one 32 MB L3
#      region, which is Frontier's documented binding granularity, and halves
#      the barrier width. Locality is the same; nothing about it is worse.
#    * 224 ranks x 1 walker (56/node): 56 copies of the table = 44 GB/node and
#      56x the setup writes, for no gain -- there is no MPI traffic to avoid and
#      OpenMP overhead at 7 threads is ~5 barriers for the whole run.
#    * 1 or 2 nodes: fewer memory controllers for the same fixed work. Use all 4.
#    * SMT (--threads-per-core=2): total walkers are pinned at 224, so 2 threads
#      per core would just mean 448 threads with 0.5 walkers each -- not
#      possible; and for a bandwidth-bound kernel a second hwthread only splits
#      the same bandwidth while doubling the per-core cache footprint.
#    * -DQMC_MIXED_PRECISION=1: would halve the spline traffic and is the single
#      biggest speedup available -- but it changes the arithmetic (float
#      splines), i.e. it is no longer the same work. Deliberately NOT used.
#    * -a <tile>: changes the spline blocking but not the number of coefficients
#      touched; -c <team_size> would actually reduce the work per walker. Both
#      left at their defaults.
#    * -t coarse: only disables the fine-grained SPO timers, and those cost the
#      master thread a std::map update per call (NewTimer only records on the
#      true master, NewTimer.h). That is well under 1% here, and the default
#      "fine" table is more informative. Left at the default.
# =============================================================================

set -eo pipefail        # deliberately no -u: Lmod's shell function trips on it

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${ROOT_DIR}/src"          # miniQMC source (contains the top CMakeLists.txt)
BUILD_DIR="${ROOT_DIR}/build"
EXE="${BUILD_DIR}/bin/miniqmc"

# NOTE: ROOT_DIR must live on a filesystem the compute nodes can see
# (your NFS home or a Lustre/orion path). Do not build in a node-local /tmp.

# --- run geometry (single source of truth) -----------------------------------
NODES=4
RANKS_PER_NODE=8                   # one rank per L3 region / CCD
THREADS_PER_RANK=7                 # 7 allocatable cores per L3 region (core 0 is reserved)
WALKERS_PER_RANK=7                 # 1 walker per thread -> perfect static schedule
RANKS=$(( NODES * RANKS_PER_NODE ))            # 32
TOTAL_WALKERS=$(( RANKS * WALKERS_PER_RANK ))  # 224  <-- required value

load_modules() {
  # Make `module` available in non-interactive shells.
  if ! command -v module >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source /usr/share/lmod/lmod/init/bash 2>/dev/null || true
  fi

  module reset >/dev/null 2>&1 || true

  # PrgEnv-gnu, NOT PrgEnv-cray. With CCE, CMAKE_CXX_COMPILER_ID is "CrayClang",
  # which the top-level CMakeLists matches as COMPILER=Cray *before* it matches
  # Clang -- and there is no CMake/CrayCompilers.cmake, so ENABLE_OPENMP is
  # never set and -fopenmp is never added. The build would succeed and then run
  # single-threaded, silently. PrgEnv-amd (Clang) would also work; GNU is the
  # path this CMakeLists exercises properly, and for a bandwidth-bound kernel
  # the compiler choice is second order.
  module load PrgEnv-gnu
  module load craype-x86-trento         # correct -march for Frontier's Trento CPU
  module load cray-libsci               # BLAS/LAPACK for the determinant updates
  module load cmake
  module load craype-hugepages2M || true  # optional: fewer TLB misses on the
                                          # per-walker heap data. Harmless if absent.

  # REQUIRED, not cosmetic: CMakeLists.txt:195 evaluates
  #   IF(NOT $ENV{CRAYPE_LINK_TYPE} STREQUAL "dynamic")
  # inside the CrayLinuxEnvironment branch. If the variable is unset it expands
  # to zero arguments and cmake dies with "if given arguments: NOT STREQUAL
  # dynamic -- Unknown arguments specified". Setting it is also what we want.
  export CRAYPE_LINK_TYPE=dynamic
}

build() {
  load_modules

  # --- locate Cray LibSci explicitly ----------------------------------------
  # CMake's FindBLAS/FindLAPACK has no notion of libsci, and this CMakeLists
  # calls find_package(LAPACK REQUIRED) after its MKL attempt fails, so a
  # cross-compiling Cray configure can abort here. Handing it the library
  # short-circuits the search entirely.
  # Prefer the *serial* libsci: every BLAS/LAPACK call in this code happens
  # inside the `omp parallel for` over walkers (DiracDeterminant / DelayedUpdate),
  # and HAVE_MKL is off so BlasThreadingEnv is a no-op -- threading must come
  # from the walker loop only.
  local SCI_DIR="${CRAY_LIBSCI_PREFIX_DIR:-${CRAY_LIBSCI_PREFIX:-}}"
  local LIBSCI=""
  if [[ -d "${SCI_DIR}/lib" ]]; then
    # (|| true: a non-matching glob must not trip `set -o pipefail`)
    LIBSCI=$(ls -1 "${SCI_DIR}"/lib/libsci_gnu*.so 2>/dev/null \
             | grep -E 'libsci_gnu_[0-9]+\.so$' | head -1 || true)
    [[ -z "${LIBSCI}" ]] && \
      LIBSCI=$(ls -1 "${SCI_DIR}"/lib/libsci_gnu*_mp.so 2>/dev/null | head -1 || true)
  fi
  if [[ -n "${LIBSCI}" ]]; then
    echo "Using Cray LibSci: ${LIBSCI}"
    BLAS_ARGS=( -DBLAS_LIBRARIES="${LIBSCI}" -DLAPACK_LIBRARIES="${LIBSCI}" )
  else
    echo "WARNING: could not locate libsci under '${SCI_DIR}'; letting CMake search."
    BLAS_ARGS=()
  fi

  # znver3 == Trento. craype-x86-trento already supplies this; passing it
  # explicitly costs nothing and guards against a stale CPU-target module.
  # (GNUCompilers.cmake deliberately adds no -march on Cray systems.)
  local ARCH_FLAGS=""
  if CC -march=znver3 -E -x c++ /dev/null >/dev/null 2>&1; then
    ARCH_FLAGS="-march=znver3 -mtune=znver3"
  fi

  rm -rf "${BUILD_DIR}"
  cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" \
    -DCMAKE_SYSTEM_NAME=CrayLinuxEnvironment \
    -DCMAKE_C_COMPILER=cc \
    -DCMAKE_CXX_COMPILER=CC \
    -DCMAKE_BUILD_TYPE=Release \
    -DQMC_MPI=1 \
    -DQMC_OMP=1 \
    -DENABLE_TIMERS=1 \
    -DCMAKE_CXX_FLAGS="${ARCH_FLAGS}" \
    -DMPI_CXX_LIBRARY_VERSION_STRING="Cray MPICH" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    "${BLAS_ARGS[@]}"
  # -DMPI_CXX_LIBRARY_VERSION_STRING: CMAKE_SYSTEM_NAME=CrayLinuxEnvironment sets
  #   CMAKE_CROSSCOMPILING, so CMakeLists.txt:285 skips MPI_DETERMINE_LIBRARY_VERSION
  #   and FindMPI never defines that variable -- then line 294,
  #   IF(${MPI_CXX_LIBRARY_VERSION_STRING} MATCHES "MVAPICH2"), expands to
  #   IF( MATCHES "MVAPICH2") and configure aborts. Defining it defuses that and
  #   the Open MPI branch below it. (Cray MPICH is what the CC wrapper links.)
  # -DCMAKE_POLICY_VERSION_MINIMUM: this project declares
  #   cmake_minimum_required(3.6); harmless on older cmake, keeps CMake 4.x happy.

  # Only the miniqmc target: skips check_spo/check_wfc/miniqmc_sync_move and the
  # Catch unit tests, which are added unconditionally (BUILD_UNIT_TESTS is not
  # actually honoured by src/*/CMakeLists.txt).
  cmake --build "${BUILD_DIR}" --target miniqmc -j 16

  echo
  echo "Built: ${EXE}"
  ls -l "${EXE}"
}

run() {
  load_modules

  if [[ -z "${SLURM_JOB_ID:-}" ]]; then
    echo "NOTE: no Slurm allocation detected. Get one first, e.g."
    echo "      salloc -A <project> -J miniqmc -t 00:15:00 -p batch -N ${NODES}"
    echo "      (4 nodes x 15 min = 60 node-minutes, the full budget; the run"
    echo "       itself should need only a few minutes.)"
    echo "      Extra srun args can be passed via SRUN_EXTRA=\"-A <project> -t 00:15:00\"."
    echo
  fi

  # --- OpenMP: one thread per core, pinned, no nesting ------------------------
  export OMP_NUM_THREADS=${THREADS_PER_RANK}
  export OMP_PLACES=cores            # one place per physical core
  export OMP_PROC_BIND=close         # fill the rank's L3 region in order
  export OMP_MAX_ACTIVE_LEVELS=1     # keep any libsci BLAS call serial inside
                                     # the walker loop (no nested oversubscription)
  export OMP_WAIT_POLICY=active      # spin at the 5 step barriers
  export OMP_STACKSIZE=32M           # cheap insurance for the per-walker frames

  # Memory policy is deliberately left at the kernel default (first-touch local):
  # that is exactly what puts each rank's spline table in its own NUMA domain.
  # Do NOT add --mem-bind=interleaved here.

  cd "${ROOT_DIR}"   # miniqmc writes info_2_2_2.xml into $PWD

  echo "Geometry: ${NODES} nodes x ${RANKS_PER_NODE} ranks x ${THREADS_PER_RANK} threads"
  echo "          = ${RANKS} ranks x ${WALKERS_PER_RANK} walkers = ${TOTAL_WALKERS} walkers"
  echo

  # -c 7 with --threads-per-core=1 => 7 physical cores per task. Frontier's 56
  # allocatable cores are the non-reserved ones (core 0 of each L3 region is
  # taken by core specialization), and Slurm hands them out in order, so tasks
  # 0..7 land on L3 regions 0..7 -- one rank per CCD, two ranks per NUMA domain.
  # --cpu-bind=cores confines each rank to its own region; OMP_PLACES then pins
  # one thread per core inside it. Append ",verbose" to print the masks.
  srun -N ${NODES} -n ${RANKS} --ntasks-per-node=${RANKS_PER_NODE} \
       -c ${THREADS_PER_RANK} --threads-per-core=1 --cpu-bind=cores \
       ${SRUN_EXTRA:-} \
       "${EXE}" -g "2 2 2" -n 5 -w ${WALKERS_PER_RANK}

  echo
  echo "Read the 'Total' row of the timer table above; 'Setup' is reported separately."
}

case "${1:-}" in
  build) build ;;
  run)   run   ;;
  *)
    echo "usage: bash $(basename "${BASH_SOURCE[0]}") {build|run}" >&2
    exit 1
    ;;
esac
