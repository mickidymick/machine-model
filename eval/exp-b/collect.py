#!/usr/bin/env python3
"""Summarise an Experiment B run.

    python3 eval/exp-b/collect.py results/amg_20260811_101500.csv

Reports median wall clock per config, the spread across passes, and -- the
number that actually matters -- what fraction of the floor-to-ceiling headroom
each arm recovered.

A raw percentage between two arms is close to meaningless on its own: 8% could
be most of what was available or a rounding error. The floor (naive default) and
ceiling (hand-tuned with everything the project knows) bracket the range, and
the arms are placed inside it.
"""
import csv, sys, statistics as st
from collections import defaultdict

def main(path):
    rows = list(csv.DictReader(open(path)))
    if not rows:
        sys.exit("no rows")

    # Verification first. A config that did not get its resources produced a
    # plausible number that means nothing, and averaging it in hides that.
    bad = [r for r in rows if r.get('exit') not in ('0', None, '')]
    if bad:
        print("!! non-zero exits -- these runs are not measurements:")
        for r in bad:
            print(f"   pass {r['pass']} {r['config']} exit={r['exit']}")
        print()

    by = defaultdict(list)
    for r in rows:
        if r.get('exit') == '0':
            by[r['config']].append(float(r['seconds']))

    if not by:
        sys.exit("no successful runs")

    med = {k: st.median(v) for k, v in by.items()}
    print(f"{'config':<16}{'n':>3}{'median s':>11}{'min':>10}{'max':>10}{'spread':>9}")
    for k in sorted(med, key=med.get):
        v = by[k]
        spread = max(v) - min(v)
        print(f"  {k:<14}{len(v):>3}{med[k]:>11.2f}{min(v):>10.2f}{max(v):>10.2f}"
              f"{spread:>9.2f}")

    floor, ceil = med.get('floor'), med.get('ceiling')
    print()
    if floor is None or ceil is None:
        print("  No floor/ceiling pair -- cannot express results as headroom recovered.")
        print("  Raw ratios between arms are hard to interpret without that scale.")
        return

    span = floor - ceil
    print(f"headroom: floor {floor:.2f}s -> ceiling {ceil:.2f}s  "
          f"({span:.2f}s, {100*span/floor:.1f}% of floor)")
    if span <= 0:
        print("  Ceiling is not faster than floor. Either the tuning does not help on")
        print("  this benchmark, or something is wrong with the configs. Stop here.")
        return

    print()
    for arm in ('no-artifact', 'with-artifact'):
        if arm not in med:
            continue
        rec = (floor - med[arm]) / span
        print(f"  {arm:<16}{med[arm]:>8.2f}s   recovered {100*rec:>6.1f}% of headroom")

    if 'no-artifact' in med and 'with-artifact' in med:
        a, b = med['no-artifact'], med['with-artifact']
        # Is the gap bigger than the noise it sits in?
        noise = max(max(by['no-artifact']) - min(by['no-artifact']),
                    max(by['with-artifact']) - min(by['with-artifact']))
        gap = a - b
        print()
        print(f"  artifact effect: {gap:+.2f}s ({100*gap/a:+.1f}%), "
              f"worst across-pass spread {noise:.2f}s")
        if abs(gap) < 2 * noise:
            print("  -> gap is within 2x the run-to-run spread. Report as NULL, not")
            print("     as a small win. More passes would be needed to resolve it.")
        else:
            print(f"  -> gap is {abs(gap)/noise:.1f}x the spread.")

if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
