#!/bin/bash
# Rebuild a run's CSV from the per-run .log files.
#
#   ./eval/exp-b/rebuild_csv.sh miniqmc 20260813_161703
#
# Needed because run_interleaved.sbatch wrote the CSV through a RELATIVE path
# while appending from inside `( cd "$tree" ... )`, so every append resolved
# against the arm tree and failed. The header was written at top level, so the
# file existed and looked plausible while containing nothing.
#
# The per-run logs were written through an absolute path and survived. They
# contain everything the comparison uses -- the application-reported time, the
# FOM, the rank/thread/walker counts. The only column that cannot be recovered
# is the harness stopwatch (`seconds`), which is deliberately NOT the number the
# analysis uses; it is left as NA.
set -eu
D=$(cd "$(dirname "$0")" && pwd)
BENCH=${1:-miniqmc}
STAMP=${2:-}
OUT="$D/results"

if [ -z "$STAMP" ]; then
  STAMP=$(ls -1 "$OUT"/${BENCH}_*_p1_*.log 2>/dev/null | head -1 \
          | sed -E "s/.*_p[0-9]+_([0-9]{8}_[0-9]{6})\.log/\1/")
  [ -n "$STAMP" ] || { echo "no logs found in $OUT" >&2; exit 1; }
  echo "using stamp $STAMP" >&2
fi

# Written to a SUBDIRECTORY, not alongside the original. Both files used to
# match results/<bench>_*.csv, so `ls -t` picked whichever was touched last --
# and a rebuild is by definition newer than the run it rebuilds. That silently
# fed a stale two-config CSV to collect.py while a four-config job was still
# queued, and the output looked entirely valid.
mkdir -p "$OUT/rebuilt"
CSV="$OUT/rebuilt/${BENCH}_${STAMP}.csv"
echo "pass,config,seconds,solve_s,fom,work,ranks,threads,exit" > "$CSV"

n=0; bad=0
for log in "$OUT"/${BENCH}_*_p*_${STAMP}.log; do
  [ -f "$log" ] || continue
  base=$(basename "$log" .log)
  # <bench>_<config>_p<N>_<stamp>   -- config may contain hyphens, so strip
  # the known prefix and suffix rather than splitting on them.
  rest=${base#${BENCH}_}
  rest=${rest%_${STAMP}}
  pass=${rest##*_p}
  name=${rest%_p${pass}}

  parsed=$("$D/parse_run.sh" "$BENCH" "$log")
  solve=$(echo "$parsed" | cut -d, -f1)
  fom=$(echo   "$parsed" | cut -d, -f2)
  work=$(echo  "$parsed" | cut -d, -f3)
  ranks=$(echo "$parsed" | cut -d, -f4)
  thr=$(echo   "$parsed" | cut -d, -f5)

  # A log with no parsable time is not a measurement, whatever else it contains.
  if [ "$solve" = "NA" ]; then rc=99; bad=$((bad+1)); else rc=0; fi
  printf '%s,%s,NA,%s,%s,%s,%s,%s,%s\n' \
    "$pass" "$name" "$solve" "$fom" "$work" "$ranks" "$thr" "$rc" >> "$CSV"
  n=$((n+1))
done

echo "rebuilt $n rows ($bad unparsable) -> $CSV"
echo
echo "Config/pass coverage:"
awk -F, 'NR>1 {c[$2]++} END {for (k in c) printf "  %-24s %d passes\n", k, c[k]}' "$CSV" | sort
