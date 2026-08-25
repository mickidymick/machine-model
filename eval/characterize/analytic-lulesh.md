# LULESH — tier-1 analytic properties

Derived from source, zero runs. Pinned commit
`3e01c40b3281aadb7f996525cdd4a3354f6d3801` (`eval/exp-b/pristine-lulesh`).

Types (`lulesh.h:38-40`): `Real_t = real8` (8 B), `Index_t = Int_t = Int4_t` (4 B).
Mesh (`lulesh-init.cc:55-77`): `numElem = nx^3`, `numNode = (nx+1)^3`, where `nx`
is the per-rank edge length `-s`.

## P1 — Footprint

**Node-centered**, `AllocateNodePersistent` (`lulesh.h:164`) — 13 `Real_t` arrays
(3 coordinates, 3 velocities, 3 accelerations, 3 forces, nodal mass):

    13 x 8 B = 104 B per node

**Element-centered persistent**, `AllocateElemPersistent` (`lulesh.h:185`):

| group | count | bytes |
|---|---|---|
| `m_nodelist` | 8 x `Index_t` | 32 |
| face connectivity `lxim…lzetap` | 6 x `Index_t` | 24 |
| `m_elemBC` | 1 x `Int_t` | 4 |
| `Real_t` fields: e, p, q, ql, qq, v, volo, delv, vdov, arealg, ss, elemMass, vnew | 13 x 8 | 104 |
| | | **164 B per element** |

**Transient**, live across the Lagrange step — `AllocateGradients` (`lulesh.h:221`,
3 x numElem + 3 x allElem) and `AllocateStrains` (`lulesh.h:245`, 3 x numElem):

    ~72 B per element   (allElem approximated as numElem + ghosts)

**Total from the two allocators.** With `numNode/numElem = ((nx+1)/nx)^3`, which
is 1.030 at `nx = 100`:

    persistent            164 + 104 x 1.030  =  271 B/element
    persistent + transient                   =  343 B/element

## CORRECTED 2026-08-25 by measurement — job 5343103

**The derivation above is low by about 2.2x, and the check that appeared to
confirm it confirmed nothing.**

Measured peak RSS at global 300^3, four configurations:

| config | ranks x threads | path | GB total | **B/element** |
|---|---|---|---|---|
| m08x1 | 8 x 1 | MPI-only | 18.6 | **688** |
| m27x1 | 27 x 1 | MPI-only | 19.4 | **718** |
| o08x7 | 8 x 7 | threaded | 24.6 | **910** |
| o27x2 | 27 x 2 | threaded | 25.3 | **938** |

**What the derivation got right.** The threaded-minus-MPI delta is
**~200-220 B/element**, against a predicted **192 B/element** for one set of
`fx/fy/fz_elem` arrays. The mechanism is confirmed; the published single-rank
run at 23.6 GB is 874 B/element and sits in the threaded band, which settles
that it was an OpenMP configuration.

**What it got wrong.** The absolute count. Counting only `AllocateNodePersistent`
and `AllocateElemPersistent` misses the rest of the `Domain` — `nodeElemStart`
and `nodeElemCornerList` alone add 8 x numElem `Index_t` (32 B/element), plus
comm buffers, symmetry planes, and the `-r 11` region index lists. A full audit
of the class is still owed; until then the measured figures stand.

**Why the round-3 cross-check was spurious.** 230 MB at 729,000 elements gives
315 B/element, which fell neatly between the two derived bounds — and that
agreement was an accident. Round 3 ran **125 ranks of 5,832 elements each**. At
that size a LULESH process is dominated by binary, MPI runtime and fixed
allocations, not by anything that scales with element count, so no per-element
coefficient can be extracted from it in either direction. A number that appeared
to validate a derivation was measuring something else entirely.

That is the same failure this project keeps meeting: **a plausible number, not an
error.** It is recorded here rather than quietly fixed, because the pattern is
more useful than the value.

**Working coefficients, measured:**

    MPI-only      ~700 B/element     confidence `medium` (n=2 configurations)
    threaded      ~920 B/element     confidence `medium` (n=2 configurations)

**Footprint is config-dependent even though work is fixed.** The decomposition
does not change the problem; it changes the memory by ~30%. Any claim binding on
footprint has to be evaluated per configuration, not per application.

## P3 — Memory traffic

~2.0 KB per element-update on the MPI-only path; the `omp_get_max_threads() > 1`
path allocates `fx/fy/fz_elem` at 8 x numElem doubles each and gathers through
`nodeElemCornerList`, adding **~768 B per element per cycle, twice per cycle** --
roughly 35% more DRAM traffic. `lulesh.cc:514` (`IntegrateStressForElems`) and
`lulesh.cc:736` (`CalcFBHourglassForElems`).

This is the property that decided round 3, and it is a **source-level fact with
no machine in it** — the canonical tier-1 case.

## P9 — Communication

Face exchange per rank per cycle: `6 x s^2 x 8 B x nfields`, plus edge and corner
messages. Analytic, evaluable at any size without running there.

---

## Choosing the size

**Target.** Jeff places LULESH's transition to memory-bound at ~20 GB RSS.
Global 300^3 = 27e6 elements lands at **18.6-25.3 GB measured**, depending on
the force path — confirmed on the machine, not extrapolated.

Round 3 ran 729,000 elements, 37x smaller and cache-resident throughout.

**The size correction achieved what it was for.** At 300^3 the code is visibly
bandwidth-limited: going from 8 cores to 56 — **7x the cores** — buys **1.69x**,
a scaling efficiency of 24%, and the 8-core configuration is by far the most
core-efficient (3,900 core-seconds against 16,300). That is the regime round 3
assumed and did not have.

**The decomposition constraint is the interesting part.** LULESH requires the
rank count to be a perfect cube `t^3` (`lulesh-init.cc:685`) and the global edge
to be `t x s`. So `t` must divide 400. Since `400 = 2^4 x 5^2`:

| ranks | t | `-s` | per-rank footprint | fits one node? |
|---|---|---|---|---|
| 8 | 2 | 200 | 2.5 GB | yes — but only 8 cores busy unless threaded |
| 64 | 4 | 100 | 315 MB | **only via SMT** — 64 > 56 allocatable cores |
| 125 | 5 | 80 | 161 MB | no — 125 > 112 allocatable PUs. Multi-node. |
| 512 | 8 | 50 | 40 MB | multi-node |

**Both single-node options force a decision the descriptor speaks to, and they
force different ones:**

- **8 ranks** leaves 48 of 56 cores idle unless the arm goes hybrid — and LULESH's
  OpenMP path costs ~35% more DRAM traffic. Pure-MPI-and-waste-the-node versus
  hybrid-and-pay-the-traffic is a genuine trade with no obvious answer.
- **64 ranks** cannot be placed one-per-core, because only **56** cores are
  allocatable. An arm that believes the vendor node diagram (64 cores) will size
  for a node that does not exist; `cpu.core_inventory` is exactly this claim, and
  its verdict is `misleading`.

At 729,000 elements neither decision mattered much. At 64e6 with rank counts
constrained to cubes, both bind.

**Recommendation: fix the global problem at 400^3 = 64,000,000 elements and leave
the decomposition to the arm.** The config surface is the thing under test.

## A flag on round 3's winning configuration

`configs/lulesh/no-artifact.sh` chose 125 ranks, reasoning "125 ranks is the
largest count that still fits one rank per hardware thread (Frontier: 64 cores x
2 SMT = 128 logical CPUs)."

Only **112** PUs are allocatable — `cpu.core_inventory` records 112 allowed of
128 topology PUs, 56 usable cores, one per L3 group OS-reserved. So 125 ranks
exceeds the allocatable set, and that run either oversubscribed or was placed in
some way not captured by the reasoning.

**The arm that won got a machine fact wrong and won anyway.** Worth resolving
before the rerun — check the job's actual placement — because it bears directly
on the paper's thesis about which facts change outcomes.
