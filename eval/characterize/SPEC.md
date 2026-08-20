# Application characterization suite

## Why this exists

It does three jobs, and it is worth building carefully because all three depend
on the same measurements.

**1. Pick the problem size.** Round 3 ran LULESH at 230 MB on a 512 GB node --
cache-resident in every configuration. Almost none of the artifact's claims
could bind, so the comparison could not have tested them. Footprint is a
selection criterion, not a runtime convenience.

**2. Build an answer key.** The round-3 treatment arm asserted LULESH was
"bandwidth-saturated" to justify disabling SMT. It was cache-resident. We only
found out because Jeff knows LULESH. Nothing in the harness could catch it, and
that does not scale to eight applications.

Without ground truth, two failure modes are indistinguishable:

| failure | the arm... | fix |
|---|---|---|
| **misclassification** | put its own workload in the wrong regime | help it classify, or let it measure |
| **misapplication** | classified right, applied the wrong claim | sharpen `measured_under` |

Every result so far conflates them.

**3. Be the "profiled" condition.** In the planned 2x3 design -- {machine
layout, web, artifact} x {with, without a measured profile} -- the bottom row
needs something to hand the arm. arXiv 2505.03988 handed over arithmetic
intensity, but for a binary compute-vs-bandwidth question that is essentially
the answer. Our regime space is not binary, so the profile has to be richer and
each line has to be something a reader can act on.

**The symmetry is worth noticing.** The project's premise was that the LLM
already holds the application half and we supply the machine half. The published
64% source-only classification accuracy, and our own LULESH misclassification,
both say the application half is unreliable. So this suite is a **measured
application descriptor** standing opposite the measured machine descriptor --
and the pairing may need both halves measured, which was not the original claim.

---

## What it measures (single node; multi-node deferred)

Every probe is a comparison between two or more runs of the SAME binary and the
SAME problem, varying one launch parameter. No counters, no instrumentation, no
profiler dependency.

| probe | runs | what it separates |
|---|---|---|
| **A. footprint** | 1 | which claims can bind at all: peak RSS total and per rank, against 32 MB L3 / ~128 GB per NUMA domain / 512 GB node |
| **B. thread scaling** | ~6 | where it stops scaling -- i.e. whether it saturates a shared resource |
| **C. SMT response** | 2 | latency-bound (stalls to fill, gains) vs throughput-bound (already saturating, loses) |
| **D. huge-page response** | 2 + rebuild | TLB-hostile unprefetchable access (gains) vs prefetchable or small (no effect) |
| **E. NUMA sensitivity** | 2 | whether data actually leaves cache: confined to one domain vs spread across four |
| **F. I/O volume** | free | bytes written and files created during the timed region |

About 13 runs per application per candidate size. Cheap runs; the value is that
every subsequent comparison becomes interpretable.

C and D are already validated as discriminators. The SMT probe was tested on
three kernels with known behaviour and produced the predicted ordering
(chase +70%, fma +78%, stream -5%); the huge-page effect is `cost.page_size_penalty`,
measured at 2.4x under pointer-chase and null under streaming.

---

## The decision rules

Deliberately explicit, so the label is reproducible and arguable rather than a
judgement call.

**Footprint class** -- from peak RSS per rank:
- `cache-resident` if under the 32 MB L3 region
- `domain-resident` if under one NUMA domain
- `node-resident` if it fits the node
- `multi-node` otherwise

**Limit class** -- from SMT response combined with thread scaling and the
huge-page probe. SMT alone is not enough: our `fma` kernel was FPU-*latency*
bound and gained 78% from SMT, the same direction as the memory-latency-bound
`chase`. The huge-page probe separates them.

| SMT | thread scaling | huge pages | label |
|---|---|---|---|
| gains > +20% | any | helps > 20% | `memory-latency-bound` |
| gains > +20% | near-linear | no effect | `compute-latency-bound` |
| loses < -2% | saturates early | no effect | `bandwidth-bound` |
| loses < -2% | near-linear | no effect | `capacity-or-contention-bound` |
| between | -- | -- | `ambiguous` -- report as such, do not force |

`ambiguous` is a real outcome and must be reported. A forced label is worse than
none, because the answer key would then be wrong in exactly the cases that are
hardest.

**Access class** -- from the huge-page response: `tlb-hostile` if it helps more
than 20%, `prefetchable-or-small` otherwise. Note this cannot distinguish
"contiguous" from "too small to matter", and the footprint class disambiguates.

**Placement sensitivity** -- from probe E: `placement-sensitive` if confining to
one domain costs more than 20%, else `placement-insensitive`. Insensitive at a
cache-resident footprint means nothing; insensitive at a node-resident footprint
is informative.

**I/O class** -- `none` / `bulk` (large writes) / `metadata` (many small files).

---

## Output

Two artefacts per (application, size).

**The label**, for our use -- the answer key, never shown to an arm:

```json
{"app":"lulesh","size":"390^3","footprint":"node-resident",
 "rss_total_gb":17.7,"rss_per_rank_gb":2.2,
 "limit":"bandwidth-bound","access":"prefetchable-or-small",
 "placement":"placement-sensitive","io":"none",
 "claims_that_can_bind":["numa.distance_matrix","cost.loaded_latency_knee",
                          "cpu.smt_benefit","cache_hierarchy"]}
```

The `claims_that_can_bind` field is the point of contact with the artifact: it
is computed from the label, and a training set is well chosen when the union
across applications covers the registry.

**The profile**, for the bottom row of the 2x3 -- measured facts about the
application, in the same style as the machine briefing, with no label and no
advice:

```
MEASURED PROFILE -- this application, at this problem size, on this node.
  peak RSS            17.7 GB total, 2.2 GB per rank
  thread scaling      6.8x from 1 to 56 threads; flat beyond ~24
  SMT (112 vs 56)     4% slower
  huge pages          1.02x, no effect
  NUMA placement      confined to one domain: 2.1x slower
  I/O                 no bytes written during the timed region
```

**It states measurements and not conclusions**, for the same reason the machine
artifact does. Handing over "this application is bandwidth-bound" would be
handing over the answer, exactly as supplying arithmetic intensity does for a
binary compute-vs-bandwidth question. The arm must still do the classification;
we are giving it evidence, not a verdict. And that keeps the comparison against
the top row meaningful.

---

## Per-application adapter

Reuses the existing `build()` / `run()` config pattern. Each application gets one
`characterize.sh` whose `run()` honours three environment variables:

    CHAR_RANKS      MPI ranks
    CHAR_THREADS    OpenMP threads per rank
    CHAR_SIZE       problem size token, passed through to the app

plus `CHAR_SMT`, `CHAR_HUGEPAGES` and `CHAR_NUMA` for probes C, D and E. The
harness sweeps; the adapter knows only how to launch one configuration.

The same fixed-work discipline applies: whatever `CHAR_SIZE` means, total work
must be constant across every rank/thread combination the sweep visits, or the
scaling curve measures problem size instead of parallel efficiency. For LULESH
that means `ranks x s^3` held constant; for XSBench, `particles x lookups`.

---

## What this does not do

- **Multi-node behaviour.** Communication scaling, collective cost and fabric
  locality need a separate sweep. Deferred deliberately: the single-node label
  is a prerequisite for choosing sizes at all.
- **Distinguish read from write pressure.** Probes are read-dominated.
- **Anything about correctness.** A configuration that runs fast and computes
  the wrong answer looks identical here; the equal-work gate is separate.
