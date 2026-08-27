# Machine briefing: Frontier (compute node)

OLCF (Oak Ridge National Laboratory). Characterized 2026-07-19, extended 2026-08-10.

- **CPU**: 1x AMD EPYC 7A53, 64 cores, 2 HWT/core, NPS4
- **Memory**: 512 GB DDR4
- **Accelerator**: 4x AMD MI250X (8 GCDs)
- **Network**: Slingshot-11, 4x NIC per node

## How to use this document

This is a **measured** description of one node type, not a spec sheet. Where the machine's own topology interfaces (hwloc, ACPI tables, vendor query tools) disagree with measurement, the measured value is given first and the declared value is shown alongside it, because other tools on this system are still acting on the declared one.

**WHAT THIS DOCUMENT CANNOT SEE.** It describes the machine. It knows nothing about your application, and for many codes the largest single lever is a property of the source rather than of the machine. That is measured, not cautionary: an agent working from this document chose SMT, page size, rank placement and compiler all correctly, and still ran **2x slower** than one that had spent its effort reading the source instead. The winning fact was an algorithmic property of the code, worth more than every machine-level decision combined, and nothing in this document could have contained it. **Before using anything below, read the hot loops and establish what limits them.** If the answer is a property of the code, this document is not where your answer is, and the correct use of it may be to use very little of it.

Rules for reasoning with what follows:

1. **Do not upgrade a hedge.** Items under *Unverified* and *Leads* are not established. Do not present them as facts, and do not build a recommendation whose correctness depends on them.
2. **Read `Measured under` before using any number, and `NOT measured` before assuming one applies.** Every measured quantity below is preceded by the conditions it was obtained under, and by an explicit list of regimes in which no value exists in either direction. **Match those against your own kernel before you use the number.** A value used outside its regime is not merely less accurate: one of the costs here was measured to CHANGE SIGN. If your access pattern, thread count or traffic mix is not the one listed, the number does not apply, and this document does not tell you what does.
3. **Regime-dependent costs are not scalars, and `regime variables` is a list.** Several costs change sign or magnitude across working-set size, access pattern, offered load or message size. Every listed regime variable has to be matched, not just the first one. Answer with the regime, not an average.
4. **Say when the answer is not in here.** This document covers one node type and, for topology, effectively one node. If a question needs data it does not contain, say so rather than interpolating.

**Measurement provenance.** ptrchase, loaded_lat and bwmatrix were validated against Intel MLC on corsys4 (Xeon Gold 6246R) before use here: peak bandwidth within 0.6%, saturated latency within the random-vs-sequential delta.

**Coverage.** Single node type and effectively a single node for the topology results. No node-to-node variability study. Whether these NUMA tiers hold machine-wide is open.

## Where this machine misdescribes itself

Read this section before acting on any topology query you run yourself, or on any advice derived from vendor documentation.

### How many cores/hardware threads the job may actually use, versus how many the node physically has

`cpu.core_inventory` — **misleading** (confidence: high)

**Declared** (hwloc (correct) vs vendor node diagram (misleading)):
- **hwloc allowed PUs**: 112
- **hwloc topology PUs**: 128
- **hwloc reserved PU logical indices**: 112-127
- **hwloc implication**: 56 usable cores of 64 present. hwloc reports the reservation correctly.
- **vendor diagram**: 64 cores
- **note**: Measured on frontier00126 2026-08-10 via hwloc 2.11.2. The declared sources DISAGREE WITH EACH OTHER: hwloc is right and the diagram is wrong. A user who runs lstopo gets the correct answer; a user who reads the node diagram does not.

**Measured**:
- **value**: 56
- **unit**: usable cores
- **reserved**: 0, 8, 16, 24, 32, 40, 48, 56

**Margin**: One core per L3 group is OS-reserved. `srun -c 56` is the ceiling; anything higher is rejected outright.

**What goes wrong if you trust the declared value**: Wasted cores, or a launch line the scheduler rejects.

**Note**: Verdict stays `misleading` but the target moves: it is the vendor diagram that misleads, not hwloc. Confirmed 2026-08-10 -- hwloc-calc reports 112 allowed of 128 topology PUs, reserved logical indices 112-127. This resolves the open question recorded in July.

### Relative cost of crossing between NUMA domains

`numa.distance_matrix` — **contradicted** (confidence: high)

**Declared** (ACPI SLIT via numactl -H, relayed by hwloc_distances_get):
- **matrix**:
  - [10, 12, 12, 12]
  - [12, 10, 12, 12]
  - [12, 12, 10, 12]
  - [12, 12, 12, 10]
- **implication**: All four domains mutually equidistant; every remote hop costs 1.2x local.

**Measured under** — holds under these conditions, not known to hold outside them:
  - pages: 4K
  - threads: 1
  - access: random
  - n: 3

**Measured**:
- **unit**:
  - **latency**: ns
  - **bandwidth**: MB/s
- **local**:
  - **latency**: 101.5
  - **bandwidth**: 44582
- **tiers**:
  -
    - **tier**: near
    - **pairs**: 0<->1, 2<->3
    - **latency**: 107.9, 108.9
    - **bandwidth**: 43750, 43962
  -
    - **tier**: mid
    - **pairs**: 0<->2, 1<->3
    - **latency**: 115.8, 116.1
    - **bandwidth**: 43219, 43020
  -
    - **tier**: far
    - **pairs**: 1<->2, 0<->3
    - **latency**: 119.2, 120
    - **bandwidth**: 42841, 42397

**Margin**: Near-to-far gap is 12.1 ns against a 1.2 ns noise floor (~10x), and 1353 MB/s against 289 MB/s (~4.7x). Two independently written tools -- one pointer-chasing, one streaming -- produce identical rank ordering across all six pairs, with perfect anti-correlation between latency and bandwidth.

**What goes wrong if you trust the declared value**: Anything reading numa_distance() treats these four domains as interchangeable. Page placement and migration policy driven by the declared matrix systematically underestimates crossing cost.

**Conditions**: Measured on 4K pages because huge pages cannot be allocated on a remote domain here (see mem.page_backing). Absolute values run ~16 ns high; the local-vs-remote structure is unaffected.

**Note**: Magnitudes differ 4x between metrics: latency spans 11% across pairs (18% counting local), bandwidth only 3.5% (4.9%). A bandwidth-only study would reasonably call these domains interchangeable. Which metric you measure determines whether you see the topology at all.

### Implicitly, that crossing cost is symmetric -- a single scalar per pair

`numa.symmetry` — **contradicted** (confidence: medium)

**Declared** (hwloc distance matrix shape):
- **implication**: One scalar per pair; direction not representable.

**Measured under** — holds under these conditions, not known to hold outside them:
  - access: dependent random (pointer chase)
  - pages: 4K
  - threads: 1
  - provenance: same probe family as numa.distance_matrix (ptrchase); not separately recorded at the time, inferred from the campaign

**NOT measured** — no value here, in either direction:
  - Whether the direction of the asymmetry holds for streaming access, or for writes. Both metrics here are read.
  - Pairs other than 2/3 directionally -- only one pair was run both ways.

**Mechanism**: A scalar distance has one value per pair, so it cannot represent a difference between 2->3 and 3->2 at all. Whatever causes the asymmetry, the declared model has no slot to put it in -- which is the point of the claim.

**Measured**:
- **example pair**: 2/3
- **2->3**:
  - **latency**: 110.8
  - **bandwidth**: 43662
- **3->2**:
  - **latency**: 106.9
  - **bandwidth**: 44263

**Margin**: 3.9 ns latency difference against a 1.2 ns floor (3.3x); 601 MB/s against 289 MB/s (2.1x). Both metrics agree on the direction -- 3->2 is better in both.

**What goes wrong if you trust the declared value**: No scalar distance can express this. The declared model is not merely miscalibrated, it is structurally insufficient.

**Note**: Confidence held at medium rather than high: the bandwidth margin is only 2.1x the floor. Worth a dedicated directional run before leaning on it in print.

### How many accelerator devices exist and how they are indexed

`gpu.device_inventory` — **misleading** (confidence: high)

**Declared** (node diagram):
- **value**: 4x MI250X

**Measured**:
- **value**: 8
- **unit**: schedulable GCDs
- **note**: Each MI250X exposes two Graphics Compute Dies; the GCD is the unit ROCm and Slurm schedule.

**Margin**: Factor of 2 between the package count on the diagram and the addressable device count.

**What goes wrong if you trust the declared value**: A rank-per-GPU launch built from the diagram idles half the accelerator. Observed directly: the 1-rank QMCPACK run was starved twice over -- one OpenMP thread and one of eight GCDs.

### That a large-page request was honoured

`mem.page_backing` — **contradicted** (confidence: high)

**Declared** (THP sysfs + hugetlb pool + madvise return):
- **implication**: A large-page request appears to succeed.

**Measured**:
- **thp setting**: never
- **hugetlb pool**:
  - **HugePages Total**: 4
  - **HugePages Free**: 0
- **outcome**: Both normal paths to huge pages fail SILENTLY. Allocation succeeds; backing is 4K.

**Margin**: Verified via smaps rather than trusting the madvise return.

**What goes wrong if you trust the declared value**: Every latency measurement taken without verification is silently wrong and still looks plausible. Three experiments in this campaign produced clean, plausible, WRONG nulls for exactly this reason.

**Working path**: craype-hugepages2M is required, and it works by RELINKING the binary, not via a runtime flag.

**Further complication**: craype-hugepages2M provisions only the LOCAL node's pool. Once linked, the default allocator ABORTS under a remote `numactl -m`. Consequence for this campaign: local latency must be measured with the module and the NUMA matrix without it -- two separate passes, which is why numa.distance_matrix is on 4K pages.

### How many network interfaces the node has and how a job maps onto them

`net.nic_inventory` — **misleading** (confidence: high)

**Declared** (facility spec sheet):
- **value**: 100
- **unit**: GB/s injection per node
- **nics**: 4
- **interfaces**: hsn0, hsn1, hsn2, hsn3

**Measured under** — holds under these conditions, not known to hold outside them:
  - ranks per node: 1
  - nics crossed: 1

**Measured**:
- **host to host**:
  - **latency us**: 2.38
  - **bandwidth GBs**: 22.6
- **device to device**:
  - **latency us**: 2.55
  - **bandwidth GBs**: 23.9
- **host to device**:
  - **latency us**: 2.42
  - **bandwidth GBs**: 23.9
- **scaling**:
  - **conditions**:
    - **tool**: osu_mbw_mr
    - **cores per rank**: 14
    - **note**: -c 14 confines each rank to one NUMA domain; Cray MPICH refuses NIC_POLICY=NUMA otherwise. Placement verified per rank.
  - **1 pair MBs**: 22673.4
  - **2 pairs MBs**: 45103
  - **4 pairs MBs**: 90262.2
  - **ratios**: 1.00 / 1.99 / 3.98 -- linear
  - **per link MBs**: 22565.6
  - **note**: 4-pair aggregate / 4 matches the 1-pair number within 0.5%.

**Margin**: Scaling is linear to 4 pairs: 22.7 -> 45.1 -> 90.3 GB/s. The node reaches 90.3 GB/s, ~90% of the declared 100 GB/s. The July 23.9 GB/s was PER LINK and the spec is correct; only the natural single-pair benchmark misleads.

**What goes wrong if you trust the declared value**: Quoting the single-pair result next to the 100 GB/s node spec looks like a 4x error. The declared number is correct; the natural benchmark configuration measures something else.

### What storage tiers a job can reach, their type and capacity, and what it must do to reach each one

`storage.tier_inventory` — **misleading** (confidence: high)

**Declared** (df on a compute node, plus the `nvme` Slurm node feature):
- **df shows**: /tmp, /dev/shm and /rootfs.rw each ~252 G "available"
- **nvme feature**: advertised on every node by sinfo
- **implication**: reads as ~252 G of node-local scratch disk available to any job

**Measured under** — holds under these conditions, not known to hold outside them:
  - node: frontier06028 default allocation, and a second node under -C nvme
  - date: 2026-08-18
  - method: df -hT, lsblk, and a write test

**NOT measured** — no value here, in either direction:
  - Bandwidth of any tier -- this claim is inventory only. See cost.storage_bands.
  - Whether the NVMe is shared with other jobs on the same node.
  - Metadata rates on any tier.

**Mechanism**: The NVMe device exists on every node but is only mapped into the job when the nvme constraint is requested. df therefore reports the tmpfs overlay in a default allocation, and a tmpfs size limit is not free storage: it is a ceiling on how much RAM the job may convert into apparent disk.

**Measured**:
- **tiers**:
  - tier node-local NVMe, path /mnt/bb/$USER, device /dev/mapper/nvme-bb, fs xfs, size 3.4 TB, access REQUIRES #SBATCH -C nvme; absent otherwise, lifetime the job
  - tier Lustre orion, performance pool, path $MEMBERWORK / $PROJWORK, fs lustre, access default layout for files 256 KiB - 8 MiB, osts 1350
  - tier Lustre orion, capacity pool, path $MEMBERWORK / $PROJWORK, fs lustre, access default layout for files 8 MiB - 128 GiB, ONE stripe
  - tier MDT (Data-on-MDT), path same, access default layout for files < 256 KiB; never touches an OST
  - tier tmpfs, path /tmp, /dev/shm, fs tmpfs, size 252 G limit, note THIS IS RAM. Bytes written count against node memory.
  - tier NFS, path $HOME (/ccs/home), fs nfs, note not Lustre; lfs exits 25. Not for bulk I/O.

**Margin**: 3.4 TB of local disk is invisible without one constraint flag, while 252 G of RAM is displayed as though it were disk.

**What goes wrong if you trust the declared value**: A job writing bulk per-rank output to /tmp consumes node memory and dies out of memory, with the failure appearing to be in the application. A job that could have staged 3.4 TB locally instead writes it to a single Lustre stripe.

### Write bandwidth as a function of file size and storage tier, and whether the declared layout boundaries are observable

`cost.storage_bands` — **misleading** (confidence: medium)

**Declared** (lfs getstripe -d $MEMBERWORK -- 7-component Progressive File Layout):
- **boundaries**: < 256 KiB: MDT (Data-on-MDT), 256 KiB - 8 MiB: pool `performance`, 1 stripe, 8 MiB - 128 GiB: pool `capacity`, 1 stripe, self-extending, > 128 GiB: pool `capacity`, 8 stripes
- **implication**: a file changes pool at 8 MiB, so behaviour should change there

**Measured under** — holds under these conditions, not known to hold outside them:
  - job: 5307805, 2026-08-19, 1 node
  - writers: 1
  - source: incompressible (/dev/urandom buffer, reused)
  - durability: fsync per file
  - target: $MEMBERWORK project directory on orion
  - machine state: 9608 nodes running machine-wide -- the filesystem is SHARED
  - passes: 3

**NOT measured** — no value here, in either direction:
  - MULTIPLE WRITERS. Every number here is one writer, and that is the case where striping and tier choice are most likely to behave differently. The striping null should NOT be generalised to a parallel write.
  - The 128 GiB boundary, where the declared layout finally uses 8 stripes.
  - Reads.
  - A quiet filesystem. Pass-to-pass spread reached 4x at 1 GiB in an earlier run; orion is shared and this varies with what everyone else is doing.

**Mechanism**: Small-file bandwidth is dominated by fixed per-file cost, which is why the curve climbs monotonically from 128 KiB to 1 GiB regardless of pool. The 256 KiB boundary is visible because Data-on-MDT is a different mechanism, not a faster disk. Node-local NVMe wins at small sizes because it avoids the network and the OST round trip, and LOSES at large sizes because a single device has a fixed write ceiling while Lustre aggregates many OSTs behind a write-back cache.

**Measured**:
- **unit**: MB/s, median of 3 passes
- **regime variables**: file size, storage tier, number of writers (NOT swept)
- **lustre by size**:
  - bytes 131072, MBps 0.9, declared band MDT
  - bytes 262144, MBps 7.1, declared band performance, step 8.1x -- the 256 KiB boundary IS observable
  - bytes 524288, MBps 5.3, declared band performance
  - bytes 4194304, MBps 108.8, declared band performance
  - bytes 8388608, MBps 137.1, declared band capacity, step 1.26x -- the 8 MiB boundary is NOT observable; the climb is smooth
  - bytes 16777216, MBps 130.9, declared band capacity
  - bytes 67108864, MBps 355.8, declared band capacity
  - bytes 268435456, MBps 721.1, declared band capacity
  - bytes 1073741824, MBps 812, declared band capacity
- **nvme vs lustre**:
  - bytes 8388608, nvme MBps 536.4, lustre MBps 137.1, ratio 3.91x
  - bytes 67108864, nvme MBps 755.9, lustre MBps 355.8, ratio 2.12x
  - bytes 268435456, nvme MBps 475.7, lustre MBps 721.1, ratio 0.66x
  - bytes 1073741824, nvme MBps 438.4, lustre MBps 812, ratio 0.54x
- **explicit stripe 8 at 1GiB**:
  - **default MBps**: 805.7
  - **stripe8 MBps**: 751.6
  - **ratio**: 0.93x
  - **replication**: 0.97x in job 5307700 -- a replicated null
- **metadata creates per sec**: 1500-1815 (0-byte files, Data-on-MDT band)

**Margin**: The NVMe-vs-Lustre ratio CROSSES OVER between 64 MiB and 256 MiB: 3.91x in favour of local at 8 MiB, 0.54x against it at 1 GiB.

**What goes wrong if you trust the declared value**: A user told "node-local is faster because it is local" is right below ~100 MB and wrong above it, by nearly 2x at 1 GiB -- which is the size range checkpoints occupy. And effort spent setting an explicit stripe count buys nothing for a single writer.

**Note**: SPLIT VERDICT on the declared layout, which is why this is `misleading` rather than confirmed or contradicted. The 256 KiB boundary is observable (8.1x step). The 8 MiB pool change -- the one a user would most want to act on, since it silently moves data from `performance` to `capacity` -- produces NO observable step at single-writer scale. The layout declares a transition that a user cannot detect and therefore cannot act on.

## What the machine reports accurately

These may be trusted from the system's own interfaces. Listed so a consumer knows which queries are reliable here, not only which are not.

**Number, size and sharing scope of cache levels** — `cpu.cache_hierarchy` via Zen3 specification. Every plateau boundary lands on the declared size. Curves were taken one per NUMA DOMAIN (four), not one per L3 region (eight) -- the four sampled curves agree, but the eight L3 regions were not sampled independently.
- **L1**:
  - **value**: 1.1
  - **unit**: ns
  - **extent**: <=32 KB
- **L2**:
  - **value**: 3.4
  - **unit**: ns
  - **extent**: <=512 KB
- **L3**:
  - **value**: 10.9-13.3
  - **unit**: ns
  - **extent**: <=32 MB
- **DRAM**:
  - **value**: 87-89
  - **unit**: ns
  - _Doubles as the calibration check for ptrchase on this machine. CORRECTION 2026-08-10: this entry previously read 'identical across all four CCDs', conflating the four NUMA domains with the CCD count. There are eight L3 regions. Caught by the treatment arm of the eval, which noticed the entry contradicted the eight OS-reserved cores (one per L3 region) recorded under cpu.core_inventory -- an internal inconsistency in the artifact, found by a consumer reading it._

**Number of NUMA domains and which cores and memory belong to each** — `numa.domain_count` via hwloc / numactl -H. Loaded latency, peak bandwidth and cache hierarchy are equivalent on all four domains. The domains are genuine peers; only the crossing cost differs.
- **value**: 4
- **diagonal uniform**: yes
  - _This confirmation is load-bearing for numa.distance_matrix: it establishes that the tier structure found there is a crossing cost, not domains being intrinsically different._

**Relative cost of device-to-device links** — `gpu.interconnect_cost` via rocm-smi XGMI link weights. No overlap between bands -- 79 ns of clear air between class 1 and 2, 139 ns between 2 and 3. Spacing is linear at ~10.8 ns per weight unit.
- **unit**: ns
- **bands**:
  -
    - **weight**: 15
    - **links**: 12
    - **mean**: 563.2
    - **range**: 525.8, 591.1
  -
    - **weight**: 30
    - **links**: 14
    - **mean**: 724.2
    - **range**: 669.8, 743.8
  -
    - **weight**: 45
    - **links**: 2
    - **mean**: 888.1
    - **range**: 882.7, 897.8
  - _THE CONTROL. Same machine, same vendor, same firmware, two topology cost tables: the GPU weight table is accurate and linear, the CPU SLIT is flat and wrong. That turns numa.distance_matrix from 'firmware tables are unreliable' into 'AMD describes its GPU interconnect accurately and its CPU interconnect not at all' -- specific and actionable rather than lazy._

**Device cache levels and memory sizes** — `gpu.memory_hierarchy` via MI250X specification / rocminfo. L1 and L2 boundaries match the MI250X specification.
- **unit**: ns
- **vector L1**:
  - **value**: 33
  - **extent**: <=16 KB
- **L2**:
  - **value**: 115-122
- **HBM local**:
  - **value**: 375
- **peer near**:
  - **value**: 540
  - **note**: on-package partner GCD
- **peer far**:
  - **value**: 730
- **host**:
  - **value**: 1250
  - **note**: ~3.4x local HBM
- **bandwidth**:
  - **HBM self**: ~1 TB/s
  - **xgmi on package**: 133-145 GB/s uni, 254-272 bidi
  - **cross package**: 37-77 GB/s
  - _No stock tool reports pointer-chase latency on MI250X memory. This is a measurement gap gpu_ptrchase fills, not a re-measurement._

## Costs that nothing on the machine reports

No topology interface, table, or spec sheet carries these. They are measurement-only, and most are **curves rather than single values** — the cost depends on a named regime variable. Answer with the regime.

### cost.page_size_penalty

The penalty is not a constant. It is zero while the TLB covers the working set, spikes where TLB reach fails but cache still holds, then settles to an offset. A single scalar cannot express it, which is why no declarative source carries it.

**Measured under** — holds under these conditions, not known to hold outside them:
  - access pattern: dependent random (pointer chase) -- each load depends on the previous
  - working set: swept, 256 KB to 1 GB; the 2.4x is at 32 MB
  - threads: 1
  - placement: single NUMA domain, first touch
  - traffic: read-only
  - node state: idle
  - page sizes: 4 KB vs 2 MB

**NOT measured** — no value here, in either direction:
  - streaming / sequential access -- the regime where the mechanism does not apply. A corsys4 bandwidth check (107,765 huge vs 107,342 4K) suggests no effect, but that is a different machine and a bandwidth metric, so it does not settle the latency question here.
  - multi-threaded first touch across a 2 MB page boundary -- a 2 MB page can span data first-touched by threads on different NUMA domains, which coarsens placement
  - write or mixed traffic
  - under memory load from co-resident ranks

**Mechanism**: The penalty comes from TLB reach failure on accesses that cannot be prefetched. 32 MB needs 8192 PTEs at 4 KB, far past the ~8 MB L2 TLB reach, so every access pays a page walk that itself misses to memory. It exists only where BOTH hold: the working set exceeds TLB reach, AND the access pattern defeats prefetch. A kernel that streams contiguously amortises the page walk across the whole page, so the mechanism is absent and no benefit should be expected.

- **regime variables**: working set size, access pattern
- **unit**: ns
- **regimes**:
  - extent <=256 KB, huge same, 4K same, delta 0, reason TLB covers the working set
  - extent 512 KB, huge 3.6, 4K 5.4, delta 1.8
  - extent 1-8 MB, huge 10.9-13, 4K 12-15, delta ~2
  - extent 16 MB, huge 13.1, 4K 17.5, delta 4.4
  - extent 32 MB, huge 13.3, 4K 32.2, delta 18.9, ratio 2.4x, reason PEAK. Working set still fits in L3 (32 MB per L3 region) but needs 8192 PTEs at 4K, far past TLB reach. Every access pays a page walk that itself goes to memory.
  - extent 64 MB - 1 GB, huge 58-89, 4K 67-103, delta 9-14, reason Both effects saturated; settles to a roughly constant offset

**Shape**: Zero, then 2.4x, then a constant offset. There is no single number that describes this.

**Consequence**: TLB misses reported as memory latency. The worst case is at a working set that still fits in cache, which is exactly where a developer would not look for it.

**Note**: MEASURED CONSEQUENCE OF USING THIS OUTSIDE ITS REGIME: an agent matched a streaming kernel's working set against the curve above -- correctly, per the regime variable declared at the time -- and enabled huge pages for it. It cost 2.7% (p=3e-10) rather than helping. The number did not merely fail to transfer; it inverted. That is why regime_variables is a list and why measured_under exists. Full write-up in eval/exp-b/RESULTS.md.

### cost.loaded_latency_knee

Peak bandwidth and usable bandwidth are different operating points, often far apart. The knee, not the peak, is where a real application should sit.

**Measured under** — holds under these conditions, not known to hold outside them:
  - threads: 1 latency + 27 bandwidth
  - traffic: read-only
  - domain: 0
  - regime swept: injection delay, densified across 48-96 after the original 19-point sweep hid the knee
  - node state: idle apart from the load generator

**NOT measured** — no value here, in either direction:
  - Read/write mix. This probe sweeps read-only traffic; MLC sweeps ratios. Write traffic saturates differently, and hwloc defines an empty WriteLatency slot waiting for it.
  - Whether the knee moves with page size or NUMA placement -- neither was varied.

**Mechanism**: Latency rises steeply near saturation because queueing delay grows without bound as utilisation approaches 1, while delivered bandwidth is already asymptotically flat. The knee is where that queueing term starts to dominate. It is a property of the memory controllers under READ load; a different read/write mix moves it.

- **regime variables**: injection delay (offered load), traffic read/write mix
- **peak**:
  - **bandwidth MBs**: 44521
  - **latency ns**: 832
- **knee**:
  - **bandwidth MBs**: 43752
  - **latency ns**: 234
  - **inject delay**: 56
- **idle floor**:
  - **bandwidth MBs**: 653
  - **latency ns**: 89

**Shape**: 98.3% of peak bandwidth is available at 2.7x lower latency. Between injection delay 52 and 56 latency collapses 634 -> 234 ns while bandwidth falls only 1.7%.

**Consequence**: Tuning to saturate bandwidth costs a factor of 2.7 in latency for 1.7% of throughput.

**Cross-validation**: Idle floor 89.0 ns agrees with ptrchase huge-page local (85.9 ns) and the cache curve DRAM plateau (87.9 ns) -- three measurements, two independent tools, within 3.5%.

**Open**: A 400 ns step remains between delay 52 and 56. The transition is genuinely sharp but has not been proven with points inside it.

### cost.host_device_transfer

Whether device-resident buffers beat host-staged ones changes sign with message size. A single-size measurement gives the wrong universal answer.

**Measured under** — holds under these conditions, not known to hold outside them:
  - pattern: ping-pong (osu_latency) and streaming (osu_bw) reported separately -- the crossover differs between them, which is why both are recorded
  - scope: inter-node
  - node state: idle
  - gcd selection: NOT RECORDED at measurement time -- recovered from evidence files if at all
  - memory type: device-resident vs host-staged; pinned/pageable NOT RECORDED at measurement time -- recovered from evidence files if at all

**NOT measured** — no value here, in either direction:
  - Intra-node device-to-device transfer -- this claim is inter-node only.
  - Under network load from other users, and the fabric is shared.
  - Whether the crossover moves with GCD choice or NUMA placement of the host buffer.

**Mechanism**: Device buffers avoid a staging copy but pay a fixed per-transfer setup that host staging does not. Below the crossover the fixed cost dominates and staging wins; above it the avoided copy dominates and device wins. The crossover therefore sits wherever those two costs cross, which is why it differs between ping-pong and streaming: a streaming benchmark keeps messages in flight and amortises the fixed cost.

- **regime variables**: message size, buffer residency (host vs device)
- **at 4MiB**:
  - **host MBs**: 22635.8
  - **host spread**: 8.1
  - **device MBs**: 23876.8
  - **device spread**: 10.3
  - **advantage**: +5.48%
  - **latency us**:
    - **host**: 191.12
    - **device**: 180.48
    - **advantage**: +5.90%
- **crossovers**:
  - **bandwidth**: 16 KB
  - **latency**: 256 KB
- **small message penalty**: 12-14% worse below 64 KB

**Shape**: The 4 MiB bandwidth gap is 82x the across-pass spread; the latency gap is 30x. Device latency varied 0.02 us across three passes (0.011%) -- the most reproducible measurement in the campaign. Passes were INTERLEAVED, not blocked, so drift over the allocation cannot masquerade as a residency effect.

**Control**: GPU-aware MPI run with HOST buffers on both ends landed within 0.02% of plain host. Enabling GPU support costs nothing by itself; the entire 5.5% lives in the hardware path between the NIC and the memory it reads. One run eliminated a whole hypothesis family.

**Practical reading**: Bandwidth turns positive at 16 KB, latency not until 256 KB -- a streaming benchmark keeps messages in flight and amortises the fixed cost, a ping-pong pays it every round trip. Production GPU HPC and LLM training move megabytes and sit far above both crossovers. The small-message penalty applies to halo exchanges and small collectives.

**Open**: Contention versus cache coherence on host DMA. The discriminating test was confounded -- see cost.contention_sensitivity.

### cost.collective_scaling

Real applications live on allreduce and alltoall, not on ping-pong. Point-to-point numbers cannot predict where a code stops scaling, because the rank-scaling exponent is not the same for every operation or every message size. MPI library documentation describes algorithms but not their cost on a specific fabric, so there is no declared source to check against.

**Measured under** — holds under these conditions, not known to hold outside them:
  - job: 5307447, 2026-08-19
  - nodes: 1 to 16, ranks 8 to 128
  - ranks per node: 8, FIXED -- more ranks means more nodes, not different packing
  - binding: -c 7 --threads-per-core=1 --cpu-bind=cores
  - passes: 2
  - buffers: host memory
  - fabric state: SHARED with all other users; occupancy recorded in the run conditions file. This claim varies with what other jobs are doing in a way that memory-side claims do not.

**NOT measured** — no value here, in either direction:
  - Beyond 128 ranks / 16 nodes. Alltoall is already superlinear at 128 and the extrapolation is the interesting part, so this bound matters.
  - Ranks-per-node other than 8 -- on-node packing was deliberately held fixed, so nothing here separates rank scaling from per-node contention.
  - GPU-resident buffers.
  - Non-power-of-two rank counts, where Cray MPICH may select a different algorithm.
  - Under network load from the job itself, as opposed to from other users.

**Mechanism**: Small-message collectives are bound by hop count and per-message overhead, so cost grows roughly with the depth of the reduction or broadcast tree -- logarithmic-ish in rank count. Large-message allreduce is bandwidth bound and each rank moves a nearly fixed volume regardless of how many peers exist, so it barely grows. Alltoall is different in kind: total messages grow as n^2, so per-rank time grows WITH the rank count and the growth is superlinear once messages are large enough to be bandwidth bound.

- **unit**: us, median of passes
- **regime variables**: message size, rank count, operation
- **rank scaling 8 to 128 ranks**:
  - op allreduce, bytes 8, us at 8 ranks 2.63, us at 128 ranks 20.86, growth 7.9x
  - op allreduce, bytes 1048576, us at 8 ranks 760.5, us at 128 ranks 1200.59, growth 1.6x
  - op alltoall, bytes 8, us at 8 ranks 5.28, us at 128 ranks 55.55, growth 10.5x
  - op alltoall, bytes 65536, us at 8 ranks 45.07, us at 128 ranks 1186.14, growth 26.3x
  - op bcast, bytes 8, us at 8 ranks 0.43, us at 128 ranks 6.38, growth 14.8x
  - op bcast, bytes 1048576, us at 8 ranks 37.35, us at 128 ranks 395.31, growth 10.6x

**Shape**: Growth from 8 to 128 ranks spans 1.6x to 26.3x depending on operation and message size -- a factor of 16 difference in the scaling exponent itself.

**Consequence**: A scaling study extrapolated from point-to-point numbers, or from one message size, predicts the wrong rank count to stop at. A code dominated by small allreduces and one dominated by large alltoall have opposite scaling behaviour on the same fabric.

**Note**: THE FINDING IS THE DISAGREEMENT. The two regime axes do not have the same shape: allreduce at 1 MiB grows 1.6x over the same rank range where alltoall at 64 KiB grows 26.3x. So no scalar and no single curve describes collective cost here -- it is a surface, and any summary that collapses either axis is wrong somewhere. This was pre-registered as the falsifiable question and could have come out the other way: matching shapes would have meant one curve sufficed.

### cpu.smt_benefit

Every user sets --threads-per-core on every job, and no source says what it is worth here. The answer is regime-dependent by nature, so a single number would be wrong for half of all codes.

**Measured under** — holds under these conditions, not known to hold outside them:
  - job: 5307847, 2026-08-19, frontier08598
  - cores: all 56 allocatable, held fixed across both arms
  - arms: 56 threads at 1/core vs 112 threads at 2/core
  - binding: OMP_PROC_BIND=close; OMP_PLACES=cores (1/core) or threads (2/core)
  - passes: 3, arms in rotating order
  - kernels: per-thread working sets of 64 MB (chase, stream) and 64 KB (fma)

**NOT measured** — no value here, in either direction:
  - A genuinely issue-saturated FPU kernel. The fma kernel was DESIGNED to be one and is not -- see the mechanism. Whether SMT hurts when the issue width is actually saturated remains open, and it is the case where the original prediction might still hold.
  - Thread counts between 56 and 112, so the shape of the transition is unknown.
  - Mixed workloads, where different threads are limited by different resources.
  - Anything at fewer than 56 threads -- and this matters: the corsys4 validation at 2 threads gave stream +88%, the opposite sign to Frontier at 56. Saturation is the mechanism, so a low-thread measurement cannot predict a high-thread one.
  - A real application that mixes regimes. All three kernels here are purely one thing -- a dependent-load chase, a dependent-FMA chain, a sequential stream -- and the latency-vs-throughput rule is derived from that purity. A code with both irregular gathers and streaming traffic has idle issue slots the aggregate bandwidth figure does not reveal, so this claim's SIGN is not established for such codes. Treat the rule as measured on microkernels and unvalidated on applications.

**Mechanism**: SMT adds a second instruction stream to a core, so it helps exactly when the core is IDLE waiting -- and not at all when the core is already saturating a shared resource. Both latency-bound kernels gain ~70-78% whether they wait on memory (chase) or on FPU result latency (fma); the bandwidth-saturated kernel loses 5%. The distinction is latency-bound versus throughput-bound, NOT memory versus compute.

- **unit**: fraction of additional work from the second hardware thread
- **regime variables**: what limits the kernel
- **by kernel**:
  - kernel chase, limit memory latency, dependent loads, smt gain +69.7%
  - kernel fma, limit FPU latency -- 4 dependent chains under-saturate a 2/cycle issue width, smt gain +78.2%
  - kernel stream, limit memory BANDWIDTH, saturated, smt gain -5.0%

**Shape**: A 75-point spread between kernels on the same node in the same job: +78.2% to -5.0%. Any single answer to "should I use SMT" is wrong for some of these.

**Consequence**: A code told to use 112 threads because "SMT helps" loses 5% if it is bandwidth bound; one told to use 56 because "SMT hurts on HPC codes" leaves ~70% on the table if it is latency bound.

**Note**: THE PREDICTION WAS FALSIFIED AND THE RESULT IS BETTER FOR IT. The probe was designed expecting fma to gain LEAST, on the reasoning that two threads share the FPU issue width. It gained MOST. The kernel uses four dependent FMA chains, and at ~4-cycle latency against a 2/cycle issue width a single thread issues about half the peak -- so it is FPU-latency bound, not issue bound, and a second thread fills the gap. The corsys4 validation was consistent with this all along (fma showed a +72% gain); it was read as "SMT helps least" when 86%-of-two-real-cores means "a second thread adds 72% more work". The design intent was wrong, the measurement was right, and the corrected rule -- latency-bound versus throughput-bound -- is more useful than the one intended.

## Operational pitfalls

Each of these presents as something other than its cause. Symptom, cause, remedy.

**huge-pages-fail-silently**
- Symptom: Latency measurements come out high with no error anywhere.
- Cause: THP is [never] and the hugetlb pool is empty (Total 4, Free 0). Both normal paths fail silently.
- Remedy: Load craype-hugepages2M -- it works by relinking, not a runtime flag. Then verify via smaps; do not trust the madvise return.
- Further: Once linked, the default allocator ABORTS under a remote `numactl -m`, because the module provisions only the local node's pool. Local latency and the NUMA matrix need two separate passes.

**core-count-ceiling**
- Symptom: `srun -c 64` is rejected.
- Cause: One core per L3 group is OS-reserved: 0, 8, 16, 24, 32, 40, 48, 56.
- Remedy: `-c 56` is the ceiling. It also divides cleanly: 14 cores / 28 threads per NUMA domain.

**login-nodes-not-representative**
- Symptom: Topology conclusions drawn on a login node do not hold on compute.
- Cause: login08 is EPYC 7763 + a single MI210; compute is 7A53 + 4x MI250X.
- Remedy: Both are gfx90a so builds carry over, but no topology measurement from a login node is valid. Run 00_topo.sh inside an allocation.

**one-rank-one-nic**
- Symptom: Inter-node bandwidth from one rank per node reads far below the node spec.
- Cause: One rank per node crosses one of four Slingshot NICs.
- Remedy: Spread ranks across the four NUMA domains -- `-c 14` gives one rank per domain.

**osu-upc-build**
- Symptom: OSU 7.4 fails to build against the Cray toolchain.
- Cause: c/upc is unconditionally in the top-level SUBDIRS and there is no configure flag to disable it; the Cray compiler has no UPC front end.
- Remedy: Build only c/mpi.

**qmcpack-build-script**
- Symptom: The shipped Frontier build script fails or takes 4-8 hours.
- Cause: config/build_olcf_frontier_ROCm.sh hardcodes BOOST_ROOT to /ccs/proj/mat151 (inaccessible outside that project) and builds all eight variants.
- Remedy: Use the boost/1.86.0 module and build only gpu_real -- about 15 minutes.

**prgenv-cray-drops-openmp**
- Symptom: A CMake project builds cleanly under the default environment and runs single-threaded. The timer table looks normal; nothing errors.
- Cause: Frontier defaults to PrgEnv-cray. CCE identifies to CMake as "CrayClang", which matches a "Cray" branch BEFORE any "Clang" branch in projects that test in that order. If the project ships no CrayCompilers.cmake, it falls through to a warning and sets no flags at all -- including -fopenmp. Configuration.h then substitutes stub omp_* functions, so every `omp parallel for` and `omp simd` is silently dropped.
- Remedy: module load PrgEnv-gnu, and verify from the GENERATED CONFIG HEADER that OpenMP is enabled -- the flag the project defines for it will be 1, not absent or 0. Do not trust a clean build, and do not trust the compile line: the flags are dropped silently at configure time, not at compile time.
- Further: Observed 2026-08-13 on a CMake-based proxy application. The failure costs a factor of the thread count and presents as "this machine is slow", not as a build problem.

**mpi-off-by-default**
- Symptom: `srun -n16` completes, prints one timer table, and reports a plausible time. Scaling studies show no speedup and no error.
- Cause: Some CMake projects default MPI OFF and require an explicit flag to enable it. The Cray wrappers link such a build without complaint, so the binary is serial and N ranks are N independent copies of the whole problem rather than one N-rank job. Nothing in the environment or the launch says so; the only signal is whether the code itself prints its rank count.
- Remedy: Pass the project's MPI flag explicitly and verify the MPI symbol in the generated config header. Then verify again at RUNTIME from the application's own output: a benchmark that prints its rank count is worth choosing for that reason alone, and a rank count of 1 under srun -n16 is the whole failure made visible.
- Further: Caught 2026-08-13 only because the application under test happened to print "MPI processes = N". A code that does not print it would have produced a full scaling study of nonsense, every number plausible.

**cmake-needs-cray-system-name**
- Symptom: CMake configure fails on a Cray system with FindMPI unable to accept the CC wrapper as an MPI compiler.
- Cause: CMAKE_SYSTEM_NAME must be CrayLinuxEnvironment for FindMPI to recognise the Cray compiler wrappers.
- Remedy: -DCMAKE_SYSTEM_NAME=CrayLinuxEnvironment. Note this also implies cross-compiling, which skips MPI_DETERMINE_LIBRARY_VERSION -- projects that test the resulting variable then abort, and need it defined manually.
- Further: Two failures from one cause, the second appearing only after the first is fixed.

**tmp-is-ram-not-disk**
- Symptom: `df -h /tmp` on a compute node reports ~252 G available, so it reads as a generous node-local scratch disk. A job that writes tens or hundreds of GB there dies out of memory, and the failure points at the application rather than at the write.
- Cause: /tmp, /dev/shm and /rootfs.rw are all tmpfs on Frontier compute nodes -- they are RAM. Every byte written counts against the node memory the job is using. The 252 G figure is a tmpfs size limit, not free storage. /var/tmp and /mnt/bb are overlay, and /mnt/bb is NOT writable by default despite every node advertising the `nvme` Slurm feature, VERIFIED 2026-08-18: `-C nvme` mounts /dev/mapper/nvme-bb, an xfs filesystem of 3.4 TB, at /mnt/bb/$USER and it is writable. Without that constraint the device is present but unmounted, so df shows only the tmpfs and a user reading df gets the wrong answer twice: /tmp looks like local disk and is RAM, while 3.4 TB of real local disk is invisible.
- Remedy: Write bulk output to $MEMBERWORK or $PROJWORK (Lustre), or request node-local NVMe with `#SBATCH -C nvme` and use /mnt/bb/$USER. Use /tmp only for small transient files and count them against the memory budget.
- Further: Observed on frontier06028, 2026-08-18. $HOME is NFS and not Lustre either (lfs exits 25 there), so neither of the two paths a user reaches for by habit is the right one for bulk I/O.

**hugepages-incompatible-with-prgenv-amd**
- Symptom: A build that works under PrgEnv-gnu fails to LINK under PrgEnv-amd with "ld.lld: error: -Ttext-segment is not supported. Use --image-base if you intend to set the base address". Nothing in the message mentions huge pages.
- Cause: craype-hugepages<N> injects -Wl,-Ttext-segment=0x20000000 into the link line (visible as PE_HUGEPAGES_TEXT_SEGMENT in the wrapper's pkg-config call). -Ttext-segment is a GNU ld option, and PrgEnv-amd links with lld, which rejects it. THE CONFLICT IS WITH THE LINKER, NOT WITH THE COMPILER: any toolchain that links with GNU ld accepts the flag, including PrgEnv-amd once its linker is swapped.
- Remedy: Three routes, all verified 2026-08-27 across a four-cell build matrix: (1) PrgEnv-gnu with craype-hugepages2M loaded -- builds; (2) PrgEnv-amd with -fuse-ld=bfd, keeping the AMD compiler and swapping only the linker -- builds; (3) drop the hugepages module -- builds, and gives up the pages. Only PrgEnv-amd with its default lld fails. Note that linking is not provisioning: a binary that links does not prove 2 MB pages were obtained at runtime, which still needs the smaps check under mem.page_backing.
- Further: Observed 2026-08-19 on a C/OpenMP proxy application. Both choices are individually reasonable -- AMD compiler for AMD hardware, huge pages for a TLB-bound kernel -- and only the COMBINATION fails. The error names neither module, so it reads as a source or toolchain problem rather than a module conflict.

## Unverified — do not rely on these

### gpu.numa_affinity — unfalsifiable_here

Drives --gpu-bind=closest and every host-buffer placement decision.

Declared but **not confirmed by measurement**:
- **map**:
  - **NUMA 0**: GCD 4, GCD 5
  - **NUMA 1**: GCD 2, GCD 3
  - **NUMA 2**: GCD 6, GCD 7
  - **NUMA 3**: GCD 0, GCD 1
- **corroboration**:
  - **sources**: rocm-smi --showtoponuma, hwloc (os=cardN -> NUMANode)
  - **note**: Both list eight devices, GPU[0]..GPU[7] / card0..card7, and agree on the mapping.


**Why it matters that this is open**: This is the claim --gpu-bind=closest depends on, and it is currently taken on faith from the same vendor whose CPU distance table is contradicted above.

### cost.contention_sensitivity — undeclared

Characterization on an idle node describes a machine nobody runs on. A real application is using its cores.

- **Confounded**: The load generator consumes cores as well as bandwidth. The GPU-direct path needs more host CPU, so core starvation swamped the effect under test. Recorded as confounded rather than reported as a number.

Side finding (confidence: medium): GPU-direct is markedly more sensitive to CPU contention than host transfers -- 75% degradation versus 50%.

### cpu.system_interference — untested

This is the question topology-driven binding tools (mpibind and friends) exist to answer: which resources should an application be kept off. A rank sharing a core with an interrupt handler pays jitter that no bandwidth or latency number predicts, and a domain hosting the NVMe controllers carries DMA traffic the others do not.

Declared but **not confirmed by measurement**:
- **device locality**:
  - **note**: Answered offline from declared/frontier-compute.hwloc.xml -- no machine time required.
  - **slingshot nics**: hsn0->NUMA3, hsn1->NUMA1, hsn2->NUMA0, hsn3->NUMA2 -- exactly one per domain, symmetric
  - **asymmetry**: ens2 (management ethernet), nvme0n1, nvme1n1 and dma0chan0 ALL sit on NUMA 0
  - **implication**: NUMA 0 carries three devices no other domain has. More interrupt handling and more DMA through one domain's memory controller. A job that is I/O heavy drives that traffic through NUMA 0 specifically.
- **not yet captured**: Slurm CoreSpecCount / CpuSpecList -- would be a SECOND declared source for the 8 reserved cores, which currently rests on hwloc alone, isolcpus / nohz_full / rcu_nocbs from /proc/cmdline, /proc/irq/*/smp_affinity_list -- configured IRQ placement, system.slice cpuset -- where system services may run


## Measured, no declared source

Established by measurement and reported by nothing on the machine. These are results, not leads -- distinct from the section below.

**gpu.die_parity** — Host-memory latency splits by GCD die parity. Even dies (0,2,4,6) mean 1382 ns; odd dies (1,3,5,7) mean 1224 ns. The slowest odd die beats the fastest even one in every pass.

- **per pass**:
  - pass 1, even 1388.6, odd 1223.2, gap 165.4, slowest odd to fastest even 144
  - pass 2, even 1391.9, odd 1224.7, gap 167.2, slowest odd to fastest even 112.2
  - pass 3, even 1365.9, odd 1224, gap 141.9, slowest odd to fastest even 91.5
- **conditions**:
  - **host memory**: explicitly bound per NUMA domain, verified with move_pages
  - **buffer**: 512 MiB
  - **passes**: 3

- **Why this is now a result**: July flagged this and declined to claim it for one specific reason: host memory used default hipHostMalloc placement, so the NUMA domain was uncontrolled and the absolute numbers were 'to some host domain'. That caveat is gone -- every allocation is now bound and verified. And the separation holds in all three passes tested INDEPENDENTLY, which pooling would not have established: pooling lets one lucky pass carry a result.
- **Further structure**: Even dies are also NUMA-sensitive (across-domain range 88-175 ns) while odd dies are nearly flat (27-55 ns), and even dies are far noisier pass-to-pass (129-155 ns vs 29-43 ns).
- **Consequence**: Host-memory-bound kernels should prefer odd GCDs; peer-heavy kernels the even ones. Nothing in ROCm's placement logic knows this, and no declared source reports it.
- **Remaining caveat**: One node type, one node. Not established machine-wide.
- **Confidence**: medium

## Leads — observed, deliberately not asserted

Each of these looks like structure and sits at or inside the noise band of its measurement. They are recorded so they are not lost. **They are not results.** Do not build advice on them, and do not repeat them as findings.

**gpu.hbm_pairing** — Per-GCD HBM latency spans 365-397 ns, and pairs (0,3), (1,4), (2,5) match within 0.3 ns.

- **Why not asserted**: That LOOKS like structure and sits inside the 37.6 ns noise band. Explicitly not claimed.

## Limits of this briefing

Questions this document cannot answer. If asked one, say so.

- Do the NUMA tiers hold across nodes? Single-node result; needs 8-16 short jobs.
- Can measured distances be injected back via hwloc_distances_add, so existing consumers (MPI, Slurm, mpibind, ZeroSum) pick up corrected values with no code change? Unverified against the hwloc version on Frontier -- and if it works it is the strongest deployment path in the project.
- Is the SLIT-vs-measured discrepancy already known to OLCF, or a known firmware simplification?
- Read/write mix for loaded latency -- currently read-only.
- Does the uniform node-0 host preference follow the probe's main thread? Re-run pinned to a different domain. If it does, it is our artifact; if not, it is a machine property with no declared source.
- Does gpu.numa_affinity become measurable with more passes or a different probe? The effect, if any, is below 8% GPU-latency variance.
- Does die parity hold across nodes? Currently one node.

Generated from `frontier-compute.json` (schema 0.1, registry 0.1) by render.py. Values are measurements with stated conditions, not specifications.
