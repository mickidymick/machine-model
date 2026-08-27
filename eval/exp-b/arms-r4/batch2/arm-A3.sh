#!/bin/bash
# =============================================================================
# LULESH 2.0 on Frontier (OLCF) -- 1 node, 300^3 elements, 50 iterations
#
#   Usage:   bash SOLUTION.sh build
#            bash SOLUTION.sh run        # from inside a 1-node allocation
#
#   The allocation is assumed to be:
#       salloc -A <proj> -N 1 -t 0:20:00 -p batch --threads-per-core=2
#   (this script's srun step explicitly asks for ONE thread per core; see below)
#
# -----------------------------------------------------------------------------
# THE CONFIGURATION, AND WHY
# -----------------------------------------------------------------------------
# Node: 1x AMD "Optimized 3rd Gen EPYC" (Trento, Zen3), 64 physical cores in
# 8 L3 regions (CCDs) of 8 cores, 4 NUMA domains (NPS4) = 2 CCDs each, 2 HW
# threads/core.  Low-noise mode + core specialization (-S 8) reserves the first
# core of every L3 region (physical cores 0,8,16,...,56), so 56 cores are
# allocatable: 7 per L3 region.
#
# 1) Decomposition: 8 MPI ranks x -s 150  (8 * 150^3 = 300^3, ranks a perfect cube).
#
#    The rank count must be a perfect cube whose cube root divides 300, and it
#    has to map cleanly onto 8 L3 regions / 56 cores.  8 is the only choice that
#    does: 8 ranks x 7 OpenMP threads = exactly 56 cores, one rank per L3 region,
#    two ranks per NUMA domain.  The alternatives are all worse:
#      - 1 rank x 56 threads: Domain's persistent arrays (~1.3 GB/rank) are
#        malloc'd and initialized SERIALLY in the constructor (lulesh-init.cc),
#        so first touch would put the entire mesh on ONE NUMA domain and the
#        run would live on 1/4 of the node's memory bandwidth.  Barriers would
#        also cross all 8 CCDs ~600k times.
#      - 27 ranks x 2 threads: only 54 of 56 cores usable, and 27 ranks do not
#        divide 8 L3 regions, so ranks straddle CCDs.
#      - 64/125/216 ranks: more ranks than the 56 available cores.  Oversubscribing
#        (or letting 8 of the cores host 2 ranks via SMT) is fatal for a
#        bulk-synchronous code -- every rank waits on the slowest one.
#    Cache footprint does NOT argue for a different decomposition: the EOS
#    temporaries are 14 arrays x (numElem/11) doubles, whose *node-aggregate*
#    size (~275 MB vs 256 MB of total L3) is identical for every decomposition.
#
# 2) One hardware thread per core: --threads-per-core=1, OMP_NUM_THREADS=7.
#
#    Stated EXPLICITLY because the allocation exposes 2 threads/core, and in
#    that case Slurm's -c counts *hardware threads*: a step that just said
#    "-c 7" would get 3.5 physical cores per rank (threads 1,65,2,66,3,67,4),
#    double-booking cores and idling half the node.  With --threads-per-core=1,
#    -c 7 = 7 physical cores = exactly one L3 region per rank.
#    I want 1 thread/core rather than 8x14=112 threads because with -r 11 -c 64
#    the run is dominated by EvalEOSForElems (reps: 5x1 + 5x65 + 1x650 = 980 per
#    cycle, i.e. ~89 EOS evaluations per element per cycle) -- long streaming
#    loops over the 14 per-region temporaries plus a run-length gather from the
#    element arrays.  That is DRAM/L3-bandwidth bound; 56 Zen3 cores already
#    saturate the 8 DDR4-3200 channels, so a second thread per core adds no
#    memory-level parallelism, halves each thread's share of the 512 KB private
#    L2 exactly where the temporaries need it, and doubles the participants in
#    the ~600k OpenMP barriers this parameter set executes.
#
# 3) Compiler: PrgEnv-amd (amdclang++ through the Cray CC wrapper), -Ofast
#    -march=znver3.  LLVM vectorizes the EOS loops (masked selects, packed
#    divides/sqrts) well on Zen3 and its OpenMP runtime (libomp, with
#    OMP_WAIT_POLICY=active) has much cheaper fork/join than libgomp -- which
#    matters because CalcEnergyForElems alone opens ~12 parallel regions per
#    rep, ~590k per rank over the run.  PrgEnv-cray (CCE) is the near-equivalent
#    fallback if PrgEnv-amd is unavailable; PrgEnv-gnu would be my last choice.
#    -Ofast cannot change the amount of work: -i 50 is reached long before
#    stoptime (dt ~ 1.2e-8 vs stoptime 1e-2), so the cycle count is fixed at 50.
#
# 4) glibc malloc tuning: EvalEOSForElems malloc()s and free()s 14 arrays per
#    region per cycle (7700 malloc/free of ~2.4 MB, plus ~27 MB gradient arrays
#    per cycle).  Raising the mmap and trim thresholds keeps those blocks on the
#    heap instead of mmap/munmap-ing them, which otherwise re-faults hundreds of
#    thousands of zero pages inside the timed loop.
#
#    (Deliberately NOT used: craype-hugepages2M.  The gather from regElemList
#    runs in contiguous runs of ~38 elements, so the access stream is
#    prefetcher- and TLB-friendly already; the upside is a couple of percent and
#    it adds a way for the build/run to fail that I cannot test from off-machine.)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src"
EXE="${SRC_DIR}/lulesh2.0"

load_env() {
    if ! command -v module >/dev/null 2>&1; then
        source /usr/share/lmod/lmod/init/bash
    fi
    module reset
    module load PrgEnv-amd
    module load craype-x86-trento     # Zen3 (Trento) target; default on Frontier
    module load cray-mpich
    module list 2>&1 | sed 's/^/[modules] /'
}

build() {
    load_env
    cd "${SRC_DIR}"
    rm -f lulesh2.0 *.o

    # Cray CC wrapper -> amdclang++ ; wrapper supplies MPI includes/libs.
    CXXFLAGS="-DUSE_MPI=1 -std=c++11 -Ofast -march=znver3 -mtune=znver3 \
              -ffp-contract=fast -funroll-loops -fopenmp -I."

    CC --version
    # Single invocation: the whole app is 5 files, and the hot code is all
    # static-inline within lulesh.cc, so nothing is lost by skipping .o files.
    CC ${CXXFLAGS} -o lulesh2.0 \
        lulesh.cc lulesh-comm.cc lulesh-viz.cc lulesh-util.cc lulesh-init.cc \
        -lm

    ls -l "${EXE}"
    echo "build: OK"
}

run() {
    load_env
    cd "${SRC_DIR}"

    # --- OpenMP: 7 threads per rank, one per physical core of that rank's L3 ---
    export OMP_NUM_THREADS=7
    export OMP_PLACES=cores
    export OMP_PROC_BIND=close
    export OMP_WAIT_POLICY=active     # spin between the ~590k parallel regions
    export OMP_DYNAMIC=false

    # --- keep the per-cycle malloc/free churn off mmap and out of trim ---
    export MALLOC_MMAP_THRESHOLD_=536870912
    export MALLOC_TRIM_THRESHOLD_=536870912

    # NOTE: srun's flags must precede the executable -- LULESH's own "-c" is the
    # region cost multiplier, srun's "-c" is cpus-per-task.  Do not reorder.
    srun -N 1 -n 8 --ntasks-per-node=8 \
         -c 7 --threads-per-core=1 \
         --cpu-bind=verbose,cores \
         "${EXE}" -s 150 -i 50 -r 11 -b 0 -c 64
    # 8 ranks x 150^3 = 300^3 = 27,000,000 elements, 50 cycles.
    # Report "Elapsed time" and the "Grind time (us/z/c)" line -- the elapsed
    # value printed on the Grind time line is the full-precision one.
}

case "${1:-}" in
    build) build ;;
    run)   run   ;;
    *)     echo "usage: bash $(basename "$0") {build|run}" >&2 ; exit 1 ;;
esac
