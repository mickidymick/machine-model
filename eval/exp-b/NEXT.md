# Where to pick this up

Nothing here has been run. In order:

1. **`./setup.sh /path/to/amg /path/to/qmcpack`** — builds the arm directories.
   Then `diff -rq arms/no-artifact/amg arms/with-artifact/amg` and confirm the
   ONLY difference is `MACHINE.md`. If anything else differs, it is a confound.

2. **Generate the two solutions.** In each arm directory, a fresh session, same
   model and effort (Opus 4.8 / High, matching Experiment A). Point it at
   `TASK.md`. It writes `SOLUTION.sh`; copy that to `configs/<bench>/<arm>.sh`.

3. **`BENCH=amg ./build_all.sh`** on a login node. Builds are excluded from the
   timing but not from the experiment — check whether the with-artifact build
   loaded `craype-hugepages2M`, because that is the predicted mechanism.

4. **`BENCH=amg PASSES=3 sbatch -A CSC617 run_interleaved.sbatch`**

5. **`python3 collect.py results/amg_<stamp>.csv`**

6. Repeat 3–5 with `BENCH=qmcpack`.

Read `PREREGISTRATION.md` before looking at any result. The predictions are
recorded so that reading them afterwards is not a prediction.

## Open questions this harness does not settle

- Does the no-artifact arm allocate more than one node? Predicted no.
- Does either arm set `--threads-per-core`? **We have no measurement on SMT** —
  every arm in Experiment A guessed at it from general knowledge, and the ceiling
  config flags its own choice as unmeasured. This is the biggest unmeasured knob
  in the project and a good candidate for the next allocation.
- AMG's iteration count must be fixed rather than solved to a tolerance, or
  convergence differences change the work and wall clock stops being comparable.
  Verify this in the source before trusting a single number.
