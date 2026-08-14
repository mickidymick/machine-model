# Predictions, written before the first run

Recorded 2026-08-10, before any Experiment B configuration was generated or run.
The point is that a prediction made after seeing the data is not a prediction.

## Primary

**CPU / AMG: the artifact arm wins, possibly by a lot.**

Mechanism: `cost.page_size_penalty` is 2.4x at a ~32 MiB working set with
irregular access (13.3 ns on 2 MB pages vs 32.2 ns on 4K), and on this machine
2 MB pages require `craype-hugepages2M`, which works by **relinking**. THP is
`[never]` and the hugetlb pool is empty, so nothing else gets you there.

In the 2026-08-10 knowledge eval the no-artifact arms got the *general* answer
("madvise success does not prove huge pages, check smaps") but missed all three
Frontier specifics. If that holds, the no-artifact arm never relinks and pays the
penalty on a sparse solver.

**GPU / QMCPACK: plausibly a null.**

The large GPU-side facts -- 8 schedulable GCDs rather than 4 packages, `-c 56`
rather than 64 -- were found by *every* arm in the knowledge eval, including the
web arm, from the OLCF User Guide. What remains that only the artifact knows is
`gpu.die_parity`: 158 ns on host-memory latency, in a GPU-offloaded code where
host memory is a small share of runtime. It may not surface at all.

## Secondary

- Neither arm uses more than one node. The 4-node limit is partly a distractor;
  both benchmarks fit on one node at these sizes. An arm that allocates 4 nodes
  has mistaken the ceiling for a target.
- The no-artifact arm gets `-c 56` right. It is in the OLCF guide via Slurm's
  `-S 8` core specialization, and the web arm found it unprompted.
- The artifact arm's advantage on AMG is dominated by huge pages, not by NUMA
  placement. Both arms should bind ranks to domains; only one relinks.
- Any die-parity effect on QMCPACK is under 3%.

## What would falsify the project's claim

- The no-artifact arm relinks for huge pages anyway (from general Cray knowledge
  rather than from measurement). Then the artifact's largest CPU-side
  contribution is already public and the gap should close.
- The gap on both benchmarks sits inside the run-to-run spread. `collect.py`
  reports NULL rather than a small win when it does; that guard is deliberate.
- The ceiling is not faster than the floor -- the tuning does not matter on these
  codes at these sizes, and the experiment cannot discriminate anything.

## What a null on GPU would mean

Not a failure. It would say the artifact's value is **concentrated where the
public record is silent**, and on the GPU side much of it is not. That is more
useful than a uniform win: it says where to point the next machine's
characterization, and it is a claim we can defend.

## Model and context, recorded before any result (2026-08-13)

Experiment A ran on **Opus 4.8, effort High**, via Jeff's `claude` CLI. The
Experiment B arms run on whatever Claude Code defaults to, which on 2026-08-13
is **Opus 5 with a 1M context window**. This is noted now rather than after the
numbers exist.

**It does not threaten B's internal validity.** The comparison is between two
arms of B, and both arms are the same model in the same harness -- the arms
differ in one file. What it does forbid is arithmetic *across* experiments:
no subtracting an A score from a B result, and no claim that the artifact's
value "grew" or "shrank" between them.

**Both arms must be on the same model, and it must be recorded.** Different
defaults in the two sessions would be a genuine confound, and it is exactly the
kind that reports as a plausible number rather than an error. Each arm's model
and context are captured into its `SOLUTION.sh` header at collection time.

**Direction of the expected bias.** A stronger model with a larger context is a
*more capable no-artifact arm*: better recall of Cray defaults, more room to
read the benchmark source. So it should make the artifact's measured advantage
**smaller**, not larger. Under that bias a win is conservative and worth more
than the same win on a weaker model. A null is correspondingly weaker evidence
-- it would not distinguish "the artifact adds nothing" from "this model already
knew it," and settling that would need a rerun on the A-era model.

## Amendment, before round 2 (2026-08-13) -- two decisions taken after seeing round 1's configs but before any timing

Round 1 produced configurations but no timings; it was voided because the spec
left total work free. See `results/round1-voided/`. Two choices made now, in the
open, because both were prompted by reading round 1:

**1. The VMem leftovers STAY in the arm trees.** `src/vpage_llc_misses.out`,
`src/working/` and `src/exe` are profiling residue from a different machine and
a different problem. The round-1 no-artifact arm read one number out of them --
86M minor page faults at 4 KB -- and cited it as corroboration for huge pages,
which is exactly the pre-registered mechanism. The clean-experiment move is to
delete them. **We are not deleting them**, because removing evidence that helped
the CONTROL, after observing that it helped the control, biases the experiment
toward our own hypothesis. Leaving them in makes the no-artifact arm stronger
than it would otherwise be, so any surviving gap is conservative. The confound
is declared rather than removed, and it must be reported alongside the result:
if the artifact wins, it won against a control that had a page-fault count
handed to it.

**2. The falsifier is treated as fired.** Both arms relinked for huge pages
without being told to. The pre-registration says that means "the artifact's
largest CPU-side contribution is already public and the gap should close."
Round 2 does not get to reinterpret that. If AMG comes back a null, the honest
reading is that this prediction was wrong on this benchmark -- not that the
experiment failed. What remains genuinely artifact-only on AMG is rank/NUMA
geometry and the `-c 14` NIC-policy constraint, both smaller effects than the
2.4x that was predicted to dominate.

**Unchanged prediction, restated so it can still be scored:** with-artifact
finishes faster than no-artifact on AMG. The mechanism now has to be placement,
not pages.

## Method adopted from ZeroSum, before round 2 runs (2026-08-13)

Huck & Malony's ZeroSum paper (SC-W 2023) is the closest published precedent for
this comparison, and it is also the paper whose unbuilt phase 2 this project
exists to supply. Four things adopted from it:

**1. n = 10 per condition, in one allocation, decided by a t-test.** Their
sec 4.1 ran miniQMC ten times per condition and reported 27.3396 +/- 0.0358 s
against 27.3395 +/- 0.1043 s, t-test p = 0.998 -- a null -- and separately
57.0657 +/- 0.0486 vs 57.3409 +/- 0.1823, p = 0.0006, a real effect of 0.5%.
A 0.13% run-to-run sd is what made a sub-1% decision possible. Our previous
n = 3 with a "gap < 2x spread" heuristic could not have resolved anything of the
size we now expect. `collect.py` does Welch (not Student, because ZeroSum's own
two conditions differed ~3x in variance) and reports the minimum detectable
effect whenever it returns a null, so "we found nothing" is distinguished from
"nothing is there".

**2. The floor is now the genuine naive default.** ZeroSum's baseline was
`srun -n8` with `OMP_NUM_THREADS=7` and no `-c`, which puts seven threads on one
core: 63.67 s against 27.33 s. The entire 2.33x in their paper is one missing
flag. `floor.sh` reproduces that specific mistake on AMG. The old floor
(`-N1 -n1`) was not the thing a user would actually type.

**3. Results are reported as a four-point ladder,** floor / no-artifact /
with-artifact / ceiling, not as a pairwise percentage.

**4. This reframes what a win would even mean, and the reframing is not in our
favour.** ZeroSum's ladder is: one documented flag worth 2.33x, then refined
thread binding worth *nothing measurable* (27.33 -> 27.40 s, and they said so
plainly). Our situation is the same shape -- huge pages are large and public,
placement is artifact-only and small. **Both of our arms already clear
ZeroSum's entire 2.33x**, because both knew about `-c` and core specialization.
So the headline gap that paper demonstrates is not available to us, and the
effect we are looking for sits in the band where ZeroSum measured a null.

**Consequence for the claim, recorded now:** if AMG returns a null, that is
consistent with the strongest published precedent rather than a failure of the
experiment. It would bound the artifact's contribution to the region above what
public documentation already delivers, which is exactly what
[[machine-model-eval-result]] found for answers. The claim to defend is not
"the artifact makes codes faster"; it is "the artifact is what distinguishes
published from verified, and the runtime consequence of that on this machine is
X" -- with X measured honestly, including if X is zero.

## Benchmark switched to miniQMC, before round 2 runs (2026-08-13)

**The primary benchmark is now miniQMC, not AMG.** Recorded before any round-2
timing exists. Reasons, in order of weight:

1. **AMG has no GPU path at all** — no HIP/CUDA in the tree — so die parity, the
   GCD/NUMA map and host-device transfer, the most artifact-only facts we hold,
   are untestable on it.
2. **AMG's second-largest lever is an application property, not a machine one.**
   hypre threads poorly and flat MPI is standard practice; a machine document
   can only mislead there. Round 1's arms split exactly along that line (224
   flat ranks vs 16x14 threaded).
3. **miniQMC is ZeroSum's own benchmark on this machine.** We are building the
   phase 2 they declined to build, so their ladder (63.67 -> 27.33 -> 27.40 s)
   becomes a published reference our floor can be checked against.
4. It is the ECP proxy for QMCPACK, has CPU-only and OMP_offload builds so one
   benchmark covers both arms, and runs in ~30 s -- which is what makes n=10
   affordable at all. Full QMCPACK being pre-built is not an advantage: the arms
   must control their own builds because craype-hugepages2M relinks.

**Predictions carried over unchanged, restated for miniQMC so they can still be
scored:** with-artifact finishes faster than no-artifact; the mechanism has to
be placement rather than pages, since round 1 showed both arms relinking; and
neither arm should need more than the 4-node budget.

**One confound does NOT carry over.** The VMem residue that fed the round-1
no-artifact arm an 86M-minor-page-fault count lived in the AMG tree. miniQMC is
a clean upstream clone, so round 2 has no such leakage in either arm. This
removes a declared confound rather than hiding one -- but it also means a
no-artifact arm that still derives huge pages did so with less help than in
round 1, which strengthens rather than weakens that finding.

**Two spec traps found by reading the source before writing the spec** (round 1
taught this): miniQMC defaults walkers to `omp_get_max_threads()`, so work would
otherwise follow thread count; and `QMC_MPI` defaults to 0, so a build without
`-DQMC_MPI=1` silently runs every rank as an independent serial copy. Both are
stated in PROBLEM.md for both arms, because neither is a machine fact and an
arm that tripped over one would add variance unrelated to the hypothesis.
Equal work is now also checked automatically from the application's own output:
`FOM x time / nelec^3` recovers ranks x walkers independently, and `collect.py`
SUPPRESSES the arm comparison if the configs did different work.

## Build requirements given to both arms (2026-08-13)

Three miniQMC build facts are stated in PROBLEM.md rather than left as traps:
`-DQMC_MPI=1` (off by default; without it every rank runs the whole problem
serially and nothing says so), `-w` explicit (walkers otherwise default to
thread count, which is round 1's failure exactly), and
`-DCMAKE_SYSTEM_NAME=CrayLinuxEnvironment` (without it CMake's FindMPI does not
recognise the Cray `CC` wrapper and configuration fails outright -- found when
the reference configs failed to build on Frontier).

The last one is arguably machine knowledge a web-capable agent could find, so
supplying it removes a small discriminator. It is supplied anyway: an arm that
fails to configure produces no data point at all, and losing an arm to a build
detail would be variance with nothing to do with the hypothesis. Declared here
rather than quietly, because it does slightly favour the no-artifact arm.

## The line between "build requirement" and "tuning decision" (2026-08-13)

Frontier defaults to PrgEnv-cray, and miniQMC has no `CrayCompilers.cmake` --
CMakeLists recognises `COMPILER Cray`, warns "No default file for compiler", and
sets no flags at all, so the build fails in NewTimer.cpp. The reference configs
now load PrgEnv-gnu.

**This is deliberately NOT added to PROBLEM.md.** The rule being applied:

> State a build requirement in the spec when it has **no performance
> consequence**. Leave anything that could change the speed to the arms.

`-DQMC_MPI=1`, `-w`, and `-DCMAKE_SYSTEM_NAME=CrayLinuxEnvironment` are in the
spec because each is binary -- the run is either correct or meaningless, and no
choice among them is faster. **Compiler choice is not like that.** PrgEnv-gnu
vs PrgEnv-amd is a real performance decision on this machine, and handing it
over would delete a legitimate discriminator.

The evidence says the arms can find it: in round 1 BOTH arms loaded a
non-default PrgEnv unprompted (no-artifact chose PrgEnv-amd, with-artifact
PrgEnv-gnu), and task.md already tells them to read the source, where the
missing CrayCompilers.cmake is visible in CMake/.

**Accepted risk:** an arm that leaves the default PrgEnv will fail to build and
produce no data point. `build_all.sh` reports NO BINARY rather than a time, so
that failure is loud. If it happens it gets reported as an arm failure, not
quietly re-run until it works -- re-rolling a failed arm until it succeeds would
select for the outcome we want.

## Allocation cut from 4 nodes to 1, before any timing (2026-08-13)

The 4-node limit was inherited from the AMG task design and never re-examined
against miniQMC. It should have been.

miniQMC calls MPI only for `MPI_Init`/`Comm_rank`/`Comm_size`. There is no
communication inside the timed region, the reported `Total` is one rank's wall
clock, and every node is loaded identically and independently. **Three of the
four nodes therefore did work that never entered the measured number**, while
adding queue wait, allocation cost, and node-to-node variability -- which
[[frontier-2026-08-10-results]] already lists as this machine's biggest
unquantified noise source.

At 1 node the total walker count is 56, one per allocatable core. Both arms'
round-2 geometries survive the change (8 ranks x 7 on L3 boundaries, 4 x 14 on
NUMA domains), and the floor becomes almost exactly ZeroSum's published
baseline: one node, 8 ranks, 7 OpenMP threads, no `-c`. That makes their
63.67 s -> 27.33 s ladder directly comparable to ours rather than merely
analogous.

The 4-node configs are archived unrun in `results/round2-4node-superseded/`.
They are kept because both arms independently derived the no-communication
property and declined to use the network -- with-artifact explicitly dismissed
the entire Slingshot section of the briefing as inapplicable. That is the
artifact being used correctly by NOT being used, and it is worth reporting.

**This changes nothing about the predictions.** The comparison remains
no-artifact vs with-artifact on intra-node placement, which is where the
artifact-only content was always concentrated.

## SCORED, 2026-08-13. The prediction was falsified.

Full write-up in `RESULTS.md`. In brief, so the pre-registration is honest about
its own outcome:

- **"with-artifact finishes faster than no-artifact": FALSE.** 28.55 s vs
  27.75 s, p = 6.3e-08, n = 10, sd < 0.7%. The artifact arm lost significantly.
- **"the mechanism has to be placement": no.** The arms CONVERGED on placement
  (both 8x7x7). There was no placement disagreement left to win or lose.
- **The huge-page decision, isolated: 0.2%, p = 0.062, not significant.** The
  mechanism this whole experiment was built around is worth nothing measurable
  on this workload.
- **The no-artifact arm's rejection reasoning was correct.** miniQMC streams;
  our 2.4x page-size penalty was measured with a pointer-chase. Right number,
  wrong regime.
- **Our hand-tuned ceiling was beaten by both arms** (27.75 vs 28.14 s).

The falsifier fired and is recorded as fired. The pre-registration's own clause
applies: "If AMG comes back a null, the honest reading is that this prediction
was wrong on this benchmark -- not that the experiment failed." That holds here
in a stronger form, because the result is not a null but a loss.
