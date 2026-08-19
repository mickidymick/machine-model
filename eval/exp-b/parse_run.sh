#!/bin/bash
# Extract, from a run log, the numbers that decide whether a run is comparable:
#   solve_s,fom,work,ranks,threads
#
# All of these come from the APPLICATION, not from the harness. An earlier
# version probed the machine with a separate `srun --overlap` step, which was
# worse than useless: that step got a fresh default allocation rather than the
# config's `-c 14`, and /proc/meminfo's Hugepagesize is the system default
# regardless of what the run actually received. Both columns were constants
# across every config and looked like verification.
#
#   ./parse_run.sh miniqmc run.log
set -u
BENCH=$1; LOG=$2
[ -f "$LOG" ] || { echo "NA,NA,NA,NA,NA"; exit 0; }

r=NA; w=NA; th=NA
case "$BENCH" in
  miniqmc)
    # "Total" is both a timer row and the "Total throughput" line, and BOTH have
    # >=5 fields -- NF alone does not separate them. Require $2 to be a number:
    # the timer row has 28.7956 there, the throughput line has the word
    # "throughput". The earlier version got the right answer only because the
    # timer row happens to print first and awk exits on the first match.
    t=$(awk '$1=="Total" && $2 ~ /^[0-9]+(\.[0-9]+)?$/ {print $2; exit}' "$LOG")
    f=$(awk '/^Total throughput/{print $NF; exit}' "$LOG")
    r=$(awk  -F'= ' '/MPI processes/{print $2; exit}'      "$LOG" | tr -dc '0-9')
    w=$(awk  -F'= ' '/walkers per rank/{print $2; exit}'   "$LOG" | tr -dc '0-9')
    th=$(awk -F'= ' '/OpenMP threads/{print $2; exit}'     "$LOG" | tr -dc '0-9')
    if [ -n "$r" ] && [ -n "$w" ]; then work=$((r * w)); else work=NA; fi
    ;;
  amg)
    t=$(awk '/Cumulative AMG-GMRES Solve Time/{f=1}
             f && /wall clock time/{print $5; exit}' "$LOG")
    f=$(awk '/Figure of Merit \(FOM_2\)/{print $NF; exit}' "$LOG")
    work=NA   # AMG does not self-report its global grid
    ;;
  xsbench)
    # Runtime is the reported figure; Lookups is the work. The verification
    # checksum is the equal-work anchor -- identical inputs must produce an
    # identical checksum, so a differing one means the arms did different work
    # no matter what the lookup count says.
    t=$(awk -F: '/^Runtime:/{gsub(/[^0-9.]/,"",$2); print $2; exit}' "$LOG")
    f=$(awk -F: '/^Lookups\/s:/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$LOG")
    work=$(awk -F: '/Verification checksum/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$LOG")
    r=$(awk -F: '/^Threads:/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$LOG")
    th=$r
    ;;
  lulesh)
    # Elapsed time, NOT grind time: grind is per-domain (elapsed/cycles/nx^3) so
    # it is not comparable between runs with different rank counts, and the two
    # arms chose 8 and 125 ranks. Both arms flagged this themselves.
    # NOT the "Elapsed time" line: LULESH prints it at 2 significant figures
    # ("= 5.4"), which flattened five distinct runs to an identical value and
    # produced sd=0.000 across every pass. The same quantity appears at 8
    # figures inside the Grind line as "( 5.4105869 overall)". Parse that.
    t=$(awk 'match($0,/\([ ]*[0-9.]+ overall\)/){
               s=substr($0,RSTART,RLENGTH); gsub(/[^0-9.]/,"",s); print s; exit}' "$LOG")
    [ -n "${t:-}" ] || t=$(awk -F= '/^Elapsed time/{gsub(/[^0-9.]/,"",$2); print $2; exit}' "$LOG")
    f=$(awk -F= '/^FOM/{gsub(/[^0-9.eE+-]/,"",$2); print $2; exit}' "$LOG")
    # work = ranks * problem_size^3, which must be identical across arms even
    # though the factorisation differs (8x45^3 == 125x18^3 == 729000).
    local_ranks=$(awk -F= '/MPI tasks/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$LOG")
    local_nx=$(awk -F= '/Problem size/{gsub(/[^0-9]/,"",$2); print $2; exit}' "$LOG")
    if [ -n "${local_ranks:-}" ] && [ -n "${local_nx:-}" ]; then
      work=$(( local_ranks * local_nx * local_nx * local_nx ))
      r=$local_ranks
    else work=NA; fi
    ;;
  *) t=""; f=""; work=NA ;;
esac
echo "${t:-NA},${f:-NA},${work:-NA},${r:-NA},${th:-NA}"
