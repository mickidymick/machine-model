#!/bin/bash
# CEILING -- hand-tuned using everything this project has measured. Not an arm;
# a reference for how much headroom exists. If an arm reaches this, the artifact
# carried everything that mattered.
#
# Every choice traces to a claim:
#   craype-hugepages2M  cost.page_size_penalty -- 2.4x at a ~32 MiB working set,
#                       and it RELINKS, so it must be a build-time decision.
#                       THP is [never] here and the hugetlb pool is empty, so
#                       nothing else gets you 2 MB pages.
#   -c 56               cpu.core_inventory -- 8 cores are OS-reserved; -c 64 is
#                       rejected outright.
#   4 ranks x 14        one rank per NUMA domain. numa.distance_matrix says the
#                       domains are NOT equidistant, so keeping a rank's memory
#                       inside one domain avoids the far-tier crossings.
#   --threads-per-core=1  UNMEASURED. Chosen because a bandwidth-bound kernel is
#                       not expected to gain from SMT -- flagged as the one
#                       choice here with no measurement behind it.
build() {
  module load craype-hugepages2M
  cd src && make -j16
}
run() {
  export OMP_NUM_THREADS=14 OMP_PROC_BIND=close OMP_PLACES=cores
  srun -N1 -n4 -c14 --threads-per-core=1 --cpu-bind=cores \
       ./test/amg -problem 2 -n 128 128 128
}
