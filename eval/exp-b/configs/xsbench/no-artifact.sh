#!/bin/bash
#==============================================================================
# XSBench on Frontier (OLCF) -- 1 node, -m history -s large -G unionized
#                               -p 500000 -l 34, MPI off, single process.
#
#   bash SOLUTION.sh build     # run this on a Frontier login node
#   bash SOLUTION.sh run       # run this inside a 1-node allocation
#
# RECOMMENDED ALLOCATION (SMT must be enabled at *allocation* time, not just
# at srun time -- see the "thread count" note below):
#
#   #SBATCH -N 1
#   #SBATCH -t 00:20:00
#   #SBATCH --threads-per-core=2
#   #SBATCH -A <project>
#   #SBATCH -p batch
#
# If you allocate without --threads-per-core=2, run() detects that and falls
# back to 56 threads automatically instead of failing.
#==============================================================================
#
# WHY THIS CONFIGURATION
# ----------------------
# 1) CPU, not GPU.  This is forced by "-m history", and it is the single most
#    important fact about this problem.  Frontier's 8 MI250X GCDs are useless
#    here: src/hip, src/cuda, src/sycl, src/opencl and src/openmp-offload all
#    implement ONLY the event-based kernel and hard-exit on history mode
#    (e.g. hip/Main.cpp: "History-based simulation not implemented in CUDA
#    code ... exit(1)").  src/openmp-threading is the only implementation with
#    run_history_based_simulation().  So the target is the node's single
#    64-core EPYC 7A53 ("Trento", Zen 3), and every decision below is about
#    feeding that CPU's memory system.
#
# 2) numactl --interleave=all -- THE big win.  With "-s large -G unionized"
#    GridInit.c allocates ~5.9 GB: index_grid is 355*11303*355*4 B = 5.70 GB,
#    nuclide_grid is 193 MB, unionized_energy_array is 32 MB.  All of it is
#    written by a *serial* loop in grid_init_do_not_profile(), so Linux
#    first-touch places 100% of it in the NUMA domain of the master thread.
#    A Frontier node has 4 NUMA domains (2 L3 regions each) and 8 DDR4
#    channels, i.e. 2 channels per domain.  Uncorrected, all 56 cores would
#    hammer 2 of the 8 memory channels for the whole run.  The lookups are
#    uniformly random over the grids, so no first-touch scheme could ever make
#    them local -- page interleaving is the optimal placement here, and it
#    turns 2 channels of bandwidth into 8.  Expect this alone to be worth
#    several x.  (Harmless no-op if the node were NPS1, so it is a free bet.)
#
# 3) craype-hugepages2M.  ~56 random gathers into the 193 MB nuclide_grid per
#    macroscopic lookup (fuel = 321 nuclides, 14% of picks), 17M lookups.  With
#    4 KB pages the nuclide grid needs 49,152 PTEs against Zen 3's 2048-entry
#    L2 TLB, so nearly every gather takes a page walk; with 2 MB pages it is
#    96 PTEs and lives entirely in the TLB.  2 MB (not 1G): Zen 3 fractures
#    1 GB pages into 2 MB entries in the L2 TLB anyway, and the 2 MB pool is
#    far more reliably available.  If the pool is short, libhugetlbfs warns and
#    silently falls back to base pages -- it cannot fail the run.
#
# 4) 112 threads = all 56 allocatable cores x SMT2.  Frontier reserves the
#    first core of each of the 8 L3 regions (low-noise mode + "-S 8" core
#    specialization), leaving 56 cores / 112 hardware threads.  The kernel is a
#    dependent-load binary search (~22 levels over the 32 MB unionized energy
#    array) followed by a pointer-gather loop -- exactly the latency-exposed
#    pattern where a second hardware thread per core buys extra memory-level
#    parallelism at no cache cost.  Thread count does not change the work
#    (-p and -l are untouched), so this is a legal knob.
#
# 5) Compiler: PrgEnv-amd (amdclang) through the Cray "cc" wrapper.  LLVM on
#    AMD silicon, and the wrapper is what makes the craype-hugepages link
#    flags take effect.  The flags are PE-agnostic though, so if PrgEnv-amd is
#    unavailable the build still works under PrgEnv-cray/gnu.
#    NOTE the Makefile trap: it rewrites "CC = cc" to gcc and appends its own
#    CFLAGS.  Passing CC/CFLAGS/LDFLAGS on the *make command line* makes them
#    override variables that the Makefile cannot reassign, which is why the
#    build below sets all three explicitly.  MPI stays "no" -- untouched.
#    No -flto: the entire hot path (calculate_macro_xs / calculate_micro_xs /
#    the particle loop) is inside Simulation.c, so -O3 inlining already gets
#    it, and LTO only adds linker-plugin risk.  No -ffast-math: it would
#    perturb the interpolation and break the verification checksum.
#==============================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src/openmp-threading"

# Fixed problem definition -- do not edit.
ARGS="-m history -s large -G unionized -p 500000 -l 34"

#------------------------------------------------------------------------------
# Make "module" usable from a non-interactive shell (bash SOLUTION.sh ...).
#------------------------------------------------------------------------------
init_modules() {
    if ! command -v module >/dev/null 2>&1; then
        for f in /usr/share/lmod/lmod/init/bash \
                 /opt/cray/pe/lmod/lmod/init/bash \
                 /etc/profile.d/lmod.sh \
                 /etc/profile.d/z00_lmod.sh; do
            [ -r "$f" ] && . "$f" && break
        done
    fi
}

load_env() {
    init_modules
    # amdclang via the Cray wrappers.  If this PE is missing, whatever PE is
    # already loaded (PrgEnv-cray by default) works with the same flags.
    module load PrgEnv-amd 2>/dev/null || echo "NOTE: PrgEnv-amd unavailable; using the default PE."
    # 2 MB huge pages for the heap: link flags at build, HUGETLB_* at run.
    module load craype-hugepages2M 2>/dev/null || echo "NOTE: craype-hugepages2M unavailable; continuing with base pages."
    command -v module >/dev/null 2>&1 && module list 2>&1 | sed 's/^/  /'
}

#==============================================================================
build() {
    load_env
    cd "$SRC" || { echo "ERROR: $SRC not found"; exit 1; }

    # -march=znver3 is correct for the EPYC 7A53; probe it so an older
    # compiler in the PE cannot break the build over a marginal flag.
    MARCH=""
    T=$(mktemp -d); echo 'int main(void){return 0;}' > "$T/t.c"
    for m in znver3 znver2; do
        if cc -march=$m -c "$T/t.c" -o "$T/t.o" >/dev/null 2>&1; then
            MARCH="-march=$m"; break
        fi
    done
    rm -rf "$T"
    echo "Using MARCH='${MARCH:-<none>}'"

    make clean

    # CC / CFLAGS / LDFLAGS on the command line are override variables: they
    # defeat both the "cc -> gcc" rewrite and the Makefile's own CFLAGS logic.
    make -j6 \
        CC=cc \
        CFLAGS="-std=gnu99 -O3 $MARCH -fopenmp -DOPENMP" \
        LDFLAGS="-lm" || { echo "BUILD FAILED"; exit 1; }

    echo
    echo "Built: $SRC/XSBench"
}

#==============================================================================
run() {
    load_env
    cd "$SRC" || { echo "ERROR: $SRC not found"; exit 1; }
    [ -x ./XSBench ] || { echo "ERROR: ./XSBench missing -- run 'bash SOLUTION.sh build' first"; exit 1; }

    # Thread count.  112 (56 cores x SMT2) is the intended configuration, but
    # srun cannot enable the second hardware thread unless the *allocation*
    # was made with --threads-per-core=2, so take that path only when Slurm
    # has actually handed us the SMT siblings.  Falling back is a performance
    # loss, not a failure; requesting -c 112 in a 56-CPU allocation IS a
    # failure, so this guard is the difference between slow and dead.
    NCPU=${SLURM_CPUS_ON_NODE:-112}
    if [ "$NCPU" -ge 112 ]; then NCPU=112; TPC=2; else NCPU=56; TPC=1; fi

    # One OpenMP thread per hardware thread, pinned, spread across all 8 L3
    # regions / 4 NUMA domains.
    export OMP_NUM_THREADS=$NCPU
    export OMP_PROC_BIND=spread
    export OMP_PLACES=threads
    # Back the 5.9 GB of grids with 2 MB pages (no-op if libhugetlbfs was not
    # linked in; warns and falls back if the pool is short).
    export HUGETLB_MORECORE=yes

    # Round-robin every page of the grids over all 4 NUMA domains / 8 memory
    # channels.  Skipped only if numactl is genuinely absent from the image.
    NUMA=""
    if command -v numactl >/dev/null 2>&1; then
        NUMA="numactl --interleave=all"
    else
        echo "WARNING: numactl not found -- running without page interleaving."
        echo "         Expect a large slowdown; all ~5.9 GB will sit in one NUMA domain."
    fi

    echo "OMP_NUM_THREADS=$OMP_NUM_THREADS  threads-per-core=$TPC"
    set -x
    srun -N1 -n1 --ntasks-per-node=1 --cpus-per-task=$NCPU \
         --threads-per-core=$TPC --cpu-bind=threads \
         $NUMA ./XSBench $ARGS -t $NCPU
    set +x
    # Report the "Runtime:" and "Lookups/s:" lines from the RESULTS block.
    # "Verification checksum: 954318 (Valid)" confirms the work was unchanged.
}

#==============================================================================
case "${1:-}" in
    build) build ;;
    run)   run   ;;
    *)     echo "usage: bash $(basename "$0") {build|run}"; exit 1 ;;
esac
