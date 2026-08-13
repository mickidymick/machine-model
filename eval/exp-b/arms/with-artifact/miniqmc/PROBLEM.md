# The problem

miniQMC is the ECP proxy application for QMCPACK -- a simplified but
computationally accurate implementation of the real-space quantum Monte Carlo
algorithms in the production code. I need to run a fixed amount of QMC work and
I care only about how long it takes.

**Fixed -- do not change these:**

- System size: `-g "2 2 2"` (3072 electrons)
- Steps: `-n 5`
- **Total walkers across all ranks must be exactly 224.** Walkers are the unit
  of work: total work is `ranks x walkers-per-rank`, so this is what holds the
  problem constant. Choose the rank count and `-w` so that
  `ranks x w = 224`. 224 = 2^5 x 7, so 1, 2, 4, 7, 8, 14, 16, 28, 32, 56, 112
  and 224 ranks all divide it -- the geometry is genuinely open.
- **Build with MPI enabled: pass `-DQMC_MPI=1` to cmake.** It is OFF by default
  in this CMakeLists. Without it the binary still builds and runs, but every
  rank runs the whole problem independently -- `srun -n16` becomes 16 separate
  serial copies rather than one 16-rank job, and nothing in the output says so.
- **You must pass `-w` explicitly.** If you omit it, miniQMC defaults the walker
  count to `omp_get_max_threads()` (src/Drivers/miniqmc.cpp), which would make
  the amount of work depend on your thread count and break the comparison.

Report the run time. miniQMC prints its own timer table; the `Total` row is the
number I care about, and `Setup` is reported separately.

The per-walker working set is on the order of tens of MiB and the access pattern
is irregular -- this is a Monte Carlo particle code, not a streaming kernel.
