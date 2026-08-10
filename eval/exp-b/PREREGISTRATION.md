# Predictions, written before the first run

Recorded 2026-08-10, before any Experiment B configuration was generated or run.
The point is that a prediction made after seeing the data is not a prediction.

## Primary

**CPU / AMG: the artifact arm wins, possibly by a lot.**

Mechanism: `cost.page_size_penalty` is 2.4x at a ~32 MiB working set with
irregular access (13.3 ns on 2 MB pages vs 32.2 ns on 4K), and on this machine
2 MB pages require `craype-hugepages2M`, which works by **relinking**. THP is
`[never]` and the hugetlb pool is empty, so nothing else gets you there.

In the 2026-08-10 knowledge eval the no-artifact arms got the *general* answer
("madvise success does not prove huge pages, check smaps") but missed all three
Frontier specifics. If that holds, the no-artifact arm never relinks and pays the
penalty on a sparse solver.

**GPU / QMCPACK: plausibly a null.**

The large GPU-side facts -- 8 schedulable GCDs rather than 4 packages, `-c 56`
rather than 64 -- were found by *every* arm in the knowledge eval, including the
web arm, from the OLCF User Guide. What remains that only the artifact knows is
`gpu.die_parity`: 158 ns on host-memory latency, in a GPU-offloaded code where
host memory is a small share of runtime. It may not surface at all.

## Secondary

- Neither arm uses more than one node. The 4-node limit is partly a distractor;
  both benchmarks fit on one node at these sizes. An arm that allocates 4 nodes
  has mistaken the ceiling for a target.
- The no-artifact arm gets `-c 56` right. It is in the OLCF guide via Slurm's
  `-S 8` core specialization, and the web arm found it unprompted.
- The artifact arm's advantage on AMG is dominated by huge pages, not by NUMA
  placement. Both arms should bind ranks to domains; only one relinks.
- Any die-parity effect on QMCPACK is under 3%.

## What would falsify the project's claim

- The no-artifact arm relinks for huge pages anyway (from general Cray knowledge
  rather than from measurement). Then the artifact's largest CPU-side
  contribution is already public and the gap should close.
- The gap on both benchmarks sits inside the run-to-run spread. `collect.py`
  reports NULL rather than a small win when it does; that guard is deliberate.
- The ceiling is not faster than the floor -- the tuning does not matter on these
  codes at these sizes, and the experiment cannot discriminate anything.

## What a null on GPU would mean

Not a failure. It would say the artifact's value is **concentrated where the
public record is silent**, and on the GPU side much of it is not. That is more
useful than a uniform win: it says where to point the next machine's
characterization, and it is a claim we can defend.
