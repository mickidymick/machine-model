#!/bin/bash
# Applied IDENTICALLY to every tree (both arms, floor, ceiling) before build_all.sh.
#
# AMG's amg.c calls HYPRE_BoomerAMGGetCumNnzAP, which is defined in
# parcsr_ls/HYPRE_parcsr_amg.c and declared in the PRIVATE header
# _hypre_parcsr_ls.h, but was never added to the public HYPRE_parcsr_ls.h.
# Under C99 that is an error, not a warning. Nothing about it is
# Frontier-specific -- it is a bug in the benchmark's own headers.
#
# Recorded because it modifies source that both arms compile. It is applied
# before either arm's build() runs, is byte-identical across trees, and touches
# no build flag, placement decision, or anything else an arm reasons about.
# NOT fixed with -Wno-implicit-function-declaration: that would have let a
# 32-bit-int return value through silently on a HYPRE_BIGINT build.
set -eu
for tree in "$@"; do
  h="$tree/parcsr_ls/HYPRE_parcsr_ls.h"
  [ -f "$h" ] || { echo "MISSING: $h"; exit 1; }
  python3 - "$h" <<'PY'
import sys
p = sys.argv[1]
L = open(p).read().split('\n')
L = [l for l in L if 'HYPRE_BoomerAMGGetCumNnzAP' not in l and 'cum_nnz_AP);' not in l]
i = next(k for k, l in enumerate(L)
         if l.startswith('HYPRE_Int HYPRE_BoomerAMGGetNumIterations'))
# Collapse any blank lines left by a previous application before re-inserting.
# Without this the patch is not idempotent: each run leaves one extra blank, the
# file hash drifts, and the cross-tree hash comparison -- the check that proves
# every arm compiled identical source -- silently stops meaning anything.
while i > 0 and L[i-1].strip() == '':
    del L[i-1]; i -= 1
L[i:i] = ["", "HYPRE_Int HYPRE_BoomerAMGGetCumNnzAP(HYPRE_Solver solver,",
          "                                     HYPRE_Real  *cum_nnz_AP);", ""]
open(p, 'w').write('\n'.join(L))
print("patched", p)
PY
done
echo "sha256 of each patched header -- these MUST match:"
for tree in "$@"; do sha256sum "$tree/parcsr_ls/HYPRE_parcsr_ls.h"; done
