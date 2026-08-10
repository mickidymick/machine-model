# Experiment B — does a configuration derived from the artifact run faster?

Experiment A asked whether a model *knows* more with the artifact. This asks
whether that knowledge changes a configuration, and whether the changed
configuration is faster.

## Design

An agent in a clean directory containing the benchmark source, a task, and fixed
constraints. It reads the code, inspects the machine if it wants, and writes a
`SOLUTION.sh` with `build()` and `run()`. We execute it and time `run()`.

Two arms, identical in every respect except one file:

| arm | directory contents |
| --- | --- |
| `no-artifact` | source + TASK.md + PROBLEM.md |
| `with-artifact` | the same, **plus `MACHINE.md`** (the measured briefing) |

Both arms may inspect the machine and search the web. Withholding that would
build a strawman: the 2026-08-10 knowledge eval showed the entire *declared*
topology is available from the OLCF User Guide, and an arm told only the
machine's name scored identically to one handed a curated topology document.

Plus two references that are not arms:

- **floor** — the naive default. Gives the arms a scale.
- **ceiling** — hand-tuned with everything this project has measured. Shows how
  much headroom exists at all.

The reported number is *what fraction of floor-to-ceiling headroom each arm
recovered*, because a bare percentage between two arms cannot be interpreted.

## Why this shape

It tests the artifact **in its delivery form** — a file in the working directory
next to the source, which is how we argued it should reach a user. And the agent
reads the source, so it supplies the application half itself; that was the whole
argument for a language model being the primary consumer rather than an
incidental one.

## Why two benchmarks

**AMG** (CPU, sparse, memory-bound, irregular access) presses the claims we
actually measured: page size, NUMA placement, the reserved cores.
**QMCPACK** (GPU offload) has a larger configuration surface but its big facts
are public. Running both is expected to produce *different* answers — see
`PREREGISTRATION.md`.

## Running it

```sh
./setup.sh /path/to/amg /path/to/qmcpack     # build the arm directories
diff -rq arms/no-artifact/amg arms/with-artifact/amg   # must differ ONLY by MACHINE.md

# in each arm directory, with the same model and effort, a fresh session each:
#   claude   (then paste/point at TASK.md)
# it writes SOLUTION.sh; copy that to configs/<bench>/<arm>.sh

BENCH=amg ./build_all.sh                      # login node; builds are not timed
BENCH=amg PASSES=3 sbatch -A CSC617 run_interleaved.sbatch
python3 collect.py results/amg_<stamp>.csv
```

## Two things the harness enforces

**Interleaving.** Every config runs once per pass in rotating order. Blocked runs
let drift across an allocation masquerade as a config difference — the July
inter-node result survived scrutiny only because its passes were interleaved.

**Verification before belief.** Each timed run records the cores it was given,
the huge-page size in effect, and the visible GPUs. A config that silently failed
to get its resources produces a plausible number that means nothing, and
`collect.py` refuses to average in a non-zero exit.
