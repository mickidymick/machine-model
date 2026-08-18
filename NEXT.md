# Pick up here — 2026-08-19

Written at the end of 2026-08-18. Everything below is committed and pushed on
both `machine-model` and `frontier`.

---

## 1. RUN THESE FIRST — all built, tested, independent

```bash
cd ~/Projects/frontier && git pull
sbatch -A CSC617 slurm/smt.sbatch          # 1 node,  25 min
sbatch -A CSC617 slurm/collectives.sbatch  # 16 nodes, 35 min
sbatch -A CSC617 slurm/storage.sbatch      # 4 nodes,  50 min (-C nvme in header)
~/Projects/machine-model/tools/jobs.sh -w
```

Then analyse:
```bash
python3 - <<'ANALYSE'
ANALYSE
# smt + storage print their own analysis at the end of the job output.
python3 scripts/18_fabric_report.py results-frontier/fabric_*/pairs.csv   # if rerun
```

**What each asks, and what would falsify it**

| job | question | falsifier |
|---|---|---|
| smt | does a 2nd hardware thread per core help? | all three kernels agree → the regime framing was wrong |
| collectives | does cost scale the same in size and in rank count? | same shape both ways → one number would have sufficed |
| storage | does bandwidth step at the declared 256 KiB and 8 MiB boundaries? | no step → the layout is declared but not observable, a `confirmed` verdict |

Storage also compares node-local NVMe against Lustre, and default layout against
`lfs setstripe -c 8` at 1 GiB.

---

## 2. FOLD RESULTS INTO THE ARTIFACT

Each job produces a claim. They are NOT yet in `registry/claims.json`:
`cpu.smt_benefit`, `cost.collective_scaling`, `cost.storage_bands`,
`cost.queue_wait`, `net.fabric_locality`, `cost.fabric_distance`.

`storage.tier_inventory` IS in (registry 0.4) and answered.

Every new claim must be born with `measured_under`, `not_measured`,
`mechanism`, and `regime_variables` as a LIST. `check.py` flags any claim
carrying a physical quantity without conditions.

---

## 3. OUTSTANDING, ROUGHLY BY VALUE

- **Re-run Experiment B with the regime-aware briefing.** Same benchmark
  (miniQMC), same everything, only the artifact's form changed. Prediction to
  pre-register: the treatment arm DECLINES huge pages, because the briefing now
  says "NOT measured: streaming" before it shows the 2.4x. This is the direct
  test of the fix, on the exact case that broke.
- **Node-to-node variability.** Still the biggest credibility gap; every number
  in the artifact is one node. 8-16 short jobs.
- **Fabric follow-ups.** Two pairs measured 3.47 us against a 3.68 mode —
  identify them (`awk -F, 'NR>1 && $9<3.55 {print $4,$5,$6,$7,$9}'`). Then
  repeat runs for coverage, one at low occupancy, one `--switches=1` for the
  near baseline.
- **XSBench**, pre-registered as the regime test. Random binary search is the
  access pattern the 2.4x was actually measured under.
- **corsys4 conditions retrofit** — `check.py` flags 6 claims there.
- **Registry pin.** Frontier answered against 0.1, registry is now 0.4. Diff
  what changed across those revisions before bumping; bumping without re-reading
  would launder a stale pin.
- **HSA_XNACK** — the one knob gap not built. Needs new HIP code.
- **Effect sizes / knob sensitivity** — Jeff deferred this deliberately. The
  idea: measure the best-to-worst spread of each knob so the artifact can say
  where a reader should spend attention, not only what a number is. Two rows
  already exist (huge pages -2.7%..+2.4x; NIC policy 0.13%).

---

## 4. THINGS THAT WILL BITE AGAIN

- **Always pass `-o` to sbatch.** A `--wrap` job's default output could not be
  found afterwards. Every committed script sets it.
- **`$HOME` is NFS, `/tmp` is RAM.** Never benchmark I/O in either.
- **Check `build_all.sh`'s hash table** before submitting a timed job — it exits
  1 if any binary is missing, but read the hashes too.
- Probes that report impossible numbers have appeared three times now (14 PB/s,
  5.9x from a missing fsync, a 64x false positive on flat data). Sanity-check
  every new probe against a physical ceiling before trusting it.
