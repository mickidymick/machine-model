# Application characterization suite

Rewritten 2026-08-20. The previous version measured machine responses. See
"The flaw this fixes" for why that was wrong and what survived the rewrite.

## Why this exists

Three jobs, all resting on the same measurements.

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

**3. Be the "profiled" condition.** In the planned 2x3 -- {machine layout, web,
artifact} x {with, without a measured profile} -- the bottom row needs something
to hand the arm.

**The symmetry is worth noticing.** The project's premise was that the LLM
already holds the application half and we supply the machine half. The published
64% source-only classification accuracy (arXiv 2505.03988) and our own LULESH
misclassification both say the application half is unreliable. So this suite is a
**measured application descriptor** standing opposite the measured machine
descriptor -- and the pairing may need both halves measured, which was not the
original claim.

---

## The flaw this fixes

Every probe in the previous spec -- SMT response, thread scaling, huge-page
response, NUMA sensitivity -- measured *how an application responds to a machine
parameter*. A response is a property of a code-machine PAIR at one operating
point. It does not transfer, and the repo already contains the proof.

**The same kernel, opposite sign.** `stream` gained **+88%** from SMT on corsys4
at 2 threads and lost **-5.0%** on Frontier at 56. Recorded in
`cpu.smt_benefit.not_measured` on `frontier-compute.json`. The mechanism is
saturation, so the measurement is a function of the whole operating point --
machine and thread count entangled, which is exactly the point: every element of
that operating point is machine-specific.

**The same kernel, a different number of peaks.** `cost.page_size_penalty` run
with the identical pointer-chase code shows **two** peaks on corsys4 (2.72x at
1 MB, 1.74x at 32 MB) and **one** on Frontier (2.4x at 32 MB). The code's page
demand per unit of work is identical in both runs. What differs is where the
machine's TLB reach falls relative to its cache capacities -- corsys4's L2 is
1 MB per core, Frontier's is 512 KB, so the first TLB boundary lands inside a
cache level on one machine and not the other.

So: "bandwidth-bound", "SMT-friendly", "TLB-hostile" are **not properties of a
code**. Measuring them on machine X tells you about X.

**The rewrite.** Measure transferable application PROPERTIES, and DERIVE the
machine-specific label by joining with the machine artifact.

    property (portable)  x  machine claim (per machine)  ->  label (per pair)

Three consequences:

- Characterization becomes **portable**: do it once on corsys4, apply it on
  Frontier, Tuolumne, Aurora. This converts scarce allocation hours into free
  lab time on a machine we own.
- The artifact does **real work** rather than being background reading. It is
  now load-bearing for a derivation, and a wrong claim produces a wrong label.
- **The join is testable.** Characterize on corsys4, derive the predicted
  Frontier label, measure Frontier directly, compare. That test is specified
  below and is this suite's validation.

**What it costs.** The old spec's rule was "no counters, no instrumentation, no
profiler dependency", and that constraint is precisely what forced every probe
to be a response -- a stopwatch on the target machine can only ever measure a
response. Properties need either source analysis or counters. That is the price
and it is worth paying.

**Nothing is thrown away.** The old probes are re-scoped, not deleted. They
become (a) sampling instruments for fitting a code-intrinsic curve, and (b) the
ground truth for the transfer validation. They were already validated as
discriminators -- the SMT probe reproduced its predicted ordering on three
kernels of known behaviour -- and that validation still holds for the new job.

---

## What counts as a property

A quantity is admissible if it passes all three:

1. **Machine-free definition.** It can be defined without naming any machine
   parameter. "Bytes fetched from beyond a cache of size C" qualifies, for C a
   free variable. "L3 misses" does not; it has the machine's L3 baked in.
2. **Per unit of application work.** Expressed per element-update, per particle
   history, per timestep -- not per second. Per-second quantities are responses.
3. **Analytic or countable in code units.** Either derivable from source and
   parameters, or measurable with counters whose units are the code's.

**The curve rule** is how a former response is converted into a property. Where
the old spec measured the response at the host machine's parameter value, measure
the code's function *over* that parameter and let the target machine's claim
select the point:

| old (response, a point) | new (property, a function) | selected by |
|---|---|---|
| huge-page speedup on this host | pages touched per unit work; page utilisation | TLB reach + `cost.page_size_penalty` |
| SMT gain at this host's core count | sync events per unit work; work items available; per-thread outstanding misses | `cpu.core_inventory`, `cpu.smt_benefit`, `cost.loaded_latency_knee` |
| thread scaling to this host's core count | parallel work available; bytes from memory per unit work | `cpu.core_inventory` + bandwidth per domain |
| NUMA penalty on this host's domains | share of footprint touched by more than one thread; first-touch discipline | `numa.distance_matrix`, `numa.domain_count` |

The point is not that the old measurements were wrong. It is that each is one
sample of a curve, and the curve is the thing that travels.

---

## The property set

Ten properties. `unit of work` (`W`) is per-application and fixed -- LULESH: one
element-update per cycle. XSBench: one macroscopic cross-section lookup. It must
be countable from the application's own output.

| # | property | unit | tier | joins with |
|---|---|---|---|---|
| P1 | **footprint** -- peak resident bytes, total and per rank | B | analytic / free | `cpu.cache_hierarchy`, `numa.domain_count`, node memory |
| P2 | **capacity-miss curve** m(C) -- bytes fetched from beyond a cache of capacity C, per W, for C swept | B/W | inferred / counted | `cpu.cache_hierarchy` |
| P3 | **memory traffic** -- bytes from memory per W, = m(C) at the target's LLC size | B/W | derived from P2 | bandwidth per domain, `cost.loaded_latency_knee` |
| P4 | **compute intensity** -- ops per W, and ops per byte from memory | ops/W | analytic / counted | peak FLOPs, bandwidth (roofline) |
| P5 | **page demand** -- distinct 4 KB pages touched per reuse window; bytes touched per page touched | pages/W | analytic / counted | TLB reach (MISSING), `cost.page_size_penalty` |
| P6 | **access character** -- stride/sequential vs dependent-random; independent misses in flight per thread | dimensionless | inferred / counted | `cost.loaded_latency_knee`, latency vs bandwidth curves |
| P7 | **concurrency structure** -- parallel work items available per rank; synchronisation events per W; serial fraction | items, events/W | analytic / inferred | `cpu.core_inventory`, `cpu.smt_benefit`, `cpu.system_interference` |
| P8 | **sharing character** -- share of footprint written by more than one thread; whether pages are first-touched by their user | fraction | analytic | `numa.distance_matrix`, `numa.symmetry` |
| P9 | **communication** -- bytes per rank per step, message-size distribution, neighbour count, collective types and counts, and how each scales with rank count | B/step | analytic | `net.nic_inventory`, `cost.collective_scaling`, fabric locality |
| P10 | **I/O** -- bytes read and written per W, file count, request-size distribution | B/W, files | analytic / free | `storage.tier_inventory`, `cost.storage_bands` |

**P1, P9 and P10 are the strongest** because they are analytic: computable at
production size without ever running at production size, and they transfer
exactly. Prefer analytic derivation everywhere it is available.

**We already do this and it already won.** The round-3 no-artifact arm's decisive
move was reading LULESH's source and computing that the OpenMP path adds
~768 B/element/cycle on a ~2 KB/element/cycle baseline -- roughly 35% more DRAM
traffic (`eval/exp-b/configs/lulesh/no-artifact.sh`). That is P3, derived
analytically, and it is the source-level property the artifact arm saw and did
not weigh. This suite makes that class of number a measured input rather than
something we hope an arm derives.

---

## Measurement tiers

Every property records which tier produced it. Tier is provenance, and it is
reported.

**Tier 1 -- analytic.** Count allocations and loop trip counts in the source;
derive from documented parameters. Zero runs. Transfers exactly. Evaluable at
production size. Must state the source location it was derived from, so it is
checkable.

**Tier 2 -- counted.** Hardware counters in code units: memory-controller read
and write bytes divided by W for P3; dTLB walk counts for P5; retired FLOPs for
P4. Availability is a risk -- uncore/DF counters may be restricted on Frontier
compute nodes. Verify access before depending on it; if unavailable, tier 3.

**Tier 3 -- inferred.** Sweeps that vary a machine parameter to sample the code's
curve. Report the curve, never the point.

- **m(C)**: LLC restriction via `resctrl` where CAT/L3 QoS is available;
  otherwise a per-rank footprint sweep read against the host's measured cache
  plateaus (which the artifact supplies -- `cpu.cache_hierarchy` is `confirmed`
  on both machines).
- **P5**: the 4K/huge arms of the existing ptrchase methodology, differenced.
- **P6**: curve shape. Prefetchable codes show shallow knees at cache
  boundaries; dependent-random codes show steps at the measured plateau
  latencies.
- **P7**: a concurrency sweep, reported as scaling *residual* after the
  bandwidth ceiling implied by P3 is divided out.

**Tier 3 is an approximation and is labelled as one.** m(C) is code-intrinsic
only under an idealised LRU, fully-associative cache. Real associativity and
replacement policy add error, and the error is machine-specific, which is the
very thing we are trying to escape. Where tier 3 is the only source, confidence
is at most `medium`.

**Validation against known answers.** No property is usable until at least one
method has reproduced the expected value on the `chase` / `fma` / `stream` trio,
whose behaviour we already know on both machines. Same discipline that validated
the SMT probe.

**Sanity floors** -- every probe checked against a physical bound before the
number is believed. Every measurement failure this project has had was a
plausible number, not an error:

- P3 >= compulsory floor (cold footprint / W), and P3 <= bytes touched per W.
- P5 x 4 KB <= footprint touched.
- (P3 x W-rate) <= measured machine bandwidth. This is the check that catches
  the 14 PB/s class of error.
- (P9 per-rank bytes x step rate) <= NIC bandwidth x NIC count.
- P4 <= peak issue rate x cores.

---

## The join

**The formulation that makes this clean:** a claim's `measured_under` block names
the application properties under which its number holds. The application profile
names the application's properties. **The join is matching them.** That is why
NEXT.md's decision to render `measured_under` before the value matters more than
it looked -- it is not a hedge, it is the claim's half of a join key.

`cost.page_size_penalty` is `measured_under: {access_pattern: dependent random,
working_set: swept, threads: 1, traffic: read-only}`. An application with P6 =
sequential-prefetchable falls outside that envelope, and the claim's
`not_measured` block says so in property terms -- it names streaming access as
"the regime where the mechanism does not apply", and declines to assert a value
there, noting that the one available datum (a corsys4 bandwidth check, 107,765
huge vs 107,342 4K) is a different machine and a different metric. That is the
join working correctly: the match fails, and the claim does not bind.

### Derivation rules

Explicit, so a label is reproducible and arguable rather than a judgement call.

**Footprint class** -- P1 per rank against the target's `cpu.cache_hierarchy` and
`numa.domain_count`: `cache-resident` / `domain-resident` / `node-resident` /
`multi-node`. Note the boundaries move: 35.75 MB shared L3 on corsys4 versus
32 MB per L3 region shared by 8 cores on Frontier, so the same per-rank footprint
lands differently depending on ranks per L3 region.

**Limit class** -- from the roofline position of (P3, P4) against the target's
bandwidth and peak issue rate, refined by P6 and P7:

| condition | label |
|---|---|
| P4/P3 below the machine balance point AND P7 says enough work to saturate | `bandwidth-bound` |
| P4/P3 above the balance point, low sync rate | `compute-throughput-bound` |
| few independent misses in flight (P6), traffic below the bandwidth ceiling | `memory-latency-bound` |
| low ops/W per dependent chain, traffic low | `compute-latency-bound` |
| sync events per W high relative to the machine's per-event cost | `synchronisation-bound` |
| none dominant, or two within the stated band | `ambiguous` |

`ambiguous` is a real outcome and must be reported. A forced label is worse than
none, because the answer key would then be wrong in exactly the cases that are
hardest.

**Page-size class** -- P5 against the target's TLB reach: predicted benefit is
nonzero only where pages demanded per reuse window exceeds reach AND the
footprint sits inside a cache level (that conjunction is the mechanism behind
both machines' peaks). Magnitude from `cost.page_size_penalty` at the matching
working-set extent, scaled by the fraction of accesses that miss TLB.

**Placement class** -- P8 against `numa.distance_matrix`. Predicted penalty is
the remote-access share implied by the sharing character, times the measured
remote/local ratio. The declared SLIT ratio is the wrong input on both machines
(corsys4 declares 1.70x against 2.35x latency / 2.87x bandwidth measured), which
is a concrete case of the artifact being load-bearing rather than decorative.

**SMT prediction** -- P7 and P6 against `cpu.smt_benefit` and the bandwidth
headroom implied by P3. Gain where the core has idle issue slots (dependent
chains, low occupancy) and loss where a shared resource is already saturated. The
registry's rule is latency-bound versus throughput-bound, NOT memory versus
compute -- `fma` gained most.

**Communication class** -- P9 against `net.nic_inventory` and
`cost.collective_scaling`, at the target's rank count.

**I/O class** -- P10 against `cost.storage_bands` and `storage.tier_inventory`.

### `claims_that_can_bind`

Falls out of the join: a claim can bind when the application's properties fall
inside its `measured_under` envelope and the derived class puts the code in the
regime the claim describes. This is the point of contact with the registry, and
it is what queue item 2 (training-set selection) consumes -- a training set is
well chosen when the union of `claims_that_can_bind` covers the registry and no
single application covers more than a few.

### What the join needs that the registry does not have

Writing the derivation rules exposed missing claims. Each is a concrete addition
to the artifact build list:

- **TLB reach** (entries x page size, per level). The registry carries
  `cost.page_size_penalty`, which is the *response of our own pointer-chase
  kernel* -- itself a code-machine pair. The structural quantity that lets P5
  predict a different code's penalty is not recorded on either machine.
- **Bandwidth per domain vs per node.** Needed to turn P3 into a limit class.
  Present inside `cost.loaded_latency_knee` and `numa.distance_matrix` but not
  as a claim with its own conditions.
- **Per-core outstanding-miss capacity** (line-fill buffers / MSHRs). Sets
  whether P6's miss concurrency can reach the bandwidth ceiling at all.
- **Synchronisation cost** -- barrier and atomic latency at a given thread count.
  `synchronisation-bound` is underivable without it.

---

## Outputs

Three artefacts. All follow SCHEMA.md's rules -- provenance on every number,
conditions as part of the measurement, the `high`/`medium`/`low`/`flagged`
confidence enum, and `flagged` used rather than dropping or promoting a pattern
that sits in the noise.

**1. `properties.json`** -- per (application, size). Machine-independent. The
portable artefact; this is the thing that gets carried to a new machine.

Shape only. The footprint coefficient is now derived from source and
cross-validated against measurement -- see `analytic-lulesh.md`. `null` marks a
property not yet measured; nothing is guessed.

```json
{"app":"lulesh","size":{"elements":27000000,"side":300,"ranks":27,"s":100},
 "work_unit":"element-update",
 "properties":{
   "footprint":{"per_rank_B":3.2e8,"total_B":8.5e9,"tier":"analytic",
                "derived_from":"315 B/element: lulesh.h:164,185 allocations;
                                agrees with round 3's 230 MB at 729k elements",
                "conditions":{"path":"MPI-only; the threaded path adds >=192 B/element"},
                "confidence":"medium"},
   "mem_traffic":{"B_per_W":2048,"tier":"analytic",
                  "derived_from":"src/lulesh.cc:514,736",
                  "conditions":{"omp":"off; the >1-thread path adds ~768 B/W"},
                  "confidence":"medium"},
   "comm":{"B_per_rank_per_cycle":"6 * s^2 * 8 * nfields","tier":"analytic",
           "confidence":"high"},
   "page_demand":null,
   "access_character":null},
 "measured_on":"corsys4","scale_down":"rank count reduced, per-rank footprint held"}
```

Chosen to land in the regime: the global 300^3 problem is anchored to a published
LULESH configuration measured at 23.6 GB, and 27 ranks x 100^3 satisfies LULESH's
cube constraint while fitting one rank per core inside the 56 allocatable. That
is job 1 of this suite doing its job -- round 3's size was 37x below it.

Note the footprint is config-dependent: the MPI-only path derives to 8.5 GB total
where the published threaded single-rank run measured 23.6 GB. Fixed work is
preserved across decompositions; fixed memory is not.

**2. `label.<machine>.json`** -- the join's output. The answer key. **Never shown
to an arm.** Records which claim produced each class, so a wrong label is
traceable to a wrong claim.

```json
{"app":"lulesh","size":"...","machine":"frontier-compute",
 "footprint":"node-resident",
 "limit":"bandwidth-bound",
 "limit_from":["cost.loaded_latency_knee","cpu.cache_hierarchy"],
 "page_size":"benefit-unlikely","placement":"placement-sensitive",
 "smt":"loss-predicted","io":"none",
 "claims_that_can_bind":["numa.distance_matrix","cost.loaded_latency_knee",
                         "cpu.smt_benefit","cpu.cache_hierarchy"]}
```

**3. `profile.txt`** -- the bottom row of the 2x3. Properties with their
conditions and tiers. **No label, no derivation, no advice.**

```
MEASURED APPLICATION PROFILE -- LULESH 2.0, 400^3 elements, 125 ranks (s=80).
Measured on corsys4 (Xeon Gold 6246R); these are properties of the code, not of
that machine. Rank count was scaled down; per-rank footprint held fixed.

  work unit             one element-update
  footprint             160 MB per rank, 20 GB total                [analytic]
  memory traffic        ~2.0 KB per element-update, MPI-only        [analytic]
                        the >1-thread OpenMP path adds ~768 B       [analytic]
  compute intensity     -- not measured --
  page demand           -- not measured --
  access character      -- not measured --
  concurrency           512,000 items per rank; N barriers/cycle    [analytic]
  sharing               -- not measured --
  communication         6 faces x 80^2 x 8 B x nfields per cycle    [analytic]
  I/O                   no bytes written during the timed region    [analytic]
```

Unmeasured lines are printed as unmeasured rather than omitted, so an arm can see
what it is not being told. Same reason the machine artifact carries
`not_measured` blocks.

**It states measurements, not conclusions**, for the same reason the machine
artifact does. Handing over "this application is bandwidth-bound" would be
handing over the answer.

**One honest caveat.** For the compute-versus-bandwidth axis specifically, P3 and
P4 plus a bandwidth number nearly *are* the answer -- that axis is a division.
arXiv 2505.03988 handed over arithmetic intensity for exactly that reason. So the
experiment cannot rest on that axis. Its discriminating power sits where the join
is genuinely nontrivial: page-size benefit, placement, SMT, collective scaling,
storage band. Design the 2x3's dependent measure around those.

---

## Validation: the corsys4 -> Frontier transfer test

The claim being tested is that properties transfer and responses do not. It is an
empirical claim, so it gets an experiment.

**Design.**

1. Characterize each application on **corsys4** -> `properties.json`. Scale down
   the rank count, hold per-rank footprint fixed, so the memory regime is
   preserved (communication regime is not, and P9 is analytic anyway).
2. Join with `machines/frontier-compute.json` -> predicted Frontier label, plus
   a predicted **magnitude** for each of four responses: huge-page speedup,
   placement penalty, SMT gain, thread-scaling knee.
3. Measure those four responses directly on Frontier, using the old spec's
   probes, now demoted to validation instruments.
4. **Negative control:** predict Frontier's responses by assuming corsys4's
   responses transfer unchanged -- the method this rewrite replaces. Score it
   identically.

Step 4 is not optional. Without it, a successful transfer only shows the method
works, not that it beats the method it replaced. We already know one point where
naive transfer fails badly (`stream` SMT, +88% to -5.0%), but that point is
confounded by thread count, so per-axis scoring is what settles it.

**Pre-registration, before any Frontier run.** Following
`eval/exp-b/PREREGISTRATION.md`. Record: the predicted class per axis, the
predicted magnitude with its band, and what result would falsify the approach.

Proposed bands, to be fixed in the pre-registration:

| axis | primary | magnitude band |
|---|---|---|
| footprint class | exact class match | -- |
| limit class | exact class match, `ambiguous` counted as declared-uncertain not wrong | -- |
| huge-page benefit | sign | +/- 30% relative |
| placement penalty | sign | +/- 25% relative |
| SMT | sign | +/- 20 percentage points |
| scaling knee | within one sweep step | -- |

**What falsifies the approach:** the join scores no better than the negative
control; or the derived labels are right only where they were already obvious
from footprint alone; or the join's accuracy rests on registry claims that turn
out to be wrong on a third machine.

**Known limits of this particular pair.** corsys4 has no accelerator and no HPC
fabric, so GPU-side properties and communication responses cannot be validated
from it -- P9 stays analytic and untested by this experiment, and GPU-offloaded
codes need a GPU-bearing characterization host. corsys4 is also a tiered-memory
machine (192 GB DDR4 + 730 GB Optane); characterize on node 0 with explicit
binding, or the far tier contaminates every property that touches memory.

---

## Use in the 2x3

{machine layout, web, artifact} x {with, without profile}. The profile is
artefact 3, identical in every cell of the bottom row.

The sharpened prediction: **only the artifact-plus-profile cell can complete the
join.** Layout has structure but no costs; web has public specifications but not
`measured_under` envelopes. So expect roughly nothing in the top row, an ordering
of artifact > web ~ layout in the bottom row, and the interaction as the result.

That is a stronger and more falsifiable prediction than "the artifact helps",
and it follows from the join being a defined operation with named inputs.

---

## Per-application adapter

Reuses the `build()` / `run()` pattern in `eval/exp-b/configs/`. One
`characterize.sh` per application, whose `run()` honours:

    CHAR_RANKS      MPI ranks
    CHAR_THREADS    OpenMP threads per rank
    CHAR_SIZE       problem size token, passed through to the app
    CHAR_PAGES      4k | huge          (P5 sampling)
    CHAR_BIND       domain binding     (P8 sampling)
    CHAR_LLC_WAYS   resctrl mask       (P2 sampling, where available)

The harness sweeps; the adapter knows only how to launch one configuration.
Each application also carries an `analytic.md` recording the tier-1 derivations
with source file and line, because an analytic number nobody can check is worse
than a measured one.

**Fixed work is mandatory.** Whatever `CHAR_SIZE` means, total work must be
constant across every rank/thread combination the sweep visits, or the scaling
curve measures problem size instead of parallel efficiency. LULESH: `ranks x s^3`
held constant. XSBench: `particles x lookups`.

**Self-reported timing at usable precision.** LULESH prints `Elapsed time` to two
significant figures, which flattened five distinct runs to sd=0.000. Verify the
application's own timer resolution before selecting it, and if it is inadequate,
time the run externally and say so.

## Harness rules

Carried from what has bitten, repeatedly:

- Sanity-floor every probe against a physical ceiling before believing it.
- Always pass `-o` to sbatch.
- Verify directives by anchored grep, not bare string match.
- Check arithmetic before submitting -- rank counts, cube constraints, element
  totals.
- Never let a glob choose the input file; name the run explicitly. A stale
  `.rebuilt.csv` once won an `ls -t` and produced a well-formed, entirely wrong
  analysis.

## What this does not do

- **GPU-side properties.** Device footprint, occupancy, host-device transfer
  volume per W. Needed for QMCPACK-class codes and not characterizable on
  corsys4 at all.
- **Multi-node responses.** P9 is analytic; whether the prediction holds needs a
  multi-node sweep, deferred.
- **Distinguish read from write pressure.** P3 is reported as a total; the
  registry's own probes are read-dominated and `cost.loaded_latency_knee`
  records read/write mix as `not_measured`. Both halves of the join share this
  gap.
- **Escape cache-model idealisation.** m(C) is code-intrinsic only under LRU and
  full associativity. Tier-3 m(C) is `medium` confidence at best.
- **Anything about correctness.** A configuration that runs fast and computes the
  wrong answer looks identical here; the equal-work gate is separate.
