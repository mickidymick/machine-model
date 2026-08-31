# Pick up here — after 2026-08-19

Everything below is committed and pushed on `machine-model` and `frontier`.

---

## THE RESULT SO FAR

Round 3 established the project's central finding. **Every artifact fact the
treatment arm used was correct, every application was correct, and it still lost
2x** — because the dominant lever was a source-level property it saw and did not
weigh. A document-level scope paragraph recovered **44%** of that gap.

    no-artifact                    5.43 s
    with-artifact + scope para     8.50 s   <- one paragraph, p=6.3e-16
    with-artifact                 10.95 s

Full write-up: `eval/exp-b/RESULTS.md`. Memory: `machine-model-attention-finding`.

---

## 1. LOOSE ENDS ON THE FINDING (do before it goes in a paper)

- **One-knob confirmation.** The two artifact arms differ in the two `MALLOC_*`
  variables AND `OMP_DYNAMIC=false`. Run the unscoped arm plus the MALLOC vars
  only, to confirm the 2.45 s is the allocator change. One node, minutes.
- **XSBench comparison is MISSING.** Its no-artifact arm failed to build:
  `craype-hugepages2M` injects `-Wl,-Ttext-segment`, which `PrgEnv-amd`'s lld
  rejects. Recorded as a pitfall. Pre-registration says report it as an arm
  failure rather than re-roll — but that loses the half of round 3 that tested
  correct POSITIVE use of the page-size number. Decide: report as-is, or add a
  disclosed "iterations to a working configuration" metric.
- **Second draw per arm.** Agent output is stochastic and every result so far
  rests on one draw per arm. Three would separate the artifact's effect from the
  luck of a single generation. Cheap — no allocation, just sessions.

## 2. THE NEXT LEVER

**Task-scoped renders.** If 44% comes from re-pointing attention inside 713
lines, reducing what must be read should beat further framing. `render.py
--for placement` was already on the build list. This is now the highest-value
artifact change.

The alternative, if that fails: accept the bound and report it. A machine
descriptor may not be the right instrument for codes whose dominant lever is
algorithmic, and saying so with this measurement behind it beats a tuned win.

## 3. ARTIFACT STATE

Registry **0.6**, 20 claims. Frontier: 4 confirmed / 3 misleading / 3
contradicted / 6 undeclared / 1 unfalsifiable / 1 untested, 11 pitfalls.
Every measured QUANTITY carries `measured_under` / `not_measured` / `mechanism`,
rendered BEFORE the value. `check.py` flags any that do not.

Added 2026-08-18/19: `storage.tier_inventory`, `cost.collective_scaling`,
`cpu.smt_benefit`, `cost.storage_bands`.

**Outstanding:** corsys4 not retrofitted with conditions (6 flagged). Registry
pin still 0.1 against 0.6 — diff what changed before bumping. `cpu.system_interference`
and HSA_XNACK still unbuilt. Fabric follow-ups (the two 3.47us outliers, a
low-occupancy run, `--switches=1`).

## 4. THINGS THAT BIT, REPEATEDLY

Every measurement failure this week was **a plausible number, not an error**,
and every one was caught by a physics or arithmetic expectation rather than by
the code looking wrong:

- SMT probe reported 14 PB/s (loops optimised out)
- missing `fsync` overstated storage 5.9x
- `/dev/zero` on NVMe reported 311 GB/s (device elides zero blocks)
- LULESH's `Elapsed time` prints 2 significant figures — five distinct runs
  flattened to sd=0.000
- a stale `.rebuilt.csv` won an `ls -t` glob and produced a well-formed,
  entirely wrong analysis

Harness rules that follow: sanity-floor every probe against a physical ceiling;
always pass `-o` to sbatch; verify directives by anchored grep, not bare string
match (a comment matched once and hid a missing `#SBATCH` line); check
arithmetic before submitting (64 was an illegal LULESH rank count).


---

# 2026-08-20 — design session, no runs

Read `machine-model-scope-decisions` in memory first; it holds the reasoning.

## THE CORRECTION THAT MATTERS

Round 3 ran LULESH at **230 MB on a 512 GB node** — cache-resident, so almost no
artifact claim could bind. The arm's "bandwidth-saturated" call was wrong and the
`cpu.smt_benefit` agreement to 0.6pp was coincidence. Correction is appended to
`eval/exp-b/RESULTS.md`. **Problem size is a selection criterion.**

## QUEUE, in order

1. ~~**Rewrite `eval/characterize/SPEC.md`.**~~ **DONE 2026-08-20.** Ten
   transferable properties (P1–P10), three measurement tiers (analytic /
   counted / inferred), explicit join rules, and the corsys4→Frontier transfer
   test with a negative control. Three things came out of writing it:

   - **The join is `measured_under` matching.** A claim's `measured_under` names
     the application properties under which its number holds; the app profile
     names the app's properties; the join is matching them. That makes rendering
     conditions before the value structural, not a hedge.
   - **The premise is already proven in-repo.** `stream` gained +88% from SMT on
     corsys4 at 2 threads and lost 5.0% on Frontier at 56; the identical
     pointer-chase shows two page-size peaks on corsys4 and one on Frontier.
     Same code, different response.
   - **The join needs four claims the registry does not have** — see below.

   Next concrete step is the per-app `analytic.md` derivations (tier 1, zero
   runs), starting with LULESH's bytes-per-element-update, which round 3's
   winning arm already computed from source.

2. **Settle the behaviour axes and pick training-set candidates.** Rule: every
   registry claim binds for at least one app; no app exercises more than a few.
   Check by mapping candidates against `registry/claims.json`. Keep a held-out
   test set — miniQMC and LULESH are already partly burned.

3. **Characterize each candidate** and choose the size where the target regime
   actually appears. Analytic where possible (footprint, comm volume).

4. **Then the 2x3.** {machine layout, web, artifact} × {with, without profile}.
   The interaction is the hypothesis: regime-dependent claims are only usable by
   a reader that knows its own regime.

5. **Endgame: the sweep comparison.** Diagnostic runs + machine knowledge vs a
   combinatorial config sweep, and at what fraction of the cost. Last, not first
   — run it now and it measures our current known-bad state.

## NEW ARTIFACT WORK, exposed by writing the join

Writing the derivation rules found four quantities the join needs and the
registry does not carry. Each is a candidate claim:

- **TLB reach** (entries × page size, per level). The registry has
  `cost.page_size_penalty`, which is the *response of our own pointer-chase
  kernel* — itself a code-machine pair. The structural quantity that lets a
  different code's page demand predict its penalty is recorded on neither
  machine. This is the same structural gap as `cost.page_size_penalty` being
  "the first entry hwloc's data model structurally cannot hold".
- **Bandwidth per domain vs per node**, as a claim with its own conditions.
  Currently buried inside `cost.loaded_latency_knee` and `numa.distance_matrix`.
- **Per-core outstanding-miss capacity** (line-fill buffers / MSHRs). Sets
  whether a code's miss concurrency can reach the bandwidth ceiling at all.
- **Synchronisation cost** — barrier and atomic latency at a given thread count.
  A `synchronisation-bound` label is underivable without it.

## STILL OPEN FROM BEFORE

- One-knob confirmation that round 3b's 2.45 s is the MALLOC change (the arms
  also differ in `OMP_DYNAMIC`).
- XSBench comparison missing — its no-artifact arm failed to build
  (`craype-hugepages2M` + `PrgEnv-amd` = lld rejects `-Ttext-segment`).
- Second draw per arm; every result rests on one stochastic generation.
- corsys4 conditions retrofit (6 claims flagged). Registry pin 0.1 vs 0.6.
- Task-scoped renders (`render.py --for <task>`) — the next artifact lever.

---

# 2026-08-31 — pick up here

Everything below supersedes the queue above, which predates the Genesis reframe.

## WHAT CHANGED: Genesis

Genesis (ORNL) funds AI-assisted conversion and optimisation of legacy HPC codes
on the national machines — five applications in the first sprint, their choice
undecided and possibly months away. That is this project's question, which makes
the descriptor the instrument for it rather than a parallel effort.

**Scope cut roughly in half.** Out: the corsys4→Frontier transfer study, the
sweep comparison, three of the four new claims (TLB reach stays), the property
set trimmed ten → five. Kept deliberately: the web baseline, replication, and
the corsys4 two-failure-modes finding even though corsys4 leaves the harness.

**The timeline fix became the design:** develop on the five codes already built,
hold the Genesis five as the untouched test set.

## DONE SINCE 08-20

- **`eval/characterize/SPEC.md`** rewritten — transferable properties, the join
  via `measured_under` matching.
- **`COVERAGE.md`** — five apps × twenty claims. Two claims have apps on
  opposite sides (`smt_benefit`, `page_size_penalty` for XSBench vs LULESH);
  three claims bind for nothing because everything is single-node and nothing
  writes data.
- **LULESH resized** to global 300³ = 27e6 elements, anchored to a published
  23.6 GB run. `analytic-lulesh.md` has the derivation and its correction.
- **Spread probe, four revisions, closed.** `SPREAD-RESULTS.md`. Verdict:
  proceed. 1.72× spread, 1.3% within-job noise, 64 ranks fastest, SMT 4% faster
  where `cpu.smt_benefit` predicts −5%.
- **XSBench build unblocked** — the conflict is craype-hugepages vs *lld*, not
  vs PrgEnv-amd. Three routes work, including `-fuse-ld=bfd`. The artifact's
  pitfall said no flag reconciles them; it was wrong and an arm acted on it.
- **Two contamination leaks found and gated.** `tools/leakcheck.py`; `setup.sh`
  refuses to build leaked arms. Round-4 batch 1 voided.
- **Round-4 batch 2 collected**: six configs and twelve transcripts archived in
  `arms-r4/batch2*`. Manipulation verified — MACHINE.md engagement 34/43/26 in
  treatment, 0/0/0 in control.

## THE STATE OF ROUND 4

**Five of six arms chose the identical configuration** — 8 ranks × 150³, 7
threads, `--threads-per-core=1`. Only B1 differs: 8 × 14 with SMT, reasoning
correctly from the artifact's latency-vs-throughput rule.

So the A/B contrast is nearly degenerate. Report **B1 against the pooled other
five**, not A-mean vs B-mean. The five identical configs are a free within-
harness noise floor and a side-test of whether `--cpu-bind` flavour and
distribution matter.

Batch 1 (voided) showed the complement: B3 read the *same* SMT rule and
*declined* SMT, classifying the kernel as bandwidth-bound where B1 called it
FP-latency-bound. **Same artifact, same correct sentence, opposite decisions** —
because the rule needs a regime classification the arm must make itself. That is
the thesis inside a single claim.

## NEXT, in order

1. **Collect batch 2 into `configs/lulesh/`** and create matching
   `arms/<name>/lulesh` trees (build_all.sh keys off the config name).
   `configs/lulesh/` is empty; round 3's five are archived in `lulesh-r3/`.
2. **Run it.** `BENCH=lulesh PASSES=3 EXPECT_WORK=27000000 sbatch -t 02:00:00`.
   Note `-i 50` in the spec vs `-i 20` in the probe — wall clock is ~2.5× the
   probe's; grind transfers, seconds do not.
3. **XSBench.** This is the discriminating test and LULESH is not — `COVERAGE.md`
   scores `page_size_penalty` `+++` for XSBench and `--` for LULESH, and five of
   six LULESH arms converging is that prediction coming true.
4. **Preregistration** before the XSBench sessions, not after.

## STILL OPEN

- Whether bare `srun -n 64 -c 1` fails under a default allocation. The
  "core_inventory unlocks the best configuration" claim rests on it. Two minutes.
- `problem-lulesh.md` says the size is "given below" but setup.sh writes it to a
  separate PROBLEM.md — no arm has been bitten yet, but fix the wording.
- Three claims bind for nothing (NIC, both storage). One multi-node AMG config
  fixes the first; the storage gap should be reported, not manufactured away.
- corsys4 conditions retrofit; registry pin 0.1 vs 0.6.
- `cpu.system_interference` untested; QMCPACK still named in the briefing, so it
  is burned as a test application until generalised.
