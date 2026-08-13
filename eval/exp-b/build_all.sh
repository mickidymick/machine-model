#!/bin/bash
# Build every config once, on a login node, BEFORE submitting the timed job.
#
#   BENCH=amg ./eval/exp-b/build_all.sh
#
# Builds are excluded from the timing on purpose -- but they are NOT excluded
# from the experiment. craype-hugepages2M relinks the binary, so the huge-page
# decision lives here, and it is the single largest measured effect on this
# machine (2.4x at a ~32 MiB working set). A config that does not load it here
# cannot get 2 MB pages at run time: THP is [never] and the hugetlb pool is empty.
#
# Each config builds in ITS OWN tree, arms/<config>/<bench>/, laid out exactly
# like the directory the agents worked in -- task.md promised them "the source
# code is in this directory" and "I will execute it as-is", so the harness has
# to make that true or their paths break through no fault of theirs.
set -u
BENCH=${BENCH:-miniqmc}
D=$(cd "$(dirname "$0")" && pwd)

for cfg in "$D/configs/$BENCH"/*.sh; do
  name=$(basename "$cfg" .sh)
  tree="$D/arms/$name/$BENCH"
  echo "=== building $name ==="
  if [ ! -d "$tree" ]; then
    echo "    NO TREE at $tree -- skipping"; continue
  fi

  # Reset to pristine. Stale .o files link WITHOUT COMPLAINT, so a rebuild could
  # otherwise silently carry objects from a previous config into this binary.
  rm -rf "$tree/src" "$tree/build"
  case "$BENCH" in
    amg)     cp -r "$D/pristine/src" "$tree/src"
             # AMG's public header is missing a prototype amg.c calls; patched
             # identically in every tree before any build() runs.
             "$D/fix_header.sh" "$tree/src/src" > /dev/null ;;
    miniqmc) cp -r "$D/pristine-miniqmc" "$tree/src" ;;
    *)       echo "    unknown BENCH=$BENCH"; continue ;;
  esac

  # Exec, do not source: the agents' scripts carry their own dispatchers and
  # `set -euo pipefail`, both of which corrupt a sourcing shell. lmod is
  # initialised here, identically for every config, because `module` is a shell
  # function that does not exist in a non-interactive subshell -- one arm
  # happened to source it and the other did not, which is an environment
  # difference that has nothing to do with the arms.
  # Keep the FULL log. `tail -5` alone discarded the actual cmake error and
  # left only its closing advice, which read like the whole message.
  mkdir -p "$D/results"
  blog="$D/results/build_${BENCH}_${name}.log"
  ( cd "$tree" || exit 1
    source /usr/share/lmod/lmod/init/bash 2>/dev/null || true
    bash "$cfg" build ) > "$blog" 2>&1
  rc=$?
  # NOT `echo $?` after a pipeline: that reports tail's status, which is always
  # 0, so every failed build announced success.
  tail -5 "$blog"
  echo "    exit=$rc   full log: $blog"
done

echo
echo "=== did the manipulation actually happen? ==="
# A config that loaded craype-hugepages2M RELINKS, so its binary must differ
# from one that did not. Identical hashes across arms mean the huge-page
# decision never reached the executable -- a failure that would otherwise
# report as "the arms performed the same", the wrong conclusion from right numbers.
for cfg in "$D/configs/$BENCH"/*.sh; do
  name=$(basename "$cfg" .sh)
  case "$BENCH" in
    amg)     bin="$D/arms/$name/$BENCH/src/src/test/amg" ;;
    miniqmc) bin="$D/arms/$name/$BENCH/build/bin/miniqmc" ;;
  esac
  # An arm may build somewhere else entirely; fall back to a search rather than
  # reporting NO BINARY for a build that actually succeeded.
  if [ ! -x "$bin" ]; then
    alt=$(find "$D/arms/$name/$BENCH" -type f -perm -u+x -name "$BENCH" 2>/dev/null | head -1)
    [ -n "$alt" ] && bin="$alt"
  fi
  if [ ! -x "$bin" ]; then
    printf '  %-14s NO BINARY -- build failed; this config cannot be timed\n' "$name"
  else
    printf '  %-14s %s  %s\n' "$name" "$(sha256sum "$bin" | cut -c1-16)" \
      "$(stat -c %s "$bin") bytes"
  fi
done
echo
echo "If two configs share a hash they built identically -- check whether the one"
echo "that asked for craype-hugepages2M actually loaded it. If any config shows"
echo "NO BINARY, do not submit the timed job: a missing config is a missing"
echo "result, not a slow one."
