#!/bin/bash
# =============================================================================
# LULESH 2.0 on Frontier (OLCF) -- 1 node, 300^3 global elements, 50 cycles
#
#   Usage:   bash SOLUTION.sh build
#            bash SOLUTION.sh run
#
# Fixed problem (unchanged):  global 300^3 elements, -r 11 -b 0 -c 64, -i 50.
#
# -----------------------------------------------------------------------------
# THE CONFIGURATION, AND WHY
# -----------------------------------------------------------------------------
# Decomposition: 8 MPI ranks x 7 OpenMP threads, -s 150.  (8^(1/3)=2, 2*150=300.)
#
#   A Frontier node is one 64-core EPYC 7A53 (Trento/Zen3): 8 L3 regions of 8
#   cores, 2 L3 regions per NUMA domain (NPS4), 4 NUMA domains.  Slurm's default
#   core specialization (-S 8) reserves the first core of each L3 region, so
#   exactly 56 cores are allocatable, as 8 groups of 7.  8 ranks x 7 threads is
#   the only perfect-cube rank count that tiles that layout with zero idle
#   cores: rank i gets L3 region i (HWT 8i+1 .. 8i+7).
#
#   The alternatives lose:
#     - 1 rank x 56 threads: LULESH's Domain constructor is serial, so every
#       array is first-touched by the master thread and lands in ONE NUMA
#       domain.  56 cores would then pull all traffic through 2 of the 8 DDR4
#       channels.  This code is bandwidth-bound (see below), so that is fatal.
#     - 27 ranks x 2 threads: 54 of 56 cores (3.6% idle), and 27 ranks do not
#       divide 8 L3 regions evenly, so per-L3 cache pressure is lumpy.
#     - 64 ranks x 1 thread: needs SMT to fit 64 tasks on 56 cores.  Slurm
#       enumerates logical CPUs core-major (1, 65, 2, 66, ...), so 8 tasks per
#       L3 region would pack onto 4 fully-SMT'd physical cores and leave 3 of
#       the 7 cores in every L3 region completely idle.
#     - 125 / 216 ranks: >2x oversubscription of 56 cores.
#
#   With 8 ranks each confined to one L3 region, each rank's serial first-touch
#   puts its memory in its own NUMA domain and all 7 of its threads sit in that
#   same NUMA domain.  Two ranks share each NUMA domain's 2 memory channels and
#   the per-rank work is uniform (-b 0), so the DRAM load comes out balanced
#   across all 8 channels with no numactl interleaving needed.
#
# Hardware threads: ONE per core -- srun --threads-per-core=1.
#
#   This is stated explicitly because the allocation is made with
#   --threads-per-core=2; without the override srun would inherit 2 and '-c 7'
#   would mean 7 *logical* cores = 3.5 physical cores per rank.  With
#   --threads-per-core=1, '-c 7' means 7 physical cores, which is what I want.
#
#   Why 1 and not 2 (which would be -c 14 --threads-per-core=2, 8x14 threads):
#   -r 11 -b 0 -c 64 makes EvalEOSForElems repeat each region 1x, 65x or 650x
#   (lulesh.cc:2386-2396), 980 region-passes per cycle against 11 regions, so
#   ~89x more EOS work than a single sweep -- EOS is ~95% of the run.  Those
#   loops stream ~15 temporaries of numElemReg doubles each; summed over the
#   node that is ~470 MB of live data against 256 MB of total L3, and the ratio
#   is invariant under the decomposition (per-rank set shrinks exactly as fast
#   as ranks-per-L3 grows).  So it runs out of DRAM at ~1 byte/cycle/core while
#   needing ~4-5 bytes/flop: memory-bandwidth-bound by more than an order of
#   magnitude over the ~13 cycles/element of divide+sqrt work.  SMT adds no
#   memory channels and no divider throughput (the FP divider is shared by the
#   two threads of a core), while it halves each thread's L1/L2 share on a code
#   that is already thrashing cache, and doubles the thread count across the
#   ~590k OpenMP fork/joins the rep loop generates.  I would run SMT1.
#
# 2 MB huge pages: the hot EOS working set is ~37 MB/rank.  With 4 KB pages
#   that is ~9500 pages against a 2048-entry L2 TLB -- a page walk on nearly
#   every stream.  2 MB pages cut it to ~19 and let the hardware prefetchers run
#   across full pages.  libhugetlbfs falls back to base pages if the pool is
#   short, so this cannot fail the run.
#
# malloc: EvalEOSForElems malloc/frees its 15 temporaries 11x per cycle, and the
#   force kernels malloc/free twelve numElem*8 arrays of 216 MB each per cycle
#   (3 in IntegrateStressForElems, 6 in CalcHourglassControlForElems, 3 in
#   CalcFBHourglassForceForElems).  216 MB is well over glibc's 32 MB cap on the
#   dynamic mmap threshold, so those are mmap'd and munmap'd every cycle: ~1 TB
#   of kernel page-zeroing over the run.  Pinning the heap (MALLOC_MMAP_MAX_=0,
#   MALLOC_TRIM_THRESHOLD_=-1) makes them recycle in place, and it also routes
#   every allocation through libhugetlbfs's morecore.
#
# Compiler: PrgEnv-cray (CCE, clang-based) via the CC wrapper -- the Frontier
#   default, so cray-mpich and the OpenMP runtime link with no extra modules,
#   and LLVM's OpenMP runtime has cheaper fork/join than libgomp, which matters
#   at ~590k parallel regions.  -march=znver3 is Trento's ISA.  No -ffast-math:
#   it would only speed up divides, which are not the bottleneck here, and I am
#   not going to perturb the numerics for nothing.
# =============================================================================

set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${ROOT}/src"
EXE="${ROOT}/lulesh2.0"

# 'module' is a shell function; it is not defined in a non-interactive shell.
init_modules() {
    if ! command -v module >/dev/null 2>&1; then
        for f in /usr/share/lmod/lmod/init/bash \
                 /opt/cray/pe/lmod/lmod/init/bash \
                 /etc/profile.d/z00_lmod.sh \
                 /etc/profile.d/lmod.sh ; do
            if [ -r "$f" ]; then . "$f"; break; fi
        done
    fi
}

load_env() {
    init_modules
    module reset                                        # Frontier default set
    module load PrgEnv-cray                             # CCE + cray-mpich + craype
    module load craype-hugepages2M || echo "WARNING: craype-hugepages2M unavailable; continuing with 4K pages"
    module list 2>&1 || true
}

# -----------------------------------------------------------------------------
build() {
    load_env

    # CC is the Cray C++ wrapper: adds cray-mpich includes/libs and the
    # libhugetlbfs link options contributed by craype-hugepages2M.
    CXXFLAGS="-DUSE_MPI=1 -O3 -march=znver3 -ffp-contract=fast -fopenmp -I${SRC}"
    LDFLAGS="-O3 -march=znver3 -fopenmp"

    rm -f "${EXE}" "${SRC}"/*.o

    for f in lulesh lulesh-comm lulesh-init lulesh-util lulesh-viz ; do
        echo "CC -c ${f}.cc"
        CC ${CXXFLAGS} -c "${SRC}/${f}.cc" -o "${SRC}/${f}.o"
    done

    echo "CC -o lulesh2.0"
    CC "${SRC}"/lulesh.o "${SRC}"/lulesh-comm.o "${SRC}"/lulesh-init.o \
       "${SRC}"/lulesh-util.o "${SRC}"/lulesh-viz.o \
       ${LDFLAGS} -lm -o "${EXE}"

    echo "built: ${EXE}"
}

# -----------------------------------------------------------------------------
run() {
    load_env

    # ---- OpenMP: 7 threads/rank, one per physical core, spinning between the
    #      ~590k parallel regions instead of sleeping.
    export OMP_NUM_THREADS=7
    export OMP_PLACES=cores
    export OMP_PROC_BIND=close
    export OMP_WAIT_POLICY=active
    export OMP_DYNAMIC=false
    export OMP_STACKSIZE=8M
    export KMP_BLOCKTIME=infinite       # ignored by runtimes that don't know it

    # ---- 2 MB pages for the heap (falls back to 4K pages if the pool is short)
    export HUGETLB_MORECORE=yes
    export HUGETLB_DEFAULT_PAGE_SIZE=2M

    # ---- keep the heap; do not mmap/munmap the big per-cycle temporaries
    export MALLOC_MMAP_MAX_=0
    export MALLOC_TRIM_THRESHOLD_=-1

    OUT="${ROOT}/lulesh_300cubed.out"

    # -N 1              1 node
    # -n 8              8 MPI ranks (perfect cube; 2 x 2 x 2)
    # -c 7              7 CPUs per rank
    # --threads-per-core=1   -> '-c 7' means 7 PHYSICAL cores, one HW thread each.
    #                          Explicit, because the allocation holds 2/core.
    # --cpu-bind=threads     bind each task to its 7 logical CPUs
    # -m block:cyclic        rank i -> L3 region i  (cores 8i+1 .. 8i+7)
    #
    # LULESH args: -s 150 per rank x cbrt(8)=2  ->  300^3 global.  Regions and
    # iteration count exactly as specified.  No -q (it would suppress the timing).
    set -x
    srun -N 1 -n 8 -c 7 \
         --threads-per-core=1 \
         --cpu-bind=threads \
         -m block:cyclic \
         "${EXE}" -s 150 -i 50 -r 11 -b 0 -c 64 2>&1 | tee "${OUT}"
    set +x

    echo
    echo "===================== results ====================="
    # The "Elapsed time" summary line is printed at setprecision(2).  The
    # full-precision elapsed value is the "( ... overall)" field of the Grind
    # time line, printed at setprecision(8) (lulesh-util.cc:214-219).
    grep -E "Grind time|Elapsed time|FOM|Final Origin Energy|Iteration count" "${OUT}" || true
    echo "=================================================="
    echo "full output: ${OUT}"
}

# -----------------------------------------------------------------------------
case "${1:-}" in
    build) build ;;
    run)   run   ;;
    *)     echo "usage: bash $(basename "$0") {build|run}" >&2 ; exit 1 ;;
esac
