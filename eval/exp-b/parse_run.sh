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
    # "Total" is both a timer row and the "Total throughput" line -- require the
    # numeric timer columns so throughput cannot match.
    t=$(awk '$1=="Total" && NF>=5 {print $2; exit}' "$LOG")
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
  *) t=""; f=""; work=NA ;;
esac
echo "${t:-NA},${f:-NA},${work:-NA},${r:-NA},${th:-NA}"
