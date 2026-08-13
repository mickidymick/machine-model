#!/bin/bash
# FLOOR -- the genuine naive default, in ZeroSum's sense. Not an arm.
#
# ZeroSum's baseline was `srun -n8 miniqmc` with OMP_NUM_THREADS=7 and no `-c`:
# srun hands each rank ONE core, all seven threads pile onto it, and the run
# takes 63.67 s instead of 27.33 s. The whole 2.33x in their paper is the single
# missing `-c` flag. This floor reproduces exactly that mistake on AMG.
#
# What a user does here that is wrong, and only this:
#   - sets OMP_NUM_THREADS but omits `-c`, so every thread lands on one core
#   - never loads craype-hugepages2M, so the binary is linked for 4K pages
#   - keeps the shipped -O2 and -DHYPRE_BIGINT
#   - no binding, no NIC policy, no --threads-per-core
# CC=cc is the one concession: the shipped Makefile says mpicc, which does not
# exist on Frontier, so no run at all is possible without it. Fixing a hard
# build error is not tuning.
#
# 32 ranks, -P 4 4 2, -n 112 112 224  ->  global 448^3, as PROBLEM.md requires.
build() {
  cd src/src && make CC=cc -j16
}
run() {
  export OMP_NUM_THREADS=14
  srun -N4 -n32 ./src/src/test/amg -problem 2 -n 112 112 224 -P 4 4 2
}

# Same CLI the agents' own scripts expose, so the harness can exec every config
# identically instead of sourcing it. Sourcing meant editing the agent's script
# before running it -- task.md promises "I will execute it as-is".
case "${1:-}" in
  build) build ;;
  run)   run ;;
  *)     echo "usage: $0 [build|run]" >&2; exit 2 ;;
esac
