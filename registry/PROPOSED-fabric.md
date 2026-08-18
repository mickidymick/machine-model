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
