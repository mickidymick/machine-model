#!/bin/bash
# =============================================================================
# LULESH 2.0 -- 729,000 elements (8 x 45^3), 500 iterations, ONE Frontier node
#
#   bash SOLUTION.sh build     # on a login node (or in the allocation)
#   bash SOLUTION.sh run       # inside a 1-node allocation
#
# Configuration chosen:  8 MPI ranks x 7 OpenMP threads, 1 thread/core,
#                        4K pages, GCC, -s 45 -i 500.
# Rationale for every choice is in the comments below.
# =============================================================================

set -eo pipefail            # (deliberately no -u: Cray's module functions trip it)

HERE="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SRC="${HERE}/src"
EXE="${SRC}/lulesh2.0"

# Lmod is normally set up by /etc/profile; a non-login `bash SOLUTION.sh` may not have it.
if ! type module >/dev/null 2>&1; then
  for _lmod in /usr/share/lmod/lmod/init/bash /opt/cray/pe/lmod/lmod/init/bash; do
    # shellcheck disable=SC1090
    [ -f "${_lmod}" ] && source "${_lmod}" && break
  done
fi

# -----------------------------------------------------------------------------
# WHY THIS SHAPE (read the source, not just the machine sheet)
# -----------------------------------------------------------------------------
# 1. Domain::Domain() in lulesh-init.cc initialises EVERY array in a SERIAL loop
#    (lines 90-193 -- std::vector::resize + plain for loops, no OpenMP anywhere
#    in the constructor).  Under Linux first-touch that means one process's
#    entire working set lands in the NUMA domain of whichever core the master
#    thread happened to start on.  So the "obvious" 1-rank x 56-thread OpenMP
#    layout (-n 1 -s 90) parks ~400 MB in ONE of the four NPS4 domains and then
#    has 42 of its 56 threads streaming remotely through a single memory
#    controller.  Running 8 MPI ranks instead makes the placement correct for
#    free: each rank constructs, and therefore first-touches, only its own
#    45^3 sub-domain, and its 7 threads live on the L3 group next to that
#    memory.  This is the single biggest lever available here and it is a
#    property of the source, not of the node.
#
# 2. Same source, second reason for 8 ranks: LULESH malloc/frees its big
#    temporaries EVERY cycle -- 9 arrays of 8*numElem doubles in
#    IntegrateStressForElems/CalcHourglassControlForElems (lulesh.cc:515,738,
#    1001) plus 14 more per region in EvalEOSForElems.  At -s 90 each of those
#    is 46.6 MB, above glibc's 32 MB dynamic mmap-threshold ceiling, so they are
#    mmap'd and munmap'd 500 times -- hundreds of MB of kernel page-zeroing and
#    fresh page faults per cycle.  At -s 45 they are 5.8 MB and get recycled on
#    the heap.  (MALLOC_MMAP_THRESHOLD_ below pins that behaviour from cycle 0.)
#
# 3. Rank count must be a perfect cube and 8 is the only cube that divides the
#    56 allocatable cores evenly: 8 ranks x 7 cores = 56, i.e. exactly one L3
#    region (one CCD, 32 MB L3) per rank, two ranks per NUMA domain, all four
#    memory controllers loaded.  27 ranks would leave 2 cores idle (27x2=54),
#    give each rank a worse surface-to-volume ratio, and its per-thread EOS
#    chunk works out slightly larger than the 8-rank case anyway.  64 ranks is
#    impossible: only 56 cores are allocatable.
#
# 4. Region parameters are left at the code's defaults (-r 11 -b 1 -c 1) and
#    are passed explicitly below so the amount of work is pinned.  They are not
#    free: with numReg=11/cost=1 the EOS is evaluated ~4.8x per element per
#    cycle and one region carries rep=20.  Lowering -r would make the run much
#    faster by doing less work, which is exactly what the task forbids.
# -----------------------------------------------------------------------------

build() {
  module reset
  module load PrgEnv-gnu          # GNU, not the default PrgEnv-cray: CCE's
                                  # "CrayClang" identity is a known source of
                                  # silently-dropped -fopenmp on this machine,
                                  # and a silently serial LULESH would look
                                  # like a slow node rather than a build bug.
  module load craype-x86-trento   # correct target CPU for the compute nodes
  # NOT loading craype-hugepages2M -- see the note in run().
  module unload craype-hugepages2M 2>/dev/null || true
  module list 2>&1 || true

  cd "${SRC}"
  make clean || true

  # CC is the Cray wrapper; with PrgEnv-gnu it is g++ + cray-mpich, so MPI needs
  # no -I/-l of its own.  USE_MPI=1 is mandatory (lulesh.h #errors without it).
  #
  # Float flags: -fno-math-errno lets sqrt() inline, -freciprocal-math turns the
  # many 1.0/v divides in the EOS into multiplies.  Deliberately NOT -ffast-math:
  # its reassociation buys little here (the hot element loops gather through
  # nodelist[] and scatter-add, so they do not auto-vectorise anyway) and it can
  # perturb the symmetry check LULESH prints at the end.  Nothing here changes
  # the number of cycles or the amount of work.
  make -j5 \
    CXX="CC" \
    CXXFLAGS="-DUSE_MPI=1 -O3 -march=znver3 -mtune=znver3 -funroll-loops \
              -fno-math-errno -fno-trapping-math -fno-signed-zeros \
              -freciprocal-math -fopenmp -I." \
    LDFLAGS="-O3 -fopenmp"

  ls -l "${EXE}"
  echo "build OK"
}

run() {
  module reset
  module load PrgEnv-gnu
  module load craype-x86-trento

  # ---- OpenMP -------------------------------------------------------------
  export OMP_NUM_THREADS=7        # 7 cores per rank x 8 ranks = 56 allocatable
  export OMP_PLACES=cores         # 1 thread per physical core (no SMT, see below)
  export OMP_PROC_BIND=close      # keep a rank's 7 threads inside its own L3
  export OMP_DYNAMIC=false
  export OMP_WAIT_POLICY=ACTIVE   # LULESH forks/joins ~350 parallel regions per
                                  # cycle (EvalEOSForElems is entered 11x, and
                                  # the rep-loop repeats it 35x in total), i.e.
                                  # ~175,000 fork-joins over the run.  Nothing
                                  # is oversubscribed, so spin-waiting at the
                                  # barriers is free and worth having.

  # ---- allocator ----------------------------------------------------------
  # Keep the per-cycle temporaries (see note 2 above) on the brk heap instead of
  # letting glibc mmap/munmap them every cycle and re-fault the pages.
  export MALLOC_MMAP_THRESHOLD_=$((1024*1024*1024))
  export MALLOC_TRIM_THRESHOLD_=$((1024*1024*1024))

  # ---- what is deliberately NOT set ---------------------------------------
  # * craype-hugepages2M: NOT used.  The huge-page win on this node is a
  #   TLB-reach effect measured on dependent random access; LULESH sweeps the
  #   element and node arrays contiguously with regular stencil neighbours, so
  #   a page walk is amortised across the whole page and the mechanism does not
  #   apply.  On a streaming kernel here it has been measured to COST ~2.7%,
  #   and it also has to be linked in, not switched on at runtime.
  # * --threads-per-core=2 / SMT: NOT used.  SMT on this node pays off for
  #   latency-bound kernels and loses ~5% for kernels that already saturate
  #   memory bandwidth.  LULESH at 56 cores is in the second group: contiguous
  #   streaming sweeps, ~1-2 flop/byte, and doubling the threads would also
  #   double the cost of those ~175,000 barriers and halve the per-thread chunk
  #   in the many small regions.  (If you want to test the other arm, it is
  #   --cpus-per-task=14 --threads-per-core=2, OMP_NUM_THREADS=14,
  #   OMP_PLACES=threads -- one variable, same binary.)
  # * numactl: not needed.  8 ranks each first-touching their own sub-domain
  #   already gives local placement on all four domains.

  # ---- the run ------------------------------------------------------------
  # -n 8 ranks x -s 45 per rank = 8 x 45^3 = 729,000 elements, -i 500 cycles.
  # --cpus-per-task=7 (spelled long: LULESH also has a -c flag) puts one rank on
  # each of the 8 L3 regions; the OS-reserved cores 0,8,16,...,56 are already
  # excluded by Slurm's default core specialisation, so 8x7=56 is the ceiling
  # and asking for 8 would be rejected.
  srun -N 1 -n 8 --cpus-per-task=7 --threads-per-core=1 --cpu-bind=cores \
       "${EXE}" -s 45 -i 500 -r 11 -b 1 -c 1 \
    2>&1 | tee "${HERE}/lulesh_run.log"

  echo
  echo "---- headline numbers ----"
  grep -E "Elapsed time|Grind time|FOM|Iteration count" "${HERE}/lulesh_run.log" || true
}

case "${1:-}" in
  build) build ;;
  run)   run   ;;
  *)     echo "usage: bash $0 {build|run}" >&2; exit 2 ;;
esac
