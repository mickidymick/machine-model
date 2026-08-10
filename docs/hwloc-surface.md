# The hwloc surface: what we can fill, and what has no home

Inventory of hwloc's data model, mapped against the claims in
`registry/claims.json`. The question this answers: **for each thing we measure,
does hwloc have a place to put it?**

Three outcomes per claim — `native` (hwloc has a typed slot), `info-only`
(no typed slot, can be attached as a string annotation), `artifact-only`
(hwloc has no way to express it and shouldn't).

Status markers: ✅ verified from docs · ⚠️ needs checking on-machine.

---

## 1. What hwloc exposes

### A. Object tree and per-object attributes ✅

Objects: `MACHINE`, `PACKAGE`, `DIE`, `CORE`, `PU`, `L1..L5CACHE`
(`L1I/L2I/L3I` variants), `NUMANODE`, `MEMCACHE`, `GROUP`, `BRIDGE`,
`PCI_DEVICE`, `OS_DEVICE`, `MISC`.

Each carries a type-specific attribute union (`hwloc_obj_attr_u`) — a cache
object has size, line size, associativity, depth; a NUMA node has local memory
size. OS devices are typed: `GPU`, `COPROC`, `NETWORK`, `OPENFABRICS`, `BLOCK`,
`DMA`.

Two things worth noting for our machines:

- **`MEMCACHE`** exists for *memory-side* caches. That is structurally what
  Aurora's HBM is in cache mode. hwloc already models the thing we would
  otherwise have had to invent vocabulary for.
- **`DIE`** sits between package and core, which is the natural home for
  Frontier's CCDs.

Everything here is **structure**, and hwloc gets structure right. Sizes, counts,
containment, allowed cpusets. Nothing we measure improves it.

### B. Distances ✅

Matrices between objects, populated on x86 from the ACPI SLIT by way of the
kernel and sysfs. Addable via `hwloc-annotate ... distances <file> [flags]`,
which maps to `hwloc_distances_set()`.

**Structurally cannot express direction** — one value per pair. Our
`numa.symmetry` result (2→3 = 110.8 ns, 3→2 = 106.9 ns, both metrics agreeing)
has no representation here at all.

### C. Memory attributes ✅ — the important one

`hwloc/memattrs.h`, hwloc 2.3+. Latency and bandwidth between an **initiator**
(a cpuset) and a **target** NUMA node. Read from the ACPI **HMAT** table when
firmware provides one and the kernel is 5.2+ (5.10+ for generic initiators).

Consumers query it through `hwloc_memattr_get_value()` and
`hwloc_memattr_get_best_target()` — the latter being, literally, *"where should
this cpuset allocate."*

Three properties that matter:

1. **Initiator-specific**, so asymmetry is representable. Strictly more
   expressive than distances for our data.
2. **HMAT is optional.** No HMAT means these slots are simply empty. ⚠️ Check
   whether Frontier exposes HMAT — the flat SLIT suggests not, in which case the
   container hwloc built for measured cost is empty on this machine.
3. **New attributes can be registered by name.**
   `hwloc-annotate topo.xml topo.xml numanode:2 memattr <Name> <flags> <value>`
   registers a *custom named* attribute. This is a supported extension point,
   not a hack.

That third point resolves the positioning problem. We do not have to overwrite
`Latency`; we can register `MeasuredLatency` alongside it. Additive, named,
attributable, and using hwloc's own mechanism. A consumer that wants firmware
values still gets them; one that wants ours asks for ours by name.

### D. CPU kinds ✅

Ranks sets of PUs by efficiency, for heterogeneous cores. Not relevant to
Frontier (uniform Zen3). ⚠️ Possibly relevant to Aurora.

### E. Info attributes ✅

Arbitrary string key/value pairs on any object, settable via
`hwloc-annotate ... info <name> <value>`. Also `subtype`, which the docs
demonstrate for exactly our kind of case — marking one NUMA node `DDR` and
another `HBM`.

This is the **provenance channel**: tool version, characterization date, node
name, pass count. Any XML we emit must carry these, or we have produced data
that looks like firmware data and cannot be traced.

---

## 2. Claim-by-claim mapping

| claim | home | notes |
| --- | --- | --- |
| `cpu.cache_hierarchy` | **info-only** | hwloc has cache *sizes*; there is no slot for measured *latency* per level. Our L1 1.1 ns / L2 3.4 ns / L3 10.9–13.3 ns is confirmation of structure, not new structure. |
| `cpu.core_inventory` | **native** | Allowed cpuset. hwloc is authoritative here by construction — it reads the live cgroup. Nothing to inject; ⚠️ verify it shows the OS-reserved cores. |
| `numa.domain_count` | **native** | Structural. Confirmed, nothing to add. |
| `numa.distance_matrix` | **native (C)** | The headline injection target. Goes in as memattr `Latency`/`Bandwidth`, or a custom `Measured*` name. Prefer memattrs over distances — richer, and the slot is likely empty rather than occupied. |
| `numa.symmetry` | **native (C only)** | Representable *only* in memattrs. Distances cannot hold it. This asymmetry is the single strongest argument for using C over B. |
| `gpu.device_inventory` | **native** | `OS_DEVICE` of type `COPROC`/`GPU`. ⚠️ Requires hwloc built with the RSMI backend, or AMD GPUs do not appear at all. |
| `gpu.numa_affinity` | **native** | OS device locality (cpuset/nodeset of the device object). ⚠️ Does hwloc report Frontier's non-naive map correctly? One `srun -n1 lstopo` answers it. Our own probe for this is still untested, so hwloc may end up being the *only* source — which is a reason to check it early. |
| `gpu.interconnect_cost` | **native (C)** ✅ | Verified on corsys4, hwloc 2.4.1: memattr values attach to `OSDev` targets, persist as `target_obj_type="OSDev"`, and read back via `lstopo --memattrs`. GPU peer and host↔device costs have a typed home. ⚠️ Still unverified whether *consumers* honour device-targeted memattrs — the storage works. |
| `gpu.memory_hierarchy` | **info-only** | hwloc does not model device-internal cache hierarchies. Our MI250X vector-L1 / L2 / HBM latencies have no typed home. |
| `mem.page_backing` | **artifact-only** | Not a topology property. hwloc reports huge page sizes available; it has no concept of "the request silently failed." |
| `net.nic_inventory` | **partial** | Device presence is native (`NETWORK`/`OPENFABRICS`). Per-NIC bandwidth and the one-rank-one-NIC behaviour have no slot. |
| `cost.page_size_penalty` | **artifact-only** | A curve with three regimes. No representation. |
| `cost.loaded_latency_knee` | **artifact-only** | A curve with an operating point. No representation. |
| `cost.host_device_transfer` | **artifact-only** | A crossover that changes sign with message size. No representation. |
| `cost.contention_sensitivity` | **artifact-only** | Depends on offered background load. No representation. |

**Tally.** Two claims have a genuine, expressive home (`numa.distance_matrix`,
`numa.symmetry`) and both land in memory attributes. Five are native but purely
confirmatory — hwloc is already right and we are checking it. Three are
info-only. **Four have no representation at all, and all four are the
regime-dependent costs.**

---

## 3. What this settles

**The injection target is memory attributes, not distances.** Richer, likely
empty rather than occupied, and the only place asymmetry fits.

**Injection is additive, not destructive.** Custom named memattrs mean we never
have to overwrite a firmware value. That removes the entire "we fix hwloc"
posture — we register measurements under our own names, next to whatever
firmware supplied.

**The artifact is not redundant with hwloc, and the reason is structural.**
hwloc's model holds scalars — per-object attributes, per-pair matrices,
per-(initiator, target) values. Every one of our regime-dependent costs is a
*curve*, and there is nowhere in hwloc to put a curve. That is not a gap in
hwloc; a topology library is not a performance model. But it means the artifact
has to exist independently, and the XML export can only ever carry part of it.

## 4. Verified locally — no allocation needed ✅

corsys4, hwloc 2.4.1, 2026-07-30:

```sh
# register a latency-like attribute. flags 6 = LOWER_FIRST|NEED_INITIATOR,
# identical to the built-in `Latency`
hwloc-annotate in.xml t1.xml root       memattr MeasuredLatency 6
hwloc-annotate t1.xml t2.xml numanode:0 memattr MeasuredLatency 0x1 101
hwloc-annotate t2.xml t3.xml os:0       memattr MeasuredLatency 0x1 555
lstopo -i t3.xml --memattrs
```

Result — **OS devices are accepted as memattr targets**:

```
Memory attribute #4 name `MeasuredLatency' flags 6
  NUMANode L#0 = 101 from cpuset 0x00000001 (PU L#0)
  OSDev  L#0 = 555 from cpuset 0x00000001 (PU L#0)
```

They persist to XML as `target_obj_type="OSDev"` and survive the round trip. So
GPU peer cost and host↔device cost have a typed home. ⚠️ Storage is proven;
whether *consumers* honour device-targeted memattrs is a separate question.

Also observed: built-in `Bandwidth` (flags 5) and `Latency` (flags 6) exist and
are **empty** on corsys4 — no HMAT, nothing ever filled them. The
container-is-empty hypothesis, confirmed on real hardware.

⚠️ **`hwloc-annotate` exits 0 whether or not a value was stored.** Always read
back with `lstopo --memattrs`. Do not trust the exit status — see
[[feedback-verify-the-manipulation]].

Note `--whole-io` is required for OS devices to appear in the export on 2.4.1;
plain `lstopo out.xml` omits them.

## 5. Remaining checks — need a Frontier allocation

1. Does Frontier expose HMAT? (Are the memattr slots empty there too?)
2. Is the module's hwloc built with RSMI, and does it report the non-naive
   GPU↔NUMA map?
3. Does the allowed cpuset show the OS-reserved cores?

---

Sources: [object attributes](https://hwloc.readthedocs.io/en/latest/attributes.html) ·
[topology attributes: distances, memattrs, CPU kinds](https://www.open-mpi.org/projects/hwloc/doc/v2.13.0/topoattrs.html) ·
[memattrs API](https://hwloc.readthedocs.io/en/master/group__hwlocality__memattrs.html) ·
[hwloc-annotate](https://man.archlinux.org/man/extra/hwloc/hwloc-annotate.1.en) ·
[CLI tools](https://hwloc.readthedocs.io/en/latest/tools.html)
