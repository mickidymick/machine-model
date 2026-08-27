#!/bin/bash
# =============================================================================
# LULESH 2.0 on ONE Frontier node -- 300^3 elements, -i 50 -r 11 -b 0 -c 64
#
#   bash SOLUTION.sh build     # module loads + compile
#   bash SOLUTION.sh run       # the single srun line
#
# -----------------------------------------------------------------------------
# WHY THIS CONFIGURATION (read the source first, then the machine)
#
# 1. WHAT ACTUALLY COSTS TIME.  `-c 64` is not a small perturbation.  In
#    ApplyMaterialPropertiesForElems (lulesh.cc:2387) the per-region repeat
#    count is  rep = 1 (regions 0-4), 1+cost = 65 (regions 5-9), 10*(1+cost)
#    = 650 (region 10).  With -r 11 -b 0 the eleven regions are equal-sized, so
#    per cycle the EOS is executed (5*1 + 5*65 + 1*650)/11 = 89.1 times per
#    element instead of once.  Everything else in the cycle -- kinematics,
#    hourglass, Q, force -- runs once.  EOS is therefore ~85-90% of the run,
#    and every other decision has to be judged by what it does to EvalEOSForElems.
#
# 2. THAT LOOP IS MEMORY BOUND, NOT COMPUTE BOUND.  One rep sweeps ~15 arrays
#    of the region (e_old, delvc, p_old, q_old, compression, compHalfStep,
#    qq_old, ql_old, work, p_new, e_new, q_new, bvc, pbvc, pHalfStep = 120 B
#    per element) with ~10 separate passes, plus indirect reads of the domain
#    arrays through regElemList.  The live set is a whole region: 27e6/11 =
#    2.45e6 elements * ~120 B = ~295 MB of temporaries alone, against 256 MB of
#    total L3 (8 x 32 MB), and that number does NOT depend on the decomposition
#    -- every rank is in the same region index at the same time.  Arithmetic is
#    ~15 core-cycles/element/rep, i.e. ~16 s of compute for the whole run on 56
#    cores, against hundreds of seconds of DRAM traffic at the node's ~178 GB/s.
#    Consequences used below: (a) the memory system, not the core count, sets
#    the pace; (b) the kernel is BANDWIDTH-saturated, not latency-bound.
#
# 3. DECOMPOSITION: 8 ranks x 7 threads, -s 150.  The rank count must be a
#    perfect cube whose cube root divides 300, and the node has 56 usable cores
#    (one core per L3 is OS-reserved; `-c 56` is the hard ceiling).  64 ranks
#    therefore does not fit 1-per-core, and 27x2 does not tile 8 L3 groups of 7
#    (some rank would straddle two L3s / two NUMA domains and pace the whole
#    bulk-synchronous cycle).  8 ranks x 7 threads is the only clean, exactly
#    balanced way to use all 56 cores: one rank per L3 group, hence one rank per
#    NUMA domain half, so LULESH's *serial* first-touch in the Domain
#    constructor puts every rank's mesh in its own local NUMA domain.
#
# 4. THE COST OF GOING HYBRID IS SMALL HERE, AND WORTH PAYING.  With
#    omp_get_max_threads() > 1, IntegrateStressForElems (lulesh.cc:513) and
#    CalcFBHourglassForceForElems (lulesh.cc:735) switch to the
#    per-element-corner buffers + node-gather path instead of scattering
#    straight into domain.fx/fy/fz.  That is the classic reason flat MPI beats
#    MPI+OpenMP in LULESH -- but it costs ~1 TB of extra traffic over the whole
#    run (~6 s), i.e. a couple of percent, precisely BECAUSE -c 64 has made EOS
#    dominant.  Paying ~2% to keep all 56 cores fed (rather than 27 with flat
#    MPI at -n 27 -s 100) is the right side of that trade: it is a wash if the
#    run is fully bandwidth-limited and close to 2x if the region temporaries
#    get partial L3 reuse.
#
# 5. SMT: ONE HARDWARE THREAD PER CORE, STATED EXPLICITLY.  The allocation
#    exposes 2/core; this step asks for 1.  Measured on this node, the second
#    hardware thread is worth +70..78% to latency-bound kernels and -5.0% to a
#    bandwidth-saturated one.  Per (2) this loop is the bandwidth-saturated
#    case: its iterations are independent, prefetch-friendly streams, so one
#    thread already keeps the core's misses outstanding.  112 threads would also
#    halve each thread's slice and double the OpenMP barrier count
#    (~590k parallel regions per run).  Hence --threads-per-core=1.
#
# 6. NO HUGE PAGES.  craype-hugepages2M is the only thing that actually gets 2 MB
#    pages here (THP is off, hugetlb pool empty), but its measured 2.4x win is
#    for pointer-chasing at TLB-reach, and on a STREAMING kernel it was measured
#    on this machine to invert and cost 2.7%.  This kernel streams.  Skipping it
#    also avoids the craype-hugepages/PrgEnv-amd lld link conflict entirely.
#
# 7. GCC, not CCE/AMD.  Being memory bound, the compiler is nearly free to
#    choose; PrgEnv-gnu is the choice with no silent-OpenMP-drop failure mode.
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/src"
EXE="${SRC}/lulesh2.0"
LOG="${HERE}/lulesh_run.log"

# ---- exact problem specification, unchanged -------------------------------
#   8 ranks * 150^3 per rank = 300^3 = 27,000,000 elements global
ARGS="-s 150 -i 50 -r 11 -b 0 -c 64"

load_modules() {
  source /usr/share/lmod/lmod/init/bash 2>/dev/null || true
  module reset            >/dev/null 2>&1 || true
  module load PrgEnv-gnu  || { echo "FATAL: cannot load PrgEnv-gnu"; exit 1; }
  module load craype-x86-trento >/dev/null 2>&1 || true   # znver3 target flags
  module load cray-mpich        >/dev/null 2>&1 || true   # normally already in
  module -t list 2>&1 | sort
}

build() {
  load_modules

  # Zen3 (Trento).  Probe once rather than assume the gcc-native version.
  ARCH="-march=znver3"
  echo 'int main(){return 0;}' > /tmp/.znver3probe.$$.cc
  CC $ARCH -c /tmp/.znver3probe.$$.cc -o /tmp/.znver3probe.$$.o >/dev/null 2>&1 \
     || ARCH="-march=native"
  rm -f /tmp/.znver3probe.$$.cc /tmp/.znver3probe.$$.o

  # -fno-math-errno lets sqrt() inline to vsqrtpd and the EOS/pressure loops
  # vectorize.  No -ffast-math: the physics stays bit-for-bit ordinary IEEE.
  CXXFLAGS="-O3 $ARCH -fopenmp -fno-math-errno -funroll-loops -I."
  LDFLAGS="-O3 -fopenmp"

  cd "$SRC" || exit 1
  make clean
  make -j 8 CXX="CC -DUSE_MPI=1" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS" \
    || { echo "FATAL: build failed"; exit 1; }
  ls -l "$EXE"
}

run() {
  load_modules

  # --- OpenMP: 7 threads, one per core of this rank's L3 group ---
  export OMP_NUM_THREADS=7
  export OMP_PLACES=cores
  export OMP_PROC_BIND=close
  export OMP_WAIT_POLICY=active     # spin; ~590k barriers over the run
  export OMP_DYNAMIC=false

  # --- Cray MPICH must admit to FUNNELED support ---
  # lulesh.cc:2663 calls MPI_Init_thread(MPI_THREAD_FUNNELED) and EXITS if it is
  # handed back MPI_THREAD_SINGLE.  cray-mpich reports SINGLE unless told.
  export MPICH_MAX_THREAD_SAFETY=funneled

  # --- keep glibc from mmap/munmap-ing the big transient buffers every cycle ---
  # IntegrateStress/FBHourglass allocate 3 x numElem*8 doubles (216 MB each at
  # -s 150) and free them every cycle; above glibc's 32 MB dynamic cap those are
  # fresh mmaps, i.e. ~16M page faults + page zeroing per rank over 50 cycles.
  export MALLOC_MMAP_THRESHOLD_=1073741824
  export MALLOC_TRIM_THRESHOLD_=1073741824

  # 1 node, 8 ranks, 7 cores each, ONE hardware thread per core (the allocation
  # exposes two; this step asks for one -- see note 5).  -c 7 with 56 allocatable
  # cores places exactly one rank per L3 group / CCD.
  srun -N 1 -n 8 -c 7 \
       --threads-per-core=1 \
       --cpu-bind=verbose,cores \
       "$EXE" $ARGS 2>&1 | tee "$LOG"

  echo
  echo "================ result ================"
  echo -n "Elapsed time (full precision, s): "
  sed -n 's/.*(\([^()]*\) overall).*/\1/p' "$LOG" | tr -d ' '
  grep -E "Grind time|FOM|Final Origin Energy|MPI tasks|Num threads" "$LOG"
  echo "  (the 'Elapsed time =' summary line is printed at setprecision(2);"
  echo "   the value in parentheses on the Grind time line is the full one.)"
}

case "${1:-}" in
  build) build ;;
  run)   run   ;;
  *) echo "usage: bash $0 {build|run}" ; exit 2 ;;
esac
