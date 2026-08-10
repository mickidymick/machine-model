#!/bin/bash
# Build every config once, on a login node, BEFORE submitting the timed job.
#
#   BENCH=amg ./eval/exp-b/build_all.sh
#
# Builds are excluded from the timing on purpose -- but they are NOT excluded
# from the experiment. craype-hugepages2M relinks the binary, so the huge-page
# decision lives here, and it is the single largest measured effect on this
# machine (2.4x at a ~32 MiB working set). A config that does not load it here
# cannot get 2 MB pages at run time, because THP is [never] and the hugetlb pool
# is empty.
set -u
BENCH=${BENCH:-amg}
D=$(cd "$(dirname "$0")" && pwd)

for cfg in "$D/configs/$BENCH"/*.sh; do
  name=$(basename "$cfg" .sh)
  echo "=== building $name ==="
  ( set +u; source "$cfg"; build ) 2>&1 | tail -5
  echo "    exit=$?"
done
echo
echo "Confirm each build actually got what it asked for -- in particular, a"
echo "config that loaded craype-hugepages2M should show a different linked"
echo "binary than one that did not."
