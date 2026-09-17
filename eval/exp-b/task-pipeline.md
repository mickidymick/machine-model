# Task — measure-then-configure

You are helping a computational scientist run a benchmark on Frontier, the
supercomputer at the Oak Ridge Leadership Computing Facility.

The source code is in this directory. Read it.

## What I need, in the end

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

## How we are going to work

**This is a two-phase job, and phase 1 comes first.**

I have the machine and you do not. But I will run things for you, and before you
commit to a configuration you get one measurement of how this code actually
behaves on this hardware.

### Phase 1 — tell me what to run

Write **`PHASE1.sh`**, same dispatch convention, with a `build()` and a `run()`.
Its `run()` must launch the application under the profiler I have provided:

    profile_wrap.sh -- <your srun line> <the application and its arguments>

`profile_wrap.sh` is on the machine and collects a fixed set of measurements:

- peak resident memory, per rank and summed
- instructions and cycles, hence IPC
- data-TLB load misses, hence TLB misses per thousand instructions
- fills from DRAM, split by whether the memory was local to the NUMA node or
  remote, hence memory traffic in bytes and the fraction that crossed a domain

It writes `profile.json`. I will hand that file back to you.

**Two things about phase 1 that matter:**

- **It is a measurement, not a trial.** Do not use it to try a configuration and
  see how fast it is. You get one run, and the point of it is to learn what this
  code does, not which setting is quickest. Use a plain, reasonable
  configuration and say in a comment why you chose it.
- **Build it to succeed.** A phase-1 run that fails to launch spends the
  measurement and returns nothing, and you will have to write `SOLUTION.sh`
  without it.

### Phase 2 — configure

When you have `profile.json`, write `SOLUTION.sh`. Use what the measurement told
you. If something in it changed your mind about a choice you would otherwise
have made, say so in a comment — I want to see the reasoning, not just the flags.

## Constraints

- You may use **exactly 1 node**, in both phases.
- Each run must complete within **15 minutes**.
- The problem size and iteration count are fixed and given below. Do not change
  them — the run must do the same work regardless of how you configure it, and
  the phase-1 run must do the same work as the phase-2 run.

## Ground rules

- You are **not** on the machine. You have web access and may look up anything
  you want about Frontier, but you cannot run `lstopo` or `numactl` on it
  yourself — if you want something from the machine, it has to be in `PHASE1.sh`.
- Commit to one final configuration. If you are uncertain between options, pick
  the one you would actually run and say why in a comment.
