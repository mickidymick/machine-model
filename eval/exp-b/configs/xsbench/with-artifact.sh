#!/bin/bash
#==============================================================================
# XSBench on Frontier (OLCF) -- 1 node, history-based, H-M large, unionized grid
#
#   bash SOLUTION.sh build     # module loads + compile
#   bash SOLUTION.sh run       # the single srun line
#
# THE ALLOCATION MUST REQUEST SMT2. OLCF: "--threads-per-core=2 ... must be
# used [at allocation time] if using --threads-per-core=2 in your srun
# command." So allocate like this:
#
#   salloc -A <project> -N 1 -t 00:20:00 -p batch --threads-per-core=2
#   bash SOLUTION.sh build      # (or build on the login node beforehand)
#   bash SOLUTION.sh run
#
# (If the allocation lacks it, run() detects that from SLURM_CPUS_ON_NODE and
# drops to 56 threads with a warning rather than letting srun reject -c 112.)
#
# Fixed problem, unchanged: -m history -s large -G unionized -p 500000 -l 34
#                           => 17,000,000 XS lookups, MPI off, 1 process.
#
#------------------------------------------------------------------------------
# THE THREE DECISIONS, in order of how much they are worth
#
#  1. This is a CPU run; the MI250Xs are unusable for it. openmp-threading is
#     the ONLY port that implements -m history. hip, cuda, sycl, opencl and
#     openmp-offload all print "History-based simulation not implemented ...
#     use the event-based method" and exit (src/hip/Main.cpp:88,
#     src/openmp-offload/Main.c:87). -m history is fixed, so that is that.
#
#  2. numactl --interleave=all -- worth ~4x, the single biggest knob.
#
#  3. 112 threads (SMT2) over 56 -- an asymmetric bet, taken.
#
#  ...and one thing deliberately NOT done: craype-hugepages2M. It is mutually
#  exclusive with (2) on this machine. Reasoning at each site below.
#==============================================================================

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/src/openmp-threading"

#==============================================================================
# BUILD
#==============================================================================
build() {
    #--------------------------------------------------------------------------
    # Compiler: PrgEnv-gnu (cc wraps gcc), NOT the Frontier default PrgEnv-cray.
    #
    # CCE identifies itself to build systems as "CrayClang" and is a known way
    # to end up with -fopenmp silently dropped and every `omp parallel for`
    # ignored -- a failure that costs a factor of the thread count and presents
    # as "the machine is slow", not as a build error. PrgEnv-gnu avoids that
    # class of problem entirely, GCC's -march=znver3 support for Zen3 is solid,
    # and libgomp honours OMP_PLACES/OMP_PROC_BIND the way this run needs.
    # PrgEnv-amd (amdclang) would also be fine, but OLCF now requires a
    # separately version-matched `rocm` module alongside it (OLCFDEV-1799),
    # which is an extra coupling to get wrong for a build that touches no GPU.
    #
    # The Makefile needs handling. It picks its OpenMP flags by string-matching
    # "gcc"/"clang"/"intel" inside $(CC) -- a wrapper named `cc` matches none of
    # them -- and it contains
    #     ifeq (cc,$(CC))
    #         CC = gcc
    # which silently rewrites CC=cc into the bare system gcc. So CC is passed
    # as an absolute path (matches neither the ifeq nor any findstring) and the
    # complete CFLAGS is given on the command line, which overrides every
    # assignment inside the Makefile. Nothing is left to inference.
    #--------------------------------------------------------------------------
    module load PrgEnv-gnu

    # Assert huge pages are NOT linked in -- see the memory-policy block in run().
    module unload craype-hugepages2M   2>/dev/null || true
    module unload craype-hugepages512M 2>/dev/null || true

    module list 2>&1 || true

    cd "$SRC"
    make clean

    # -march=znver3: the EPYC 7A53 "Trento" is a Zen3 part.
    # No -ffast-math / -Ofast: the run must still print
    #   "Verification checksum: 954318 (Valid)"   (io.c:88)
    # and that checksum is an argmax over 5 interpolated doubles. The kernel is
    # memory bound, so relaxed FP would buy nothing to pay for that risk.
    # No -flto: calculate_macro_xs, calculate_micro_xs and grid_search all live
    # in Simulation.c already -- there is nothing cross-TU left to inline.
    make -j 8 \
        CC="$(command -v cc)" \
        CFLAGS="-std=gnu99 -O3 -march=znver3 -fopenmp -DOPENMP" \
        LDFLAGS="-lm"

    test -x "$SRC/XSBench"
    echo "BUILD OK: $SRC/XSBench"
}

#==============================================================================
# RUN
#==============================================================================
run() {
    module load PrgEnv-gnu            # runtime libgomp must be on the path too
    cd "$SRC"

    if [[ -z "${SLURM_JOB_ID:-}" ]]; then
        echo "ERROR: no Slurm allocation. Allocate WITH SMT2 enabled, then rerun:" >&2
        echo "  salloc -A <project> -N 1 -t 00:20:00 -p batch --threads-per-core=2" >&2
        echo "  bash SOLUTION.sh run" >&2
        exit 1
    fi

    #--------------------------------------------------------------------------
    # THREADS: 112 = 56 usable cores x 2 hardware threads. This is the config
    # I am committing to; the else-branch exists only so a mis-allocated job
    # still produces a number instead of an srun rejection.
    #
    # 56, not 64: Frontier runs SLURM core specialization (-S 8) by default,
    # reserving the first core of each of the 8 L3 regions -- cores 0, 8, 16,
    # 24, 32, 40, 48, 56 -- leaving 56 allocatable. `-S 0` at allocation time
    # would hand back all 64, and I considered it and rejected it: this kernel
    # is memory-bandwidth limited, so +14% cores buys ~0% throughput, while
    # core 0 is where low-noise mode pins every system process, so those threads
    # would be jitter-prone stragglers. Not worth it.
    #
    # 112, not 56 -- the one call I went back and forth on:
    #   - SMT on this node is worth about +70% for a dependent-load
    #     (latency-bound) kernel and about -5% for a bandwidth-saturated one.
    #   - This kernel is BOTH, in one loop body. Every macroscopic lookup does
    #     a binary search over the 32 MB unionized energy array -- ~22 strictly
    #     dependent, unprefetchable loads, a textbook pointer chase -- and then
    #     ~55 independent random gathers into the 193 MB nuclide grid
    #     (E[nuclides/lookup] = 55.4 under pick_mat's material distribution;
    #     the fuel material alone carries 321 of the 355 nuclides). The gathers
    #     saturate bandwidth. The binary search does not -- it just stalls, and
    #     a second hardware thread is exactly what fills that stall.
    #   - So the payoff is asymmetric: worst case -5% if I have misjudged the
    #     mix and it is purely bandwidth bound, best case a large gain on the
    #     serial-search half. Take the bet.
    #
    # OMP_PROC_BIND=close + OMP_PLACES=threads is the binding under which that
    # SMT figure was measured on this node. Changing the binding while keeping
    # the number would be unsound, so it is not changed.
    #--------------------------------------------------------------------------
    local NCPU="${SLURM_CPUS_ON_NODE:-112}"
    local THREADS TPC
    if (( NCPU >= 112 )); then
        THREADS=112; TPC=2
    else
        THREADS="$NCPU"; TPC=1
        echo "WARNING: allocation exposes only ${NCPU} CPUs, so SMT2 is off." >&2
        echo "         Running ${THREADS} threads. For the intended config," >&2
        echo "         reallocate with --threads-per-core=2." >&2
    fi

    export OMP_NUM_THREADS="$THREADS"
    export OMP_PLACES=threads
    export OMP_PROC_BIND=close
    export OMP_WAIT_POLICY=ACTIVE     # one parallel region; also silences an
                                      # OLCF-documented affinity warning

    #--------------------------------------------------------------------------
    # MEMORY POLICY: interleave, and deliberately NOT huge pages. On this
    # machine the two are mutually exclusive, and this is the trade I made.
    #
    # Why interleave (worth ~4x): grid_init_do_not_profile() in GridInit.c is
    # entirely SERIAL. Under default first-touch, all ~5.9 GB of grid -- the
    # 5.7 GB index grid, the 193 MB nuclide grid, the 32 MB unionized energy
    # array -- is faulted in by one thread and therefore lands behind ONE of
    # the four memory controllers, ~44.5 GB/s. Every one of the 112 threads
    # then queues on that single controller. Interleaving spreads the pages
    # over all four (~178 GB/s). This run moves on the order of 165 GB of DRAM
    # traffic (~10 KB per lookup x 17M lookups) against a per-thread demand
    # that already oversubscribes the memory system several times over, so
    # aggregate controller bandwidth is the binding constraint and 4x of it is
    # the largest single factor available anywhere in this configuration.
    #
    # Why not huge pages: they are not a runtime flag here. THP is set to
    # `never` and the hugetlb pool is empty, so madvise and the pool both fail
    # SILENTLY and you get 4K backing while everything still looks fine; the
    # only working path is craype-hugepages2M, which works by RELINKING the
    # binary. And once linked, the module provisions only the LOCAL NUMA node's
    # pool, so the default allocator ABORTS as soon as the process is given a
    # non-local memory policy. Genuinely one or the other.
    #   The 2.4x page-size penalty that makes huge pages look attractive here
    # was measured single-threaded on an idle node, and is explicitly NOT
    # measured under memory load from co-resident threads. At 112 threads the
    # memory system is saturated and latency is queueing-dominated -- the
    # regime where a TLB-reach number does not transfer, and where that same
    # curve has already been observed to invert when applied outside it.
    #   Asymmetry decides it either way: misjudging page size costs tens of
    # percent, misjudging NUMA placement costs 4x.
    #
    # `numactl -i` sets memory policy only. It does not touch CPU affinity, so
    # it does not fight Slurm's binding or OMP_PLACES.
    #--------------------------------------------------------------------------
    local NUMA=(numactl --interleave=all)
    if ! command -v numactl >/dev/null 2>&1; then
        echo "WARNING: numactl not found -- running WITHOUT interleave." >&2
        echo "         Expect roughly a quarter of the lookup rate: all grid" >&2
        echo "         data will sit in a single NUMA domain." >&2
        NUMA=()
    fi

    #--------------------------------------------------------------------------
    # THE RUN.
    # -t is XSBench's thread count (feeds omp_set_num_threads); it does not
    # change the work. -m/-s/-G/-p/-l are the fixed problem, verbatim.
    # Expect 1-2 minutes of SERIAL, un-timed initialization first (nuclide grid
    # + qsort of the 4,012,565-point unionized grid + generation of the 5.7 GB
    # index grid). That is not in the reported figure, but it is inside the 15
    # minutes -- the whole job lands far under the limit.
    #--------------------------------------------------------------------------
    srun -N 1 -n 1 -c "$THREADS" \
         --threads-per-core="$TPC" \
         --cpu-bind=verbose,threads \
         "${NUMA[@]}" ./XSBench -m history -s large -G unionized \
                                -p 500000 -l 34 -t "$THREADS"

    #--------------------------------------------------------------------------
    # WHAT TO REPORT -- from the RESULTS block XSBench prints:
    #     Runtime:     <x.xxx> seconds
    #     Lookups/s:   <n>
    # and check the line just above them:
    #     Verification checksum: 954318 (Valid)
    # 954318 is the fixed expected value for history + large (io.c:98) and does
    # not depend on thread count. If it says INVALID, the rate is not
    # comparable to anything -- say so instead of reporting it.
    #--------------------------------------------------------------------------
}

#==============================================================================
case "${1:-}" in
    build) build ;;
    run)   run   ;;
    *)     echo "usage: bash $0 {build|run}" >&2; exit 1 ;;
esac
