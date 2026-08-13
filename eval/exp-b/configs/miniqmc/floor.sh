#!/bin/bash
# FLOOR -- ZeroSum's naive default, reproduced almost exactly. Not an arm.
#
# Their baseline was `srun -n8 miniqmc` on ONE node with OMP_NUM_THREADS=7 and
# no `-c`: srun gives each rank one core, seven threads pile onto it, 63.67 s
# against 27.33 s. The entire 2.33x in their paper is that one missing flag.
# At 1 node this floor is their configuration: 8 ranks, 7 OpenMP threads, no -c.
#
# 8 ranks x 7 walkers = 56 total walkers, as PROBLEM.md requires.
# -DQMC_MPI=1, CC and CrayLinuxEnvironment are not tuning: without them the
# build is serial or does not configure at all.
build() {
  module load PrgEnv-gnu
  module load cmake 2>/dev/null || true
  mkdir -p build && cd build
  cmake -DQMC_MPI=1 -DCMAKE_CXX_COMPILER=CC -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=CrayLinuxEnvironment ../src
  make -j16
}
run() {
  module load PrgEnv-gnu
  export OMP_NUM_THREADS=7
  srun -N1 -n8 ./build/bin/miniqmc -g "2 2 2" -n 5 -w 7
}

case "${1:-}" in
  build) build ;;
  run)   run ;;
  *)     echo "usage: $0 [build|run]" >&2; exit 2 ;;
esac
