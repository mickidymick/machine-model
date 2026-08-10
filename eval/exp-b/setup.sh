#!/bin/bash
# Build the clean per-arm working directories for Experiment B.
#
#   ./setup.sh /path/to/amg/src /path/to/qmcpack/src
#
# Each arm gets an IDENTICAL directory -- same source, same task, same
# constraints -- differing in exactly one thing: whether MACHINE.md is present.
# That single file is the intervention. Anything else that differs between arms
# is a confound.
#
# Arms:
#   no-artifact    source + task. The agent may inspect the machine itself
#                  (lstopo, numactl -H, rocm-smi) and search the web. This is
#                  the honest baseline -- the 2026-08-10 eval showed the declared
#                  topology is entirely available from the OLCF User Guide, so
#                  withholding it would build a strawman.
#   with-artifact  the same, plus MACHINE.md = the measured briefing.
set -u

AMG_SRC=${1:-}
QMC_SRC=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
BRIEFING="$ROOT/prompts/frontier-compute.md"

[ -r "$BRIEFING" ] || { echo "missing briefing: $BRIEFING" >&2; exit 1; }

for bench in amg qmcpack; do
  case $bench in
    amg)     src=$AMG_SRC ;;
    qmcpack) src=$QMC_SRC ;;
  esac
  if [ -z "$src" ] || [ ! -d "$src" ]; then
    echo "SKIP $bench -- no source directory given or it does not exist"
    echo "     usage: ./setup.sh /path/to/amg /path/to/qmcpack"
    continue
  fi
  for arm in no-artifact with-artifact; do
    d="$HERE/arms/$arm/$bench"
    rm -rf "$d"; mkdir -p "$d"
    cp -r "$src"/. "$d/src/" 2>/dev/null || { mkdir -p "$d/src"; cp -r "$src"/* "$d/src/"; }
    cp "$HERE/task.md" "$d/TASK.md"
    cp "$HERE/problem-$bench.md" "$d/PROBLEM.md" 2>/dev/null || true
    if [ "$arm" = with-artifact ]; then
      cp "$BRIEFING" "$d/MACHINE.md"
    fi
    echo "built $d  ($(ls "$d" | tr '\n' ' '))"
  done
done

echo
echo "Verify the arms differ by exactly one file before running:"
echo "  diff -rq arms/no-artifact/<bench> arms/with-artifact/<bench>"
echo "The only difference must be MACHINE.md."
