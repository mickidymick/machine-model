#!/bin/bash
#SBATCH -J amg_frontier
#SBATCH -N 4
#SBATCH -t 00:15:00
#SBATCH -p batch
#SBATCH -o amg_frontier.%j.out
#
# ============================================================================
#  AMG (ECP proxy, hypre BoomerAMG-GMRES) on OLCF Frontier -- 4 nodes
# ============================================================================
#
#  USAGE
#    On a login node:   ./SOLUTION.sh build          # compiles (~2 min)
#    Then:              export SBATCH_ACCOUNT=<your_project>
#                       sbatch SOLUTION.sh           # runs (calls run())
#
#    Bare `./SOLUTION.sh` on a login node = build only, then tells you to
#    submit.  Inside a Slurm allocation it runs.  `./SOLUTION.sh build` and
#    `./SOLUTION.sh run` also work explicitly.
#    (No `#SBATCH -A` line above on purpose: set SBATCH_ACCOUNT or pass
#     `sbatch -A <project> SOLUTION.sh`.)
#
#  THE CONFIGURATION, IN ONE LINE
#    Flat MPI, 56 ranks/node x 4 nodes = 224 ranks, one rank per allocatable
#    physical core, 32-bit indices, 2 MiB huge pages, NIC chosen per NUMA
#    domain.  No OpenMP.
#
#  WHY (the reasoning behind every committed choice)
#
#  1. 224 ranks, -P 8 7 4, and why that pins the workload.
#     In this driver `-n` is the PER-RANK block, not the global grid
#     (src/src/test/amg.c:704 -- nx_global = P*nx).  So total work is
#     224 * 128^3 = 4.70e8 unknowns on a 1024 x 896 x 512 grid, and the work
#     done is set by the RANK COUNT, not by -n.  I therefore fix the rank
#     count and the topology and tune everything else; shrinking the rank
#     count would "speed up" the run only by solving a smaller problem, which
#     is exactly what the fixed-work constraint forbids.  8x7x4 is the
#     near-cubic factorization of 224 (aspect 2 : 1.75 : 1), which minimizes
#     ghost-surface per rank; a default -P would give a 1x224x1 slab and a
#     pathologically anisotropic global domain.
#
#  2. 56 ranks/node, not 64.  Frontier runs in low-noise mode with Slurm core
#     specialization (-S 8) applied at allocation time, reserving the first
#     core of each of the 8 L3 regions -> 56 allocatable cores/node.  Asking
#     for 64 oversubscribes onto reserved cores and adds OS jitter, which in
#     a bulk-synchronous multigrid V-cycle costs every rank the slowest
#     rank's delay at every level.
#
#  3. Flat MPI, no OpenMP.  hypre's OpenMP is coarse-grained `parallel for`
#     over rows; its thread scaling inside BoomerAMG is well below its MPI
#     scaling, and threads spanning a 16-core NUMA domain rely on first-touch
#     that the AMG setup phase does not reliably preserve across the
#     hierarchy.  One rank per core gives NUMA-local memory by construction
#     with no numactl, no OMP_PLACES, and no first-touch assumptions.  This
#     also lets me drop -DHYPRE_HOPSCOTCH, which the README documents as an
#     OpenMP-only optimization.
#
#  4. Dropping -DHYPRE_BIGINT -- the single biggest lever here.  In this
#     vintage of hypre, HYPRE_BIGINT makes EVERY HYPRE_Int a `long long`
#     (src/src/HYPRE.h:37), not just global indices: all CSR row pointers and
#     column indices double in width.  This problem needs 4.70e8 global rows,
#     4.6x under the 2^31-1 limit, so 32-bit indices are safe and cut the
#     integer half of the matrix traffic in half.  For a latency/bandwidth
#     bound sparse solve (see 5) that is the largest single-flag win
#     available, and it changes no arithmetic: same matrices, same iteration
#     count, same residual.
#     Verified overflow-safe: global nnz (~1.3e10) DOES exceed int32, but it
#     is only accumulated into a HYPRE_Int at par_amg_solve.c:308, reachable
#     only when amg_print_level > 1, and this driver leaves poutdat = 0
#     (amg.c:162).  The FOM path uses the HYPRE_Real DNumNonzeros field
#     instead, so the printed FOM stays correct.
#     >>> If you ever raise the rank count past ~1000 (>2^31 unknowns), set
#     >>> BIGINT=1 below.  At 224 ranks it must stay 0.
#
#  5. craype-hugepages2M, loaded at BOTH link and run time.  PROBLEM.md's
#     "tens of MiB per thread, irregular access" is the decisive detail: the
#     level-0 vectors alone are ~17 MB per rank, so the hot set overflows the
#     32 MB L3 shared by the CCD and every access is a DRAM round trip whose
#     address must be translated.  Zen 3's L2 TLB covers only ~8 MB with 4 KB
#     pages, so the run is TLB-thrashing, not cache-blocking-limited.  2 MiB
#     pages cover the same footprint in ~1/500th the entries.  I chose 2M
#     over 8M/64M because the larger pools fragment and can fail to back the
#     heap at 56 ranks/node.  This is also why there is no cache-blocking or
#     "reduce ranks to save bandwidth" tuning here -- the code is not a
#     streaming kernel and neither would help.
#
#  6. MPICH_OFI_NIC_POLICY=NUMA.  Frontier has 4 Slingshot NICs, one per NUMA
#     domain; HPE documents NUMA policy as the right setting for CPU-only
#     applications, so each rank uses the NIC attached to its own domain
#     rather than contending on a single NIC.
#
#  7. -DHYPRE_USING_PERSISTENT_COMM kept: persistent neighbor exchanges, which
#     is what the 26-neighbor halo of a 27-point stencil wants.  -O3 with
#     -march=znver3 (EPYC 7A53 "Trento" is Zen 3).  No -ffast-math: it could
#     perturb the Krylov convergence and hence the iteration count, which the
#     problem statement fixes.
#
#  8. Budget.  4 nodes x 15 min wall = 60 node-minutes exactly, so -t is set
#     to the full budget rather than something shorter -- a job killed at the
#     wall clock spends the allocation and returns nothing.  Estimated solve
#     is several minutes at this size, so this should land comfortably.
#
#  WHAT I DELIBERATELY IGNORED
#    src/working/ and src/vpage_llc_misses.out contain profiling from a
#    different machine and a different problem: a single 30-thread OpenMP
#    process on a 2-tier (Intel PCM, tier_1/tier_2) memory testbed at
#    -n 300 300 300, launched under `numactl -C 0-29 --preferred 0`.  None of
#    it transfers to a 4-node AMD/Slingshot flat-MPI run -- in particular the
#    `--preferred 0` NUMA pinning and the tiering knobs would be actively
#    harmful here.  The one signal I did take from it is corroborating: 86M
#    minor page faults at 4 KB, which is the TLB pressure that item 5
#    addresses.  The prebuilt src/exe is from that machine; it is left
#    untouched and unused.
# ============================================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${ROOT}/src/src"
AMG="${ROOT}/src/amg.frontier"      # built binary (src/exe left untouched)

BIGINT=0                            # see reasoning item 4 -- keep 0 at 224 ranks

# --- launch geometry (see reasoning items 1 and 2) ---------------------------
NODES=4
RANKS_PER_NODE=56
RANKS=$(( NODES * RANKS_PER_NODE ))  # 224
PX=8; PY=7; PZ=4                     # PX*PY*PZ must equal RANKS
NX=128; NY=128; NZ=128               # fixed by PROBLEM.md -- do not change

load_modules() {
    module reset
    module load PrgEnv-amd           # AMD clang: vendor compiler for Trento
    module load craype-x86-trento    # correct wrapper target for the EPYC 7A53
    # Huge pages must be present at link time AND run time (reasoning item 5).
    if ! module load craype-hugepages2M; then
        echo "WARNING: craype-hugepages2M unavailable -- continuing on 4 KB" \
             "pages; expect a slower solve." >&2
    fi
    module list 2>&1 || true
}

build() {
    load_modules

    local cflags="-O3 -march=znver3 -DTIMER_USE_MPI -DHYPRE_USING_PERSISTENT_COMM"
    if [ "${BIGINT}" -eq 1 ]; then
        cflags="${cflags} -DHYPRE_BIGINT"
    fi

    cp -n "${SRC}/Makefile.include" "${SRC}/Makefile.include.orig" || true
    cat > "${SRC}/Makefile.include" <<EOF
# Generated by SOLUTION.sh for OLCF Frontier (original: Makefile.include.orig)
# cc = Cray compiler wrapper; it supplies Cray MPICH, so no mpicc needed.
CC = cc
INCLUDE_CFLAGS = ${cflags}
INCLUDE_LFLAGS = -lm
EOF

    # The top-level Makefile walks HYPRE_DIRS in dependency order; parallelize
    # within each directory, not across them.
    cd "${SRC}"
    make clean
    for d in utilities krylov IJ_mv parcsr_ls parcsr_mv seq_mv test; do
        echo "=== building ${d} ==="
        make -C "${d}" -j 16
    done
    cp "${SRC}/test/amg" "${AMG}"
    echo "built: ${AMG}"
}

run() {
    load_modules                       # re-establishes HUGETLB_* for the run

    export MPICH_OFI_NIC_POLICY=NUMA   # NIC local to each rank's NUMA domain
    export MPICH_SMP_SINGLE_COPY_MODE=XPMEM  # zero-copy for the 56 on-node peers
    export OMP_NUM_THREADS=1           # no-op for this build; guards against
                                       # any stray OMP runtime pulled in by cc

    # One srun. --threads-per-core=1 keeps SMT off (a second thread per core
    # would only add TLB and L2 pressure to a latency-bound kernel);
    # block:block:block puts consecutive ranks -- which are x-neighbors, since
    # px = myid % P (amg.c:722) -- on adjacent cores and thus in a shared L3.
    srun -N "${NODES}" -n "${RANKS}" \
         --ntasks-per-node="${RANKS_PER_NODE}" \
         --cpus-per-task=1 --threads-per-core=1 \
         --cpu-bind=cores --distribution=block:block:block \
         "${AMG}" -problem 2 -n ${NX} ${NY} ${NZ} -P ${PX} ${PY} ${PZ} \
         2>&1 | tee "${ROOT}/amg_frontier.log"

    echo "--- solve time (the number PROBLEM.md asks for) ---"
    grep -A3 "GMRES Solve" "${ROOT}/amg_frontier.log" || true
    grep -E "Figure of Merit|Cum. No. of Iterations|Final Relative Residual" \
         "${ROOT}/amg_frontier.log" || true
}

# --- dispatcher --------------------------------------------------------------
if [ $# -gt 0 ]; then
    "$@"
elif [ -n "${SLURM_JOB_ID:-}" ]; then
    run
else
    build
    echo
    echo "Build complete.  Now:  export SBATCH_ACCOUNT=<your_project>"
    echo "                       sbatch ${BASH_SOURCE[0]}"
fi
