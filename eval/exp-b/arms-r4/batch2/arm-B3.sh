#!/bin/bash
# =============================================================================
# LULESH 2.0 on Frontier -- 1 node, 300^3 global elements, -r 11 -b 0 -c 64, -i 50
#
#   bash SOLUTION.sh build     # module loads + compile
#   bash SOLUTION.sh run       # the single srun line + its environment
#
# -----------------------------------------------------------------------------
# CONFIGURATION CHOSEN:  8 MPI ranks x 7 OpenMP threads, -s 150, 1 thread/core.
# -----------------------------------------------------------------------------
#
# WHY (the decision that dominates everything else is the RANK COUNT, and the
# reason is in the source, not in the machine):
#
# 1. With -r 11 -c 64 the run IS the EOS region loop.  ApplyMaterialPropertiesForElems
#    (lulesh.cc:2380) sets rep = 1 for regions 0-4, rep = 1+cost = 65 for regions
#    5-9, and rep = 10*(1+cost) = 650 for region 10.  EvalEOSForElems then repeats
#    its whole body `rep` times.  With -b 0 the regions are uniformly sized, so the
#    per-cycle EOS work is (numElem/11)*(5*1 + 5*65 + 1*650) = 89.1 * numElem
#    element-passes.  Region 10 alone is 650/980 = 66% of it.  Everything else in
#    the cycle is a few passes over the mesh.  So whatever load the EOS loop has is
#    the benchmark's load.
#
# 2. That load is NOT evenly distributed over MPI ranks, and the imbalance is
#    exactly computable, because CreateRegionIndexSets (lulesh-init.cc:401) seeds
#    `srand(myRank)` -- region sizes are a deterministic function of the rank count.
#    Replaying that RNG for each legal decomposition gives max-rank / mean-rank EOS
#    cost:
#
#        ranks   -s    EOS imbalance (max rank / mean rank)
#            1   300      1.000
#            8   150      1.064
#           27   100      1.097
#           64    75      1.177
#          125    60      1.340
#          216    50      1.909
#
#    Every cycle ends in an MPI_Allreduce on the timestep, so the slowest rank sets
#    the pace and this factor lands on the wall clock in full.  The obvious move --
#    "pure MPI, one rank per core, as many ranks as possible" -- is the expensive
#    one here: it costs 18% at 64 ranks and 91% at 216.  Rank count is a load
#    balancing decision in this problem, not a parallelism decision.
#
# 3. So: few ranks.  1 rank (perfect balance) and 8 ranks (1.064) are the only two
#    contenders.  I chose 8 because the ~6% imbalance is bought back by things
#    that only the multi-rank layout gets:
#      - NUMA first touch.  Domain setup (lulesh-init.cc:159 onward) is SERIAL, so
#        every page is first-touched by the rank's master thread.  With 8 ranks
#        that places each rank's ~2 GB in its own NUMA domain, 2 ranks per domain,
#        all 4 domains loaded evenly, 100% local -- for free.  With 1 rank x 56
#        threads every page lands in one domain and the run is capped at one
#        memory controller unless it is rescued with numactl --interleave.
#      - Barrier cost.  The EOS loop enters ~13 OpenMP parallel regions per rep,
#        i.e. ~640k fork/join+barrier pairs over the run.  A 7-thread team inside
#        one CCD (shared 32 MB L3) pays a fraction of what a 56-thread team spread
#        over 4 NUMA domains pays.
#      - Setup wall clock.  The serial mesh build is 8-way parallel across ranks
#        instead of one thread walking 27M elements.  It is outside the timer but
#        inside the 15 minutes.
#    Net, these are worth about as much as the 6% they cost, and this layout is the
#    lower-variance one.  If forced to pick a runner-up it is 1 rank x 56 threads
#    with numactl --interleave=all -- not 64 ranks.
#
# 4. 8 x 7 also happens to be exactly the machine's shape.  One core per L3 group
#    is OS-reserved (cores 0,8,16,24,32,40,48,56), so 56 of 64 cores are usable and
#    `-c 56` is the ceiling.  8 tasks x `-c 7` = 56, and because Slurm hands out the
#    allocatable cores in ascending order, task i gets physical cores 8i+1..8i+7 --
#    exactly one CCD / one 32 MB L3 region per rank, 2 ranks per NUMA domain.
#
# 5. --threads-per-core=1 (stated explicitly, as required).  The EOS temporaries are
#    ~16 arrays of numElemReg (EvalEOSForElems allocates 14, CalcEnergyForElems one
#    more) plus the 7 domain arrays gathered through regElemList; across the node
#    that is ~430 MB against 256 MB of total L3, so the rep loop streams from DRAM
#    and the node sits at memory-bandwidth saturation.  The measured SMT numbers for
#    this machine split on exactly that: latency-bound kernels gain ~70-78%, the
#    bandwidth-saturated one LOSES 5.0%.  The loop bodies here are independent per
#    element and fully prefetchable -- no dependent-load chain for a second thread to
#    hide -- so this is the losing side.  1 thread/core.
#
# 6. No craype-hugepages2M, deliberately.  The huge-page win on this machine is a
#    TLB-reach effect measured on dependent random access; the mechanism requires an
#    access pattern that defeats prefetch.  These kernels sweep contiguously and
#    amortise the page walk across the page.  The same reasoning applied to a
#    streaming kernel on this machine was measured at -2.7%, not a gain.
#
# 7. PrgEnv-gnu, not the default PrgEnv-cray: CCE is known here to silently drop
#    -fopenmp in some build paths, which costs a factor of the thread count and
#    presents as "the machine is slow".  build() verifies OpenMP and MPI actually
#    landed in the binary, and LULESH prints "Num processors:" / "Num threads:" at
#    runtime -- check those two lines say 8 and 7.
#
# 8. MALLOC_* settings are a source-driven fix, not folklore.  Allocate() is a bare
#    malloc (lulesh.h:111) and LULESH allocates and frees hundreds of MB per cycle:
#    AllocateGradients/AllocateStrains (9 x numElem doubles), and -- because
#    numthreads > 1 -- the fx/fy/fz_elem scratch of numElem*8 doubles in both
#    IntegrateStressForElems (lulesh.cc:514) and the hourglass force routine.  At
#    27 MB and 216 MB per array these sit above glibc's 32 MB dynamic mmap-threshold
#    cap, so each cycle mmaps, page-faults and zero-fills them and then munmaps them
#    (with TLB shootdowns across the team).  Raising the threshold makes the heap
#    reuse them instead.  Costs nothing, removes hundreds of GB of kernel zeroing.
# =============================================================================

set -u

ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SRC="${ROOT}/src"
EXE="${SRC}/lulesh2.0"

# --- fixed problem: 300^3 global elements = 8 ranks x 150^3 ------------------
RANKS=8
S=150
THREADS=7
LULESH_ARGS="-s ${S} -i 50 -r 11 -b 0 -c 64"

# =============================================================================
build() {
    set -e
    echo "=== LULESH build (Frontier, PrgEnv-gnu, CPU/OpenMP+MPI) ==="

    module reset
    module load PrgEnv-gnu
    module load craype-x86-trento          # Frontier compute CPU (EPYC 7A53, Zen3)
    module load cray-mpich
    # NOT loaded, on purpose: craype-hugepages2M  (see note 6 in the header)
    module list 2>&1 || true

    cd "${SRC}"

    # znver3 is the right -march for Trento; fall back if this GCC is too old.
    ARCH="-march=znver3 -mtune=znver3"
    if ! echo 'int main(){return 0;}' | CC -x c++ ${ARCH} -o /dev/null - 2>/dev/null; then
        echo "!! GCC does not know znver3, falling back to -march=native"
        ARCH="-march=native -mtune=native"
    fi

    # -fno-math-errno: lets the vectorizer inline sqrt() in the Q/soundspeed loops
    # instead of calling libm (which would block vectorization of those loops).
    # It changes no result value -- it only drops errno on math calls.
    CXXFLAGS="-O3 ${ARCH} -fopenmp -fno-math-errno -DUSE_MPI=1 -I. -Wall"
    LDFLAGS="-O3 -fopenmp"

    rm -f *.o "${EXE}"
    for f in lulesh.cc lulesh-comm.cc lulesh-viz.cc lulesh-util.cc lulesh-init.cc; do
        echo "  CC ${f}"
        CC -c ${CXXFLAGS} -o "${f%.cc}.o" "${f}"
    done
    echo "  link"
    CC lulesh.o lulesh-comm.o lulesh-viz.o lulesh-util.o lulesh-init.o \
       ${LDFLAGS} -lm -o "${EXE}"

    # --- verify the two things that fail SILENTLY on this machine -----------
    echo "--- build verification ---"
    if nm -C "${EXE}" 2>/dev/null | grep -q 'GOMP_parallel'; then
        echo "  OpenMP : OK (GOMP_parallel present)"
    else
        echo "  OpenMP : *** NOT LINKED -- do not run, the binary is serial ***"; exit 1
    fi
    if nm -C "${EXE}" 2>/dev/null | grep -q 'MPI_Init'; then
        echo "  MPI    : OK (MPI_Init present)"
    else
        echo "  MPI    : *** NOT LINKED -- 8 ranks would be 8 copies of the problem ***"; exit 1
    fi
    echo "=== build done: ${EXE} ==="
}

# =============================================================================
run() {
    set -e
    cd "${SRC}"
    [ -x "${EXE}" ] || { echo "no binary -- run 'bash SOLUTION.sh build' first"; exit 1; }

    # 7 threads per rank, one per core of the rank's CCD, pinned and spinning.
    export OMP_NUM_THREADS=${THREADS}
    export OMP_PLACES=cores
    export OMP_PROC_BIND=close
    export OMP_WAIT_POLICY=ACTIVE          # ~640k barriers; never sleep between them

    # Keep the per-cycle 27 MB / 216 MB scratch arrays on the heap instead of
    # re-mmapping and zero-filling them every cycle (header note 8).
    export MALLOC_MMAP_THRESHOLD_=1073741824
    export MALLOC_TRIM_THRESHOLD_=1073741824
    export MALLOC_TOP_PAD_=268435456
    export MALLOC_MMAP_MAX_=0

    LOG="${ROOT}/lulesh.out"

    # --- THE RUN COMMAND ----------------------------------------------------
    # -n 8 -c 7  = 56 allocatable cores, one CCD / one 32 MB L3 per rank.
    # --threads-per-core=1 : stated explicitly. Bandwidth-saturated kernel; the
    #                        second hardware thread is measured at -5% for this
    #                        regime on this machine.
    srun -N 1 -n ${RANKS} -c ${THREADS} \
         --threads-per-core=1 \
         --cpu-bind=cores \
         --distribution=block:block \
         "${EXE}" ${LULESH_ARGS} 2>&1 | tee "${LOG}"
    # ------------------------------------------------------------------------

    echo
    echo "=== reported figures ==="
    # Sanity: these must say 8 and 7, or the launch did not do what was intended.
    grep -E '^Num (processors|threads):' "${LOG}" || true
    # "Elapsed time" is printed at setprecision(2) -- 2 significant figures.
    # The full-precision elapsed value is the "( ... overall)" field of the
    # Grind time line, printed at setprecision(8) (lulesh-util.cc:222-226).
    grep -E '^Grind time' "${LOG}" || true
    ELAPSED=$(sed -n 's/^Grind time.*(\([0-9.eE+-]*\) *overall).*/\1/p' "${LOG}")
    GRIND=$(sed -n 's/^Grind time (us\/z\/c)  = *\([0-9.eE+-]*\).*/\1/p' "${LOG}")
    echo "  Total elapsed time (full precision) : ${ELAPSED} s"
    echo "  Grind time (us/z/c, per domain)     : ${GRIND}"
    grep -E '^FOM' "${LOG}" || true
}

# =============================================================================
case "${1-}" in
    build) build ;;
    run)   run   ;;
    *)     echo "usage: bash $0 {build|run}" ; exit 2 ;;
esac
