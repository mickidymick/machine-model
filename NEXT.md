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

1. **Rewrite `eval/characterize/SPEC.md`.** Every probe in it measures a machine
   RESPONSE (SMT, huge pages, NUMA, thread scaling), and responses don't transfer
   between machines. Rewrite to measure transferable app PROPERTIES — footprint
   in bytes, comm volume, I/O volume, access-pattern character — and derive the
   machine-specific label by joining with the artifact. Add the corsys4→Frontier
   transfer test as its validation.

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

## STILL OPEN FROM BEFORE

- One-knob confirmation that round 3b's 2.45 s is the MALLOC change (the arms
  also differ in `OMP_DYNAMIC`).
- XSBench comparison missing — its no-artifact arm failed to build
  (`craype-hugepages2M` + `PrgEnv-amd` = lld rejects `-Ttext-segment`).
- Second draw per arm; every result rests on one stochastic generation.
- corsys4 conditions retrofit (6 claims flagged). Registry pin 0.1 vs 0.6.
- Task-scoped renders (`render.py --for <task>`) — the next artifact lever.
