#!/bin/bash
# =============================================================================
# AMG (ECP proxy, hypre-based) on Frontier -- build + run recipe
#
# Usage:   ./SOLUTION.sh build      # on a login node (or inside the alloc)
#          ./SOLUTION.sh run        # from INSIDE an allocation of >= 4 nodes
#          ./SOLUTION.sh            # does both (this is what sbatch will do)
#
#   sbatch -A <project> -N 4 -t 00:15:00 -p batch ./SOLUTION.sh
#
# -----------------------------------------------------------------------------
# THE ONE THING TO READ BEFORE RUNNING THIS
#
# In this code `-n` is the grid PER MPI RANK, not the global grid
# (src/src/test/amg.c:679 -- "problem size per MPI process", and the global
# domain is nx*P x ny*Q x nz*R). So the rank count IS the problem size: 32 ranks
# do exactly twice the work of 16, not the same work twice as fast. There is no
# configuration of this benchmark in which the total work is invariant to the
# launch geometry, so I had to pin the rank count and then optimise everything
# else around it.
#
# I pinned it at 16 ranks = 4 nodes x 4 ranks (global 512 x 256 x 256, 33.5M
# unknowns), because that fills the 4-node ceiling you gave me and puts exactly
# one rank on each NUMA domain of each node. Every per-rank block is 128^3 as
# specified. If your intended baseline used a different rank count, change ONLY
# the -N/-n/-P numbers in run() -- the rest of the recipe is unaffected.
#
# -----------------------------------------------------------------------------
# THE CONFIGURATION, AND WHY
#
# 1. 2 MiB pages, linked in at build time.  Biggest single lever, and it is a
#    BUILD decision, not a runtime flag. On this machine THP is `never` and the
#    hugetlb pool is empty (Total 4 / Free 0), so madvise and THP both fail
#    silently -- the allocation succeeds and you get 4K backing anyway.
#    craype-hugepages2M works by relinking the binary, so it must be loaded
#    before make, not before srun. This matters here more than for most codes:
#    the per-thread working set is tens of MiB, which is exactly the band where
#    the measured 4K page penalty peaks (32 MB working set: 32.2 ns on 4K vs
#    13.1 ns on huge, 2.4x -- still inside L3, every access paying a page walk
#    that itself misses to memory). Aggregated per rank the footprint lands in
#    the 64 MB-1 GB band instead, where the penalty is a flatter 9-14 ns on
#    58-89 ns (~15%). I do not know which of those two regimes your per-thread
#    footprint really sits in, so the honest expectation is "somewhere between
#    15% and 2.4x off the memory latency", not a single number.
#
# 2. 4 ranks/node, one per NUMA domain, 14 cores each.  56 usable cores per
#    node, not 64: one core per L3 group is OS-reserved (0,8,16,24,32,40,48,56),
#    hwloc reports 112 allowed PUs of 128, and `-c 64` is rejected outright.
#    56/4 = 14 cores per NUMA domain, which is why this geometry is the one that
#    divides cleanly. Putting a whole rank inside one domain means first-touch
#    keeps every thread's data local and the measured near/mid/far crossing
#    tiers (107.9 / 115.8 / 119.2 ns against 101.5 local -- the ACPI SLIT claims
#    a flat 12 for all of them and is wrong) never appear on the intra-rank
#    path at all. A 1-rank/node 56-thread layout would spread one rank's heap
#    across all four domains and pay those crossings on an irregular access
#    pattern that cannot prefetch around them.
#
# 3. -c 14 also unlocks MPICH_OFI_NIC_POLICY=NUMA.  Cray MPICH refuses that
#    policy unless each rank is confined to a single NUMA domain. With it, the
#    4 ranks land on the 4 Slingshot NICs (hsn0->NUMA3, hsn1->NUMA1,
#    hsn2->NUMA0, hsn3->NUMA2 -- one per domain). One rank per node crosses one
#    NIC and reads ~22.6 GB/s; four ranks reach 90.3 GB/s, and the scaling to
#    that point is linear (1.00 / 1.99 / 3.98).
#
# 4. 14 threads/rank, one per physical core, SMT off.  Coin-flip against 28
#    threads on 14 cores; I would run 14. The solver is latency-bound with a
#    per-thread working set in the tens of MiB, so SMT siblings would halve the
#    effective L2 (512 KB/core) and share L1 for work that is already cache-
#    resident-ish, and the loaded-latency curve says the domain reaches 98.3% of
#    peak bandwidth at 234 ns vs 832 ns at saturation -- there is no throughput
#    left for extra threads to buy, only latency to lose. To test the other
#    side: OMP_NUM_THREADS=28, OMP_PLACES=threads, `-c 28 --threads-per-core=2`.
#
# 5. 32-bit indices (dropped -DHYPRE_BIGINT).  In this vintage of hypre
#    HYPRE_BIGINT retypes *every* HYPRE_Int to long long (HYPRE.h:36), so it
#    doubles the column-index array of every CSR matrix: 8B value + 8B index
#    becomes 8B + 4B, ~25% less traffic on the dominant data structure of a
#    memory-bound sparse solve. Safe here with room to spare: 33.5M unknowns
#    and ~905M fine-grid nonzeros against a 2.1B ceiling. If you raise the rank
#    count past ~32, re-check that headroom before keeping this off.
#
# 6. -O3 but NOT -Ofast/-ffast-math.  Problem 2 runs six time steps, and the
#    first solve of each step is convergence-based (tol 1e-8, amg.c:116), not a
#    fixed iteration count -- only the four trailing solves are fixed at 6/5/4/3
#    iterations. Reassociating that arithmetic can change the iteration count,
#    which would change the work done and break the comparison you asked me to
#    protect. -fno-math-errno is kept: it is free and changes no results.
#
# 7. No GPUs.  This tree has no HIP/CUDA path at all (only a stray "device" in
#    an ams.c comment), so all 8 GCDs sit idle no matter what I do. Nothing in
#    the accelerator half of the machine briefing -- XGMI weights, HBM latency,
#    die parity, --gpu-bind -- applies to this code. Not requesting them.
#
# 8. No numactl.  Deliberate. Once the binary is linked against
#    craype-hugepages2M, the default allocator ABORTS under a remote
#    `numactl -m`, because the module provisions only the local node's pool.
#    srun's --cpu-bind plus default first-touch already gives local placement
#    here, so numactl would add a failure mode and buy nothing.
#
# WHAT I DID NOT ACT ON
#   - NUMA 0 hosts the management NIC, both NVMe controllers and dma0chan0,
#     which no other domain has, so it plausibly carries extra interrupt and DMA
#     traffic. That is filed as untested in the briefing, and dodging NUMA 0
#     would cost a quarter of the node's cores against an unmeasured effect.
#     Using all four domains.
#   - The 3->2 directional asymmetry (medium confidence) and the GPU/NUMA
#     affinity map (unverified) do not touch this configuration either way.
#
# BUDGET: 4 nodes x ~15 min wall = ~60 node-minutes, and I expect the job to
# need well under that -- setup plus six time steps at 2.1M unknowns/rank on 14
# cores should land in single-digit minutes. The -t 00:15:00 above is the cap
# that keeps one bad run from eating the whole allocation.
# =============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${ROOT}/src/src"
EXE="${ROOT}/amg"

# Order matters: this is the same dependency order the top-level Makefile uses.
HYPRE_DIRS="utilities krylov IJ_mv parcsr_ls parcsr_mv seq_mv test"

# -DHYPRE_USING_OPENMP  : threaded solve (this is what the 14 threads run)
# -DHYPRE_HOPSCOTCH     : lock-free hash for the threaded matrix assembly
# -DHYPRE_USING_PERSISTENT_COMM : persistent halo exchanges, set up once
# -DTIMER_USE_MPI       : MPI_Wtime for the timing this benchmark reports
# (no -DHYPRE_BIGINT -- see note 5 above)
AMG_CFLAGS="-O3 -march=znver3 -mtune=znver3 -fno-math-errno -fopenmp \
-DTIMER_USE_MPI -DHYPRE_USING_OPENMP -DHYPRE_HOPSCOTCH -DHYPRE_USING_PERSISTENT_COMM"
AMG_LFLAGS="-lm -fopenmp"

load_modules() {
    source /usr/share/lmod/lmod/init/bash 2>/dev/null || true
    module reset
    module load PrgEnv-gnu          # gcc via the cc wrapper; hypre builds clean with it
    module load craype-x86-trento   # compute nodes are EPYC 7A53 (login is 7763; both Zen3)
    module load craype-hugepages2M  # MUST be loaded for the build -- it relinks the binary
    module list 2>&1
}

build() {
    load_modules

    # Wipe the shipped objects/libs: they were built with -O2 and BIGINT, and a
    # stale .a here would silently link the slow indices back in.
    make -C "${SRC}" veryclean

    # CC=cc uses the Cray wrapper (replaces the mpicc in Makefile.include and
    # pulls in cray-mpich + the hugepage link line). Command-line vars override
    # the assignments in Makefile.include and propagate to each sub-make.
    for d in ${HYPRE_DIRS}; do
        make -C "${SRC}/${d}" -j 32 \
            CC=cc \
            INCLUDE_CFLAGS="${AMG_CFLAGS}" \
            INCLUDE_LFLAGS="${AMG_LFLAGS}"
    done

    cp "${SRC}/test/amg" "${EXE}"
    echo "built: ${EXE}"
    # Confirms the hugepage relink actually happened -- expect libhugetlbfs here.
    ldd "${EXE}" | grep -i hugetlb || echo "NOTE: no libhugetlbfs in ldd output"
}

run() {
    load_modules

    # --- placement ---------------------------------------------------------
    export OMP_NUM_THREADS=14
    export OMP_PLACES=cores
    export OMP_PROC_BIND=close
    export OMP_WAIT_POLICY=ACTIVE   # spin at barriers; AMG has many short regions
    export OMP_DYNAMIC=false

    # --- network -----------------------------------------------------------
    export MPICH_OFI_NIC_POLICY=NUMA   # legal only because each rank is -c 14
    export MPICH_GPU_SUPPORT_ENABLED=0 # no device buffers in this code

    # --- huge pages --------------------------------------------------------
    # The failure mode here is silence: allocation succeeds, backing is 4K, and
    # the only symptom is a slow run. VERBOSE=2 makes libhugetlbfs say so on
    # stderr at startup. Costs nothing during the solve.
    export HUGETLB_VERBOSE=2

    # 16 ranks: 4 nodes x 4 ranks, one rank per NUMA domain, 14 physical cores
    # each. --threads-per-core=1 is what makes -c 14 mean 14 cores rather than
    # 14 hardware threads (SMT is on). block:block walks the allowed CPUs in
    # order, so rank i lands on domain i. cpu-bind=verbose prints the mask per
    # rank at launch -- placement is the thing most likely to go wrong quietly.
    # -P 4 2 2 keeps the global domain compact; the default topology for 16
    # ranks is 1x16x1, a pencil whose halo surface and coarse-grid coupling are
    # far worse for identical per-rank work. Per-rank block is 128^3 either way.
    # Add -printstats if you want the per-step GMRES iteration counts to confirm
    # the work done; it puts a few dozen printfs inside the timed region.
    srun -N 4 -n 16 --ntasks-per-node=4 \
         -c 14 --threads-per-core=1 \
         --cpu-bind=verbose,cores --distribution=block:block \
         "${EXE}" -problem 2 -n 128 128 128 -P 4 2 2

    # Report the line: "Problem 2: Cumulative AMG-GMRES Solve Time"
    # (wall clock, printed by AMG itself; FOM_2 follows it).
}

case "${1:-all}" in
    build) build ;;
    run)   run ;;
    all)   build; run ;;
    *)     echo "usage: $0 [build|run]" >&2; exit 1 ;;
esac
