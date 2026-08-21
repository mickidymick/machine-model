# Claim coverage across the five applications

Analysis only, no runs. 2026-08-20.

The rule from the training/test design: **every registry claim should bind for at
least one application, and no single application should exercise more than a
few.** This maps the five applications already built in `eval/exp-b/configs/`
against the twenty claims in `registry/claims.json` to find what nothing
exercises.

Behaviour is taken from the `problem-*.md` statements, which are the authored
descriptions the arms receive, not from new measurement.

## What each application is

| app | character | parallelism | footprint |
|---|---|---|---|
| **AMG** | algebraic multigrid, sparse, irregular access | MPI, rank geometry open (448 = 2^6 x 7) | tens of MiB per thread; 9.0e7 unknowns global |
| **LULESH** | structured mesh, contiguous sweeps, regular stencil | MPI, rank count must be a perfect cube | size correction pending -- see below |
| **XSBench** | random indexing into a multi-GB grid, no prefetch | **threads only, MPI off, one node** | several GB, single process |
| **miniQMC** | Monte Carlo particle, irregular | MPI, 56 walkers total | tens of MiB per walker |
| **QMCPACK** | VMC with GPU offload, gfx90a | 112 walkers, GPU | device-resident |

## The matrix

`++` strong -- the claim is a first-order lever for this app.
`+` binds. `~` binds weakly or in a different regime than the claim was
measured under. `--` does not bind.

| claim | AMG | LULESH | XSBench | miniQMC | QMCPACK |
|---|---|---|---|---|---|
| cpu.cache_hierarchy | ++ | + | ~ | ++ | ~ |
| cpu.core_inventory | + | ~ | + | ++ | + |
| numa.domain_count | + | + | + | + | + |
| numa.distance_matrix | ++ | + | ++ | + | ~ |
| numa.symmetry | ~ | ~ | ~ | ~ | ~ |
| gpu.device_inventory | -- | -- | -- | -- | ++ |
| gpu.numa_affinity | -- | -- | -- | -- | + |
| gpu.interconnect_cost | -- | -- | -- | -- | ~ |
| gpu.memory_hierarchy | -- | -- | -- | -- | + |
| mem.page_backing | + | + | + | + | + |
| **net.nic_inventory** | -- | -- | -- | -- | -- |
| cost.page_size_penalty | ++ | -- | +++ | ++ | ~ |
| cost.loaded_latency_knee | + | ++ | + | ~ | ~ |
| cost.host_device_transfer | -- | -- | -- | -- | ++ |
| cost.contention_sensitivity | + | + | + | + | + |
| cpu.system_interference | ~ | ~ | ~ | ~ | ~ |
| **storage.tier_inventory** | -- | -- | -- | -- | -- |
| cost.collective_scaling | ~ | ~ | -- | ~ | ~ |
| cpu.smt_benefit | + | ++ | ++ | + | ~ |
| **cost.storage_bands** | -- | -- | -- | -- | -- |

Strong binds per app: AMG 9, LULESH 7, XSBench 8, miniQMC 8, QMCPACK 8.

---

## The result that changes the experiment

Two claims have **applications on opposite sides**, and they are the two claims
whose correct use most obviously requires knowing your own regime.

**cpu.smt_benefit.** The registry's rule is latency-bound versus
throughput-bound, measured as +69.7% (chase), +78.2% (fma), -5.0% (stream).

- **XSBench** is random indexing into a multi-GB grid with no prefetch --
  latency-bound. SMT should **help**.
- **LULESH** at a correct size sweeps a structured mesh contiguously --
  bandwidth-bound. SMT should **hurt**.

**cost.page_size_penalty.** Measured 2.4x at a 32 MB working set under dependent
random access, and explicitly `not_measured` for streaming.

- **XSBench** is the mechanism's poster child: random access, working set far
  past TLB reach. Huge pages should be a **large win**.
- **LULESH** is contiguous and prefetchable, which is the regime the claim's own
  `not_measured` block says it does not cover. Should be **null**.

So the same two artifact facts, correctly stated, imply **opposite actions** for
two applications in the set. That is the project's hypothesis in its cleanest
possible form -- a regime-dependent claim is only usable by a reader that knows
its own regime -- and it is a much sharper instrument than "five apps, three
arms" because a wrong answer is unambiguous rather than a small regression.

**Recommendation: make LULESH x XSBench on these two claims the spine of the
experiment**, with AMG, miniQMC and QMCPACK as the generality check. It also
gives the failure a name: an arm that applies the SMT claim uniformly is wrong
for one of the two no matter which way it goes.

Note this raises the cost of XSBench's build failure (`craype-hugepages2M`
injects `-Wl,-Ttext-segment`, which `PrgEnv-amd`'s lld rejects). XSBench is no
longer one app of five; it is half of the spine. **Fixing that build moves from
housekeeping to critical path.**

---

## Gaps: three claims bind for nothing

`net.nic_inventory`, `storage.tier_inventory`, `cost.storage_bands`.

These are not three independent misses. They have **one root cause each**, and
both are properties of how the set was assembled rather than of the applications:

**Everything runs on a single node.** So no NIC claim can bind, and
`cost.collective_scaling` binds only weakly -- the apps do perform collectives,
but intra-node, which is a different regime from the multi-node measurement the
claim carries. A claim used outside its `measured_under` envelope is exactly the
failure mode this project exists to study, so this one matters twice.

**Nothing writes data.** No app in the set does meaningful I/O, so both storage
claims are dead.

### Recommended fixes

**Add one multi-node configuration.** AMG is the natural host -- 448 factors
cleanly and multigrid is allreduce-heavy, so a 2- or 4-node run activates
`net.nic_inventory` and moves `cost.collective_scaling` into the regime it was
measured in. This is the single highest-value addition to the set and it needs
no new application.

**Accept the storage gap and report it.** None of these codes exist to write
data, and bolting on I/O to manufacture coverage would be worse than a stated
limitation. Say the descriptor carries storage claims that this application set
cannot exercise, and that they await a code that checkpoints.

**`cpu.system_interference` is untested on Frontier**, so it cannot bind for
anything regardless of the application set. That is an artifact-side gap, not a
coverage gap.

---

## Two structural observations

**Four claims bind for everything and therefore discriminate nothing.**
`mem.page_backing`, `numa.domain_count`, `cost.contention_sensitivity` and
`cpu.core_inventory` are universal. They are still worth carrying -- page
backing failing silently invalidates everything downstream -- but they cannot
separate a good arm from a bad one. The claims that carry experimental weight
are the ones binding for a subset: `page_size_penalty`, `smt_benefit`,
`loaded_latency_knee`, `distance_matrix`, and the GPU set.

**QMCPACK alone carries five claims** -- all four `gpu.*` plus
`cost.host_device_transfer`. If it is dropped or its build fails, one fifth of
the registry loses its only application. Either accept the GPU side as
single-app and say so, or promote miniQMC's GPU build to a second carrier.

**The "no more than a few" rule does not survive contact.** Every app exercises
7-9 of 20. The rule's intent was to prevent one application from dominating, and
that intent is met -- the subsets differ, and no app covers the discriminating
claims alone. Restate the rule in terms of the discriminating claims rather than
all claims.

---

## What this does not do

- It does not verify a single binding by measurement. Every entry is inferred
  from the authored problem statements plus the claims' own `measured_under`
  envelopes. The footprint-dependent rows (`cache_hierarchy`,
  `distance_matrix`, `loaded_latency_knee`) will move once problem sizes are
  corrected -- LULESH's especially, since it is currently specified at 729,000
  elements, the size that invalidated round 3.
- It says nothing about whether an arm will *use* a claim that binds. Binding is
  necessary, not sufficient -- that is what the experiment measures.
