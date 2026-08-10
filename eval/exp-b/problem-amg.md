# The problem

AMG is an algebraic multigrid solver (ECP proxy application). I need to solve a
fixed 3D Laplace problem and I care only about how long the solve takes.

**Fixed — do not change these:**

- Problem: `-problem 2` (3D 27-point Laplace)
- Global grid: `-n 128 128 128` per rank-block as configured by the launch
- Solver iterations are fixed by the proxy; do not alter the tolerance or the
  cycle count.

Report wall-clock time for the solve phase, which AMG prints itself.

The working set per thread is on the order of tens of MiB and the access pattern
is irregular -- this is a sparse solver, not a streaming kernel.
