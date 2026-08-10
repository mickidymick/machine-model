#!/bin/bash
#SBATCH -J exp-b
#SBATCH -N 4
#SBATCH -t 01:30:00
#SBATCH -p batch
#SBATCH -o results/expb_%j.out
#SBATCH -e results/expb_%j.err
#
# Experiment B: do configurations derived WITH the artifact run faster than
# configurations derived WITHOUT it?
#
#   BENCH=amg PASSES=3 sbatch -A CSC617 eval/exp-b/run_interleaved.sbatch
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

BENCH=${BENCH:-amg}
PASSES=${PASSES:-3}
D=eval/exp-b
OUT=$D/results
mkdir -p "$OUT"
STAMP=$(date +%Y%m%d_%H%M%S)

CONFIGS=()
for c in "$D/configs/$BENCH"/*.sh; do CONFIGS+=("$c"); done
[ ${#CONFIGS[@]} -gt 0 ] || { echo "no configs in $D/configs/$BENCH" >&2; exit 1; }

echo "=== exp-b: $BENCH, ${#CONFIGS[@]} configs, $PASSES passes, job $SLURM_JOB_ID ==="
printf '  %s\n' "${CONFIGS[@]}"

CSV="$OUT/${BENCH}_${STAMP}.csv"
echo "pass,config,seconds,exit,cpus_allowed,hugepages_kb,visible_gpus" > "$CSV"

for p in $(seq 1 "$PASSES"); do
  # Rotate the order every pass. Fixed order would give the first config the
  # same thermal and cache state every time.
  n=${#CONFIGS[@]}
  for i in $(seq 0 $((n-1))); do
    idx=$(( (i + p - 1) % n ))
    cfg=${CONFIGS[$idx]}
    name=$(basename "$cfg" .sh)
    echo; echo "--- pass $p : $name ---"

    ( set +u; source "$cfg"
      # Verify the manipulation BEFORE trusting the number. A config that
      # silently failed to get its cores, its GPUs or its huge pages produces a
      # plausible time that means nothing.
      probe=$(srun -N1 -n1 --overlap bash -c \
        'echo "$(grep -c . /dev/null)$(grep Cpus_allowed_list /proc/self/status | tr -d " \t" | cut -d: -f2)|"; \
         grep -m1 Hugepagesize /proc/meminfo | tr -dc "0-9"; echo -n "|"; \
         echo "${ROCR_VISIBLE_DEVICES:-unset}"' 2>/dev/null | tr -d '\n')
      t0=$(date +%s.%N)
      run > "$OUT/${BENCH}_${name}_p${p}_${STAMP}.log" 2>&1
      rc=$?
      t1=$(date +%s.%N)
      secs=$(echo "$t1 - $t0" | bc)
      printf '%s,%s,%.2f,%s,%s\n' "$p" "$name" "$secs" "$rc" "$probe" >> "$CSV"
      printf '    %-14s %8.2f s   exit=%s\n' "$name" "$secs" "$rc"
    )
  done
done

echo; echo "=== raw results: $CSV ==="
echo "Analyse with:  python3 $D/collect.py $CSV"
echo
echo "Before believing any of it, check the verification columns: a config that"
echo "did not get its cores, GPUs or huge pages produced a plausible time that"
echo "means nothing."
