# The problem

XSBench is the ECP proxy for the Monte Carlo neutron transport cross-section
lookup kernel in OpenMC. I need to run a fixed number of lookups and I care only
about how long they take.

**Fixed -- do not change these:**

- Simulation method: `-m history`
- Benchmark size: `-s large`
- Grid type: **`-G unionized`**. This is not a tuning knob: the grid type
  changes both the algorithm and the amount of work. `nuclide` does a binary
  search per nuclide, `hash` does neither, and their results are not comparable
  to each other.
- **Total lookups: `-p 500000 -l 34`.** Work is `particles x lookups`, so both
  must stay as given. Thread count (`-t`) does NOT change the work and is yours
  to choose.
- **Single process, MPI off.** The Makefile ships `MPI = no` and it must stay
  that way. XSBench's MPI mode is a weak-scaling harness, not a domain
  decomposition: every rank performs the FULL lookup count and the summary
  divides by the rank count (`io.c`). Running 8 ranks would therefore do 8x the
  work while reporting a per-rank figure that looks unchanged. Use one node.

Report the reported lookup rate and the runtime. XSBench prints both.

**The allocation exposes both hardware threads per core** (`--threads-per-core=2`
at the job level). Your `srun` step may request either one or two per core --
fewer than the allocation holds is allowed, more is not. **State what you want
explicitly**, because a step that does not state it is placed by whatever the
allocation happens to expose rather than by what you intended. This is part of
the configuration, not part of the environment.

The cross-section grid is several GB and each lookup indexes into it at a
location determined by the particle's energy -- the accesses are effectively
random and do not prefetch.
