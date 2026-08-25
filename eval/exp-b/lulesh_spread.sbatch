#!/bin/bash
#SBATCH -J lulesh-spread
#SBATCH -N 1
#SBATCH -t 00:30:00
#SBATCH -p batch
#
# -o/-e are relative to the SUBMIT directory and Slurm resolves them BEFORE the
# script runs, so a mkdir inside cannot create them in time. Submit from the
# repo root.
#SBATCH -o eval/exp-b/results/spread_%j.out
#SBATCH -e eval/exp-b/results/spread_%j.err
#
# DOES A CONFIGURATION SPREAD EXIST AT THE CORRECTED PROBLEM SIZE?
#
#   ./eval/exp-b/build_spread.sh                     # login node, once
#   PASSES=3 sbatch -A CSC617 eval/exp-b/lulesh_spread.sbatch
#
# Round 3 measured 5.43 s to 27.40 s across four configurations -- a 5x spread,
# and the reason to believe the prize is real. But that was 729,000 elements,
# cache-resident on a 512 GB node, in a regime where almost none of the
# artifact's claims could bind. We do not actually know the spread survives at
# a size where they do. If it collapses into the noise here, the experiment
# cannot discriminate anything and that has to be found out now, in half an
# hour, rather than after forty-five agent sessions.
#
# SECOND JOB: settle the footprint question. The source count in
# eval/characterize/analytic-lulesh.md gives 315 B/element for the MPI-only
# path, agreeing with round 3's 230 MB at 729,000 elements. A published
# single-rank run at 27e6 elements measured 23.6 GB -- 874 B/element, 2.8x
# more. If the gap is the threaded path's temporaries, then FOOTPRINT DEPENDS
# ON THE CONFIG UNDER TEST, and peak RSS across these six configurations says
# so directly.
#
# INTERLEAVED, not blocked. Every config runs once per pass in rotating order.
# Blocked runs let drift across an allocation masquerade as a config
# difference; that artifact nearly sank the July inter-node comparison.
set -u
cd "$SLURM_SUBMIT_DIR" || exit 1

D=eval/exp-b
BIN=$D/bin
OUT=$D/results
PASSES=${PASSES:-3}
mkdir -p "$OUT"

STAMP=$(date +%Y%m%d_%H%M%S)
CSV="$OUT/spread_${SLURM_JOB_ID}_${STAMP}.csv"
LOGD="$OUT/spread_${SLURM_JOB_ID}_logs"
mkdir -p "$LOGD"

# ---------------------------------------------------------------- the problem
# Fixed across every configuration -- see problem-lulesh.md.
ELEMS=27000000        # global 300^3
ITERS=50
REGION="-r 11 -b 0 -c 64"
ALLOCATABLE_PU=112    # 56 usable cores x 2 HWT; see cpu.core_inventory

# ------------------------------------------------------------- configurations
# id : ranks : s : threads : binary
# Every row must satisfy  cbrt(ranks) * s == 300  and  ranks * s^3 == 27e6.
CONFIGS=(
  "m08x1:8:150:1:mpi"     # floor -- 8 cores busy, cheap force path
  "m27x1:27:100:1:mpi"    # one rank per core, 27 of 56, cheap force path
  "m64x1:64:75:1:mpi"     # 64 ranks on 56 allocatable cores -- the trap
  "o27x2:27:100:2:omp"    # 54 cores, threaded force path and its extra traffic
  "o08x7:8:150:7:omp"     # 56 cores reached through threads, not ranks
  "o27x4:27:100:4:omp"    # 108 threads -- into the second hardware thread
)

# ------------------------------------------------------- pre-flight arithmetic
# "Check arithmetic before submitting" -- 64 was an illegal LULESH rank count
# once already, and the job ran for twenty minutes before saying so.
fail=0
icbrt() { python3 -c "import sys;n=int(sys.argv[1]);r=round(n**(1/3));print(r if r**3==n else -1)" "$1"; }

for c in "${CONFIGS[@]}"; do
  IFS=: read -r id ranks s threads bin <<<"$c"
  t=$(icbrt "$ranks")
  if [ "$t" -lt 0 ]; then
    echo "PREFLIGHT $id: $ranks is not a perfect cube" >&2; fail=1; continue
  fi
  if [ $(( t * s )) -ne 300 ]; then
    echo "PREFLIGHT $id: cbrt($ranks)=$t times s=$s is $(( t * s )), not 300" >&2; fail=1
  fi
  if [ $(( ranks * s * s * s )) -ne "$ELEMS" ]; then
    echo "PREFLIGHT $id: ranks*s^3 = $(( ranks * s * s * s )), not $ELEMS" >&2; fail=1
  fi
  if [ $(( ranks * threads )) -gt "$ALLOCATABLE_PU" ]; then
    echo "PREFLIGHT $id: ranks*threads = $(( ranks * threads )) exceeds $ALLOCATABLE_PU allocatable PUs" >&2; fail=1
  fi
  [ -x "$BIN/lulesh-$bin" ] || { echo "PREFLIGHT $id: missing $BIN/lulesh-$bin -- run build_spread.sh" >&2; fail=1; }
done
[ "$fail" -eq 0 ] || { echo "preflight failed; nothing submitted to srun"; exit 1; }
echo "preflight OK: ${#CONFIGS[@]} configurations, all at $ELEMS elements"
echo

echo "config,pass,ranks,s,threads,binary,elapsed_s,grind_us,peak_rss_kb,rc" > "$CSV"

# ------------------------------------------------------------------- the sweep
for p in $(seq 1 "$PASSES"); do
  n=${#CONFIGS[@]}
  for k in $(seq 0 $(( n - 1 ))); do
    # Rotate the order each pass so position in the allocation cannot be read
    # as a property of the configuration.
    idx=$(( (k + p - 1) % n ))
    IFS=: read -r id ranks s threads bin <<<"${CONFIGS[$idx]}"
    log="$LOGD/${id}_p${p}.log"

    OMP_NUM_THREADS=$threads \
    OMP_PROC_BIND=close \
    OMP_PLACES=cores \
    srun -n "$ranks" -c "$threads" --cpu-bind=cores \
         /usr/bin/time -v "$BIN/lulesh-$bin" \
         -s "$s" -i "$ITERS" $REGION -p \
         > "$log" 2>&1
    rc=$?

    # Parse the FULL-PRECISION elapsed value. LULESH also prints a
    # two-significant-figure summary; parsing that one flattened five distinct
    # runs to sd=0.000 in round 3.
    elapsed=$(grep -oP 'Elapsed time\s*=\s*\K[0-9.]+(?:[eE][-+]?[0-9]+)?' "$log" | tail -1)
    grind=$(grep -oP 'Grind time \(us/z/c\)\s*=\s*\K[0-9.eE+-]+' "$log" | tail -1)
    # Peak RSS across ranks, not of one rank.
    rss=$(grep -oP 'Maximum resident set size \(kbytes\):\s*\K[0-9]+' "$log" | sort -n | tail -1)

    echo "$id,$p,$ranks,$s,$threads,$bin,${elapsed:-NA},${grind:-NA},${rss:-NA},$rc" >> "$CSV"
    printf 'pass %s  %-6s ranks=%-3s s=%-4s thr=%s  %ss  rss=%s kB  rc=%s\n' \
           "$p" "$id" "$ranks" "$s" "$threads" "${elapsed:-NA}" "${rss:-NA}" "$rc"
  done
done

# ------------------------------------------------------------------- the check
echo
echo "=================================================================="
python3 - "$CSV" "$ELEMS" <<'PY'
import csv, sys, statistics as st
csv_path, elems = sys.argv[1], int(sys.argv[2])
rows = [r for r in csv.DictReader(open(csv_path))]
ok = [r for r in rows if r["rc"] == "0" and r["elapsed_s"] not in ("NA", "")]
bad = [r for r in rows if r not in ok]

if bad:
    print(f"!! {len(bad)} of {len(rows)} runs failed or did not report a time:")
    for r in bad:
        print(f"     {r['config']} pass {r['pass']}  rc={r['rc']}")
if not ok:
    print("no usable runs -- read the logs, do not interpret this file"); sys.exit(1)

by = {}
for r in ok:
    by.setdefault(r["config"], []).append(r)

print(f"{'config':8} {'n':>2} {'median_s':>9} {'sd_s':>7} {'sd_%':>6} "
      f"{'peak_GB':>8} {'B/elem':>7}")
summary = []
for cid, rs in sorted(by.items(), key=lambda kv: st.median(float(r['elapsed_s']) for r in kv[1])):
    t = [float(r["elapsed_s"]) for r in rs]
    med = st.median(t)
    sd = st.stdev(t) if len(t) > 1 else 0.0
    rss = [int(r["peak_rss_kb"]) for r in rs if r["peak_rss_kb"] not in ("NA", "")]
    peak_gb = max(rss) * int(rs[0]["ranks"]) / 1e6 if rss else float("nan")
    b_per_elem = peak_gb * 1e9 / elems if rss else float("nan")
    print(f"{cid:8} {len(t):>2} {med:9.3f} {sd:7.3f} {100*sd/med:5.1f}% "
          f"{peak_gb:8.1f} {b_per_elem:7.0f}")
    summary.append((cid, med, sd, b_per_elem))

fast = min(summary, key=lambda x: x[1])
slow = max(summary, key=lambda x: x[1])
spread = slow[1] / fast[1]
worst_sd = max(100 * s / m for _, m, s, _ in summary if m)

print()
print(f"SPREAD  {spread:.2f}x   ({fast[0]} {fast[1]:.2f}s  ->  {slow[0]} {slow[1]:.2f}s)")
print(f"NOISE   worst per-config sd {worst_sd:.1f}% of median")
print()

# Sanity floors. Every measurement failure this project has had was a plausible
# number, not an error -- so each of these is checked against a physical bound
# rather than against whether the code looked right.
floor_s = 1.0
if fast[1] < floor_s:
    print(f"!! FASTEST RUN IS {fast[1]:.2f}s FOR {elems*50:.2e} ELEMENT-UPDATES.")
    print("   Below the plausible floor. Check the problem actually built at -s")
    print("   as given, and that -p did not truncate the run.")
mpi_floor = 250   # B/element, persistent arrays only; see analytic-lulesh.md
low = [c for c, _, _, b in summary if b == b and b < mpi_floor]
if low:
    print(f"!! {', '.join(low)} report under {mpi_floor} B/element, below the")
    print("   allocation floor counted from source. The RSS capture is wrong.")

print("HOW TO READ THIS")
print()
if spread >= 2.0:
    print(f"  {spread:.1f}x spread -- the prize is real at this size. Proceed to the")
    print("  replicated core experiment.")
elif spread >= 1.2 and worst_sd < 5:
    print(f"  {spread:.1f}x spread, and noise is small enough to resolve it. Usable,")
    print("  but a smaller effect than round 3 saw; raise PASSES for the real runs.")
else:
    print(f"  {spread:.1f}x spread against {worst_sd:.1f}% noise. THE EXPERIMENT CANNOT")
    print("  DISCRIMINATE HERE. Do not spend agent sessions. Either the size is")
    print("  still wrong or LULESH is insensitive to the levers the artifact")
    print("  speaks to -- and which of those is true is the next thing to find out.")
print()
print("  Compare m27x1 against o27x2: same ranks, same work, threaded force path.")
print("  If B/elem roughly triples, the 315-vs-874 question is settled and")
print("  footprint is config-dependent.")
print()
print("  Look hard at m64x1. 64 ranks on 56 allocatable cores is the configuration")
print("  an arm reaches by trusting the vendor node diagram.")
PY
echo "=================================================================="
echo "csv:  $CSV"
echo "logs: $LOGD"
