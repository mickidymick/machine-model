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

*Reported by: vendor node diagram*

- **value**: 64
- **unit**: cores

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

**huge-pages-fail-silently** — Latency numbers plausible but ~16 ns high; no error anywhere. THP is [never] and the hugetlb pool is empty (Total 4, Free 0). Both normal paths fail silently. Load craype-hugepages2M -- it works by relinking, not a runtime flag. Then verify via smaps; do not trust the madvise return.

**core-count-ceiling** — `srun -c 64` is rejected. One core per L3 group is OS-reserved: 0, 8, 16, 24, 32, 40, 48, 56. `-c 56` is the ceiling. It also divides cleanly: 14 cores / 28 threads per NUMA domain.

**login-nodes-not-representative** — Topology conclusions drawn on a login node do not hold on compute. login08 is EPYC 7763 + a single MI210; compute is 7A53 + 4x MI250X. Both are gfx90a so builds carry over, but no topology measurement from a login node is valid. Run 00_topo.sh inside an allocation.

**one-rank-one-nic** — Inter-node bandwidth reads as ~24 GB/s against a 100 GB/s node spec. One rank per node crosses one of four NICs. osu_mbw_mr with 4 concurrent pairs and MPICH_OFI_NIC_POLICY=NUMA. Never quote a single-pair number as per-node.

**osu-upc-build** — OSU 7.4 fails to build against the Cray toolchain. c/upc is unconditionally in the top-level SUBDIRS and there is no configure flag to disable it; the Cray compiler has no UPC front end. Build only c/mpi.

**qmcpack-build-script** — The shipped Frontier build script fails or takes 4-8 hours. config/build_olcf_frontier_ROCm.sh hardcodes BOOST_ROOT to /ccs/proj/mat151 (inaccessible outside that project) and builds all eight variants. Use the boost/1.86.0 module and build only gpu_real -- about 15 minutes.

---

Compiled from the declared topology of `frontier-compute.json`. No performance measurements were taken; all values are as reported by the system and its documentation.
