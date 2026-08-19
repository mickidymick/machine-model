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
  # ONLY="a b c" restricts which configs are built, matching the timed job.
  if [ -n "${ONLY:-}" ]; then
    case " $ONLY " in *" $name "*) ;; *) continue ;; esac
  fi
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
    xsbench) cp -r "$D/pristine-xsbench" "$tree/src" ;;
    lulesh)  cp -r "$D/pristine-lulesh"  "$tree/src" ;;
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
  # Install the config INTO the tree and run it from there. The arms resolve
  # their paths from `dirname "${BASH_SOURCE[0]}"` -- which is correct, because
  # task.md told them the source is in their directory. Exec'ing them out of
  # configs/ pointed SRC_DIR at configs/miniqmc/src, which does not exist.
  cp "$cfg" "$tree/SOLUTION.sh"
  do_build() {
    ( cd "$tree" || exit 1
      source /usr/share/lmod/lmod/init/bash 2>/dev/null || true
      bash ./SOLUTION.sh build ) > "$blog" 2>&1
  }
  # Up to 3 attempts. The Cray wrapper shells out to pkg-config on every
  # compile, and on a busy login node it has been seen to die with "Bus error
  # (core dumped) ... Error invoking pkg-config!" on arbitrary translation units
  # while the identical command succeeds for other configs in the same loop.
  # A degraded environment also leaves CRAY_LIBSCI_PREFIX_DIR unset, which turns
  # into a FindLAPACK failure on the NEXT attempt -- a different error from the
  # same cause, which is why matching on the pkg-config signature alone was not
  # enough. Retry on ANY failure: a config that genuinely cannot build fails all
  # three times, and the missing-binary guard below still stops the run.
  attempt=1
  do_build
  rc=$?
  while [ $rc -ne 0 ] && [ $attempt -lt 3 ]; do
    attempt=$((attempt+1))
    echo "    build failed (exit $rc) -- attempt $attempt of 3"
    sleep 5
    rm -rf "$tree/build"
    do_build
    rc=$?
  done
  [ $attempt -gt 1 ] && [ $rc -eq 0 ] && echo "    succeeded on attempt $attempt"
  # NOT `echo $?` after a pipeline: that reports tail's status, which is always
  # 0, so every failed build announced success.
  tail -5 "$blog"
  echo "    exit=$rc   full log: $blog"
done

missing=0
echo
echo "=== did the manipulation actually happen? ==="
# A config that loaded craype-hugepages2M RELINKS, so its binary must differ
# from one that did not. Identical hashes across arms mean the huge-page
# decision never reached the executable -- a failure that would otherwise
# report as "the arms performed the same", the wrong conclusion from right numbers.
for cfg in "$D/configs/$BENCH"/*.sh; do
  name=$(basename "$cfg" .sh)
  # Respect ONLY here too. Otherwise a config that was never requested, and
  # will never run, blocks submission of a job that does not need it.
  if [ -n "${ONLY:-}" ]; then
    case " $ONLY " in *" $name "*) ;; *) continue ;; esac
  fi
  bin=""   # must be set before the -x test; an unrecognised BENCH would
           # otherwise leave it unbound and crash the summary under `set -u`
  case "$BENCH" in
    amg)     bin="$D/arms/$name/$BENCH/src/src/test/amg" ;;
    miniqmc) bin="$D/arms/$name/$BENCH/build/bin/miniqmc" ;;
    # XSBench builds in-tree; LULESH's location depends on which build system
    # the arm chose, so both fall through to the search below if absent.
    xsbench) bin="$D/arms/$name/$BENCH/src/openmp-threading/XSBench" ;;
    lulesh)  bin="$D/arms/$name/$BENCH/build/lulesh2.0" ;;
  esac
  # An arm may build somewhere else entirely; fall back to a search rather than
  # reporting NO BINARY for a build that actually succeeded.
  if [ ! -x "$bin" ]; then
    # -name "$BENCH" alone misses XSBench (capitalised) and lulesh2.0
    # (versioned), and an arm may build somewhere unexpected. Search the known
    # executable names for this benchmark, newest first.
    case "$BENCH" in
      xsbench) pat='XSBench' ;;
      lulesh)  pat='lulesh2.0' ;;
      *)       pat="$BENCH" ;;
    esac
    alt=$(find "$D/arms/$name/$BENCH" -type f -perm -u+x -name "$pat" 2>/dev/null | head -1)
    [ -n "$alt" ] && bin="$alt"
  fi
  if [ ! -x "$bin" ]; then
    printf '  %-14s NO BINARY -- build failed; this config cannot be timed\n' "$name"
    missing=$((missing+1))
  else
    printf '  %-14s %s  %s\n' "$name" "$(sha256sum "$bin" | cut -c1-16)" \
      "$(stat -c %s "$bin") bytes"
  fi
done
echo
echo "If two configs share a hash they built identically -- check whether the one"
echo "that asked for craype-hugepages2M actually loaded it."

if [ "$missing" -gt 0 ]; then
  echo
  echo "############################################################"
  echo "##  $missing CONFIG(S) HAVE NO BINARY. DO NOT SUBMIT."
  echo "##  A missing config is a missing result, not a slow one --"
  echo "##  the timed job runs happily without it and spends the"
  echo "##  allocation producing a comparison with a hole in it."
  echo "############################################################"
  exit 1
fi
echo
echo "all $(ls "$D/configs/$BENCH"/*.sh 2>/dev/null | wc -l) configs present; $missing missing."
