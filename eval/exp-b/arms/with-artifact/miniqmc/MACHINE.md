# Machine briefing: Frontier (compute node)

OLCF (Oak Ridge National Laboratory). Characterized 2026-07-19, extended 2026-08-10.

- **CPU**: 1x AMD EPYC 7A53, 64 cores, 2 HWT/core, NPS4
- **Memory**: 512 GB DDR4
- **Accelerator**: 4x AMD MI250X (8 GCDs)
- **Network**: Slingshot-11, 4x NIC per node

## How to use this document

This is a **measured** description of one node type, not a spec sheet. Where the machine's own topology interfaces (hwloc, ACPI tables, vendor query tools) disagree with measurement, the measured value is given first and the declared value is shown alongside it, because other tools on this system are still acting on the declared one.

Rules for reasoning with what follows:

1. **Do not upgrade a hedge.** Items under *Unverified* and *Leads* are not established. Do not present them as facts, and do not build a recommendation whose correctness depends on them.
2. **Conditions are part of every number.** A latency measured on 4K pages, or a bandwidth measured across one of four network links, does not generalise to other conditions. The conditions are stated; carry them.
3. **Regime-dependent costs are not scalars.** Several costs here change sign or magnitude with working-set size, offered load, or message size. Answer with the regime, not an average.
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

**Measured**:
- **unit**:
  - **latency**: ns
  - **bandwidth**: MB/s
- **conditions**:
  - **pages**: 4K
  - **threads**: 1
  - **access**: random
  - **n**: 3
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

**Measured**:
- **conditions**:
  - **ranks per node**: 1
  - **nics crossed**: 1
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
- **conditions**:
  - **n**: 5
  - **access**: random peer chase
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

- **unit**: ns
- **regime variable**: working set size
- **regimes**:
  - extent <=256 KB, huge same, 4K same, delta 0, reason TLB covers the working set
  - extent 512 KB, huge 3.6, 4K 5.4, delta 1.8
  - extent 1-8 MB, huge 10.9-13, 4K 12-15, delta ~2
  - extent 16 MB, huge 13.1, 4K 17.5, delta 4.4
  - extent 32 MB, huge 13.3, 4K 32.2, delta 18.9, ratio 2.4x, reason PEAK. Working set still fits in L3 (32 MB per L3 region) but needs 8192 PTEs at 4K, far past TLB reach. Every access pays a page walk that itself goes to memory.
  - extent 64 MB - 1 GB, huge 58-89, 4K 67-103, delta 9-14, reason Both effects saturated; settles to a roughly constant offset

**Shape**: Zero, then 2.4x, then a constant offset. There is no single number that describes this.

**Consequence**: TLB misses reported as memory latency. The worst case is at a working set that still fits in cache, which is exactly where a developer would not look for it.

**Note**: Latency effect only. Streaming bandwidth barely notices page size -- 107,765 huge vs 107,342 4K on corsys4 -- because sequential reads amortise the walk across a whole page.

### cost.loaded_latency_knee

Peak bandwidth and usable bandwidth are different operating points, often far apart. The knee, not the peak, is where a real application should sit.

- **conditions**:
  - **threads**: 1 latency + 27 bandwidth
  - **traffic**: read-only
  - **domain**: 0
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

**Not measured**: Read/write mix. This probe sweeps read-only traffic; MLC sweeps ratios. Write traffic saturates differently.

### cost.host_device_transfer

Whether device-resident buffers beat host-staged ones changes sign with message size. A single-size measurement gives the wrong universal answer.

- **regime variable**: message size
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
