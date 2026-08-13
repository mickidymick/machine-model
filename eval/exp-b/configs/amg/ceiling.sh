#!/bin/bash
# CEILING -- hand-tuned using everything this project has measured. Not an arm;
# a reference for how much headroom exists. If an arm reaches this, the artifact
# carried everything that mattered.
#
# 16 ranks (4 nodes x 4), -P 4 2 2, -n 112 224 224 -> global 448^3 per PROBLEM.md.
#
# Every choice traces to a claim:
#   craype-hugepages2M  cost.page_size_penalty -- 2.4x at a ~32 MiB working set,
#                       and it RELINKS, so it must be a build-time decision.
#                       THP is [never] here and the hugetlb pool is empty, so
#                       nothing else gets you 2 MB pages.
#   -c 14               cpu.core_inventory -- 8 cores are OS-reserved, 56 usable,
#                       56/4 = 14. `-c 64` is rejected outright. -c 14 is also
#                       what makes MPICH_OFI_NIC_POLICY=NUMA legal: Cray MPICH
#                       refuses it when a rank spans NUMA domains.
#   4 ranks/node        one rank per NUMA domain. numa.distance_matrix says the
#                       domains are NOT equidistant (107.9/115.8/119.2 vs 101.5
#                       local) though the ACPI SLIT declares them flat.
#   NIC_POLICY=NUMA     net.nic_inventory -- 4 NICs, one per domain. NOTE: our
#                       own control showed the policy itself is worth 0.13%;
#                       spreading ranks across domains is the whole effect. It
#                       is set here because it is free, not because it is large.
#   --threads-per-core=1  UNMEASURED. Chosen because a bandwidth-bound kernel is
#                       not expected to gain from SMT -- flagged as the one
#                       choice here with no measurement behind it.
build() {
  module load craype-hugepages2M
  cd src/src && make CC=cc -j16
}
run() {
  # The module is needed at RUN time as well as link time: linking makes the
  # binary huge-page capable, but HUGETLB_* in the environment is what actually
  # backs the heap. Loading it only in build() links a capable binary and then
  # runs it on 4K pages -- a silent miss that looks like "huge pages did not
  # help". Both round-1 arms loaded modules in run() too; this matches them.
  module load craype-hugepages2M
  export HUGETLB_VERBOSE=2   # say so on stderr if the backing falls back to 4K
  export OMP_NUM_THREADS=14 OMP_PROC_BIND=close OMP_PLACES=cores
  export MPICH_OFI_NIC_POLICY=NUMA
  srun -N4 -n16 --ntasks-per-node=4 -c14 --threads-per-core=1 \
       --cpu-bind=cores --distribution=block:block \
       ./src/src/test/amg -problem 2 -n 112 224 224 -P 4 2 2
}

# Same CLI the agents' own scripts expose, so the harness can exec every config
# identically instead of sourcing it. Sourcing meant editing the agent's script
# before running it -- task.md promises "I will execute it as-is".
case "${1:-}" in
  build) build ;;
  run)   run ;;
  *)     echo "usage: $0 [build|run]" >&2; exit 2 ;;
esac
