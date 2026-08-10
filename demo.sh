#!/bin/bash
# End-to-end run of everything, in the order it makes sense to show it.
#
#   ./demo.sh              # all machines under machines/
#   ./demo.sh --regen      # also regenerate the briefings
#
# Order is deliberate: integrity first (a descriptor that fails integrity must
# not be believed), then per-machine fidelity, then the cross-machine result,
# which is the part that does not exist with one machine.
set -u
cd "$(dirname "$0")" || exit 1

REGEN=0
[ "${1:-}" = "--regen" ] && REGEN=1

MACHINES=(machines/*.json)

hr() { printf '\n\033[1m%s\033[0m\n' "── $1 ──────────────────────────────────────────"; }

hr "1. integrity + fidelity, per machine"
fail=0
for m in "${MACHINES[@]}"; do
	python3 check.py "$m" || fail=1
done

if [ "$fail" -ne 0 ]; then
	echo
	echo "!! a descriptor failed integrity. Stopping -- a briefing generated"
	echo "!! from an unvalidated descriptor still reads as authoritative."
	exit 1
fi

hr "2. cross-machine"
if [ "${#MACHINES[@]}" -ge 2 ]; then
	python3 compare.py "${MACHINES[@]}"
else
	echo "only one descriptor; comparison needs two or more"
fi

hr "3. briefings"
for m in "${MACHINES[@]}"; do
	base=$(basename "$m" .json)
	out="prompts/${base}.md"
	if [ "$REGEN" -eq 1 ]; then
		python3 render.py "$m" > "$out" || exit 1
		echo "regenerated $out"
	fi
	if [ -f "$out" ]; then
		printf '  %-28s %5s lines  %6s bytes  ~%sk tokens\n' \
			"$out" "$(wc -l <"$out")" "$(wc -c <"$out")" \
			"$(( $(wc -c <"$out") / 4000 ))"
	fi
done

echo
echo "The briefing is what a user pastes alongside their source code. It is"
echo "app-agnostic on purpose: it states cost structure and conditions, never"
echo "conclusions, because the model holds the half we do not -- the code."
echo
