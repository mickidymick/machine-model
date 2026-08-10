# Machine briefing: corsys4 (single-node tiered-memory testbed node)

UTK EECS (corsys lab). Characterized 2026-07-16.

- **CPU**: 1x Intel Xeon Gold 6246R (Cascade Lake), 16 cores, 2 HWT/core
- **Memory**: node 0: 192 GB DDR4  |  node 1: 730 GB Intel Optane PMEM, cpuless, KMEM DAX system-ram
- **Accelerator**: none
- **Network**: 1 GbE management only; no HPC fabric

## How to use this document

This is a **measured** description of one node type, not a spec sheet. Where the machine's own topology interfaces (hwloc, ACPI tables, vendor query tools) disagree with measurement, the measured value is given first and the declared value is shown alongside it, because other tools on this system are still acting on the declared one.

Rules for reasoning with what follows:

1. **Do not upgrade a hedge.** Items under *Unverified* and *Leads* are not established. Do not present them as facts, and do not build a recommendation whose correctness depends on them.
2. **Conditions are part of every number.** A latency measured on 4K pages, or a bandwidth measured across one of four network links, does not generalise to other conditions. The conditions are stated; carry them.
3. **Regime-dependent costs are not scalars.** Several costs here change sign or magnitude with working-set size, offered load, or message size. Answer with the regime, not an average.
4. **Say when the answer is not in here.** This document covers one node type and, for topology, effectively one node. If a question needs data it does not contain, say so rather than interpolating.

**Measurement provenance.** Intel MLC v3.12 is the reference instrument here rather than a tool under test; ptrchase was originally validated against it on this machine before being taken to Frontier. The cross-tier copy matrix is a separate, independently written tool that verifies placement via move_pages before timing rather than trusting first touch.

**Coverage.** One machine, one node, and there is only one of it. Nothing here speaks to node-to-node variability, and it cannot -- this is a single lab workstation, not a partition of a large system. Its value is as a second, independently-built data point of a different vendor and a different memory technology, not as a population.

## Where this machine misdescribes itself

Read this section before acting on any topology query you run yourself, or on any advice derived from vendor documentation.

### Number of NUMA domains and which cores and memory belong to each

`numa.domain_count` — **misleading** (confidence: high)

**Declared** (numactl -H, hwloc NUMA nodes):
- **value**: 2
- **detail**: node 0: CPUs 0-31, 192 GB. node 1: no CPUs, 730 GB.
- **implication**: Two NUMA domains, presented by the same interface, in the same units, as peer placement targets.

**Measured**:
- **unit**:
  - **latency**: ns
  - **bandwidth**: MB/s
- **conditions**:
  - **tool**: Intel MLC v3.12
  - **access**: sequential
  - **buffer**: 200 MiB
  - **n**: 1
- **node0**:
  - **local latency**: 74.8
  - **read bandwidth**: 106692
  - **cpus**: 32
  - **technology**: DDR4
- **node1**:
  - **local latency**: None
  - **read bandwidth**: None
  - **cpus**: 0
  - **technology**: Optane PMEM (KMEM DAX system-ram)
- **node1 from node0**:
  - **latency**: 175.8
  - **read bandwidth**: 37231.5

**Margin**: The declared count is correct and the partition is real. What fails is the peer assumption behind it: node 1 has no CPUs, so its diagonal cannot be measured at all, and reaching it costs 2.35x the latency and 0.35x the bandwidth of node 0. These are not two of the same kind of thing.

**What goes wrong if you trust the declared value**: Anything that treats NUMA nodes as interchangeable placement units -- default first-touch under memory pressure, round-robin interleave, most NUMA-aware allocators -- will silently place hot data on persistent memory and report no error. The count is right and the model behind it is wrong.

**Note**: Frontier's four domains ARE peers -- local latency, peak bandwidth and cache hierarchy are equivalent across all four, and this claim is confirmed there. The same interface, on this machine, presents a DRAM node and a persistent-memory node in identical language. The registry question is portable; the answer is not.

### Relative cost of crossing between NUMA domains

`numa.distance_matrix` — **contradicted** (confidence: high)

**Declared** (ACPI SLIT via numactl -H, relayed by hwloc_distances_get):
- **matrix**:
  - [10, 17]
  - [17, 10]
- **implication**: Reaching node 1 costs 1.70x a local access.

**Measured**:
- **unit**:
  - **latency**: ns
  - **bandwidth**: MB/s
- **conditions**:
  - **tool**: Intel MLC v3.12
  - **access**: sequential
  - **pages**: 2 MB hugetlb configured
  - **prefetchers**: disabled by MLC via MSR
  - **n**: 1
- **local**:
  - **latency**: 74.8
  - **bandwidth**: 106692
- **to node1**:
  - **latency**: 175.8
  - **bandwidth**: 37231.5
- **latency ratio**: 2.35
- **bandwidth ratio**: 2.87
- **declared ratio**: 1.7

**Margin**: The declared 1.70x understates the measured latency cost by 38% and the measured bandwidth cost by 69%. Beyond the calibration error, the two measured ratios disagree with each other by 22% -- so there is no value of the scalar that would have been right for both metrics.

**What goes wrong if you trust the declared value**: Everything reading numa_distance() underestimates what crossing costs, and here the far node is a different memory technology, so the underestimate lands on migration and tiering policy specifically. A tiering engine that prices demotion off the declared distance is off by more than a third before it starts.

**Conditions**: Single MLC invocation, sequential access, so these are not directly comparable in absolute nanoseconds to Frontier's 3-pass random pointer chase. The ratios are internally consistent (same tool, same run, same conditions on both arms) and that is what the claim rests on. The tier gap is independently reproduced by the copy matrix, which verifies placement via move_pages rather than trusting first touch.

**Note**: The cross-machine finding is NOT that both SLITs understate cost -- checked, and they do not. Frontier declares 1.200x for every remote hop and measures 1.063-1.182x, so its scalar is close to the right average and its failure is that it ERASES STRUCTURE: four domains declared equidistant, three tiers measured, spanning 11%. corsys4 has only two nodes so there is no structure to erase, and the failure is that the SCALAR IS SIMPLY WRONG -- 1.70x declared against 2.35x latency and 2.87x bandwidth. Two machines, two distinct failure modes, same data model. That is the stronger claim: neither is a calibration error that better firmware numbers would fix, because one scalar per pair cannot hold tiers, direction, or two metrics that disagree with each other.

### Implicitly, that crossing cost is symmetric -- a single scalar per pair

`numa.symmetry` — **contradicted** (confidence: high)

**Declared** (hwloc distance matrix shape):
- **implication**: One scalar per pair; direction is not representable.

**Measured**:
- **unit**: GB/s
- **conditions**:
  - **tool**: src/copy_matrix.c
  - **threads**: 16
  - **buffer**: 2 GiB
  - **placement**: numa_alloc_onnode, verified via move_pages before timing
  - **n**: 3
  - **reported**: best of 3
- **dram to optane**: 6.71
- **optane to dram**: 23.21
- **asymmetry ratio**: 3.46
- **single threaded**:
  - **dram to optane**: 3.63
  - **optane to dram**: 3
  - **asymmetry ratio**: 0.83

**Margin**: 3.46x directional asymmetry at 16 threads, against a tool reproducible to 0.5%. This is not a marginal effect; the cost of the 0<->1 pair differs by a factor of three depending on which way the bytes move.

**What goes wrong if you trust the declared value**: No scalar distance can express this. As on Frontier, the declared model is not merely miscalibrated but structurally insufficient -- and the magnitude here makes the point unarguable.

**Conditions**: The registry's probe for this claim is a directional pointer chase plus a directional bandwidth matrix, and the pointer-chase arm is UNFALSIFIABLE on this machine: node 1 has no CPUs, so no thread can be resident on it and the 1->0 direction cannot be initiated. The verdict above rests on a substitute probe -- cross-tier copy bandwidth -- which measures a read+write pair rather than a directed read. Recorded as a substitution, not as the registry's probe.

**Note**: The mechanism is that the destination tier sets the cost -- writing to Optane costs 6.4-6.7 GB/s regardless of where the data was read from, so the matrix bands vertically rather than along the diagonal. And the asymmetry INVERTS at one thread (3.63 vs 3.00), because Optane writes barely scale with threads while the read path scales well. A single directional scalar would be wrong at one thread count or the other; there is no thread-independent answer to record. Frontier's directional asymmetry is 3.9 ns against a 1.2 ns floor (3.3x noise); here it is a factor of 3.46 in the quantity itself. Same structural defect in the declared model, two orders of magnitude apart in how obvious it is.

## What the machine reports accurately

These may be trusted from the system's own interfaces. Listed so a consumer knows which queries are reliable here, not only which are not.

**Number, size and sharing scope of cache levels** — `cpu.cache_hierarchy` via lscpu. Every plateau boundary falls on a declared capacity: the step out of L1d is between 32K and 64K, out of L2 between 1M and 2M, out of L3 between 32M and 64M against a declared 35.75 MB. No boundary is off by a factor of two.
- **unit**: ns
- **conditions**:
  - **pages**: huge (2 MB hugetlb)
  - **threads**: 1
  - **access**: random dependent load
  - **n**: 1
- **plateaus**:
  - level L1d, extent <=32 KB, latency 1
  - level L2, extent 64 KB - 1 MB, latency 3.5
  - level L3, extent 2 - 16 MB, latency 19.5
  - level L3 edge, extent 32 MB, latency 23.5
  - level DRAM, extent >=256 MB, latency 87
  - _Same verdict as Frontier. Structure is the part machines describe reliably, and that is true on both vendors._

**How many cores/hardware threads the job may actually use, versus how many the node physically has** — `cpu.core_inventory` via lscpu. The allowed mask is the full declared set. No cores are withheld.
- **source**: /proc/self/status Cpus_allowed_list
- **value**: 0-31
- **unit**: logical CPUs
- **count**: 32

**That a large-page request was honoured** — `mem.page_backing` via /proc/meminfo, /sys/kernel/mm/transparent_hugepage/enabled. The two arms report different backing at every size, and the resulting latency curves separate. A silently-failed huge-page request would have produced identical curves.
- **conditions**:
  - **tool**: bin/ptrchase --hugepages
  - **verification**: tool reports the backing it actually got, per size, rather than trusting the madvise return
- **result**: hugetlb reported at every buffer size from 4 KB to 1 GB on the huge arm; 4K reported at every size on the 4K arm
- **arms differ**: yes
  - _Contradicted on Frontier, where the compute-node pool is effectively empty and both normal paths to huge pages fail silently. The second control: the same claim, the same probe, opposite verdicts, and the difference is a machine configuration fact rather than a vendor defect._

## Costs that nothing on the machine reports

No topology interface, table, or spec sheet carries these. They are measurement-only, and most are **curves rather than single values** — the cost depends on a named regime variable. Answer with the regime.

### cost.page_size_penalty

The penalty is not a constant. It is zero while the TLB covers the working set, spikes where TLB reach fails but cache still holds, then settles to an offset. A single scalar cannot express it, which is why no declarative source carries it.

- **unit**: ns
- **regime variable**: working set size
- **conditions**:
  - **tool**: bin/ptrchase --curve, huge and 4K arms differenced
  - **threads**: 1
  - **access**: random
  - **n**: 1
  - **binding**: numactl -N 0 -m 0
- **regimes**:
  - extent <=256 KB, huge 1.0-3.5, 4k 1.0-3.5, delta 0, ratio 1, reason TLB reach covers the working set at both page sizes
  - extent 512 KB, huge 3.5, 4k 4.7, delta 1.2, ratio 1.34, reason first-level dTLB reach starting to fail
  - extent 1 MB, huge 3.6, 4k 9.8, delta 6.2, ratio 2.72, reason PEAK 1. 256 PTEs at 4K exceeds first-level dTLB reach while the data is still L2-resident (L2 is 1 MB per core).
  - extent 2-16 MB, huge 19.5, 4k 22.4-25.5, delta 2.9-6.0, ratio 1.15-1.31, reason recovered by the second-level TLB; data L3-resident
  - extent 32 MB, huge 23.5, 4k 41, delta 17.5, ratio 1.74, reason PEAK 2. 8192 PTEs at 4K exceeds second-level STLB reach while the data is still L3-resident (L3 is 35.75 MB).
  - extent 64 MB - 1 GB, huge 65-87, 4k 73-106, delta 6.5-19.2, ratio 1.08-1.22, reason both effects saturated; settles to a roughly constant offset

**Consequence**: TLB misses reported as memory latency, twice, at two different working-set sizes. Both peaks sit where the data is still cache-resident, which is exactly where a developer would not look for a memory-system problem.

**Note**: This is the strongest cross-machine result in the pair. Frontier shows ONE peak (2.4x at 32 MiB, data L3-resident); corsys4 shows TWO (2.72x at 1 MB with data in L2, 1.74x at 32 MB with data in L3). The mechanism is identical on both machines -- the penalty peaks where TLB reach fails while the data is still cache-resident -- but the regime boundaries land at completely different sizes because the TLB and cache geometries differ. A scalar 'huge pages are ~2x better' would be wrong at nearly every size on both machines, and wrong in different places on each. This is the case for carrying curves rather than numbers, made twice.

### cost.loaded_latency_knee

Peak bandwidth and usable bandwidth are different operating points, often far apart. The knee, not the peak, is where a real application should sit.

- **unit**:
  - **latency**: ns
  - **bandwidth**: MB/s
- **regime variable**: offered load
- **conditions**:
  - **tool**: Intel MLC v3.12 --loaded_latency
  - **traffic**: read-only
  - **binding**: numactl --membind
  - **n**: 1
  - **note**: membind, NOT MLC's -j flag -- see pitfalls
- **tiers**:
  -
    - **tier**: DDR4 (node 0)
    - **peak**:
      - **bandwidth**: 106487
      - **latency**: 233.3
      - **inject delay**: 8
    - **knee**:
      - **bandwidth**: 98515.3
      - **latency**: 153.29
      - **inject delay**: 100
      - **pct of peak**: 92.5
      - **latency gain**: 1.52
    - **idle floor**:
      - **latency**: 76.27
      - **bandwidth**: 1604.1
  -
    - **tier**: Optane (node 1)
    - **peak**:
      - **bandwidth**: 32555.9
      - **latency**: 531.04
      - **inject delay**: 300
    - **knee**:
      - **bandwidth**: 31890.9
      - **latency**: 387.54
      - **inject delay**: 400
      - **pct of peak**: 98
      - **latency gain**: 1.37
    - **idle floor**:
      - **latency**: 188.98
      - **bandwidth**: 1101.9
    - **wasted region**:
      - **inject delays**: 0-200
      - **bandwidth pct of peak**: 97.3-99.6
      - **latency range**: 600-674

**Consequence**: On Optane the entire high-load region buys nothing. Injecting at delay 100 gives 98.6% of peak bandwidth at 674 ns; backing off to delay 400 gives 98.0% at 388 ns. The last 0.6% of bandwidth costs 286 ns -- 74% more latency for six-tenths of one percent of throughput. A tiering engine that saturates the persistent-memory tier is paying that for nothing.

**Note**: The two tiers have different curve SHAPES, not just different offsets. DDR4 trades 7.5% of bandwidth for 1.52x latency; Optane trades 2.0% for 1.37x and is bandwidth-saturated so early that the first third of the sweep is flat. Frontier's DDR4 knee is more generous than either (98.3% of peak at 3.6x lower latency), so the shape is not even a property of the memory technology alone.

## Operational pitfalls

Each of these presents as something other than its cause. Symptom, cause, remedy.

**mlc-j-flag-silently-reports-dram**
- Symptom: MLC reports Optane at ~106 GB/s and ~76 ns -- marginally faster than DRAM, which is physically impossible.
- Cause: MLC's -j<n> flag places memory by running the initialising thread on a CPU of node n and relying on first touch. Node 1 has no CPUs. It does not warn and does not fail; it allocates from node 0 and reports DRAM numbers under an Optane label.
- Remedy: Use numactl --membind=<n>, which constrains the page allocator directly and needs no CPU on the target node. Sanity check for any node-1 run: read bandwidth must land near 32 GB/s, never near 106 GB/s.
- Further: This is the canonical unsuitable-probe failure: the instrument's own placement mechanism silently degrades to the thing you are trying to measure against. It is the same class of error as verifying GPU affinity with a bandwidth probe on Frontier.

**loaded-latency-plot-order**
- Symptom: A loaded-latency curve plotted from these files zigzags instead of forming a clean L.
- Cause: Points ordered by bandwidth rather than by inject delay. Near saturation many delays give nearly the same bandwidth at very different latencies.
- Remedy: Order by inject delay, always.

**mlc-needs-root**
- Symptom: MLC returns quietly less accurate numbers.
- Cause: MLC disables hardware prefetchers via MSR and needs root to do it. Without root it falls back silently.
- Remedy: Run as root; confirm the prefetcher line in the output header.

## Unverified — do not rely on these

### cpu.core_inventory — confirmed

Directly sets `-c` / ranks per node. Getting it wrong either wastes allocation or gets the job rejected.

Declared but **not confirmed by measurement**:
- **value**: 32
- **unit**: logical CPUs (16 cores x 2 HWT)

- **Not run**: The registry's probe has two halves: read the allowed mask, then attempt to exceed it. Only the first half ran. There is no batch scheduler on this machine to reject an oversubscription, so the falsifying half of the probe is not available here.

**Why it matters that this is open**: None. Recorded because the same claim on Frontier is misleading -- one core per L3 group is OS-reserved there. A confirmation on one machine and a contradiction on the other is what makes the claim worth carrying in a portable registry.

### cost.contention_sensitivity — untested

Characterization on an idle node describes a machine nobody runs on. A real application is using its cores.


## Leads — observed, deliberately not asserted

Each of these looks like structure and sits at or inside the noise band of its measurement. They are recorded so they are not lost. **They are not results.** Do not build advice on them, and do not repeat them as findings.

**mem.thread_scaling_inversion** — Cross-tier copy asymmetry inverts with thread count. At 16 threads promotion (Optane->DRAM, 23.21 GB/s) is 3.46x cheaper than demotion (DRAM->Optane, 6.71 GB/s). At one thread it reverses: promotion 3.00 GB/s is SLOWER than demotion 3.63 GB/s. Optane writes scale 1.9x from 1 to 16 threads; the promotion path scales 7.8x.

- **Why not asserted**: Both arms are real measurements reproduced within 0.5%, so the observation itself is solid. What is flagged is the generalisation -- two thread counts is not a scaling curve, and the crossover point between them is unmeasured. 'Promotion is cheap' is being asserted as a multi-threaded property on the basis of two samples.

## Limits of this briefing

Questions this document cannot answer. If asked one, say so.

- The registry has no claim for cross-tier copy cost. On Frontier that cost appears as cost.host_device_transfer; here the same physical question -- what does it cost to move a page from one memory technology to another, and is it directional -- has no home, so the machine's single most useful measurement (the copy matrix) is carried under numa.symmetry as a substitute probe. A cost.tier_transfer claim would cover both machines and would make Frontier's HBM/DDR pair askable too. This is the second machine changing the portable question list, which is what a second machine is for.
- Does the SLIT understate crossing cost on a third machine? Two vendors agree so far, both in the same direction. A machine where the SLIT is accurate would be the most informative single data point available, and would say the error is a choice rather than a norm.
- Node 1 has no CPUs, so no CPU-initiated probe can measure direction out of it. corsys4 has DSA; a DMA-initiated transfer could measure directed cost without a resident thread. Untried.
- Loaded latency is read-only here and on Frontier. Optane's read-write gap is 17.8x against 2.9x read-only, so the read-only curve is the least representative measurement in this file for anything that writes.
- Is the two-peak page-size penalty a property of two TLB levels generally, or of this specific cache/TLB geometry? Frontier shows one peak. A third machine decides whether the count of peaks is predictable from the declared geometry, which would make it derivable rather than requiring measurement.

Generated from `corsys4.json` (schema 0.1, registry 0.2) by render.py. Values are measurements with stated conditions, not specifications.
