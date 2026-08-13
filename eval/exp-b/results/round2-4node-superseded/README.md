# Round 2 at 4 nodes -- superseded before timing, kept for the reasoning

Never run. The arms were regenerated at 1 node instead.

miniQMC calls MPI only for `MPI_Init`/`Comm_rank`/`Comm_size` -- there is not a
single communication call inside the timed region, and the reported `Total` is
one rank's wall clock. Every node is loaded identically and independently, so
three of the four nodes did work that never touched the measured number while
adding queue wait, allocation cost and node-to-node variability. The 4-node
limit was inherited from the AMG task design and never re-examined against this
benchmark's communication structure.

**Both arms established this themselves** and declined to use the network;
with-artifact explicitly dismissed the whole Slingshot section of the briefing
as irrelevant to this code. That reasoning is why these files are kept.

At 1 node the total walker count becomes 56 (one per allocatable core) and both
arms' preferred geometries survive: 8 ranks x 7 walkers on L3 boundaries, and
4 ranks x 14 on NUMA domains. The floor also becomes almost exactly ZeroSum's
own published baseline -- 8 ranks, 7 OpenMP threads, one node, no `-c`.
