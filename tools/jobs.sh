#!/bin/bash
# Show my Slurm jobs and tail what they are writing.
#
#   ./tools/jobs.sh              # list my jobs, tail each one's output
#   ./tools/jobs.sh -w           # same, refreshing until the queue empties
#   ./tools/jobs.sh -n 40        # tail 40 lines instead of 15
#   ./tools/jobs.sh 5256458      # just this job, even if it has finished
#   ./tools/jobs.sh -q           # queue only, no tails
#
# The output path comes from `scontrol show job` (StdOut=), not from a guess.
# A job whose -o path pointed somewhere unexpected is exactly the case where
# guessing would show you a stale file and look like the job produced nothing.
set -u

LINES=15
WATCH=0
QUIET=0
JOBID=""
INTERVAL=30

while [ $# -gt 0 ]; do
  case "$1" in
    -n) LINES=$2; shift 2 ;;
    -w) WATCH=1; shift ;;
    -i) INTERVAL=$2; shift 2 ;;
    -q) QUIET=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *)  JOBID=$1; shift ;;
  esac
done

command -v squeue >/dev/null 2>&1 || {
  echo "no squeue on this host -- run this on a Frontier login node" >&2; exit 1; }

hr() { printf '%*s\n' "${COLUMNS:-72}" '' | tr ' ' '-'; }

# Where is this job writing? Ask Slurm; fall back to the job script's own log.
stdout_of() {
  scontrol show job "$1" 2>/dev/null \
    | tr ' ' '\n' | awk -F= '/^StdOut=/{print $2; exit}'
}

show_one() {
  local id=$1
  local state elapsed name
  read -r state elapsed name < <(
    squeue -j "$id" -h -o '%T %M %j' 2>/dev/null)
  if [ -z "${state:-}" ]; then
    # not in the queue any more -- sacct knows how it ended
    read -r state elapsed < <(
      sacct -j "$id" -n -X -o State,Elapsed 2>/dev/null | head -1)
    name=$(sacct -j "$id" -n -X -o JobName 2>/dev/null | head -1)
  fi
  hr
  printf 'job %s  %s  %s  elapsed %s\n' \
    "$id" "${name:-?}" "${state:-UNKNOWN}" "${elapsed:-?}"

  [ "$QUIET" = 1 ] && return

  local f
  f=$(stdout_of "$id")
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    # Slurm may have purged the record; try the usual places
    f=$(ls -t "$HOME"/machine-model/eval/exp-b/results/*"$id"* \
              "$HOME"/machine-model/results/*"$id"* 2>/dev/null | head -1)
  fi
  if [ -n "${f:-}" ] && [ -f "$f" ]; then
    printf '  %s\n' "$f"
    tail -n "$LINES" "$f" | sed 's/^/  | /'
  else
    echo "  (no output file found -- if the job failed instantly, its -o path"
    echo "   probably names a directory that does not exist; Slurm resolves -o"
    echo "   before the script runs, so a mkdir inside the script is too late)"
  fi
}

once() {
  if [ -n "$JOBID" ]; then
    show_one "$JOBID"
    return
  fi
  local ids
  ids=$(squeue -u "$USER" -h -o '%i' 2>/dev/null)
  if [ -z "$ids" ]; then
    hr; echo "no jobs in the queue for $USER"
    local last
    last=$(sacct -u "$USER" -n -X -S "$(date -d '12 hours ago' +%Y-%m-%dT%H:%M 2>/dev/null || echo now-12hours)" \
             -o JobID,JobName%22,State,Elapsed 2>/dev/null | tail -6)
    [ -n "$last" ] && { echo; echo "recent (last 12h):"; echo "$last" | sed 's/^/  /'; }
    return
  fi
  squeue -u "$USER" -o '%.10i %.22j %.9T %.10M %.10L %.6D %R' 2>/dev/null
  for id in $ids; do show_one "$id"; done
}

if [ "$WATCH" = 1 ]; then
  # Loop until nothing of mine is left in the queue. One extra pass afterwards
  # so the final output is shown rather than the second-to-last refresh.
  while :; do
    clear 2>/dev/null || true
    date '+%H:%M:%S'
    once
    squeue -u "$USER" -h -o '%i' 2>/dev/null | grep -q . || break
    sleep "$INTERVAL"
  done
  echo
  echo "queue empty."
  once
else
  once
fi
