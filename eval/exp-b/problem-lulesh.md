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
explicitly.** A step that does not is placed by whatever the allocation happens
to expose, and the same configuration has been measured 2.36x apart on that
difference alone. This is part of the configuration, not part of the
environment.

The mesh is structured and the kernels sweep it in order -- element and node
arrays are traversed contiguously with regular stencil neighbours. The region
settings above mean per-element work is not uniform across the mesh.

---

## Provenance of this configuration

**v1 (round 3) ran 729,000 elements and is preserved in `problem-lulesh.v1.md`.**
That was 230 MB on a 512 GB node -- cache-resident in every configuration, so
almost none of the machine artifact's claims could bind, and the comparison could
not have tested them. See the correction in `RESULTS.md`.

The size here is anchored to a **published, measured** LULESH configuration:
`-s 300 -i 12 -r 11 -b 0 -c 64`, single rank, measured at **23.6 GB**. This spec
keeps that total problem size and the region settings, and distributes it across
ranks so that the decomposition is a real choice rather than fixed at one.

Two deliberate deviations from the published run:

- **Distributed rather than single-rank.** A single rank has no decomposition to
  choose, which removes most of the configuration surface under test.
- **`-i 50` rather than `-i 12`.** At 12 iterations the total work is 3.2e8
  element-updates, about the same as round 3, giving runs of a few seconds. Wall
  clock is the dependent variable here, so iterations are raised for timing
  stability at a cost of roughly 25 s per run.

Analytic footprint derivation, and the open question about the 315 vs 874
bytes-per-element discrepancy between the MPI-only and threaded paths, are in
`eval/characterize/analytic-lulesh.md`.
