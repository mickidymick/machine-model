#!/bin/bash
#SBATCH -J lulesh-spread
#SBATCH -N 1
#SBATCH -t 02:00:00
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
# ---------------------------------------------------------------------------
# REVISION 2, after job 5343103. Four things that run taught us:
#
# 1. TIMING COMES FROM GRIND, NOT `Elapsed time`. LULESH prints elapsed at two
#    significant figures -- 4.9e+02 -- which is the same trap that flattened
#    five distinct runs to sd=0.000 in round 3, and revision 1 walked into it.
#    `Grind time` carries eight digits and is the same measurement:
#        elapsed = grind_per_dom x s^3 x iterations
#    Verified against the low-precision line: 8.0046166 us/z/c at s=100, 50
#    iterations gives 400.2 s against a reported 4e+02.
#
# 2. THE CORE CEILING IS 56, NOT 112. Revision 1 gated on 112 allocatable PUs,
#    but --cpu-bind=cores allocates CORES, and there are 56. m64x1 (64 ranks)
#    and o27x4 (108 threads) both died on it. Reaching the second hardware
#    thread requires --threads-per-core=2 and binding to threads. The gate that
#    let them through made exactly the error cpu.core_inventory exists to warn
#    about.
#
# 3. THE SPREAD WAS CONFOUNDED. Revision 1 varied core count and force path
#    together, so its 1.69x was mostly "did you use the whole node" -- the least
#    interesting lever. This set adds EQUAL-CORE PAIRS: the same number of cores
#    reached by ranks versus by threads. 1 is a perfect cube, so a single rank
#    with N threads is a legal LULESH configuration and gives the pure-threaded
#    end of each pair.
#
# 4. RUNS ARE MINUTES, NOT SECONDS. Revision 1 estimated 25 s by scaling round
#    3's throughput -- which was measured cache-resident, in the regime this
#    size deliberately leaves. Real runs were 290-490 s. Iterations drop 50 ->
#    20 (still 1.5x round 3's total work) and the wall goes to two hours.
#
# THE FINDING THIS PROBE IS NOW SHAPED AROUND. LULESH needs a cube rank count;
# Frontier has 56 usable cores. The cubes are 1, 8, 27, 64 -- so the largest
# pure-MPI configuration that fits uses 27 cores, 48% of the node. This node
# CANNOT BE FILLED WITH PURE MPI. You idle 29 cores or you go hybrid and pay the
# threaded force path's extra ~200 B/element. With the vendor diagram's 64
# cores, 64 ranks fits perfectly and the dilemma never arises.
# ---------------------------------------------------------------------------
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
ELEMS=27000000        # global 300^3
ITERS=20
REGION="-r 11 -b 0 -c 64"
CORES=56              # usable cores; cpu.core_inventory, verdict `misleading`
PUS=112               # with the second hardware thread

# ------------------------------------------------------------- configurations
# id : ranks : s : threads : binary
# Every row must satisfy cbrt(ranks)*s == 300 and ranks*s^3 == 27e6.
#
# The pairs are the point. Each pair holds CORES FIXED and moves the work from
# ranks to threads, which is the only way to separate the force-path cost from
# the how-much-of-the-node-did-you-use effect that dominated revision 1.
CONFIGS=(
  # -- 8 cores: decomposition vs threading, equal cores
  "m08x1:8:150:1:mpi"      # 8 ranks, cheap force path
  "o01x8:1:300:8:omp"      # 1 rank, 8 threads, threaded force path
  # -- 27 cores: the largest pure-MPI configuration that fits
  "m27x1:27:100:1:mpi"     # 27 ranks, cheap path, 29 cores idle
  "o01x27:1:300:27:omp"    # 1 rank, 27 threads, threaded path
  # -- filling the node, which pure MPI cannot do
  "o27x2:27:100:2:omp"     # 54 cores
  "o08x7:8:150:7:omp"      # 56 cores
  # -- past the core ceiling: requires the second hardware thread
  "m64x1:64:75:1:mpi"      # 64 ranks -- what trusting the vendor diagram buys
  "o27x4:27:100:4:omp"     # 108 threads
)

# ------------------------------------------------------- pre-flight arithmetic
fail=0
icbrt() { python3 -c "import sys;n=int(sys.argv[1]);r=round(n**(1/3));print(r if r**3==n else -1)" "$1"; }

for c in "${CONFIGS[@]}"; do
  IFS=: read -r id ranks s threads bin <<<"$c"
  t=$(icbrt "$ranks")
  if [ "$t" -lt 0 ]; then
    echo "PREFLIGHT $id: $ranks is not a perfect cube" >&2; fail=1; continue
  fi
  [ $(( t * s )) -eq 300 ] || { echo "PREFLIGHT $id: cbrt($ranks)*s = $(( t * s )), not 300" >&2; fail=1; }
  [ $(( ranks * s * s * s )) -eq "$ELEMS" ] || { echo "PREFLIGHT $id: ranks*s^3 = $(( ranks * s * s * s )), not $ELEMS" >&2; fail=1; }
  pu=$(( ranks * threads ))
  [ "$pu" -le "$PUS" ] || { echo "PREFLIGHT $id: needs $pu PUs, only $PUS exist" >&2; fail=1; }
  [ -x "$BIN/lulesh-$bin" ] || { echo "PREFLIGHT $id: missing $BIN/lulesh-$bin -- run build_spread.sh" >&2; fail=1; }
  if [ "$pu" -gt "$CORES" ]; then
    echo "  note $id: $pu > $CORES cores, will request --threads-per-core=2"
  fi
done
[ "$fail" -eq 0 ] || { echo "preflight failed; nothing submitted to srun"; exit 1; }
echo "preflight OK: ${#CONFIGS[@]} configurations, all at $ELEMS elements, -i $ITERS"
echo

echo "config,pass,ranks,s,threads,binary,pu,smt,grind_us,grind_overall,fom,elapsed_s,elapsed_reported,peak_rss_kb,rc" > "$CSV"

# ------------------------------------------------------------------- the sweep
for p in $(seq 1 "$PASSES"); do
  n=${#CONFIGS[@]}
  for k in $(seq 0 $(( n - 1 ))); do
    idx=$(( (k + p - 1) % n ))
    IFS=: read -r id ranks s threads bin <<<"${CONFIGS[$idx]}"
    log="$LOGD/${id}_p${p}.log"
    pu=$(( ranks * threads ))

    # Above 56 the second hardware thread has to be requested explicitly.
    # --cpu-bind=cores allocates cores, and asking for more than exist is
    # rejected outright rather than downgraded.
    if [ "$pu" -gt "$CORES" ]; then
      bind=(--threads-per-core=2 --cpu-bind=threads); places=threads; smt=1
    else
      bind=(--cpu-bind=cores); places=cores; smt=0
    fi

    OMP_NUM_THREADS=$threads \
    OMP_PROC_BIND=close \
    OMP_PLACES=$places \
    srun -n "$ranks" -c "$threads" "${bind[@]}" \
         /usr/bin/time -v "$BIN/lulesh-$bin" \
         -s "$s" -i "$ITERS" $REGION -p \
         > "$log" 2>&1
    rc=$?

    # Eight digits, not two. `Grind time (us/z/c) = X (per dom) ( Y overall)`.
    grind=$(grep -oP 'Grind time \(us/z/c\)\s*=\s*\K[0-9.eE+-]+' "$log" | tail -1)
    goverall=$(grep -oP 'Grind time.*\(\s*\K[0-9.eE+-]+(?=\s*overall)' "$log" | tail -1)
    fom=$(grep -oP 'FOM\s*=\s*\K[0-9.eE+-]+' "$log" | tail -1)
    reported=$(grep -oP 'Elapsed time\s*=\s*\K[0-9.eE+-]+' "$log" | tail -1)
    rss=$(grep -oP 'Maximum resident set size \(kbytes\):\s*\K[0-9]+' "$log" | sort -n | tail -1)

    # elapsed = grind_per_dom(us) x zones_per_dom x cycles, in seconds.
    if [ -n "${grind:-}" ]; then
      elapsed=$(python3 -c "print(f'{$grind*1e-6*$s**3*$ITERS:.3f}')")
    else
      elapsed=NA
    fi

    echo "$id,$p,$ranks,$s,$threads,$bin,$pu,$smt,${grind:-NA},${goverall:-NA},${fom:-NA},$elapsed,${reported:-NA},${rss:-NA},$rc" >> "$CSV"
    printf 'pass %s  %-7s pu=%-3s smt=%s  %8ss  rss=%s kB  rc=%s\n' \
           "$p" "$id" "$pu" "$smt" "$elapsed" "${rss:-NA}" "$rc"
  done
done

# ------------------------------------------------------------------- the check
echo
echo "=================================================================="
python3 - "$CSV" "$ELEMS" <<'PY'
import csv, sys, statistics as st
csv_path, elems = sys.argv[1], int(sys.argv[2])
rows = list(csv.DictReader(open(csv_path)))
ok  = [r for r in rows if r["rc"] == "0" and r["elapsed_s"] not in ("NA", "")]
bad = [r for r in rows if r["rc"] != "0" or r["elapsed_s"] in ("NA", "")]

if bad:
    print(f"!! {len(bad)} of {len(rows)} runs failed or reported no grind time:")
    for r in bad:
        print(f"     {r['config']:8} pass {r['pass']}  pu={r['pu']} smt={r['smt']} rc={r['rc']}")
    print("   A config that will not LAUNCH is a result, not a gap -- it is where")
    print("   an arm lands by trusting the vendor diagram. Read its log.")
    print()
if not ok:
    print("no usable runs -- read the logs, do not interpret this file"); sys.exit(1)

by = {}
for r in ok:
    by.setdefault(r["config"], []).append(r)

print(f"{'config':8} {'pu':>3} {'n':>2} {'median_s':>9} {'sd_%':>6} {'GB':>6} {'B/elem':>7} {'core_s':>8}")
summ = {}
for cid, rs in sorted(by.items(), key=lambda kv: st.median(float(r['elapsed_s']) for r in kv[1])):
    t   = [float(r["elapsed_s"]) for r in rs]
    med = st.median(t)
    sd  = st.stdev(t) if len(t) > 1 else 0.0
    pu  = int(rs[0]["pu"])
    rss = [int(r["peak_rss_kb"]) for r in rs if r["peak_rss_kb"] not in ("NA", "")]
    gb  = max(rss) * int(rs[0]["ranks"]) / 1e6 if rss else float("nan")
    bpe = gb * 1e9 / elems if rss else float("nan")
    print(f"{cid:8} {pu:>3} {len(t):>2} {med:9.1f} {100*sd/med:5.1f}% {gb:6.1f} {bpe:7.0f} {med*pu:8.0f}")
    summ[cid] = dict(med=med, sd=sd, pu=pu, bpe=bpe)

fast = min(summ.items(), key=lambda kv: kv[1]["med"])
slow = max(summ.items(), key=lambda kv: kv[1]["med"])
spread = slow[1]["med"] / fast[1]["med"]
worst_sd = max(100*v["sd"]/v["med"] for v in summ.values())

# Sanity floors -- physical bounds, not code inspection. Every measurement
# failure this project has had was a plausible number.
if fast[1]["med"] < 5.0:
    print(f"\n!! fastest median {fast[1]['med']:.1f}s for {elems*20:.2e} element-updates -- implausible")
low = [c for c, v in summ.items() if v["bpe"] == v["bpe"] and v["bpe"] < 600]
if low:
    print(f"\n!! {', '.join(low)} report under 600 B/element; measured floor is ~690. RSS capture suspect.")

print(f"\nSPREAD  {spread:.2f}x  ({fast[0]} {fast[1]['med']:.0f}s -> {slow[0]} {slow[1]['med']:.0f}s)"
      f"   worst sd {worst_sd:.1f}%")

# The equal-core pairs: same cores, work moved from ranks to threads. This is
# the comparison revision 1 could not make.
print("\nEQUAL-CORE PAIRS -- ranks vs threads at fixed core count")
for cores, a, b in (("8", "m08x1", "o01x8"), ("27", "m27x1", "o01x27")):
    if a in summ and b in summ:
        ra, rb = summ[a]["med"], summ[b]["med"]
        db = summ[b]["bpe"] - summ[a]["bpe"]
        print(f"  {cores:>3} cores: {a} {ra:6.1f}s   vs   {b} {rb:6.1f}s"
              f"   ratio {rb/ra:5.2f}x   footprint +{db:.0f} B/elem")
    else:
        print(f"  {cores:>3} cores: incomplete -- one side did not run")
print("  A ratio near 1.0 says the threaded force path costs little here.")
print("  Above ~1.2 says it is a real tax, and the node cannot be filled without paying it.")

print("\nHOW TO READ THIS")
if spread >= 2.0:
    print(f"  {spread:.1f}x -- the prize is real at this size. Proceed to the replicated experiment.")
elif spread >= 1.2 and worst_sd < 5:
    print(f"  {spread:.1f}x against {worst_sd:.1f}% noise -- resolvable, but smaller than round 3's")
    print("  apparent 5x. Raise PASSES for the real runs and expect to need the t-test.")
else:
    print(f"  {spread:.1f}x against {worst_sd:.1f}% noise. THE EXPERIMENT CANNOT DISCRIMINATE HERE.")
    print("  Do not spend agent sessions. Either the size is still wrong, or LULESH is")
    print("  insensitive to the levers the artifact speaks to -- find out which first.")
PY
echo "=================================================================="
echo "csv:  $CSV"
echo "logs: $LOGD"
