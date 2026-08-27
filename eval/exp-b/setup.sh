#!/bin/bash
# Build the clean per-arm working directories for Experiment B.
#
#   ./setup.sh lulesh            # one benchmark
#   ./setup.sh lulesh xsbench    # several
#
# Source comes from the PINNED pristine-<bench> trees that setup_bench.sh
# fetches, not from a path argument. Every arm, on every machine, on every
# rerun, therefore starts from byte-identical source, and the paper can name the
# revision.
#
# Each arm gets an IDENTICAL directory -- same source, same task, same
# constraints -- differing in exactly one thing: whether MACHINE.md is present.
# That single file is the intervention. Anything else that differs is a
# confound, so the difference is ASSERTED here rather than left to the reader.
#
# Arms:
#   no-artifact    source + task. The agent may inspect the machine itself and
#                  search the web. This is the honest baseline -- the 2026-08-10
#                  eval showed the declared topology is entirely available from
#                  the OLCF User Guide, so withholding it would build a
#                  strawman.
#   with-artifact  the same, plus MACHINE.md = the measured briefing.
#
# WHAT THIS SCRIPT DOES NOT DO, AND MUST NOT. It does not write SOLUTION.sh.
# That file is the measurement. It is produced by an agent in a FRESH session
# with no context beyond what is in the arm directory -- no knowledge of the
# spread probe, of which configuration was fastest, or of what the other arm
# did. An arm written by anyone who has seen the answer key is a demonstration,
# not a result.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
BRIEFING="$ROOT/prompts/frontier-compute.md"
BENCHES=${*:-lulesh}

[ -r "$BRIEFING" ] || { echo "missing briefing: $BRIEFING" >&2; exit 1; }
[ -r "$HERE/task.md" ] || { echo "missing $HERE/task.md" >&2; exit 1; }

# The briefing is what the treatment arm receives. If it names a benchmark that
# is under test, the treatment arm has been handed an answer the control arm has
# to derive. Refuse rather than warn.
if [ -x "$ROOT/tools/leakcheck.py" ] || [ -r "$ROOT/tools/leakcheck.py" ]; then
  python3 "$ROOT/tools/leakcheck.py" "$ROOT/machines/frontier-compute.json" >/dev/null || {
    echo "REFUSING: leakcheck reports a test-application measurement in the artifact." >&2
    echo "Run: python3 tools/leakcheck.py machines/frontier-compute.json" >&2
    exit 1
  }
fi
for b in $BENCHES; do
  if grep -qi "\b$b\b" "$BRIEFING"; then
    echo "REFUSING: the briefing names '$b', which is under test." >&2
    echo "  grep -n -i '$b' $BRIEFING" >&2
    exit 1
  fi
done

fail=0
for bench in $BENCHES; do
  src="$HERE/pristine-$bench"
  prob="$HERE/problem-$bench.md"
  if [ ! -d "$src" ]; then
    echo "SKIP $bench -- no $src; run ./setup_bench.sh $bench first"; fail=1; continue
  fi
  # Round 3's version used `|| true` here, so a missing problem statement
  # produced an arm with a task and no problem and nothing said so.
  if [ ! -r "$prob" ]; then
    echo "SKIP $bench -- no $prob"; fail=1; continue
  fi

  for arm in no-artifact with-artifact; do
    d="$HERE/arms/$arm/$bench"
    rm -rf "$d"; mkdir -p "$d/src"
    cp -r "$src"/. "$d/src/"
    cp "$HERE/task.md" "$d/TASK.md"
    cp "$prob"        "$d/PROBLEM.md"
    [ "$arm" = with-artifact ] && cp "$BRIEFING" "$d/MACHINE.md"
    echo "built $d"
  done

  # ASSERT the arms differ by exactly MACHINE.md.
  a="$HERE/arms/no-artifact/$bench"; b="$HERE/arms/with-artifact/$bench"
  d=$(diff -rq "$a" "$b" 2>&1 | sed "s|$HERE/||g")
  n=$(printf '%s\n' "$d" | grep -c . || true)
  only=$(printf '%s\n' "$d" | grep -c 'MACHINE.md' || true)
  if [ "$n" -ne 1 ] || [ "$only" -ne 1 ]; then
    echo "  !! ARMS DIFFER BY MORE THAN MACHINE.md -- this is a confound:"
    printf '     %s\n' "$d"
    fail=1
  else
    echo "  verified: arms differ by exactly MACHINE.md"
  fi
done

echo
[ "$fail" -eq 0 ] || { echo "setup incomplete -- see above"; exit 1; }
cat <<'EOF'
NEXT -- and this part cannot be automated.

In EACH arm directory, start a FRESH agent session with no other context and
point it at TASK.md. Same model, same effort, every arm. It writes SOLUTION.sh.
Then:

    cp arms/<arm>/<bench>/SOLUTION.sh configs/<bench>/<arm>.sh

Three draws per arm; agent output is stochastic and one draw cannot separate the
intervention from the luck of a single generation.

The session must not know the problem size was chosen from a spread probe, which
configuration was fastest, or what the other arm produced. That is the whole
measurement.
EOF
