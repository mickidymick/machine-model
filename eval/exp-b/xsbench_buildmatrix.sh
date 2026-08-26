#!/bin/bash
# Settle the XSBench build question: is craype-hugepages2M incompatible with
# PrgEnv-amd, or with lld? Login node, ~5 minutes, no allocation.
#
#   ./eval/exp-b/xsbench_buildmatrix.sh
#
# WHY THIS EXISTS
#
# Round 3's no-artifact arm loaded PrgEnv-amd AND craype-hugepages2M and failed
# to link. Its own comment says "the flags are PE-agnostic though" -- the belief
# that caused it. The with-artifact arm switched to PrgEnv-gnu and ALSO unloaded
# craype-hugepages2M, so it avoided the failure but gave up huge pages on a code
# that is nothing but random gathers into a multi-GB grid, which is the exact
# regime cost.page_size_penalty measures at 2.4x.
#
# If cell B below builds AND shows 2 MB backing, then the artifact's pitfall
# overstates the conflict: it is craype-hugepages vs LLD, not vs PrgEnv-amd, and
# the arm gave up a lever it could have kept. Fixing the claim's wording is then
# a real artifact change traceable to a measured arm decision.
#
# Cell D is the one the pitfall says has no fix. Worth one attempt: -fuse-ld=bfd
# keeps the AMD compiler and swaps only the linker. If it works, the pitfall
# gains a remedy it does not currently have.
set -u

D=$(cd "$(dirname "$0")" && pwd)
SRC="$D/pristine-xsbench"
OUT="$D/bin/xsbench-matrix"
[ -d "$SRC" ] || { echo "no source at $SRC -- run setup_bench.sh xsbench" >&2; exit 1; }
mkdir -p "$OUT"

init_modules() {
  command -v module >/dev/null 2>&1 && return 0
  source /usr/share/lmod/lmod/init/bash 2>/dev/null || \
  source /opt/cray/pe/lmod/lmod/init/bash 2>/dev/null || return 1
}
init_modules || { echo "cannot initialise modules" >&2; exit 1; }

# id : PrgEnv : hugepages : extra LDFLAGS : what it tests
CELLS=(
  "A:PrgEnv-amd:yes::the round-3 no-artifact arm -- expected to FAIL"
  "B:PrgEnv-gnu:yes::huge pages under GNU ld -- the lever the artifact arm dropped"
  "C:PrgEnv-gnu:no::control, no huge pages"
  "D:PrgEnv-amd:yes:-fuse-ld=bfd:AMD compiler, GNU linker -- not in the pitfall"
)

printf '%-3s %-12s %-6s %-14s %-8s %s\n' ID PRGENV HUGE LDFLAGS BUILD NOTE
printf '%.0s-' {1..92}; echo

for cell in "${CELLS[@]}"; do
  IFS=: read -r id pe huge extra note <<<"$cell"
  work=$(mktemp -d "${TMPDIR:-/tmp}/xsb-${id}.XXXXXX")
  cp -r "$SRC"/* "$work/" 2>/dev/null
  log="$OUT/build_${id}.log"

  (
    set +u
    module reset            >/dev/null 2>&1 || true
    module load "$pe"       >/dev/null 2>&1 || echo "WARN: $pe unavailable"
    if [ "$huge" = yes ]; then
      module load craype-hugepages2M >/dev/null 2>&1 || echo "WARN: hugepages module unavailable"
    else
      module unload craype-hugepages2M   >/dev/null 2>&1 || true
      module unload craype-hugepages512M >/dev/null 2>&1 || true
    fi
    echo "--- module list ---"; module list 2>&1
    echo "--- link line probe ---"
    cc --cray-print-opts=all 2>/dev/null | tr ' ' '\n' | grep -i 'ttext\|image-base' || echo "(no text-segment flag emitted)"
    echo "--- build ---"
    cd "$work/openmp-threading" 2>/dev/null || cd "$work" || exit 1
    make clean >/dev/null 2>&1 || true
    make -j8 CC=cc MPI=no LDFLAGS="$extra" 2>&1
  ) > "$log" 2>&1
  rc=$?

  bin=$(find "$work" -maxdepth 2 -name XSBench -type f -perm -u+x 2>/dev/null | head -1)
  if [ -n "$bin" ]; then
    cp "$bin" "$OUT/XSBench-$id"; status=OK
  else
    status=FAIL
  fi

  # The specific error the pitfall names, so a DIFFERENT failure is not
  # silently read as confirmation of the one we expect.
  if [ "$status" = FAIL ] && grep -q 'Ttext-segment is not supported' "$log"; then
    status="FAIL:lld"
  elif [ "$status" = FAIL ]; then
    status="FAIL:other"
  fi

  printf '%-3s %-12s %-6s %-14s %-8s %s\n' "$id" "$pe" "$huge" "${extra:-none}" "$status" "$note"
  rm -rf "$work"
done

echo
echo "NEXT: for every cell that built, confirm the pages are REAL. A relinked"
echo "binary that silently falls back to 4K looks identical to one that works --"
echo "which is the sting on the huge-pages-fail-silently pitfall. In a job:"
echo
echo "    ./XSBench-B -m history -s large -G unionized -p 5000 -l 34 &"
echo "    grep -c 'AnonHugePages:\\s*[1-9]' /proc/\$!/smaps"
echo
echo "Trust smaps. Do not trust the madvise return, and do not trust the module"
echo "list -- loading craype-hugepages2M proves the flag was injected, not that"
echo "the pages were provisioned."
echo
echo "logs: $OUT/build_<ID>.log"
