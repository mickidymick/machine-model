# Spread probe — results

Job 5359372, 2026-08-27. Global 300^3 (27e6 elements), `-i 20`,
`-r 11 -b 0 -c 64`, one node, 6 configurations x 2 passes, interleaved.

**The probe's question was go/no-go: does configuration choice matter at a
problem size where the artifact's claims can bind?** It does. It also produced
three findings that were not the question, two of which overturn things this
harness previously asserted.

## Results

| config | ranks x thr | PU | median s | sd | GB | B/elem | core-s |
|---|---|---|---|---|---|---|---|
| m64x1 | 64 x 1 (mpi) | 64 | **114.6** | 1.1% | 20.6 | 762 | 7335 |
| o08x7 | 8 x 7 (omp) | 56 | 117.1 | 0.3% | 24.6 | 910 | 6560 |
| o27x4 | 27 x 4 (omp) | 108 | 122.4 | 0.1% | 25.3 | 937 | 13215 |
| o27x2 | 27 x 2 (omp) | 54 | 127.5 | 0.3% | 25.3 | 938 | 6884 |
| m27x1 | 27 x 1 (mpi) | 27 | 158.8 | 1.3% | 19.3 | 716 | 4286 |
| m08x1 | 8 x 1 (mpi) | 8 | **196.6** | 0.7% | 18.6 | 688 | 1573 |

**Spread 1.72x, worst sd 1.3%.** Roughly 130x the within-job noise.

Validation against job 5349696, which ran four of these under a different
allocation: 196.0 -> 196.6, 116.1 -> 117.1, 156.8 -> 158.8, 125.0 -> 127.5.
All within 2%, inside the established 2.5% cross-job floor. Cross-allocation
comparability is restored.

## 1. The node CAN be filled with pure MPI, and that is the fastest thing to do

Earlier revisions of this probe asserted the opposite: that LULESH's cube rank
constraint against 56 usable cores means the largest pure-MPI configuration
uses 27 cores, so you must either idle 29 cores or go hybrid and pay the
threaded force path. **That was wrong.**

64 ranks fits, using the second hardware thread, and it is both the fastest
configuration (114.6 s) and the cheapest in memory (762 B/element, the MPI-only
force path). Hybrid buys nothing here.

**The machine fact still decides the outcome — but it unlocks rather than
prevents.** Reaching 64 ranks requires `--threads-per-core=2` on the job, and a
configurer only knows to ask for that if it knows the node has 56 cores rather
than the 64 the vendor node diagram shows. `cpu.core_inventory`, verdict
`misleading`, is the claim; what it buys is the best configuration, not the
avoidance of a bad one.

**Untested, and it should be before this goes in a paper:** whether the naive
`srun -n 64 -c 1` under a default allocation fails. Job 5349696 shows
`srun --threads-per-core=2` failing when the job lacks it; the bare form has
not been tried. Two minutes of work and the claim rests on it.

## 2. cpu.smt_benefit gives the wrong sign for this application

`o27x4` and `o27x2` differ only in the second hardware thread — same 27 ranks,
same 54 cores, same binary.

    o27x2   54 threads   127.5 s
    o27x4  108 threads   122.4 s      SMT is 4.0% FASTER

The registry claim predicts bandwidth-saturated codes **lose** about 5%,
measured as -5.0% on `stream`. LULESH at this size is bandwidth-saturated by
the scaling evidence below. The rule's sign is wrong here.

The mechanism is the interesting part. The claim's rule — latency-bound gains,
throughput-bound loses — was measured on three microkernels, each purely one
thing. LULESH is bandwidth-heavy *and* full of irregular gathers through
`nodelist` and dependent chains. Those latency-bound components have idle issue
slots for a second thread to fill.

**A rule derived from microkernels does not transfer to an application that
mixes regimes.** This is the same shape as the project's central finding, one
level down: the claim is not wrong about what it measured, it is wrong about
what it is applied to. `cpu.smt_benefit`'s `measured_under` should say so.

## 3. Bandwidth saturation, quantified

Core-seconds is median x PU — the resource cost of each configuration:

    m08x1     8 PU    1573 core-s
    m27x1    27 PU    4286
    o27x2    54 PU    6884
    o08x7    56 PU    6560
    m64x1    64 PU    7335
    o27x4   108 PU   13215

8 PUs to 64 PUs is **8x the resource for 1.72x the time**. Scaling efficiency
about 21%. The code is memory-bandwidth limited well before the node is full,
which is the regime round 3 assumed and did not have, and is why the spread is
1.72x rather than round 3's apparent 5x.

## 4. Allocation flags are part of the configuration

Job 5358788 ran the identical six configurations with `--threads-per-core=2` on
the job but not on each step, and the <=56 configurations moved by up to
**2.36x** — o08x7 at 274.3 s against 117.1 s here — while agreeing to 0.3%
*within* each job.

A job-level flag nobody would list as part of "the configuration" outweighs
most of the levers deliberately under test. Two consequences:

- **The harness must pin it.** Every step states `--threads-per-core`
  explicitly. Without that, arms are scored on numbers that are not properties
  of what they chose.
- **It is reportable.** An arm that specifies ranks, threads and binding but
  says nothing about the hardware-thread request has under-specified the run.
  What counts as "a configuration" is larger than it looks.

## Verdict

**Proceed to the replicated experiment.** 1.72x against 1.3% noise resolves
easily. Round 3's apparent 5x was measured in a cache-resident regime and does
not transfer; expect effects of this size and plan replication accordingly —
two passes suffice for the spread itself, more for arm-vs-arm differences that
may be smaller.

The answer key for LULESH at this size: **m64x1 is the target configuration**,
m08x1 is the floor, and an arm that lands on hybrid has chosen a slower and
larger-footprint option for no gain.
