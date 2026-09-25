#!/usr/bin/env python3
"""Fold lulesh-regions per-rank fragments into one per-phase profile.

    merge.py [regions.d] [--whole profile-lulesh-t7.json] [--peak-mbps 178084]

GROUND-TRUTH ONLY -- output describes the test application. Never into
machines/*.json, never into an arm.

Node-level numbers per region: counts are summed over ranks and threads; time is
the MEAN over ranks (ranks run the phases in lockstep, coupled by MPI), so
bandwidth = node bytes / region seconds. bytes are data-cache fills from system
and are a LOWER BOUND, exactly as in profile_wrap -- fraction_of_peak is a floor.

Checks, each of which makes the profile untrustworthy on failure:
  - every rank enabled, same thread identity throughout, full team, no read errors
  - every region entered exactly once per time step (the markers partition it)
  - regions' seconds sum to LULESH's own elapsed time
  - with --whole: region counts sum to profile_wrap's independent whole-run
    counts (a separate run, and it includes setup, so within 10%, not equal)
"""
import json, glob, os, sys, argparse

ap = argparse.ArgumentParser()
ap.add_argument("dir", nargs="?", default=os.environ.get("RG_OUTDIR", "./regions.d"))
ap.add_argument("--whole", help="profile_wrap profile.json of the same config")
ap.add_argument("--peak-mbps", type=float, default=178084)
ap.add_argument("--json", default="regions.json")
a = ap.parse_args()

frags = [json.load(open(p)) for p in sorted(glob.glob(os.path.join(a.dir, "rank*.json")))]
if not frags:
    sys.exit(f"merge: no fragments in {a.dir}")
LINE = 64
keys = frags[0]["keys"]
K = {k: i for i, k in enumerate(keys)}
names = [r["name"] for r in frags[0]["regions"]]
nthr = frags[0]["threads"]
steps = frags[0]["timesteps"]

checks, warn = {}, []
checks["all_ranks_enabled"] = all(f["enabled"] for f in frags)
for f in frags:
    if not f["enabled"]:
        warn.append(f"rank {f['rank']} disabled: {f['why_disabled']}")
checks["thread_identity_stable"] = all(f["thread_identity_stable"] for f in frags)
checks["full_team_every_read"] = all(f["full_team_every_read"] for f in frags)
checks["no_read_errors"] = not any(f["read_errors"] for f in frags)
checks["same_threads_and_steps_on_every_rank"] = all(
    f["threads"] == nthr and f["timesteps"] == steps for f in frags)
bad_calls = [(f["rank"], r["name"], r["calls"]) for f in frags for r in f["regions"]
             if r["calls"] != steps]
checks["each_region_once_per_step"] = not bad_calls
if bad_calls:
    warn.append(f"regions not entered once per step ({steps}): {bad_calls[:5]}")

elapsed = sum(f["elapsed_seconds"] for f in frags) / len(frags)
covered = sum(sum(r["seconds"] for r in f["regions"]) for f in frags) / len(frags)
checks["regions_cover_elapsed"] = abs(covered / elapsed - 1) < 0.02 if elapsed else False

rows, tot = [], [0] * len(keys)
for j, name in enumerate(names):
    sec = sum(f["regions"][j]["seconds"] for f in frags) / len(frags)
    s = [0] * len(keys); m = [0] * len(keys); w_ins = []
    for f in frags:
        pt = f["regions"][j]["per_thread"]
        for t, vals in enumerate(pt):
            for e, v in enumerate(vals):
                s[e] += v
                if t == 0: m[e] += v
            if t > 0: w_ins.append(vals[K["instructions"]])
    for e in range(len(keys)): tot[e] += s[e]
    ins, cyc = s[K["instructions"]], s[K["cycles"]]
    fills = s[K["dram_fills_local"]] + s[K["dram_fills_remote"]]
    mbps = fills * LINE / sec / 1e6 if sec else 0
    ranks = len(frags)
    rows.append({
        "region": name,
        "seconds": round(sec, 4),
        "share_of_loop": round(sec / covered, 4) if covered else None,
        "ipc": round(ins / cyc, 3) if cyc else None,
        "ipc_master": round(m[K["instructions"]] / m[K["cycles"]], 3) if m[K["cycles"]] else None,
        # cycles per thread-second: near the clock where every thread is busy
        # (or spinning); well below it where threads were descheduled.
        "ghz_per_thread": round(cyc / (sec * nthr * ranks) / 1e9, 2) if sec else None,
        # worker imbalance: max/mean instructions over non-master threads. Spin
        # instructions inflate idle threads, so this UNDERSTATES imbalance.
        "worker_ins_max_over_mean": (round(max(w_ins) / (sum(w_ins) / len(w_ins)), 2)
                                     if w_ins and sum(w_ins) else None),
        "dram_MB_per_s": round(mbps, 1),
        "fraction_of_peak_floor": round(mbps / a.peak_mbps, 3),
        "remote_fill_fraction": round(s[K["dram_fills_remote"]] / fills, 4) if fills else None,
        "dtlb_mpki": round(s[K["dtlb_load_misses"]] / ins * 1000, 3) if ins else None,
        "raw": dict(zip(keys, s)),
    })

out = {"ranks": len(frags), "threads": nthr, "timesteps": steps,
       "elapsed_seconds": round(elapsed, 3), "regions_seconds": round(covered, 3),
       "bytes_from_dram_is": "a LOWER BOUND -- see profile_wrap; fraction_of_peak_floor is a floor",
       "regions": sorted(rows, key=lambda r: -r["seconds"])}

if a.whole:
    w = json.load(open(a.whole))
    wh = {"instructions": w["cpu"]["instructions"], "cycles": w["cpu"]["cycles"],
          "dram_fills": w["memory"]["dram_fills_local"] + w["memory"]["dram_fills_remote"]}
    mine = {"instructions": tot[K["instructions"]], "cycles": tot[K["cycles"]],
            "dram_fills": tot[K["dram_fills_local"]] + tot[K["dram_fills_remote"]]}
    ratio = {k: round(mine[k] / wh[k], 3) for k in wh if wh[k]}
    out["closure_vs_whole_run"] = ratio
    checks["closes_against_whole_run"] = all(0.90 <= r <= 1.10 for r in ratio.values())
    out["whole_run_seconds"] = w["wall_seconds"]

out["checks"] = checks
out["warnings"] = warn
out["trustworthy"] = all(checks.values()) and not warn
json.dump(out, open(a.json, "w"), indent=2)

if not checks["all_ranks_enabled"]:
    # Nothing was counted, so there is no table to print -- only the reason.
    for x in warn: print("WARNING:", x)
    sys.exit(f"merge: instrumentation disabled on some rank; wrote {a.json}, trustworthy=False")

print(f"{len(frags)} ranks x {nthr} threads, {steps} steps, loop {elapsed:.2f} s "
      f"(regions cover {covered:.2f} s)")
if "closure_vs_whole_run" in out:
    print(f"closure vs whole-run profile: {out['closure_vs_whole_run']}")
print(f"\n{'region':<17}{'sec':>8}{'share':>7}{'IPC':>6}{'IPCm':>6}{'GHz/t':>6}"
      f"{'imbal':>6}{'GB/s':>7}{'peak>=':>7}{'TLBmpki':>8}")
for r in out["regions"]:
    f = lambda v, fmt: format(v, fmt) if v is not None else "-"
    print(f"{r['region']:<17}{r['seconds']:>8.2f}{f(r['share_of_loop'], '>7.1%')}"
          f"{f(r['ipc'], '>6.2f')}{f(r['ipc_master'], '>6.2f')}{f(r['ghz_per_thread'], '>6.2f')}"
          f"{f(r['worker_ins_max_over_mean'], '>6.2f')}{r['dram_MB_per_s'] / 1000:>7.1f}"
          f"{r['fraction_of_peak_floor']:>7.1%}{f(r['dtlb_mpki'], '>8.3f')}")
print(f"\nchecks: {checks}")
for x in warn: print("WARNING:", x)
print(f"wrote {a.json}  trustworthy={out['trustworthy']}")
sys.exit(0 if out["trustworthy"] else 1)
