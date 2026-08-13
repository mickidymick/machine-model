#!/bin/bash
#SBATCH -J exp-b
#SBATCH -N 4
#SBATCH -t 00:45:00
#
# 45 minutes, not 2 hours. 5 configs x 10 passes x ~34 s measured = ~28 min, and
# Slurm backfills a short job into gaps a long one cannot fit. Asking for 2 h on
# the smallest node bin pushed the estimated start out by five hours for a job
# that runs in half an hour. Raise this if PASSES or the config count grows.
#SBATCH -p batch
#
# -o/-e are relative to the SUBMIT directory (~/machine-model) and Slurm
# resolves them BEFORE the script runs, so a mkdir inside the script cannot
# create them in time. Submit from the repo root.
#SBATCH -o eval/exp-b/results/expb_%j.out
#SBATCH -e eval/exp-b/results/expb_%j.err
#
# Experiment B: do configurations derived WITH the artifact run faster than
# configurations derived WITHOUT it?
#
#   BENCH=amg PASSES=10 sbatch -A CSC617 eval/exp-b/run_interleaved.sbatch
#
# TEN passes, following ZeroSum (Huck & Malony, SC-W 2023 sec 4.1), which ran
# each condition 10x IN THE SAME ALLOCATION and reported a t-test rather than a
# ratio of single runs. Their run-to-run std was 0.13% of runtime, tight enough
# to resolve a 0.5% effect. n=3 cannot resolve anything of the size we now
# expect: after round 1 showed BOTH arms relinking for huge pages, the remaining
# artifact-only levers are placement-sized, not 2.4x-sized.
#
# Builds happen once, on the login node, BEFORE this job -- see build_all.sh.
# Only run() is timed.
#
# INTERLEAVED, not blocked. Every config runs once per pass, in rotating order.
# Blocked runs let drift across an allocation masquerade as a config difference,
# which is the artifact that nearly sank the July inter-node comparison; that
# result only stood because its passes were interleaved.
set -u
cd "$SLURM_SUBMIT_DIR" || exit 1

BENCH=${BENCH:-miniqmc}
PASSES=${PASSES:-10}
D=eval/exp-b
OUT=$D/results
mkdir -p "$OUT"
STAMP=$(date +%Y%m%d_%H%M%S)
D=$(cd "$D" && pwd)          # absolute -- configs are exec'd after a cd
ABSOUT=$(cd "$OUT" && pwd)   # so relative paths would escape

# SNAPSHOT the configs and the parser at job start, and use only the snapshot.
# Both are read on EVERY pass, so a `git pull` while this job is running would
# otherwise leave early passes and late passes executing different code, averaged
# into a single mean with nothing in the CSV to show it. The batch script itself
# is already immune -- Slurm spools a copy at submission.
SNAP="$ABSOUT/snapshot_${BENCH}_${STAMP}"
mkdir -p "$SNAP"
cp -r "$D/configs/$BENCH" "$SNAP/configs"
cp "$D/parse_run.sh" "$SNAP/parse_run.sh"
chmod +x "$SNAP/parse_run.sh"
echo "configs snapshotted to $SNAP -- a git pull during this run cannot affect it"

CONFIGS=()
for c in "$SNAP/configs"/*.sh; do CONFIGS+=("$c"); done
[ ${#CONFIGS[@]} -gt 0 ] || { echo "no configs in $D/configs/$BENCH" >&2; exit 1; }

echo "=== exp-b: $BENCH, ${#CONFIGS[@]} configs, $PASSES passes, job $SLURM_JOB_ID ==="
printf '  %s\n' "${CONFIGS[@]}"

CSV="$OUT/${BENCH}_${STAMP}.csv"
echo "pass,config,seconds,solve_s,fom,work,ranks,threads,exit" > "$CSV"

for p in $(seq 1 "$PASSES"); do
  # Rotate the order every pass. Fixed order would give the first config the
  # same thermal and cache state every time.
  n=${#CONFIGS[@]}
  for i in $(seq 0 $((n-1))); do
    idx=$(( (i + p - 1) % n ))
    cfg=${CONFIGS[$idx]}
    name=$(basename "$cfg" .sh)
    echo; echo "--- pass $p : $name ---"

    tree="$D/arms/$name/$BENCH"
    if [ ! -d "$tree" ]; then
      echo "    $name: NO TREE -- skipped"; continue
    fi
    # Same as build_all.sh: the config runs from inside its own tree, because
    # the arms resolve paths relative to the script's own location.
    cp "$cfg" "$tree/SOLUTION.sh"
    ( cd "$tree" || exit 1
      source /usr/share/lmod/lmod/init/bash 2>/dev/null || true
      # No separate machine probe. The previous one ran its own
      # `srun --overlap`, which got a fresh default allocation rather than the
      # config's binding, and read a system-wide Hugepagesize -- both columns
      # were constants across every config while looking like verification.
      # The application reports ranks, threads and walkers itself; that is the
      # only verification that actually distinguishes one config from another.
      t0=$(date +%s.%N)
      bash ./SOLUTION.sh run > "$ABSOUT/${BENCH}_${name}_p${p}_${STAMP}.log" 2>&1
      rc=$?
      t1=$(date +%s.%N)
      secs=$(echo "$t1 - $t0" | bc)

      # THE number is the application's own reported time, not this stopwatch.
      # ZeroSum reported "the application reported execution time" for the same
      # reason: the harness clock also contains module loads, srun launch
      # overhead and AMG's setup phase, and those are not what any config is
      # trying to improve. Worse, they are ASYMMETRIC -- only configs that load
      # craype-hugepages2M pay the module cost, and that penalty lands on
      # exactly the configs expected to be fastest.
      log="$ABSOUT/${BENCH}_${name}_p${p}_${STAMP}.log"
      parsed=$("$SNAP/parse_run.sh" "$BENCH" "$log")
      solve=$(echo "$parsed" | cut -d, -f1)
      fom=$(echo   "$parsed" | cut -d, -f2)
      work=$(echo  "$parsed" | cut -d, -f3)
      ranks=$(echo "$parsed" | cut -d, -f4)
      thr=$(echo   "$parsed" | cut -d, -f5)

      # A SOLUTION.sh that defines build()/run() but has no dispatcher exits 0
      # having done nothing. That is indistinguishable from a fast run unless we
      # check: exit 0 with no application timing is not a measurement.
      if [ "$rc" = "0" ] && [ "$solve" = "NA" ]; then
        echo "    !! $name exited 0 but reported no timing -- not a measurement."
        echo "       Most likely SOLUTION.sh has no 'build|run' dispatcher, or"
        echo "       the run died before printing. See $log"
        rc=99
      fi

      printf '%s,%s,%.2f,%s,%s,%s,%s,%s,%s\n' "$p" "$name" "$secs" "$solve" "$fom" "$work" "$ranks" "$thr" "$rc" >> "$CSV"
      printf '    %-14s wall %8.2f s   app %10s s   work=%s ranks=%s thr=%s   exit=%s\n' "$name" "$secs" "$solve" "$work" "$ranks" "$thr" "$rc"
    )
  done
done

echo; echo "=== raw results: $CSV ==="
echo "Analyse with:  python3 $D/collect.py $CSV"
echo
echo "Before believing any of it, check the verification columns: a config that"
echo "did not get its cores, GPUs or huge pages produced a plausible time that"
echo "means nothing."
