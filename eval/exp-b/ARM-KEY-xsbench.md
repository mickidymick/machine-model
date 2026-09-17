# Round 5 arm key — XSBench

Kept **in the repo**, deliberately, for the same reason as `ARM-KEY.md`: the arm
sessions run under `~/scratch`, which cannot reach this file. A key stored next
to the arms would be readable by the sessions it is meant to blind.

| directory | arm | has MACHINE.md |
|---|---|---|
| `~/scratch/xsb-A1` `xsb-A2` `xsb-A3` | **no-artifact** (control) | no |
| `~/scratch/xsb-B1` `xsb-B2` `xsb-B3` | **with-artifact** (treatment) | yes |

Three draws each, separate directories per draw so a later session cannot find
an earlier draw's `SOLUTION.sh` and be contaminated by it. Directory names are
deliberately different from round 4's `arm-A1`… so a stale scratch directory
cannot be mistaken for this round's.

Source: `eval/exp-b/arms/{no-artifact,with-artifact}/xsbench`, built by
`./setup.sh xsbench`, which asserted the two differ by exactly `MACHINE.md`
(verified 2026-09-17).

## Setup state, recorded at creation

- `tools/leakcheck.py machines/frontier-compute.json` — **no CRITICAL**. One
  `xsbench` provenance mention, in `pitfalls[10].evidence[0]`, which is a repo
  path in a field `render.py` does not emit. The rendered briefing contains the
  string `xsbench` **zero** times.
- `problem-xsbench.md` — clean against setup.sh's measurement/repo-path regex.
- Briefing is `prompts/frontier-compute.md`, 714 lines, registry v0.6.
- Round-3 XSBench configs archived to `configs/xsbench-r3/` so they cannot run
  alongside this round. `configs/xsbench/` is empty.

## Collecting

    cp ~/scratch/xsb-A1/SOLUTION.sh eval/exp-b/configs/xsbench/no-artifact-1.sh
    cp ~/scratch/xsb-B1/SOLUTION.sh eval/exp-b/configs/xsbench/with-artifact-1.sh
    ...

## Contamination backstop

Not a substitute for the directory separation, which is the real control. Grep
each collected `SOLUTION.sh` for tells from our own measurements:

    grep -nE '2\.4x|32 MB|32 MiB|8192 PTE|69\.7|78\.2|-5\.0|chase|fma|stream|job [0-9]{6,}' \
      eval/exp-b/configs/xsbench/*.sh

A hit means that draw saw an answer key and is void. A clean grep is weak
evidence, not proof: an agent that read the answer and then justified it from
the source produces reasoning indistinguishable from derivation.
