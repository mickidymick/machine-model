#!/bin/bash
# CEILING -- hand-tuned from everything this project has measured. Not an arm;
# a reference for how much headroom exists.
#
# 1 node, 4 ranks x 14 walkers = 56 total walkers, per PROBLEM.md.
#
# Every choice traces to a claim:
#   craype-hugepages2M  cost.page_size_penalty -- 2.4x at a ~32 MiB working set.
#                       It RELINKS, so it is a build-time decision; THP is
#                       [never] here and the hugetlb pool is empty. Loaded at run
#                       time too: HUGETLB_* in the environment backs the heap.
#   -c 14               cpu.core_inventory -- 8 cores OS-reserved, 56 usable,
#                       56/4 = 14. `-c 64` is rejected outright.
#   4 ranks/node        one rank per NUMA domain. numa.distance_matrix measured
#                       107.9/115.8/119.2 ns against 101.5 local; the ACPI SLIT
#                       declares them flat and is wrong. The 750 MB spline table
#                       is first-touched by each rank's master thread, so a rank
#                       spanning domains reads it remotely.
#   --threads-per-core=1  UNMEASURED -- the one choice here with no measurement
#                       behind it. There are exactly 56 walkers for 56 cores, so
#                       a second hardware thread has no walker to run.
#
# No MPI or NIC tuning: miniQMC makes no communication call inside the timed
# region, so net.nic_inventory does not apply to this code.
build() {
  module load PrgEnv-gnu
  module load craype-hugepages2M
  module load craype-x86-trento 2>/dev/null || true
  module load cmake 2>/dev/null || true
  mkdir -p build && cd build
  cmake -DQMC_MPI=1 -DCMAKE_CXX_COMPILER=CC -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=CrayLinuxEnvironment ../src
  make -j16
}
run() {
  module load PrgEnv-gnu
  module load craype-hugepages2M
  export HUGETLB_VERBOSE=2
  export OMP_NUM_THREADS=14 OMP_PROC_BIND=close OMP_PLACES=cores
  export OMP_MAX_ACTIVE_LEVELS=1
  srun -N1 -n4 --ntasks-per-node=4 -c14 --threads-per-core=1 \
       --cpu-bind=cores --distribution=block:block \
       ./build/bin/miniqmc -g "2 2 2" -n 5 -w 14
}

case "${1:-}" in
  build) build ;;
  run)   run ;;
  *)     echo "usage: $0 [build|run]" >&2; exit 2 ;;
esac
