# Experiment B — result, miniQMC on Frontier, 2026-08-13

Job 5257305, one node (frontier03766), 5 configs × 10 interleaved passes,
50 timed runs, 0 failures. Raw: `results/miniqmc_20260813_161703.rebuilt.csv`.
Timing is miniQMC's own `Total` row, not the harness stopwatch.

> **Superseded in part.** Two statements below were corrected on 2026-08-14 by
> the decomposition runs — see **ATTRIBUTION COMPLETE** at the end of this file.
> The huge-page mechanism is *not* null: it accounts for 96% of the arm gap.
> The residual is *not* unattributed: it is 0.03 s and null. The sections below
> are kept as written because they record what was known at the time.

## The numbers

| config | mean (s) | sd | sd % | position |
|---|---|---|---|---|
| no-artifact-hugepages | 27.69 | 0.054 | 0.19% | — (decomposition) |
| **no-artifact** | **27.75** | 0.069 | 0.25% | **101.3% of headroom** |
| ceiling (hand-tuned) | 28.14 | 0.471 | 1.67% | 100% by definition |
| **with-artifact** | **28.55** | 0.192 | 0.67% | 98.7% of headroom |
| floor (ZeroSum default) | 58.70 | 0.165 | 0.28% | 0% |

**The arm comparison: no-artifact is 0.80 s (2.9%) FASTER. Welch t = −12.43,
dof = 11.3, p = 6.3e−08.** The artifact arm lost, significantly, at n = 10 with
run-to-run spread under 0.7%.

## Scored against the pre-registration

**Prediction: "with-artifact finishes faster than no-artifact on miniQMC."
FALSIFIED.** It finished slower, and the margin is far outside the noise.

**Prediction: "the mechanism has to be placement, not pages."** Neither. The
arms *converged* on placement — both chose 8 ranks × 7 threads × 7 walkers,
both `-t coarse`, both `-march=znver3`, both PrgEnv-gnu, neither took
`QMC_MIXED_PRECISION`. There was no placement disagreement left to win.

**The huge-page decision, isolated: +0.06 s (0.2%), p = 0.062. Not significant.**
`no-artifact-hugepages` is `no-artifact` plus one `module load` line. The
pre-registered mechanism for the entire predicted effect is worth nothing
measurable on this workload.

## Why huge pages did nothing — the finding that matters

The `no-artifact` arm **considered and rejected** the module, reasoning:

> the hot kernel streams 64 contiguous ~12 KB coefficient chunks per spline
> evaluation, so page walks overlap with the DRAM traffic they precede — this
> code is bandwidth-bound, not TLB-latency-bound, so the payoff is small.

**It was right.** `with-artifact` took the module citing our measured 2.4×
page-size penalty at a ~32 MB working set. That number is correct — and it was
measured with a **pointer-chase**, i.e. dependent random access. miniQMC
**streams**. The measurement was sound; the regime did not transfer.

This cuts at the artifact directly. `MACHINE.md` line 17 instructs the reader:

> **Conditions are part of every number.** A latency measured on 4K pages, or a
> bandwidth measured across one of four network links, does not generalise to
> other conditions. The conditions are stated; carry them.

The briefing stated the caveat, the reader had it in context, and the
misapplication happened anyway. **Stating conditions is not sufficient to
prevent a number being used outside its regime.** That is a design finding about
measured-machine artifacts, not merely a null.

It also rhymes with [[machine-model-eval-result]]: there, a tidy authoritative
document made the model *more* confidently wrong than free search did. Here, a
measured number made it confidently wrong in a regime the measurement never
covered. Same failure, different surface.

## Our own ceiling was beaten

`no-artifact` at 27.75 s is faster than `ceiling` at 28.14 s — 101.3% of
"headroom". The ceiling encoded our measured NUMA claims as 4 ranks × 14
threads, one per domain. Both arms independently chose 8 × 7 on L3 boundaries
and both beat it. `with-artifact` explicitly considered 4 × 14 — its own
round-1 choice — and rejected it: one core per L3 group is OS-reserved, leaving
exactly 7 usable per CCD across 8 CCDs, so 8 × 7 is the only geometry confining
a rank to a single L3 *and* a single NUMA domain.

**The hand-tuned reference built from our artifact was the worse
configuration.** The ceiling is also the noisiest config in the set (sd 1.67% vs
0.19–0.67% elsewhere), which is itself worth a look.

## Harness validation

floor 58.70 → ceiling 28.14 is a **2.09× span**, against ZeroSum's published
2.33× (63.67 → 27.33 s) on the same benchmark and machine, with our floor
reproducing their exact baseline shape (one node, 8 ranks, 7 OpenMP threads, no
`-c`). Equal work verified on all 50 runs (56 walkers, recovered independently
from `ranks × walkers` and from `FOM × time / nelec³`).

## Not established

The residual after removing huge pages is **−0.86 s and significant**
(t = −13.59, p = 6.0e−08), so something else makes `with-artifact` slower.
Remaining differences: `OMP_PLACES=cores` vs `threads`, and BLAS linkage
(`-DBLA_VENDOR=All` vs an explicitly pinned `libsci_gnu_*` path — possibly not
the same variant). `-DENABLE_TIMERS=1` is a no-op; it already defaults to 1.
**Do not attribute the residual without a one-knob run.**

## What to claim

Not "the artifact makes codes slower" — one benchmark, one machine, one draw
per arm. What is supported:

1. On this workload the artifact's contribution was **negative and
   significant**, and the pre-registered mechanism was **worth nothing**.
2. The failure mode is **regime mismatch**, not bad data. Every number in the
   briefing is correct.
3. The briefing's own conditions field **did not prevent** the misuse.
4. A control with no machine document reasoned its way to the better
   configuration from the source code — and beat our hand-tuned reference.

The methodological answer this points to: a measured artifact should carry the
**access pattern under which each number was obtained** as a first-class,
matchable field, not as prose the reader is asked to honour. That is a concrete,
testable next design step, and this experiment is what motivates it.

---

# ATTRIBUTION COMPLETE — 2026-08-14

Three decomposition runs, n = 10 each, all interleaved in single allocations.

| knob varied (one at a time, from with-artifact) | mean s | vs with-artifact | verdict |
|---|---|---|---|
| `OMP_PLACES` cores→threads | 28.35 | +0.04 | null |
| BLAS pinned libsci→`BLA_VENDOR=All` | 28.36 | +0.05 | **no-op** — byte-identical binary |
| drop `--distribution=block:block` | 28.41 | +0.10 | null |
| `craype-x86-trento` | — | — | killed by `objdump`, identical codegen |
| **drop `craype-hugepages2M`** | **27.69** | **−0.76** | **p = 3.2e−10** |

**Huge pages account for 96% of the arm gap.** Residual 0.03 s, p = 0.35, null.
Strip them from the treatment arm and it is statistically indistinguishable from
the control (27.69 vs 27.66 s).

## The distinction that matters

| | relink | runtime `HUGETLB_*` | effect |
|---|---|---|---|
| no-artifact-hugepages | yes | **no** | +0.06 s, n.s. |
| with-artifact | yes | **yes** | **−0.76 s, p=3e−10** |

The relink alone is free. **Huge pages actually backing the heap is what costs
2.7%.** The first decomposition missed this because the added `module load`
landed in `build()` only, and `no-artifact`'s `run()` loads no modules.

## The corrected claim

Not "the number failed to transfer." **The number inverted.** A measured 2.4×
*benefit* under pointer-chase became a measured 2.7% *penalty* under streaming
with first-touch placement. An artifact recording `page_size_penalty: 2.4x`
without the access pattern does not merely fail to help — it reverses sign, and
the briefing's prose instruction to "carry the conditions" did not prevent it.

**Hypothesis for the mechanism, not measured:** first-touch granularity. At 4 KB
each thread's slice of the ~19 MB determinant matrices lands on its own NUMA
domain; at 2 MB one page can span data first-touched by threads on different
domains, coarsening placement and forcing remote reads. Testing it is future work.

## Method notes

- `craype-x86-trento` was eliminated by `objdump` — 2779 FMA and 19521 AVX2
  instructions in both binaries — for the cost of one command rather than an
  allocation.
- The BLAS knob was a **no-op**: byte-identical binary, so its null says nothing
  about BLAS. Recorded because it was briefly counted as evidence.
- Only **two distinct binaries** exist across all nine configurations, split
  exactly on the huge-page relink (1226920 vs 1226960 bytes).

---

# CORRECTION — 2026-08-18. The defect is more specific than first recorded.

The write-up above says the conditions were stated and the model misapplied the
number anyway. That is true but imprecise, and the precise version is a better
finding.

**What the treatment arm actually read** (render of `cost.page_size_penalty`):

```
- regime variable: working set size
- regimes:
  - extent 32 MB, huge 13.3, 4K 32.2, delta 18.9, ratio 2.4x, reason PEAK...
  - extent 64 MB - 1 GB, huge 58-89, 4K 67-103, delta 9-14...

Note: Latency effect only. Streaming bandwidth barely notices page size --
107,765 huge vs 107,342 4K on corsys4 -- because sequential reads amortise the
walk across a whole page.
```

**What the treatment arm wrote:**

> the 4K penalty peaks at 2.4x for a ~32 MB working set (the 1536^2 determinant
> matrices are 19 MB) and settles to a +9-14 ns offset from 64 MB-1 GB (the
> 750 MB spline table)

It matched its working set against the declared regime variable, **correctly**.
It did exactly what the structure told it to do.

**The defect: the artifact declared ONE regime variable and there were two.**
`regime_variable: "working set size"` is singular and authoritative. The
access-pattern dependency appears only as a trailing prose `Note`, and that note
is phrased in terms of the *measurement metric* — "streaming **bandwidth** barely
notices" — rather than a property a reader can recognise in their own kernel.
Mapping "my spline kernel streams contiguous chunks" onto "streaming bandwidth
barely notices page size" requires a translation the structured fields never
asked for.

**So the conclusion is not "prose caveats are insufficient" but something
sharper: a structured field that names the regime variable is an assertion that
those are THE regime variables.** A reader that trusts the structure — which is
the whole point of structuring it — will not go looking for a second axis
hiding in a footnote.

This is why `measured_under` must be a matchable record of the conditions rather
than a prose note, and why `regime_variable` must be a list. It also raises the
bar for the retrofit: every existing cost claim needs asking "what else did we
hold fixed that we never declared?", not just "did we write down the conditions".

---

# ROUND 3, LULESH — 2026-08-19. The artifact arm is 2x slower.

| arm | mean s | sd | geometry |
|---|---|---|---|
| no-artifact | **5.42** | 0.007 (0.12%) | 125 ranks x 1 thread, flat MPI |
| with-artifact | **10.93** | 0.025 (0.23%) | 8 ranks x 7 threads, one per L3 group |

Welch t = -483, p = 6.2e-12, n = 5. Equal work verified: both 729,000 elements
(125 x 18^3 and 8 x 45^3).

## What the with-artifact arm did, and it is not incompetence

Its reasoning is dense with correctly-applied artifact facts:

- **SMT off**, citing `cpu.smt_benefit`: *"latency-bound kernels gain +70-78%, the
  BANDWIDTH-SATURATED stream kernel loses 5.0%. LULESH sweeps element and node
  arrays contiguously... which is the arm that LOSES."*
- **Huge pages declined**, citing `cost.page_size_penalty`'s mechanism and the
  recorded inversion.
- **8 ranks**, one per L3 group, citing NPS4 and first-touch.

Every one of those uses a measured claim correctly, including two added the same
day. This is the artifact working as designed.

## What it never weighed

The no-artifact arm read the source and found the dominant lever:

> whenever `omp_get_max_threads() > 1`, LULESH switches to a completely different
> force-summation algorithm... ~768 extra bytes of memory traffic per element per
> cycle, twice a cycle, on top of roughly 2 KB/element/cycle -- i.e. ~35% more
> DRAM traffic on a node that is already memory-bandwidth bound. Running MPI-only
> keeps the cheap path.

The with-artifact arm's SOLUTION.sh contains **zero mentions** of it, though its
post-hoc answer lists the force-accumulation path among what it read. So it saw
the fact and did not weight it, which is worse than missing it: the machine
document won an argument against a source fact already in hand.

## The claim this supports, stated carefully

NOT "the artifact gives bad advice" -- every number it used was correct, and
correctly conditioned.

**A rich machine document changes where a model spends its attention, and
attention is finite.** The treatment arm reasoned about four machine properties
and one application property; the control reasoned about one machine property
and three application properties, and the application properties were where the
performance was.

This is the SECOND instance. It was flagged as a risk before round 2 --
"a machine-shaped document nudges toward machine-shaped answers on a code whose
main lever is an application property" -- and miniQMC was the first, at 2.9%.
LULESH is the same shape at 102%.

## Attribution is NOT established

The two configs differ in several ways at once and a one-knob decomposition is
required before any causal claim:

- **125 vs 56 hardware threads.** The control used 2.2x more of the node. This
  alone could explain most of the gap and has nothing to do with attention.
- **flat MPI vs hybrid**, which is what triggers the expensive force path.
- **SMT on vs off**, tangled with the above.

Decomposition needed: (a) 8 ranks x 7 threads with SMT ON, to test whether the
`cpu.smt_benefit` classification was itself wrong; (b) 56 ranks x 1 thread flat
MPI without SMT, to separate "more threads" from "cheap force path"; (c) 125
ranks with the OpenMP build, to isolate the force path directly.

Until those run, the honest statement is: the control was twice as fast, its
own account credits a source-level fact worth ~35% memory traffic, and the
treatment arm never weighed that fact.

## And a caveat about this run specifically

Both arms ran under `-S 0 --threads-per-core=2`, a permissive allocation chosen
so each arm could have the flags it asked for. That means **no core
specialization**, which is not the Frontier default and is not the environment
either arm reasoned about. Applied equally, so not an arm-vs-arm confound, but
it is not the production configuration.
