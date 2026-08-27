# The problem

LULESH is the LLNL shock-hydrodynamics proxy application. I need to run a fixed
problem and I care only about how long it takes.

**Fixed -- do not change these:**

- **Global problem size: 300^3 elements** (27,000,000 elements total).
  Careful: `-s` is the cube edge length **PER RANK**, not globally, and LULESH
  requires the rank count to be a **perfect cube** (`lulesh-init.cc:685`). The
  global edge is `cbrt(numRanks) * s`, so the cube root of the rank count must
  divide 300. That leaves:

  | `-n` ranks | `-s` |
  |---|---|
  | 1 | 300 |
  | 8 | 150 |
  | 27 | 100 |
  | 64 | 75 |
  | 125 | 60 |
  | 216 | 50 |

  **The rank count and per-rank size are yours to choose; their product is not.**
  Every one of these does identical work -- `BuildMesh()` scales the physical
  domain by the decomposition, so the global mesh, the initial timestep, the
  initial energy and the per-cycle physics are the same problem in every case.
  Only the decomposition changes.

- **Regions: `-r 11 -b 0 -c 64`.** Eleven material regions, uniformly sized,
  with a 64x cost spread between them. This is not a tuning knob -- it changes
  the amount and distribution of work. It must be passed exactly.
- **Iterations: `-i 50`.**
- Do not change the CFL condition, the timestep, or any physics option.

Report the total elapsed time and the "Grind time" figure LULESH prints. Parse
the full-precision elapsed value, not the two-significant-figure summary line.

**The allocation exposes both hardware threads per core** (`--threads-per-core=2`
at the job level). Your `srun` step may request either one or two per core --
fewer than the allocation holds is allowed, more is not. **State what you want
explicitly**, because a step that does not state it is placed by whatever the
allocation happens to expose rather than by what you intended. This is part of
the configuration, not part of the environment.

The mesh is structured and the kernels sweep it in order -- element and node
arrays are traversed contiguously with regular stencil neighbours. The region
settings above mean per-element work is not uniform across the mesh.
