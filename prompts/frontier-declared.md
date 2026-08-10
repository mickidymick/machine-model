# Frontier (compute node) — system documentation

OLCF (Oak Ridge National Laboratory).

- **CPU**: 1x AMD EPYC 7A53, 64 cores, 2 HWT/core, NPS4
- **Memory**: 512 GB DDR4
- **Accelerator**: 4x AMD MI250X (8 GCDs)
- **Network**: Slingshot-11, 4x NIC per node

The following is what the system reports about itself through its standard interfaces — the ACPI tables, `hwloc`, `numactl`, vendor query tools and the facility documentation. This is the information available to any user on the machine.

## Processor

### Number, size and sharing scope of cache levels

*Reported by: Zen3 specification*

- **levels**: L1 32 KB, L2 512 KB, L3 32 MB per CCD

### How many cores/hardware threads the job may actually use, versus how many the node physically has

*Reported by: hwloc (correct) vs vendor node diagram (misleading)*

- **hwloc allowed PUs**: 112
- **hwloc topology PUs**: 128
- **hwloc reserved PU logical indices**: 112-127
- **hwloc implication**: 56 usable cores of 64 present. hwloc reports the reservation correctly.
- **vendor diagram**: 64 cores

Measured on frontier00126 2026-08-10 via hwloc 2.11.2. The declared sources DISAGREE WITH EACH OTHER: hwloc is right and the diagram is wrong. A user who runs lstopo gets the correct answer; a user who reads the node diagram does not.

### Which cores and NUMA domains the system reserves for its own work, and where device interrupts land

*Reported by: hwloc device locality (captured); Slurm CoreSpecCount, /proc/cmdline, /proc/irq/*/smp_affinity_list, system.slice cpuset (NOT yet captured)*

- **device locality**:
  - **note**: Answered offline from declared/frontier-compute.hwloc.xml -- no machine time required.
  - **slingshot nics**: hsn0->NUMA3, hsn1->NUMA1, hsn2->NUMA0, hsn3->NUMA2 -- exactly one per domain, symmetric
  - **asymmetry**: ens2 (management ethernet), nvme0n1, nvme1n1 and dma0chan0 ALL sit on NUMA 0
  - **implication**: NUMA 0 carries three devices no other domain has. More interrupt handling and more DMA through one domain's memory controller. A job that is I/O heavy drives that traffic through NUMA 0 specifically.
- **not yet captured**: Slurm CoreSpecCount / CpuSpecList -- would be a SECOND declared source for the 8 reserved cores, which currently rests on hwloc alone, isolcpus / nohz_full / rcu_nocbs from /proc/cmdline, /proc/irq/*/smp_affinity_list -- configured IRQ placement, system.slice cpuset -- where system services may run

## Memory topology

### Number of NUMA domains and which cores and memory belong to each

*Reported by: hwloc / numactl -H*

- **value**: 4
- **config**: NPS4

### Relative cost of crossing between NUMA domains

*Reported by: ACPI SLIT via numactl -H, relayed by hwloc_distances_get*

- **matrix**:
  - [10, 12, 12, 12]
  - [12, 10, 12, 12]
  - [12, 12, 10, 12]
  - [12, 12, 12, 10]

All four domains mutually equidistant; every remote hop costs 1.2x local.

### Implicitly, that crossing cost is symmetric -- a single scalar per pair

*Reported by: hwloc distance matrix shape*

One scalar per pair; direction not representable.

## Accelerators

### How many accelerator devices exist and how they are indexed

*Reported by: node diagram*

- **value**: 4x MI250X

### Which NUMA domain each accelerator is physically attached to

*Reported by: rocm-smi --showtoponuma*

- **map**:
  - **NUMA 0**: GCD 4, GCD 5
  - **NUMA 1**: GCD 2, GCD 3
  - **NUMA 2**: GCD 6, GCD 7
  - **NUMA 3**: GCD 0, GCD 1
- **corroboration**:
  - **sources**: rocm-smi --showtoponuma, hwloc (os=cardN -> NUMANode)
  - **note**: Both list eight devices, GPU[0]..GPU[7] / card0..card7, and agree on the mapping.

### Relative cost of device-to-device links

*Reported by: rocm-smi XGMI link weights*

- **classes**: 15, 30, 45

### Device cache levels and memory sizes

*Reported by: MI250X specification / rocminfo*

## Memory configuration

### That a large-page request was honoured

*Reported by: THP sysfs + hugetlb pool + madvise return*

A large-page request appears to succeed.

## Network

### How many network interfaces the node has and how a job maps onto them

*Reported by: facility spec sheet*

- **value**: 100
- **unit**: GB/s injection per node
- **nics**: 4
- **interfaces**: hsn0, hsn1, hsn2, hsn3

## Known operational notes

_Published by the facility or readable from the machine with standard tools._

**huge-pages-fail-silently** — Latency measurements come out high with no error anywhere. THP is [never] and the hugetlb pool is empty (Total 4, Free 0). Both normal paths fail silently. Load craype-hugepages2M -- it works by relinking, not a runtime flag. Then verify via smaps; do not trust the madvise return.

**core-count-ceiling** — `srun -c 64` is rejected. One core per L3 group is OS-reserved: 0, 8, 16, 24, 32, 40, 48, 56. `-c 56` is the ceiling. It also divides cleanly: 14 cores / 28 threads per NUMA domain.

**login-nodes-not-representative** — Topology conclusions drawn on a login node do not hold on compute. login08 is EPYC 7763 + a single MI210; compute is 7A53 + 4x MI250X. Both are gfx90a so builds carry over, but no topology measurement from a login node is valid. Run 00_topo.sh inside an allocation.

**one-rank-one-nic** — Inter-node bandwidth from one rank per node reads far below the node spec. One rank per node crosses one of four Slingshot NICs. Spread ranks across the four NUMA domains -- `-c 14` gives one rank per domain.

_2 further operational note(s) exist in the descriptor but were discovered by measurement and are withheld from this rendering._

---

Compiled from the declared topology of `frontier-compute.json`. No performance measurements were taken; all values are as reported by the system and its documentation.
