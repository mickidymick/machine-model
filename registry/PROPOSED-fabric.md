# Proposed: fabric locality + the `regime` schema change

Two things, deliberately in one document because the second is what makes the
first safe to publish.

---

## 1. The schema change, shown on the claim that failed

Experiment B's loss was not a wrong number. It was a right number without the
conditions that bound it. The control arm — with no artifact at all — reasoned
correctly that miniQMC streams and is therefore not TLB-bound. The treatment
arm, holding a bare `2.4x`, did not reason at all. **A confident scalar
displaced analysis the model was already capable of.**

So every cost value gains three siblings. Not advice — advice would be worse,
because it is even more directly actionable than a number.

```json
"cost.page_size_penalty": {
  "value":   { "huge_ns": 13.3, "4k_ns": 32.2, "ratio": 2.4 },

  "measured_under": {
    "access_pattern": "dependent random (pointer chase)",
    "working_set":    "32 MiB",
    "threads":        1,
    "node_state":     "idle",
    "placement":      "single NUMA domain, first-touch"
  },

  "mechanism": "32 MiB needs 8192 PTEs at 4K, far past L2 TLB reach (~8 MB), so
                every access pays a page walk that itself misses to memory. The
                penalty exists only where TLB reach fails AND the access cannot
                be prefetched.",

  "not_measured": [
    "streaming / sequential access",
    "multi-threaded first-touch across a 2 MB page boundary",
    "under memory load from co-resident ranks"
  ]
}
```

`mechanism` is the load-bearing field. Given *"the penalty comes from TLB reach
failure on unprefetchable access"*, a model reading a streaming kernel can
conclude the mechanism is absent — which is exactly what the control arm did
without any artifact at all. The artifact's job is to supply the measurement and
its boundary, and then get out of the way.

`not_measured` is the field nobody writes and it may matter most. **An unmeasured
regime is a fact about the artifact, not a gap to paper over.** Had this field
existed and said *"streaming: not measured"*, Experiment B's treatment arm would
have had to reason rather than pattern-match.

Retrofit order — worst exposure first: `cost.page_size_penalty` (demonstrated
harm), `cost.loaded_latency_knee` (read-only sweep), `cost.contention_sensitivity`
(already flagged confounded), `cost.host_device_transfer` (already stored as a
curve, so least exposed), then the `numa.*` latencies.

---

## 2. `net.fabric_locality` — structural

**Declares:** whether a node's position in the fabric is discoverable, and how
nodes are grouped.

**Declared source:** OLCF documents Frontier as a Slingshot dragonfly at a high
level. What is *not* declared anywhere we have found is the mapping from an
allocated node to its group — which is what a job would need to act on this.

**Why it matters:** every cost below is a function of this classification. If it
cannot be established, the cost claim is not measurable and must be recorded as
such rather than estimated.

**Probe:** `scripts/16_fabric_locate.sh` — reports what location metadata each
node exposes (xname, cxi properties, Slurm topology, node features). Measures
nothing. Phase 0 exists separately because a *wrong* group map yields a
confident cost matrix for the wrong pairs, which is worse than no matrix.

**Verdict rule:** `undeclared` if no source on the machine yields a usable
position; `confirmed` if a source exists and OLCF's documented grouping agrees
with it.

---

## 3. `cost.fabric_distance` — the measurement

**Declares:** point-to-point cost as a function of topological distance and
message size.

**Why it matters:** this is what a model needs to reason about
`MPICH_RANK_REORDER_METHOD`, about how many nodes to ask for, and about whether
a communication-bound decomposition is worth reshaping. It is a large lever for
any halo-exchange or all-to-all code, and no domain scientist knows the knob
exists. **It is also the claim with no public answer** — the category Experiment A
showed is the only place the artifact is not competing with a search engine.

**Distance classes:** intra-node (shared memory, no NIC) · same group · cross
group. Classified *after* allocation from the phase-0 metadata, never assumed.

**Measured as a curve, not a scalar.** `osu_latency` and `osu_bw` across the
full message-size range. `cost.host_device_transfer` already taught us that a
single-size measurement gives the wrong universal answer — there the sign
changes with size.

**The condition that makes this claim different from every other one in the
artifact:** the fabric is *shared*. NUMA latency does not depend on other users;
cross-group bandwidth does. A number taken on a quiet machine at 3am may not
hold at noon.

That has two consequences. It must be sampled repeatedly across different times
and allocations, and `measured_under` must record when. And **the variance is
itself the result** — "cross-group bandwidth is X ± Y, where Y is large and
here is the distribution over N samples" is a more honest and more useful entry
than a single number, and it is a genuinely novel thing for a machine
descriptor to carry.

**Expected `not_measured`:** collectives (point-to-point only), congestion from
the job's own traffic, GPU-resident buffers, and any distance class the
allocation did not happen to span.

**Verdict rule:** `undeclared` — nothing publishes this. Falls to
`unfalsifiable_here` if the allocations obtained never span more than one group,
which is a real possibility and must be reported rather than worked around.

---

## Why this ordering

Phase 0 is cheap and might kill the whole claim. If node position is not
discoverable from inside a job, then no application could act on the cost matrix
even if we measured it, and the right answer is to record that and move to
storage or SMT instead. Finding that out costs one small allocation.

---

# PHASE 0 RESULT — 2026-08-18, job 5301870, 16 nodes

## The planned classification is unavailable

`/etc/cray/xname`, `/proc/cray_xt/cname`, `/proc/cray_xt/nid` and `CRAY_XNAME`
are **all empty on all 16 nodes**. A user job cannot learn its physical
position. The cabinet-based grouping this claim was designed around is dead.

## Slurm's topology replaces it, and is a better source

```
SwitchName=root  Level=1  Nodes=frontier[00001-09472,10113-10496]
SwitchName=s2000 Level=0  Nodes=frontier[00001-00128]
SwitchName=s2001 Level=0  Nodes=frontier[00129-00256]
...
SwitchName=s2611 Level=0  Nodes=frontier[10369-10496]
```

**77 Level=0 switches × 128 nodes = 9856**, matching the machine's node count
exactly. Contiguous blocks in switch-name order. Available on a login node with
no allocation, it is what Slurm itself uses for placement, and a job can act on
it via `--switches`. Captured as a declared source alongside the hwloc XML.

## Default allocations provide zero co-location

The 16-node allocation landed on **16 distinct switches**: 120 pairs, **0
same-switch, 120 cross-switch**. Spanning three switch-name families
(s20xx, s21xx, s22xx).

If that is typical, every multi-node job on this machine is scattered, and the
near class cannot be measured without `--switches=1`.

## The finding that matters: Slurm declares a TREE for a DRAGONFLY

Slurm's model is `root → 77 switches → 128 nodes`. A two-level tree asserts that
**every cross-switch pair is equivalent**. Frontier is a Slingshot dragonfly,
where same-group and cross-group links are not equivalent.

If group structure exists, **Slurm's topology model cannot express it** — the
same structural insufficiency as `numa.symmetry`, where a scalar distance cannot
represent an asymmetric cost. Not miscalibration; the wrong shape of model.

This is a hypothesis until measured, and it is measurable.

## Phase 1, sharpened — and now cheap

The question is no longer "which pairs are near." It is:

> **Is the cross-switch class uniform?**

Measure many cross-switch pairs across the message-size range and look at the
distribution. **Unimodal** → the fabric is flat at this scale, Slurm's model is
adequate, and the claim resolves as `confirmed` for a declared source that
happens to be sufficient. **Multimodal** → there is group structure Slurm cannot
represent, and every job on the machine is being placed by a model that cannot
see it.

**This needs no `--switches=1`.** A default 16-node allocation already yields 120
cross-switch pairs spanning three switch-name families. If those families
correspond to groups, the structure appears as clustering in the pair costs.
`--switches=1` remains worth doing for the same-switch baseline, but it is no
longer a blocker, and the measurement runs on an allocation that is always
obtainable.

**Ask OLCF** whether a Slurm switch here is a physical Slingshot switch, a
cabinet, or a dragonfly group. The measurement does not depend on the answer —
same-switch vs cross-switch is a real distinction regardless — but the
`mechanism` field does, and mechanism is what makes a number safe to reuse.

---

# PHASE 1 RESULT — 2026-08-18, job 5302124, 16 nodes, 240 pairs

**The cross-switch class is uniform.** 240 of 240 pairs usable.

| | mean | sd | min | max |
|---|---|---|---|---|
| 8 B latency | 3.68 us | 0.03 (0.7%) | 3.47 | 3.73 |
| 1 MiB bandwidth | 21975 MB/s | 170 (0.8%) | 20539 | 22308 |

One tight mode, 3.63–3.73 us, plus two pairs at 3.47. The widest gap isolates
only those two, which is an outlier and not a mode.

Switch-name families are indistinguishable: s20xs20 3.68, s21xs21 3.67,
s20xs21 3.68. **If those families were dragonfly groups, cross-family pairs
would cost more. They do not.**

## Our own hypothesis is falsified, and that is the result

Phase 0 proposed that Slurm's two-level tree is structurally insufficient for a
dragonfly, the same way a scalar SLIT distance cannot express the NUMA asymmetry
we measured. **At the scale sampled, it is not.** Slurm asserts every
cross-switch pair is equivalent, and to 0.7% they are.

That makes `cost.fabric_distance` a **`confirmed`** verdict on a declared model —
the category that turns "declared data is unreliable" from a slogan into a
falsifiable claim. Four of the artifact's claims are confirmed and they are what
make the three contradicted ones credible.

## What this result does NOT cover

**The allocation was compact.** Sixteen contiguous switches, s2000–s2011 and
s2100–s2104, node IDs 96–2108: **20% of the machine, 2 of 7 switch families.**
No genuinely distant pair (s2000 to s2600) was sampled. Uniformity across a
compact region does not establish uniformity across the machine, and the
dragonfly's global links are exactly what a compact allocation avoids.

**The machine was 95% occupied** — 9404 of 9856 nodes running, 1487 jobs
pending. Under that load, congestion is a live alternative explanation:
if every path is contended, topology differences wash out. The measurement is
arguably more *useful* for being taken under realistic load, but it cannot
distinguish "the fabric is flat" from "the fabric was saturated".

**No same-switch pairs at all.** All 240 were cross-switch, so there is still no
near baseline and no measured answer to what `--switches=1` would buy.

`not_measured`: distant pairs across the full node range · a quiet machine ·
same-switch · message sizes other than 8 B and 1 MiB · collectives · GPU buffers.

## What would settle it

Repeat runs accumulating coverage, recording which switch regions each
allocation touched, until either a distant pair shows a difference or the
uniform region is wide enough to claim machine-wide. Plus one run at low
occupancy, and one `--switches=1` for the near baseline. The variance across
those runs is itself part of the entry — this is the only claim in the artifact
whose value legitimately depends on what other users are doing.
