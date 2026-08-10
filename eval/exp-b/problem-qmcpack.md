# The problem

QMCPACK, variational Monte Carlo on the 2-atom carbon diamond primitive cell.
I need a fixed amount of sampling done as fast as possible.

**Fixed — do not change these:**

- Input: the diamond primitive-cell VMC benchmark, 1000 blocks
- **Total walkers: 112.** Set this explicitly. Do not let the walker count float
  with the thread count -- the amount of work must be identical across
  configurations, or wall clock is not comparable.

Build the `gpu_real` variant with GPU offload targeting gfx90a. Report the
wall-clock time QMCPACK prints for the VMC run.
