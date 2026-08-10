# machine-model

A measured machine descriptor: hwloc structure, verified against benchmarks,
with the disagreements kept rather than overwritten.

```
registry/claims.json          portable. the question list + probes. moves to a new machine unchanged.
machines/<name>.json          per-machine. verdicts and numbers, keyed by claim id.
SCHEMA.md                     design rules for the descriptor.
check.py                      joins the two: integrity, fidelity, work queue.
render.py                     projects a descriptor into an LLM-consumable briefing.
prompts/<name>.md             generated output. do not hand-edit.
```

```sh
python3 check.py  machines/frontier-compute.json
python3 render.py machines/frontier-compute.json > prompts/frontier-compute.md
```

`check.py` is for you; `render.py` is for a consumer. Run `check.py` first — a
descriptor that fails integrity should not be rendered, because the briefing
reads as authoritative whether or not the probes behind it ran.

## The one rule

**Declared values are never overwritten.** hwloc and the firmware tables go into
`declared` verbatim, measurement goes into `measured`, and where they disagree
that disagreement is the record. Overwriting the SLIT with measured tiers would
produce a topology file that happens to be correct and would destroy the only
evidence that anything reading `numa_distance()` on this machine is wrong.

Renderers may lead with the corrected number. The artifact keeps both.

## Why a separate registry

The numbers are machine-specific; the questions are not. `claims.json` names,
for each fact a user needs before placing work: what declares it, which probe
can falsify it, **why that probe and not an easier one**, and how to read the
verdict. That file is the portable part — the thing that goes to Tuolumne and
Aurora unchanged.

Two fields exist because of specific failures, not tidiness:

- **`probe.rationale` / `unsuitable_probes`** — picking the wrong instrument
  manufactures a false confirmation. Host↔device *bandwidth* on Frontier is flat
  to within 0.1% across every NUMA/GCD pair; verifying GPU affinity with it
  returns a flat result that reads as "affinity doesn't matter."
- **`probe_validated`, separate from `verdict`** — a probe that silently failed
  to run is indistinguishable in its output from one that confirmed. `check.py`
  refuses a positive verdict on an unvalidated probe.

## Verdicts

`confirmed` · `contradicted` · `misleading` · `undeclared` · `untested` ·
`unfalsifiable_here`

`confirmed` is a result, not a non-event — it is the control. Frontier's XGMI
weight table being *accurate* is what turns the SLIT finding from "firmware is
unreliable" into "AMD describes its GPU interconnect accurately and its CPU
interconnect not at all, on the same node." Without the control there is no
finding, only complaining.

`undeclared` is excluded from the fidelity score on purpose: a vendor cannot be
inaccurate about a fact it never asserted. Those rows measure something else —
what hwloc's data model structurally cannot hold. All four on Frontier are
regime-dependent curves (page-size penalty, loaded-latency knee, transfer
crossover, contention sensitivity), not scalars.

## What the renderer must not do

`render.py` leads with the corrected value but keeps the declared one visible —
a consumer reasoning about why *other* tools on the machine give different advice
needs to see what those tools were told.

It carries four reasoning rules into the briefing itself: don't upgrade a hedge,
conditions travel with every number, regime-dependent costs get answered with the
regime rather than an average, and say when a question isn't covered. `Unverified`
and `Leads` are separate sections with explicit instructions not to build on them.

A renderer that flattens `flagged` into a plain assertion has broken the contract
that makes the artifact worth trusting.

## Frontier, today

40% declaration fidelity — 4 of 10 resolved claims survive measurement. Structure
is reliable; cost is a coin flip; four of the most actionable facts are declared
nowhere at all.

Briefing renders to ~430 lines / ~5.7k tokens, which is inside the budget for
pasting into a session alongside real work.

## Known v0.1 limitation

`declared` and `measured` blocks are free-form, so `render.py` formats them
generically rather than semantically. It prints faithfully, but it can't order a
block by importance or pick a table over bullets. Constraining those shapes is
the main v0.2 job, and it should be driven by a second machine — Frontier alone
won't reveal which fields are actually universal.
