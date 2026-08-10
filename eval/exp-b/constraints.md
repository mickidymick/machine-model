# Why these constraints

**"At most 4 nodes" and a 60 node-minute budget** exist to make this an
optimization rather than a trivia question. Both benchmarks fit comfortably on
one node at the sizes used, so the node limit is partly a distractor: a good
answer resolves it correctly (use one node, spend the budget on repeats or a
larger rank count) rather than reflexively using the maximum.

**Fixed problem size and iteration count** make wall clock a valid metric. If the
work can vary with the configuration, a faster run may simply be doing less --
which is why the earlier QMCPACK comparison had to use error bars instead of
seconds. Fixing the work removes that ambiguity.

**Produce-and-stop** keeps this a test of the artifact rather than of agentic
iteration. An agent allowed to run, measure and tune would likely converge on a
good configuration regardless of what it knew going in; that is a different and
also interesting experiment, but it would not isolate what we are measuring.

**`SOLUTION.sh` with build() and run()** rather than a bare srun line, because
the single largest measured effect on this machine -- the 2.4x page-size penalty
at a 32 MiB working set -- is decided at BUILD time. `craype-hugepages2M` works
by relinking the binary, not via a runtime flag. A deliverable that captured only
the srun line could not express it.
