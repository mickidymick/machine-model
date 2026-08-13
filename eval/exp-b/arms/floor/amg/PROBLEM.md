# The problem

AMG is an algebraic multigrid solver (ECP proxy application). I need to solve a
fixed 3D Laplace problem and I care only about how long the solve takes.

**Fixed -- do not change these:**

- Problem: `-problem 2` (3D 27-point Laplace)
- **Global grid: 448 x 448 x 448** (~9.0e7 unknowns).
  Careful: this driver's `-n` is the block size PER MPI RANK, not the global
  grid -- the global domain is `nx*Px  x  ny*Py  x  nz*Pz`. Choose `-n` and
  `-P` together so their product is 448 in each dimension. **The rank count and
  the per-rank block are yours to choose; the global grid is not.** 448 factors
  as 2^6 x 7, so 4, 7, 8, 14, 16, 28, 32, 56, 64, 112 and 224 all divide it
  cleanly -- the geometry is genuinely open.
- Solver iterations are fixed by the proxy; do not alter the tolerance or the
  cycle count.

Report wall-clock time for the solve phase, which AMG prints itself.

The working set per thread is on the order of tens of MiB and the access pattern
is irregular -- this is a sparse solver, not a streaming kernel.
