# Machine descriptor schema v0.1

A machine descriptor is a versioned, machine-readable model of one node type on
one system. It exists because **structure and cost are different things, and the
system only tells you the first one reliably.**

hwloc, the ACPI SLIT, and vendor node diagrams describe how a machine is wired.
They do not describe what the wiring costs, and on at least one production
machine (Frontier) the firmware's own cost table is measurably wrong. A
descriptor carries both, keeps them separate, and records where they disagree.

## Design rules

**1. `declared` and `measured` are never merged.**
`declared` is what the machine says about itself: hwloc, SLIT, `rocm-smi`,
vendor documentation. `measured` is what a benchmark observed. Merging them
destroys the only evidence that a disagreement exists. A consumer that trusts
firmware and a consumer that trusts measurement should both be able to read this
file and know which one they got.

**2. Disagreements are first-class objects, not footnotes.**
`discrepancies[]` is a top-level array. Each entry names the declared claim, the
measured claim, the evidence, and — critically — what a consumer would get wrong
by believing the declared version. This is the highest-value content in the file.

**3. Every number carries its provenance.**
A bare number is worse than no number, because a downstream consumer (human or
model) will state it without hedging. Every measurement is an object:

```json
{
  "value": 107.9,
  "unit": "ns",
  "method": "ptrchase-random",
  "n": 3,
  "spread": 1.2,
  "spread_kind": "max_deviation",
  "conditions": { "pages": "4K", "threads": 1 },
  "confidence": "high",
  "note": "optional caveat"
}
```

`spread_kind` is one of `max_deviation`, `stddev`, `range`, `ci95`. Prefer
reporting what you actually computed over converting it.

**4. Confidence is an explicit enum, and `flagged` is a real value.**

| level | meaning |
| --- | --- |
| `high` | validated tool, replicated, effect >> noise |
| `medium` | single configuration or unreplicated, but effect >> noise |
| `low` | effect comparable to noise, or n=1 |
| `flagged` | an observation the author explicitly declines to assert |

`flagged` exists because real characterization produces patterns that look like
structure and sit inside the noise band. Frontier's GCD die-parity split is one.
The honest thing is to record it as visible-but-unasserted rather than to drop it
(losing a lead) or promote it (making a claim the data will not support). A
renderer must not present `flagged` entries as fact.

**5. Conditions are part of the measurement, not the environment.**
Page size, thread count, binding, read/write mix, message size, and how many
links were crossed all change the number. Frontier's NUMA matrix is on 4K pages
because huge pages cannot be allocated on a remote domain; its inter-node
bandwidth crossed one of four NICs. Both facts change how the number should be
quoted. If a condition is missing, the number is not reusable.

**6. Pitfalls are actionable, not descriptive.**
A pitfall entry says what breaks, how it presents, and what to do. "THP is off"
is trivia. "Both normal paths to huge pages fail *silently*, so verify via smaps
rather than trusting madvise, and load `craype-hugepages2M`, which works by
relinking" is a pitfall.

## Top-level structure

```
machine          identity, facility, node type, characterization date
sources          what produced the declared section, with versions
declared         topology as the system reports it
measured         topology as benchmarks observe it
discrepancies[]  declared-vs-measured conflicts, with consequence
pitfalls[]       actionable gotchas: symptom, cause, remedy
guidance[]       derived rules of thumb, each citing its evidence
open_questions[] known gaps, so a consumer knows the edges of the model
```

## What a descriptor is NOT

It is not a benchmark result archive — it is a *model*, distilled from results,
and it should stay small enough to read. Raw sweep output stays in the
characterization repo; the descriptor cites it by filename.

It is not a placement decision. It is the input a placement decision needs.

## Renderers

The descriptor is the artifact. A renderer projects it into a consumer format.
`render.py` produces an LLM-consumable Markdown briefing, which is one renderer
among several possible ones (mpibind policy input, scheduler hints, autotuner
priors, a ZeroSum phase-2 reference configuration).

Renderers must preserve confidence. A renderer that flattens `flagged` into a
plain assertion has broken the contract that makes the artifact trustworthy.
