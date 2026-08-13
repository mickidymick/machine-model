#!/bin/bash
#SBATCH -J expb-size
#SBATCH -N 4
#SBATCH -t 00:20:00
#SBATCH -p batch
#SBATCH -o results/size_%j.out
#
# Run BEFORE the real job. Times ONE ceiling run to check the problem is sized
# so that n=10 is affordable.
#
#   BENCH=miniqmc sbatch -A CSC617 eval/exp-b/size_probe.sbatch
#
# ZeroSum's miniQMC runs were 27-64 s, which is why 10 repeats per condition
# were affordable and why their run-to-run sd came in at 0.13%. 4 configs x 10
# passes at 60 s is ~40 min plus launch overhead, inside the 2 h wall clock.
# At 180 s it is not.
set -u
cd "$SLURM_SUBMIT_DIR" || exit 1
BENCH=${BENCH:-miniqmc}
D=$(cd eval/exp-b && pwd)
mkdir -p "$D/results"
tree="$D/arms/ceiling/$BENCH"
log="$D/results/size_${BENCH}_${SLURM_JOB_ID}.log"

[ -d "$tree" ] || { echo "no tree at $tree"; exit 1; }
( cd "$tree" || exit 1
  source /usr/share/lmod/lmod/init/bash 2>/dev/null || true
  t0=$(date +%s.%N)
  bash "$D/configs/$BENCH/ceiling.sh" run > "$log" 2>&1
  rc=$?
  t1=$(date +%s.%N)
  echo "=== exit=$rc  wall=$(echo "$t1 - $t0" | bc) s ==="
)
echo
echo "--- parsed: solve_s,fom,work,ranks,threads ---"
"$D/parse_run.sh" "$BENCH" "$log"
echo
echo "CHECK THE WORK FIELD FIRST. For miniqmc it must be 224 (ranks x walkers)."
echo "A different number means the config does not match PROBLEM.md and every"
echo "timing built on it is uncomparable -- that is what voided round 1."
echo
echo "Then the application-reported time:"
echo "  30-90 s  -> good. Run the real job at PASSES=10."
echo "  > 90 s   -> reduce -n (steps) in PROBLEM.md and BOTH reference configs,"
echo "              then regenerate the arms. Do not change the walker total:"
echo "              that is what holds the work fixed across geometries."
echo "  < 15 s   -> too short; launch overhead will dominate the variance and"
echo "              the t-test will be measuring Slurm."
echo
echo "Full log: $log"
