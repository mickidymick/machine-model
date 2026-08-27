#!/bin/bash
#==============================================================================
# LULESH 2.0 on Frontier (OLCF) -- 300^3 elements, 50 cycles, -r 11 -b 0 -c 64
#
#   bash SOLUTION.sh build     # module loads + compile
#   bash SOLUTION.sh run       # the single srun line (run inside an allocation)
#
# Assumes the standard Frontier allocation: 1 node, default core specialization
# (-S 8), and --threads-per-core=2 at the job level as stated in PROBLEM.md.
#
#------------------------------------------------------------------------------
# THE CONFIGURATION, AND WHY
#------------------------------------------------------------------------------
# Decomposition: 8 MPI ranks x 7 OpenMP threads, -s 150  (8 * 150^3 = 300^3).
#
#   A Frontier node is one 64-core EPYC 7A53: 8 L3 regions (CCDs) of 8 cores,
#   2 CCDs per NUMA domain, 4 NUMA domains.  Low-noise mode + core
#   specialization (-S 8) reserve the FIRST core of each L3 region, so only 56
#   cores are allocatable -- 7 per CCD.  8 x 7 = 56 is the only perfect-cube
#   rank count that tiles the allocatable cores exactly, and `-n 8 -c 7` is the
#   documented Frontier layout that puts rank i alone on L3 region i
#   (HWT 1-7, 9-15, 17-23, ...).  So every rank gets a private L3 and every
#   rank's pages are first-touched in its own NUMA domain.
#
#   That last point is why 1 rank x 56 threads is not on the table: Domain's
#   constructor (lulesh-init.cc:159-178) initialises the mesh in *serial*, so
#   first-touch would put the entire ~8 GB working set on one NUMA domain and
#   3/4 of all traffic would be cross-die.  MPI ranks are what buys locality
#   here, not the thread count.
#
#   The other legal cubes are worse: 27 ranks x 2 threads leaves 2 of 56 cores
#   idle and straddles L3 regions unevenly; 64 and 125 ranks need more cores
#   than exist; 1 rank is the NUMA disaster above.  Cache residency does not
#   break the tie -- the per-node footprint of the EOS temporaries is
#   14 arrays * (27e6/11 elem) * 8 B ~= 275 MB against 256 MB of total L3
#   regardless of how the 27e6 elements are split, so no decomposition makes
#   the hot loop cache-resident.
#
# Threads per core: ONE.  The srun step explicitly says --threads-per-core=1.
#
#   Stated explicitly because the allocation exposes 2: under
#   --threads-per-core=2 the `-c` flag counts *logical* cores, so `-c 7` would
#   hand each rank 3.5 physical cores (HWT 1,65,2,66,...) instead of 7.  With
#   --threads-per-core=1, `-c 7` means 7 physical cores, which is what I want.
#
#   Why not SMT2 (-c 14, 14 threads/rank)?  With -c 64 the run is dominated by
#   EvalEOSForElems' `rep` loop (rep = 1/65/650 over the 11 regions, ~89
#   element-EOS evaluations per element per cycle).  Those loops are unit-stride
#   streams over ~14 temporaries plus 6 gathers, i.e. DRAM-bandwidth bound; 56
#   Zen3 cores already saturate the 8 DDR4-3200 channels, so a second thread per
#   core adds no bandwidth.  What it would add is 2x the concurrent stream count
#   per core (~28 streams) competing for the same 32 KB L1 / 512 KB L2 and the
#   same limited set of hardware prefetch stream trackers, plus double-width
#   OpenMP barriers across the ~540k parallel regions this run executes.  One
#   thread per core.
#
# Compiler: PrgEnv-amd (amdclang++ via the CC wrapper), -O3 -ffast-math.
#
#   -ffast-math is the single biggest flag here: CalcPressureForElems and
#   CalcEnergyForElems execute several full-precision divides and a sqrt per
#   element per rep, and fast-math lets clang emit reciprocal/rsqrt sequences
#   and vectorise them.  It changes only rounding -- no physics option, no CFL
#   condition, and the cycle count is pinned by -i 50 either way.
#   If PrgEnv-amd's module set is broken on the day, build() falls back to
#   PrgEnv-cray automatically (also LLVM-based, same flags).
#
# Runtime knobs:
#   OMP_WAIT_POLICY=ACTIVE -- ~540k fork/joins per rank; cores are exclusive.
#   MALLOC_*_THRESHOLD_    -- EvalEOSForElems allocates and frees 14 arrays per
#                             region and CalcEnergyForElems one more per rep
#                             (~1000 alloc/free pairs per cycle).  Pinning the
#                             thresholds high keeps glibc from round-tripping
#                             those multi-MB buffers through mmap/munmap and
#                             re-faulting zeroed pages every rep.
#   craype-hugepages2M     -- 2 MB pages for the gather-heavy indirect accesses
#                             over ~27 MB arrays.  Guarded with `|| true`: if
#                             the module is absent nothing is lost.
#
# Expected: ~1 GB/rank (~8 GB/node), well inside 512 GB, and comfortably inside
# the 15-minute limit.
#==============================================================================

set -uo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SRC="$DIR/src"
EXE="$DIR/lulesh2.0"
LOG="$DIR/lulesh_run.log"

# Fixed problem: 8 ranks * 150^3 = 300^3 elements, 11 regions, 64x cost spread,
# 50 iterations.  Do not touch.
RANKS=8
NX=150
ARGS="-s ${NX} -i 50 -r 11 -b 0 -c 64"

THREADS=7          # 7 allocatable cores per L3 region under -S 8

#------------------------------------------------------------------------------
init_modules() {
    if ! command -v module >/dev/null 2>&1; then
        # `module` is a shell function and may not survive into a child bash
        for f in /usr/share/lmod/lmod/init/bash /etc/profile.d/z00_lmod.sh; do
            [ -f "$f" ] && . "$f" && break
        done
    fi
}

#------------------------------------------------------------------------------
build() {
    init_modules
    module reset                        >/dev/null 2>&1 || true
    module load PrgEnv-amd              || true   # CC -> amdclang++
    module load craype-x86-trento       >/dev/null 2>&1 || true
    module load cray-mpich              >/dev/null 2>&1 || true
    module load craype-hugepages2M      >/dev/null 2>&1 || true
    module list

    CXXFLAGS="-DUSE_MPI=1 -O3 -ffast-math -fopenmp -march=znver3 -mtune=znver3 -I."
    SOURCES="lulesh.cc lulesh-comm.cc lulesh-viz.cc lulesh-util.cc lulesh-init.cc"

    rm -f "$EXE"
    cd "$SRC" || exit 1

    echo "+ CC $CXXFLAGS $SOURCES -lm -o $EXE"
    if ! CC $CXXFLAGS $SOURCES -lm -o "$EXE" ; then
        echo "### PrgEnv-amd build failed -- falling back to PrgEnv-cray ###" >&2
        module swap PrgEnv-amd PrgEnv-cray || module load PrgEnv-cray
        module list
        echo "+ CC $CXXFLAGS $SOURCES -lm -o $EXE"
        CC $CXXFLAGS $SOURCES -lm -o "$EXE" || { echo "BUILD FAILED" >&2; exit 1; }
    fi

    ls -l "$EXE"
    echo "build: OK"
}

#------------------------------------------------------------------------------
run() {
    init_modules
    module reset                        >/dev/null 2>&1 || true
    module load PrgEnv-amd              >/dev/null 2>&1 || true
    module load cray-mpich              >/dev/null 2>&1 || true
    module load craype-hugepages2M      >/dev/null 2>&1 || true

    [ -x "$EXE" ] || { echo "No $EXE -- run 'bash SOLUTION.sh build' first." >&2; exit 1; }
    [ -n "${SLURM_JOB_ID:-}" ] || echo "WARNING: no SLURM_JOB_ID; run this inside your 1-node allocation." >&2

    export OMP_NUM_THREADS=${THREADS}
    export OMP_PLACES=cores
    export OMP_PROC_BIND=close
    export OMP_DYNAMIC=FALSE
    export OMP_WAIT_POLICY=ACTIVE
    export MALLOC_MMAP_THRESHOLD_=1073741824
    export MALLOC_TRIM_THRESHOLD_=1073741824

    # --- the run ---------------------------------------------------------
    srun -N 1 -n ${RANKS} -c ${THREADS} \
         --threads-per-core=1 \
         --cpu-bind=threads \
         -m block:cyclic \
         "$EXE" ${ARGS} 2>&1 | tee "$LOG"
    # ---------------------------------------------------------------------

    echo
    echo "==================== RESULT ===================="
    grep -E "Elapsed time|Grind time|FOM" "$LOG"
    # The "Elapsed time" line is setprecision(2); the full-precision elapsed is
    # the "( ... overall)" figure on the Grind time line (setprecision(8)).
    grep "Grind time" "$LOG" | sed -n \
        's/^Grind time (us\/z\/c)  *=  *\([0-9.eE+-]*\) (per dom)  *(  *\([0-9.eE+-]*\) overall).*/Grind time  = \1 us\/z\/c\nElapsed     = \2 s (full precision)/p'
    echo "==============================================="
}

#------------------------------------------------------------------------------
case "${1:-}" in
    build) build ;;
    run)   run   ;;
    *)     echo "usage: bash $(basename "$0") {build|run}" >&2 ; exit 1 ;;
esac
