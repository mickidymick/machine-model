# Round 4 arm key — LULESH

Kept **in the repo**, deliberately. The arm sessions run under `~/scratch`,
which cannot reach this file. A key stored next to the arms would be readable by
the sessions it is meant to blind.

| directory | arm | has MACHINE.md |
|---|---|---|
| `~/scratch/arm-A1` `arm-A2` `arm-A3` | **no-artifact** (control) | no |
| `~/scratch/arm-B1` `arm-B2` `arm-B3` | **with-artifact** (treatment) | yes |

Three draws each. Separate directories per draw so a later session cannot find
an earlier draw's `SOLUTION.sh` and be contaminated by it.

Verified at creation: MACHINE.md present in all three B, absent in all three A;
no `.git`, no results files, no answer key anywhere under `~/scratch`.

Source: `eval/exp-b/arms/{no-artifact,with-artifact}/lulesh`, built by
`setup.sh lulesh`, which asserts the two differ by exactly MACHINE.md.

## Collecting

    cp ~/scratch/arm-A1/SOLUTION.sh eval/exp-b/configs/lulesh/no-artifact-1.sh
    cp ~/scratch/arm-B1/SOLUTION.sh eval/exp-b/configs/lulesh/with-artifact-1.sh
    ...

**Clear the round-3 configs out of `configs/lulesh/` first.** They target
729,000 elements and would run alongside these and fail the equal-work gate.

## Contamination backstop

Not a substitute for the directory separation, which is the real control. Grep
each collected SOLUTION.sh for tells:

    grep -nE 'm64x1|o27x2|o27x4|m27x1|m08x1|o08x7|spread|114\.6|5359372|5349696' \
      eval/exp-b/configs/lulesh/*.sh

Any hit means that draw saw the answer key and is void. A clean grep is weak
evidence, not proof: an agent that read the answer and then justified it from
the source produces reasoning indistinguishable from derivation.
