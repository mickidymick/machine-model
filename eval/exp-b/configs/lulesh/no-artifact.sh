#!/bin/bash
# =============================================================================
# LULESH 2.0 on Frontier (OLCF) -- 1 node, 729,000 elements, 500 iterations
#
#   bash SOLUTION.sh build     # module loads + compile
#   bash SOLUTION.sh run       # the single srun line
#
# COMMITTED CONFIGURATION:  125 MPI ranks x 1 thread,  -s 18 -i 500
#                           (125 = 5^3 ranks, 5*18 = 90 elements/side globally,
#                            125 * 18^3 = 729,000 elements -- the required size)
#
# WHY THIS AND NOT SOMETHING ELSE  (reasoning, in order of how much it matters)
#
# 1. NO OpenMP.  This is the single biggest lever, and it is a property of this
#    source tree, not a general rule.  Look at IntegrateStressForElems() in
#    src/lulesh.cc:514 and CalcFBHourglassForceForElems() at src/lulesh.cc:736:
#    whenever omp_get_max_threads() > 1, LULESH switches to a completely
#    different force-summation algorithm.  It allocates fx_elem/fy_elem/fz_elem
#    of 8*numElem doubles each (192 B *per element*), writes every element's 8
#    corner forces there, then gathers them back through nodeElemCornerList.
#    That is ~768 extra bytes of memory traffic per element per cycle, twice a
#    cycle, on top of a baseline of roughly 2 KB/element/cycle -- i.e. ~35% more
#    DRAM traffic on a node that is already memory-bandwidth bound.  The
#    numthreads==1 path instead accumulates straight into the node force arrays.
#    Running MPI-only keeps the cheap path.  (This matches the literature: pure
#    MPI beats hybrid MPI+OpenMP for LULESH at single-node scale; hybrid only
#    wins at large rank counts where communication dominates.)
#    The binary is therefore built WITHOUT -fopenmp, so the fast path is not
#    merely selected at runtime, it is the only one compiled.
#
# 2. USE THE WHOLE NODE.  LULESH forces numRanks to be a perfect cube
#    (src/lulesh-init.cc:685), and 729,000/numRanks must also be a perfect cube.
#    That leaves exactly: 1(s=90), 8(s=45), 27(s=30), 125(s=18), 216(s=15), ...
#    Note 64 is NOT available (729000/64 = 11390.6, not a cube), so there is no
#    "one rank per physical core" option.  27 ranks would idle more than half
#    the node.  125 ranks is the largest count that still fits one rank per
#    hardware thread (Frontier: 64 cores x 2 SMT = 128 logical CPUs).  Even if
#    SMT bought nothing at all, 125 ranks still occupies 63 physical cores
#    versus 27 -- so this dominates the 27-rank option regardless of how SMT
#    behaves.  OLCF generally recommends 1 MPI rank per physical core plus
#    OpenMP for the second hardware thread; that advice is deliberately
#    overridden here because of point 1 -- LULESH's OpenMP path costs more than
#    SMT contention does.
#
#    All of these choices do identical work: BuildMesh() (src/lulesh-init.cc:220)
#    scales the physical domain as 1.125 * (rank_offset)/(tp*nx), so the global
#    mesh is always a 1.125^3 cube with 90 elements/side.  Initial dt, initial
#    energy and the per-cycle physics are bit-for-bit the same problem for
#    -n 1/-s 90, -n 8/-s 45, -n 27/-s 30 and -n 125/-s 18.  Only the
#    decomposition changes.
#
# 3. -S 0 AND --threads-per-core=2 AT ALLOCATION TIME.  Frontier defaults to
#    SLURM core specialization -S 8 (one core reserved per L3 region -> only 56
#    allocatable cores) and --threads-per-core=1.  Both are allocation-level
#    settings, so they are on the srun line below, which is why run() is written
#    to be launched from a login node (srun creates its own allocation).
#
# 4. -m block:block packs ranks L3-region by L3-region, and with
#    --threads-per-core=2 consecutive rank slots are the two hardware threads of
#    the same physical core.  Since LULESH numbers ranks
#    rank = plane*25 + row*5 + col, consecutive ranks are x-direction
#    neighbours, so a rank and its busiest halo partner land on the same core
#    and the next few land in the same 32 MB L3.  Ranks 0 and 1 land on core 0,
#    which is where Frontier's low-noise mode confines system processes; that
#    costs a percent or so on the per-cycle dt Allreduce.  I chose to eat that
#    rather than use --cpu-bind=map_cpu to dodge core 0, because Slurm's
#    map_cpu list is interpreted in abstract (not OS) CPU ids and getting that
#    wrong silently mis-binds all 125 ranks -- a much worse failure than 1%.
#
# 5. Never use -n 1 -s 90.  LULESH's Domain constructor initialises every array
#    serially (src/lulesh-init.cc:88-115, BuildMesh), so with one rank and many
#    threads first-touch puts the entire ~570 MB working set in one of the 4
#    NUMA domains.  One rank per small domain makes first-touch automatically
#    NUMA-correct.
#
# 6. MALLOC_MMAP_THRESHOLD_/MALLOC_TRIM_THRESHOLD_.  CalcHourglassControlForElems
#    malloc()s and free()s six 8*numElem-double temporaries (dvdx, dvdy, dvdz,
#    x8n, y8n, z8n) every single cycle, ~373 KB each at -s 18.  That is above
#    glibc's 128 KB mmap threshold, so without this they would be mmap'd and
#    munmap'd 500 times, re-faulting every page each cycle.  Raising both
#    thresholds keeps the churn inside the heap.
#
# 7. Compiler: PrgEnv-gnu, -O3 -march=znver3 -ffast-math.  Trento is a Zen3
#    core, so znver3 is the right target.  GCC is the reference build for this
#    code and is entirely self-contained for a CPU-only MPI C++ build --
#    PrgEnv-amd additionally wants a matching rocm module loaded, which buys
#    nothing here since amdclang's Zen3 codegen is stock LLVM.  -ffast-math is a
#    compiler flag, not a physics option: the CFL condition, the timestep
#    algorithm and the iteration count are untouched, and with -i 500 the run
#    does exactly 500 cycles either way.  It does perturb the last digits of the
#    final energy; drop it if you need bit-reproducibility (costs ~10%).
#
# EXPECTED: the whole run is only a few seconds of compute -- the 15 minute
# limit is not close to binding.  Report "Elapsed time" and "Grind time".
# NOTE ON REPORTING: LULESH's grindTime1 is per *domain* (elapsed/cycles/nx^3
# with nx=18), so it is NOT comparable across rank counts.  The comparable
# numbers are "Elapsed time" and "FOM (z/s)".
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/src"
EXE="${SRC}/lulesh2.0"

# Your OLCF project id.  Only needed when run() has to create its own
# allocation (i.e. when you launch from a login node).
ACCOUNT="${LULESH_ACCOUNT:-${SLURM_ACCOUNT:-}}"
PARTITION="${LULESH_PARTITION:-batch}"

# --- make `module` usable from a non-interactive bash ------------------------
init_modules() {
    if ! type module >/dev/null 2>&1; then
        if [ -n "${MODULESHOME:-}" ] && [ -f "${MODULESHOME}/init/bash" ]; then
            . "${MODULESHOME}/init/bash"
        elif [ -f /usr/share/lmod/lmod/init/bash ]; then
            . /usr/share/lmod/lmod/init/bash
        else
            echo "ERROR: cannot find Lmod init; run this on a Frontier login node." >&2
            exit 1
        fi
    fi
}

# =============================================================================
# BUILD
# =============================================================================
build() {
    init_modules

    module reset                       # back to Frontier defaults (craype-x86-trento, cray-mpich)
    module load PrgEnv-gnu             # Cray wrappers -> g++ + cray-mpich
    module load craype-x86-trento      # Zen3/Trento target flags (default, loaded explicitly)
    module load cray-mpich             # (default, loaded explicitly)
    module list 2>&1

    local CXXFLAGS="-DUSE_MPI=1 -I. -O3 -march=znver3 -mtune=znver3 \
-ffast-math -fno-math-errno -funroll-loops -fomit-frame-pointer -std=c++11"
    # deliberately NO -fopenmp : see note 1 in the header

    set -e
    cd "${SRC}"
    rm -f *.o "${EXE}"

    echo "CXXFLAGS = ${CXXFLAGS}"
    for f in lulesh.cc lulesh-comm.cc lulesh-init.cc lulesh-util.cc lulesh-viz.cc; do
        echo "Building ${f}"
        CC ${CXXFLAGS} -c "${f}" -o "${f%.cc}.o" &
    done
    wait
    for f in lulesh lulesh-comm lulesh-init lulesh-util lulesh-viz; do
        [ -f "${SRC}/${f}.o" ] || { echo "ERROR: ${f}.o was not produced" >&2; exit 1; }
    done

    echo "Linking"
    CC ${CXXFLAGS} lulesh.o lulesh-comm.o lulesh-init.o lulesh-util.o lulesh-viz.o \
       -o "${EXE}" -lm
    set +e

    echo
    echo "Built ${EXE}"
    ls -l "${EXE}"
}

# =============================================================================
# RUN
# =============================================================================
run() {
    init_modules
    module reset >/dev/null 2>&1
    module load PrgEnv-gnu craype-x86-trento cray-mpich >/dev/null 2>&1

    [ -x "${EXE}" ] || { echo "ERROR: ${EXE} not found -- run 'bash SOLUTION.sh build' first." >&2; exit 1; }

    # ---- environment ---------------------------------------------------
    export OMP_NUM_THREADS=1              # binary has no OpenMP; belt and braces
    export MALLOC_MMAP_THRESHOLD_=1073741824   # see note 6
    export MALLOC_TRIM_THRESHOLD_=1073741824
    export MPICH_ENV_DISPLAY=1            # log the MPI settings actually used
    export MPICH_VERSION_DISPLAY=1

    local ACCT_ARG=()
    [ -n "${ACCOUNT}" ] && ACCT_ARG=(-A "${ACCOUNT}")

    # ---- the committed configuration -----------------------------------
    # 125 MPI ranks, one per hardware thread, 18^3 elements each, 500 cycles.
    if [ -z "${SLURM_JOB_ID:-}" ]; then
        # Launched from a login node: srun creates the allocation, so the
        # allocation-level flags (-S 0, --threads-per-core=2) take effect here.
        set -x
        srun "${ACCT_ARG[@]}" -t 00:15:00 -p "${PARTITION}" \
             -N 1 -S 0 --threads-per-core=2 \
             -n 125 -c 1 --cpu-bind=threads -m block:block \
             "${EXE}" -s 18 -i 500
        set +x
        return $?
    fi

    # Already inside an allocation: -S and --threads-per-core were fixed when
    # that allocation was made and cannot be changed now.
    local avail="${SLURM_JOB_CPUS_PER_NODE:-0}"
    avail="${avail%%(*}"                      # "128(x1)" -> "128"
    [[ "${avail}" =~ ^[0-9]+$ ]] || avail=0

    if [ "${avail}" -ge 125 ]; then
        set -x
        srun -N 1 -n 125 -c 1 --cpu-bind=threads -m block:block \
             "${EXE}" -s 18 -i 500
        set +x
        return $?
    fi

    # The allocation cannot host the committed configuration.  Rather than
    # hand you nothing, fall back to the best config that fits the default
    # 56-core / --threads-per-core=1 allocation: 27 MPI ranks, still MPI-only,
    # still exactly 729,000 elements.  This is SLOWER -- roughly 2x.
    echo "=============================================================" >&2
    echo "WARNING: this allocation exposes only ${avail} CPUs per node."  >&2
    echo "The committed configuration (125 ranks) needs an allocation"    >&2
    echo "made with:   -N 1 -S 0 --threads-per-core=2"                    >&2
    echo "Falling back to 27 ranks x 30^3 (same 729,000 elements,"        >&2
    echo "same 500 iterations, but ~2x slower).  Re-allocate as above,"   >&2
    echo "or just run 'bash SOLUTION.sh run' from a login node."          >&2
    echo "=============================================================" >&2
    set -x
    srun -N 1 -n 27 -c 1 --cpu-bind=threads -m block:cyclic \
         "${EXE}" -s 30 -i 500
    set +x
}

# =============================================================================
case "${1:-}" in
    build) build ;;
    run)   run   ;;
    *)     echo "usage: bash $0 {build|run}" >&2; exit 2 ;;
esac
