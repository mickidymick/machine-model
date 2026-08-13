#!/bin/bash
# FLOOR -- ZeroSum's naive default, reproduced. Not an arm.
#
# Their baseline was `srun -n8 miniqmc` with OMP_NUM_THREADS=7 and NO `-c`:
# srun gives each rank one core, seven threads pile onto it, 63.67 s instead of
# 27.33 s. The entire 2.33x in their paper is that one missing flag. This is the
# same mistake at our scale.
#
# 32 ranks (8/node) x 7 walkers = 224 total walkers, as PROBLEM.md requires.
# -DQMC_MPI=1 and -DCMAKE_CXX_COMPILER=CC are not tuning: without them the build
# is serial and every rank would run the whole problem independently.
build() {
  # PrgEnv-gnu, not the site default. Frontier defaults to PrgEnv-cray, and
  # miniQMC has NO CrayCompilers.cmake -- CMakeLists recognises COMPILER Cray
  # then warns "No default file for compiler" and sets no flags at all, so the
  # build dies in NewTimer.cpp. GNU is the best-supported path (GNUCompilers
  # .cmake exists). This is a build necessity, not tuning: the floor is naive
  # about placement and page size, not about compiling at all.
  module load PrgEnv-gnu
  module load cmake 2>/dev/null || true   # present on some systems, not all
  mkdir -p build && cd build
  # If cmake cannot find LAPACK, cray-libsci is what provides it on this
  # machine; the CC wrapper links it automatically, so pointing CMake at it
  # explicitly is the fallback:
  #   -DLAPACK_LIBRARIES="$CRAY_LIBSCI_PREFIX_DIR/lib/libsci_cray.so"
  cmake -DQMC_MPI=1 -DCMAKE_CXX_COMPILER=CC -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=CrayLinuxEnvironment ../src
  make -j16
}
run() {
  export OMP_NUM_THREADS=7
  srun -N4 -n32 ./build/bin/miniqmc -g "2 2 2" -n 5 -w 7
}

# Same CLI the agents' own scripts expose, so the harness can exec every config
# identically instead of sourcing it. Sourcing meant editing the agent's script
# before running it -- task.md promises "I will execute it as-is".
case "${1:-}" in
  build) build ;;
  run)   run ;;
  *)     echo "usage: $0 [build|run]" >&2; exit 2 ;;
esac
