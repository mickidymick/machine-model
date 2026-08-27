#!/bin/bash
# =============================================================================
# LULESH 2.0 on Frontier -- 1 node, 300^3 elements, 50 iterations, -r 11 -b 0 -c 64
#
#   bash SOLUTION.sh build     # module loads + compile
#   bash SOLUTION.sh run       # the single srun line (run inside a 1-node alloc)
#
# Expected job allocation (given by the problem statement):
#   salloc -A <proj> -N 1 -t 15 --threads-per-core=2
#
# -----------------------------------------------------------------------------
# THE CONFIGURATION, AND WHY
# -----------------------------------------------------------------------------
# Decision            Choice                     Reason
# ------------------  -------------------------  ---------------------------------
# decomposition       8 ranks x 14 threads       see (1),(2)
#                     (-n 8, -s 150)
# SMT                 --threads-per-core=2       see (3)
# huge pages          NOT loaded                 see (4)
# compiler            PrgEnv-gnu (CC/g++)        see (5)
# force-path in src   accepted (~10-15% cost)    see (2)
#
# (1) WHERE THE TIME ACTUALLY GOES -- read ApplyMaterialPropertiesForElems()
#     (lulesh.cc:2387) before anything else.  With -r 11 -c 64 the per-region
#     repeat count `rep` is 1 for regions 0-4, 1+cost=65 for regions 5-9, and
#     10*(1+cost)=650 for region 10.  With -b 0 the regions are equal-sized, so
#     the EOS work per cycle is (numElem/11)*(5*1 + 5*65 + 1*650) = 89.1*numElem
#     element-updates, against roughly 1*numElem for everything else.
#     >>> ~85-90% of this run is EvalEOSForElems/CalcEnergyForElems. <<<
#     That kernel is unit-stride over ~15 temporary arrays of numElemReg doubles
#     that are re-read `rep` times, i.e. it is cache-resident FP work, not a
#     DRAM streaming kernel.  Per element per rep it issues 6 divides and
#     3 sqrts -- it is bound by the FP divide/sqrt unit, not by memory bandwidth.
#     Every choice below follows from that one fact.
#
# (2) WHY 8 RANKS x 14 THREADS AND NOT 64 PURE-MPI RANKS.
#     LULESH requires a perfect-cube rank count, so on one node the candidates
#     are 8, 27 or 64.  The node has only 56 usable cores (one core per L3 group
#     is OS-reserved: 0,8,...,56), so:
#       - 27 ranks pure MPI leaves 29 of 56 cores idle;
#       - 64 ranks pure MPI cannot be balanced on 56 cores -- 8 cores must carry
#         two ranks each.  LULESH is bulk-synchronous (allreduce + halo every
#         cycle), so the doubled cores set the critical path: those ranks run at
#         0.5-0.85x, giving 32-54 core-equivalents instead of 56.  That is the
#         1.3-1.75x this configuration avoids.
#     8 ranks is also the only cube that maps exactly onto the hardware: one
#     rank per L3 group (7 usable cores each), two ranks per NUMA domain.  That
#     matters because Domain's constructor first-touches every array SERIALLY
#     (lulesh-init.cc:159) -- a rank's whole heap lands in its master thread's
#     NUMA domain, which is correct here and would be catastrophic for a single
#     56-thread rank.
#     Cost paid: with omp_get_max_threads()>1, IntegrateStressForElems
#     (lulesh.cc:514) and CalcFBHourglassForceForElems switch to per-element
#     force scratch arrays (3 x numElem*8 doubles, written then gathered back),
#     ~768 extra bytes/element/cycle.  With -c 64 the force kernels are only
#     ~11% of the run, so this costs ~10%, which is much less than the 1.3-1.75x
#     that 64 imbalanced ranks would cost.  (Without -c 64 the trade would flip.)
#     Second-order confirmation: CreateRegionIndexSets uses srand(myRank), so
#     region sizes differ per rank; the spread on region 10 (rep=650, 2/3 of all
#     work) is ~5% of the mean at 8 ranks but ~15% at 64 ranks, and the slowest
#     rank sets the pace.
#
# (3) SMT: 2 THREADS PER CORE, REQUESTED EXPLICITLY.
#     The rule from the machine characterisation is latency-bound vs
#     throughput-saturated, not memory vs compute: the dependent-chase and
#     dependent-FMA kernels gain +70/+78% from the second hardware thread; only
#     the bandwidth-saturated stream kernel loses (-5%).  The dominant kernel
#     here (1) is a cache-resident chain of divides and sqrts with a
#     semi-irregular regElemList gather in front of it -- FP-latency shaped, not
#     bandwidth-saturated.  Upside is large, the measured downside is 5%.
#     8 x 14 = 112 threads = all allocatable hardware threads, perfectly
#     balanced across all 56 cores; nothing is left idle and nothing is doubled.
#
# (4) NO HUGE PAGES.  craype-hugepages2M is deliberately NOT loaded.  The 2.4x
#     page-size penalty only exists where the working set exceeds TLB reach AND
#     the access pattern defeats prefetch.  LULESH sweeps element and node
#     arrays contiguously, and the hot EOS loops are unit-stride over cached
#     temporaries, so the mechanism is absent; the one measured attempt to apply
#     that number to a streaming kernel on this machine cost 2.7%.  It also
#     avoids the linker conflict with non-GNU-ld toolchains.
#
# (5) PrgEnv-gnu.  Verified-good toolchain here; PrgEnv-cray silently drops
#     -fopenmp in some project layouts, which would cost the full thread count.
#     We bypass CMake and the shipped Makefile's hardcoded 'mpig++' entirely and
#     drive the Cray CC wrapper directly, so none of the CMake failure modes
#     (MPI off by default, CMAKE_SYSTEM_NAME, FindMPI) can apply.
#     Flag notes:
#       -march=znver3        EPYC 7A53 (Trento) is Zen3.  Named explicitly, not
#                            -march=native, so a login-node build is valid.
#       -fno-math-errno      lets sqrt() become vsqrtpd instead of a libm call;
#                            without it the sqrt-carrying EOS loops cannot
#                            vectorise at all.
#       -freciprocal-math    hoists 1/rho0 out of three of the six divides per
#                            element per rep.  Divide throughput is the
#                            bottleneck in (1), so this is worth real time.
#       --param vect-max-version-for-alias-checks=200
#                            CalcEnergyForElems' hot loops carry 11-13 distinct
#                            Real_t* arguments; GCC's default cap of 10 runtime
#                            alias checks makes it refuse to vectorise exactly
#                            the loops that hold every sqrt.  Raising the cap is
#                            numerically inert.
#     Full -ffast-math is deliberately NOT used: -ffinite-math-only would put
#     the inf-producing guard in CalcCourantConstraintForElems on undefined
#     ground, and the timestep is off limits.
# =============================================================================

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/src"
EXE="${SRC_DIR}/lulesh2.0"

build() {
    source /usr/share/lmod/lmod/init/bash 2>/dev/null || true
    module reset
    module load PrgEnv-gnu
    module load craype-x86-trento          # Zen3 target (Frontier default)
    # NOTE: craype-hugepages* intentionally NOT loaded -- see (4).
    module list 2>&1 || true
    CC --version

    cd "${SRC_DIR}"
    rm -f *.o "${EXE}"

    CXXFLAGS="-DUSE_MPI=1 -I. -O3 -march=znver3 -mtune=znver3 -fopenmp \
-fno-math-errno -fno-trapping-math -fno-signed-zeros -freciprocal-math \
-ffp-contract=fast -funroll-loops \
--param vect-max-version-for-alias-checks=200"
    LDFLAGS="-O3 -fopenmp"

    for f in lulesh.cc lulesh-comm.cc lulesh-viz.cc lulesh-util.cc lulesh-init.cc; do
        CC -c ${CXXFLAGS} -o "${f%.cc}.o" "${f}" &
    done
    wait

    CC lulesh.o lulesh-comm.o lulesh-viz.o lulesh-util.o lulesh-init.o \
       ${LDFLAGS} -lm -o "${EXE}"

    echo "built: ${EXE}"
}

run() {
    source /usr/share/lmod/lmod/init/bash 2>/dev/null || true
    module reset
    module load PrgEnv-gnu
    module load craype-x86-trento

    # 8 ranks x 14 threads, one rank per L3 group, both hardware threads per core.
    # Frontier logical CPU n and n+64 are the two hardware threads of core n;
    # cores 0,8,16,...,56 are OS-reserved, so rank i owns cores 8i+1..8i+7,
    # i.e. CPUs {8i+1..8i+7} U {64+8i+1..64+8i+7}  ->  0xFE<<8i in both halves.
    MASKS="0x00000000000000FE00000000000000FE"
    MASKS+=",0x000000000000FE00000000000000FE00"
    MASKS+=",0x0000000000FE00000000000000FE0000"
    MASKS+=",0x00000000FE00000000000000FE000000"
    MASKS+=",0x000000FE00000000000000FE00000000"
    MASKS+=",0x0000FE00000000000000FE0000000000"
    MASKS+=",0x00FE00000000000000FE000000000000"
    MASKS+=",0xFE00000000000000FE00000000000000"

    export OMP_NUM_THREADS=14
    export OMP_PLACES=threads          # place on hardware threads, in mask order
    export OMP_PROC_BIND=close         # thread t -> place t within the rank's mask
    export OMP_WAIT_POLICY=ACTIVE      # ~14k fork/joins per cycle in the EOS rep
                                       # loop; futex sleeps there would be costly
    export OMP_DYNAMIC=false
    export OMP_MAX_ACTIVE_LEVELS=1

    srun -N 1 -n 8 -c 14 --threads-per-core=2 \
         --cpu-bind=verbose,mask_cpu:"${MASKS}" \
         --distribution=block:block \
         "${EXE}" -s 150 -i 50 -r 11 -b 0 -c 64
    #        ^ 8 ranks x 150^3 = 300^3 = 27,000,000 elements globally
}

case "${1:-}" in
    build) build ;;
    run)   run ;;
    *)     echo "usage: bash $0 {build|run}" >&2; exit 2 ;;
esac
