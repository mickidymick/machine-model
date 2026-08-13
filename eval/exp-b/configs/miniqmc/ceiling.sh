#!/bin/bash
# CEILING -- hand-tuned from everything this project has measured. Not an arm;
# a reference for how much headroom exists.
#
# 16 ranks (4 nodes x 4) x 14 walkers = 224 total walkers, per PROBLEM.md.
#
# Every choice traces to a claim:
#   craype-hugepages2M  cost.page_size_penalty -- 2.4x at a ~32 MiB working set.
#                       It RELINKS, so it is a build-time decision; THP is
#                       [never] here and the hugetlb pool is empty, so nothing
#                       else yields 2 MB pages. Loaded at run time too, because
#                       HUGETLB_* in the environment is what backs the heap.
#   -c 14               cpu.core_inventory -- 8 cores OS-reserved, 56 usable,
#                       56/4 = 14. `-c 64` is rejected outright. -c 14 is also
#                       what makes MPICH_OFI_NIC_POLICY=NUMA legal at all.
#   4 ranks/node        one rank per NUMA domain. numa.distance_matrix measured
#                       107.9/115.8/119.2 ns against 101.5 local; the ACPI SLIT
#                       declares them flat and is wrong.
#   NIC_POLICY=NUMA     net.nic_inventory -- 4 NICs, one per domain. Our own
#                       control showed the policy is worth 0.13%; spreading
#                       ranks across domains is the whole effect. Set because it
#                       is free, not because it is large.
#   --threads-per-core=1  UNMEASURED -- flagged as the one choice here with no
#                       measurement behind it.
build() {
  module load craype-hugepages2M
  # craype-x86-trento targets the EPYC 7A53 compute nodes; the login nodes are
  # 7763. Both are Zen 3, but the module is the Cray-idiomatic way to say so and
  # is safer than hand-passing -march= through whichever PrgEnv is default.
  module load craype-x86-trento 2>/dev/null || true
  module load cmake 2>/dev/null || true
  mkdir -p build && cd build
  cmake -DQMC_MPI=1 -DCMAKE_CXX_COMPILER=CC -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=CrayLinuxEnvironment ../src
  make -j16
}
run() {
  module load craype-hugepages2M
  export HUGETLB_VERBOSE=2
  export OMP_NUM_THREADS=14 OMP_PROC_BIND=close OMP_PLACES=cores
  export MPICH_OFI_NIC_POLICY=NUMA
  srun -N4 -n16 --ntasks-per-node=4 -c14 --threads-per-core=1 \
       --cpu-bind=cores --distribution=block:block \
       ./build/bin/miniqmc -g "2 2 2" -n 5 -w 14
}

# Same CLI the agents' own scripts expose, so the harness can exec every config
# identically instead of sourcing it. Sourcing meant editing the agent's script
# before running it -- task.md promises "I will execute it as-is".
case "${1:-}" in
  build) build ;;
  run)   run ;;
  *)     echo "usage: $0 [build|run]" >&2; exit 2 ;;
esac
