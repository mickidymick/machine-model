# The problem

LULESH is the LLNL shock-hydrodynamics proxy application. I need to run a fixed
problem and I care only about how long it takes.

**Fixed -- do not change these:**

- **Global problem size: 8 x 45^3 elements** (729,000 elements total).
  Careful: `-s` is the cube edge length **PER RANK**, not globally, and LULESH
  requires the rank count to be a **perfect cube** (1, 8, 27, 64...). So total
  work is `numRanks x s^3` and you must choose the pair together:
  `-n 1` needs `-s 90`, `-n 8` needs `-s 45`, `-n 27` needs `-s 30`.
  The rank count and per-rank size are yours to choose; their product is not.
- Iterations: `-i 500`
- Do not change the CFL condition, the timestep, or any physics option.

Report the total elapsed time and the "Grind time" figure LULESH prints.

The mesh is structured and the kernels sweep it in order -- element and node
arrays are traversed contiguously with regular stencil neighbours.
