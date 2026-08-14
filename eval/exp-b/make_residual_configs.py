#!/usr/bin/env python3
"""Generate one-knob decomposition configs for the Experiment B residual.

Experiment B left -0.86 s unexplained and significant: with-artifact was slower
than no-artifact for reasons OTHER than huge pages, which were isolated to 0.2%
and are not significant. Three differences remain between the arms. Each config
here is with-artifact.sh with EXACTLY ONE of them changed to match no-artifact,
so the effect of each can be attributed instead of guessed at.

These are NOT arms. They are instrumentation on a result already obtained.
"""
import pathlib, sys

C = pathlib.Path(__file__).parent / "configs" / "miniqmc"
base = (C / "with-artifact.sh").read_text()

def emit(name, why, old, new, count=1):
    assert old in base, f"{name}: anchor not found:\n{old[:120]}"
    body = base.replace(old, new, count)
    hdr = (f"#!/bin/bash\n"
           f"# DECOMPOSITION CONFIG -- NOT AN ARM. Do not report as a result.\n"
           f"#\n"
           f"# with-artifact.sh with EXACTLY ONE change, to attribute the -0.86 s\n"
           f"# residual that huge pages did not explain.\n"
           f"#\n"
           f"# CHANGED: {why}\n")
    (C / f"{name}.sh").write_text(hdr + body.split("\n", 1)[1])
    print(f"  wrote {name}.sh")

# 1. OMP_PLACES: with-artifact used cores, no-artifact used threads.
emit("wa-places",
     "OMP_PLACES=cores -> threads, matching no-artifact",
     "  export OMP_PLACES=cores         # one thread per physical core, no SMT",
     "  export OMP_PLACES=threads       # CHANGED: match no-artifact")

# 2. Task distribution: with-artifact set it explicitly, no-artifact left the default.
emit("wa-nodist",
     "drop --distribution=block:block, matching no-artifact's default",
     "       --cpu-bind=threads --distribution=block:block \\",
     "       --cpu-bind=threads \\")

# 3. BLAS: with-artifact pinned the SERIAL libsci; no-artifact used BLA_VENDOR=All,
#    which on Frontier lets the CC wrapper supply the threaded libsci_gnu_mpi_mp.
#    This one needs a rebuild, which build_all.sh does anyway.
emit("wa-blas",
     "pinned serial libsci -> -DBLA_VENDOR=All, matching no-artifact",
     '  libsci="$(ls "${CRAY_LIBSCI_PREFIX_DIR:-/nonexistent}"/lib/libsci_gnu_*[0-9].so 2>/dev/null | head -1 || true)"',
     '  libsci=""   # CHANGED: force the BLA_VENDOR=All path no-artifact took')
emit_blas_extra = None
p = C / "wa-blas.sh"
t = p.read_text()
old = '    "${libsci_args[@]}"'
assert old in t
p.write_text(t.replace(old, '    -DBLA_VENDOR=All', 1))
print("  wa-blas.sh: swapped libsci_args for -DBLA_VENDOR=All")
