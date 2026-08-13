# Task given to every arm

You are helping a computational scientist run a benchmark on Frontier, the
supercomputer at the Oak Ridge Leadership Computing Facility.

The source code is in this directory. Read it.

## What I need

Configure this code to run **as fast as possible** on Frontier, within the
constraints below, and give me:

1. **A build recipe** — every module load and configure/make command, in order.
2. **A single run command** — the complete `srun` line plus any environment
   variables it needs.

Write both into `SOLUTION.sh` in this directory, as a runnable script with a
`build()` function and a `run()` function. I will execute it as-is.

`SOLUTION.sh` **must dispatch on its first argument**: `bash SOLUTION.sh build`
runs the build, `bash SOLUTION.sh run` runs the benchmark. I invoke it exactly
that way — a script that only defines the functions would exit having done
nothing.

## Constraints

- You may use **at most 4 nodes**.
- Your allocation budget for this run is **60 node-minutes**.
- The problem size and iteration count are fixed and given below. Do not change
  them — the run must do the same work regardless of how you configure it.

## Ground rules

- **Do not run the benchmark.** Produce the recipe and stop. I will run it.
- You are **not** on the machine. You have web access and may look up anything
  you want about Frontier, but you cannot run `lstopo` or `numactl` on it.
- Commit to one configuration. If you are uncertain between options, pick the
  one you would actually run and say why in a comment.
