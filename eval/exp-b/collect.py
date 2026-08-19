#!/usr/bin/env python3
"""Summarise an Experiment B run.

    python3 eval/exp-b/collect.py results/amg_20260813_101500.csv [--svg out.svg]

Method follows ZeroSum (Huck & Malony, SC-W 2023, sec 4.1), which is the closest
published precedent for this comparison: run each condition ~10x in the SAME
allocation, report mean +/- std, and decide with a t-test rather than by eyeing
a ratio of single runs. Their baseline was 27.3396 +/- 0.0358 s against
27.3395 +/- 0.1043 s -- a 0.13% run-to-run std -- and that resolution is what
let them call a 0.5% effect real (p=0.0006) and a 0.07 s difference null
(p=0.998).

That precision matters here. Round 1 showed BOTH arms relinking for huge pages,
so the artifact-only levers that remain are placement-sized. An n=3 design
cannot tell a 3% win from noise, and reporting one would be worse than
reporting nothing.

Results are placed on a four-point ladder -- floor, no-artifact, with-artifact,
ceiling -- because a bare percentage between two arms is uninterpretable. In
ZeroSum's own ladder a single missing `-c` flag was worth 2.33x while refined
thread binding was worth nothing measurable; the position on the ladder is the
result, not the pairwise delta.

No scipy: this has to run on a login node.
"""
import csv, sys, math, statistics as st
from collections import defaultdict

LADDER = ('floor', 'no-artifact', 'with-artifact', 'ceiling')


# ---------------------------------------------------------------- statistics
def _betacf(a, b, x, itmax=200, eps=3e-16, fpmin=1e-300):
    """Continued fraction for the incomplete beta function (Lentz's method)."""
    qab, qap, qam = a + b, a + 1.0, a - 1.0
    c = 1.0
    d = 1.0 - qab * x / qap
    if abs(d) < fpmin:
        d = fpmin
    d = 1.0 / d
    h = d
    for m in range(1, itmax + 1):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        if abs(d) < fpmin:
            d = fpmin
        c = 1.0 + aa / c
        if abs(c) < fpmin:
            c = fpmin
        d = 1.0 / d
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        if abs(d) < fpmin:
            d = fpmin
        c = 1.0 + aa / c
        if abs(c) < fpmin:
            c = fpmin
        d = 1.0 / d
        de = d * c
        h *= de
        if abs(de - 1.0) < eps:
            break
    return h


def _betai(a, b, x):
    """Regularized incomplete beta I_x(a, b)."""
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    lbeta = (math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
             + a * math.log(x) + b * math.log1p(-x))
    if x < (a + 1.0) / (a + b + 2.0):
        return math.exp(lbeta) * _betacf(a, b, x) / a
    return 1.0 - math.exp(lbeta) * _betacf(b, a, 1.0 - x) / b


def welch(xs, ys):
    """Welch's unequal-variance t-test. Returns (t, dof, two-sided p).

    Welch rather than Student because the arms are not guaranteed equal
    variance -- in ZeroSum's own data the instrumented condition was ~3x noisier
    than the baseline, and assuming equal variance there would have been wrong.
    """
    nx, ny = len(xs), len(ys)
    if nx < 2 or ny < 2:
        return None, None, None
    mx, my = st.mean(xs), st.mean(ys)
    vx, vy = st.variance(xs), st.variance(ys)
    sx, sy = vx / nx, vy / ny
    denom = sx + sy
    if denom <= 0:
        return None, None, None
    t = (mx - my) / math.sqrt(denom)
    dof = denom ** 2 / ((sx ** 2 / (nx - 1)) + (sy ** 2 / (ny - 1)))
    p = _betai(0.5 * dof, 0.5, dof / (dof + t * t))
    return t, dof, p


# ------------------------------------------------------------------- loading
def load(path):
    try:
        rows = list(csv.DictReader(open(path)))
    except FileNotFoundError:
        sys.exit(f"no such CSV: {path}\n"
                 "  Runs write results/<bench>_<stamp>.csv; rebuilds write\n"
                 "  results/rebuilt/<bench>_<stamp>.csv. Name the stamp explicitly --\n"
                 "  `ls -t` once picked a stale rebuild over a queued run's output.")
    if not rows:
        sys.exit("no rows in " + path)

    # Verification first. A config that did not get its cores, huge pages or
    # GPUs produced a plausible number that means nothing, and averaging it in
    # hides exactly that.
    bad = [r for r in rows if (r.get('exit') or '0') != '0']
    if bad:
        print("!! non-zero exits -- these runs are NOT measurements:")
        for r in bad:
            print(f"   pass {r['pass']:>3} {r['config']:<16} exit={r['exit']}")
        print()

    # Prefer AMG's own reported solve time over the harness stopwatch. The
    # stopwatch also contains module loads, srun launch overhead and the setup
    # phase -- none of which any config is trying to improve, and the module
    # cost is asymmetric (only huge-page configs pay it). ZeroSum likewise
    # reported "the application reported execution time".
    use_solve = any((r.get('solve_s') or 'NA') != 'NA' for r in rows)
    field = 'solve_s' if use_solve else 'seconds'
    missing = 0

    by = defaultdict(list)
    meta = defaultdict(set)
    for r in rows:
        if (r.get('exit') or '0') == '0':
            raw = r.get(field) or 'NA'
            if raw == 'NA':
                missing += 1
                continue
            by[r['config']].append(float(raw))
            if r.get('work') and r['work'] != 'NA':
                meta[(r['config'], 'work')].add(r['work'])
            for k in ('ranks', 'threads'):
                if r.get(k) and r[k] != 'NA':
                    meta[(r['config'], k)].add(r[k])
    if not by:
        sys.exit("no successful runs")

    if use_solve:
        print("timing source: application-reported time (setup and launch excluded)")
    else:
        print("timing source: HARNESS WALL CLOCK -- no solve_s column found.")
        print("  This includes module loads, srun launch and AMG's setup phase.")
        print("  The module cost falls only on huge-page configs, so it biases")
        print("  AGAINST the configs expected to be fastest. Treat small gaps")
        print("  with suspicion until the parser is fixed.")
    if missing:
        print(f"  !! {missing} successful run(s) had no parsable time and were dropped.")
        print("     A run that succeeded but printed no timing is a parser bug,")
        print("     not a data point -- check the .log before trusting the rest.")
    print()
    return by, meta


def check_equal_work(by, meta):
    """Did every config do the SAME AMOUNT OF WORK?

    This is the check round 1 did not have. Both arms produced defensible
    configurations that solved problems 14x apart, and nothing in the harness
    noticed -- the timings would have been compared anyway and the artifact arm
    would have "won" by an order of magnitude. miniQMC reports MPI ranks and
    walkers per rank, so the work is recoverable from the run itself rather than
    from anyone's intentions.
    """
    works = {c: meta.get((c, 'work'), set()) for c in by}
    known = {c: w for c, w in works.items() if w}
    if not known:
        print("EQUAL WORK: not verifiable -- no work column in this CSV.")
        print("  For AMG this is expected (it does not self-report its grid);")
        print("  the spec is the only guarantee. For miniQMC it means the runs")
        print("  produced no 'MPI processes' line, which is what a QMC_MPI=0")
        print("  serial build looks like. Check a .log before comparing.")
        print()
        return True
    allvals = set()
    for w in known.values():
        allvals |= w
    ok = len(allvals) == 1
    print("EQUAL WORK CHECK" + ("  -- OK, all configs did " + allvals.pop() +
          " units" if ok else "  -- *** MISMATCH ***"))
    if not ok:
        for c in sorted(known):
            print(f"    {c:<16} {','.join(sorted(known[c]))}")
        print("  The configs did DIFFERENT amounts of work. Wall-clock between")
        print("  them is meaningless -- do not report a comparison from this")
        print("  run. Fix the spec so total work cannot vary, and regenerate")
        print("  the arms. This is exactly what voided round 1.")
    missing = [c for c in works if not works[c]]
    if missing:
        print(f"  (no work reported for: {', '.join(sorted(missing))})")
    print()
    return ok


def report_manipulation(by, meta):
    """Did each config actually get what it asked for, on every pass?"""
    print("verification -- what the APPLICATION reported it ran with")
    print(f"  {'config':<16}{'ranks':>8}{'threads':>10}")
    for cfg in sorted(by):
        rk = ','.join(sorted(meta.get((cfg, 'ranks'), {'?'})))
        th = ','.join(sorted(meta.get((cfg, 'threads'), {'?'})))
        flag = ''
        if len(meta.get((cfg, 'ranks'), set())) > 1 or \
           len(meta.get((cfg, 'threads'), set())) > 1:
            flag = '  <- VARIED ACROSS PASSES, investigate before comparing'
        print(f"  {cfg:<16}{rk:>8}{th:>10}{flag}")
    print()


# ------------------------------------------------------------------- reports
def main(path, svg_out=None):
    # Name the source file and its age. The previous run analysed a stale
    # rebuilt CSV because `ls -t` matched it, and nothing in the output said
    # which file had been read, so the numbers looked like a fresh result.
    import os, time
    try:
        mtime = time.strftime('%Y-%m-%d %H:%M',
                              time.localtime(os.path.getmtime(path)))
        print(f"source: {path}   (written {mtime})")
    except OSError as e:
        # A provenance line must never be the thing that kills the tool, and a
        # missing file deserves load()'s message rather than a stat traceback.
        print(f"source: {path}   (stat failed: {e.strerror})")
    by, meta = load(path)
    work_ok = check_equal_work(by, meta)
    report_manipulation(by, meta)

    stats = {}
    for k, v in by.items():
        stats[k] = dict(n=len(v), mean=st.mean(v),
                        sd=st.stdev(v) if len(v) > 1 else 0.0,
                        lo=min(v), hi=max(v), med=st.median(v))

    print(f"  {'config':<16}{'n':>3}{'mean s':>10}{'sd':>8}{'sd %':>7}"
          f"{'min':>9}{'max':>9}")
    for k in sorted(stats, key=lambda c: stats[c]['mean']):
        s = stats[k]
        sdpct = 100 * s['sd'] / s['mean'] if s['mean'] else 0
        print(f"  {k:<16}{s['n']:>3}{s['mean']:>10.2f}{s['sd']:>8.3f}"
              f"{sdpct:>6.2f}%{s['lo']:>9.2f}{s['hi']:>9.2f}")
    print()

    tight = [k for k in stats if stats[k]['mean'] and
             100 * stats[k]['sd'] / stats[k]['mean'] > 2.0]
    if tight:
        print("  NOTE: run-to-run sd exceeds 2% for: " + ', '.join(sorted(tight)))
        print("  ZeroSum saw 0.13% on Frontier. A spread this wide means the")
        print("  allocation is noisy or the config is not getting stable")
        print("  resources -- check the verification table before trusting any")
        print("  comparison below.")
        print()

    # ---- the ladder ----
    floor, ceil = stats.get('floor'), stats.get('ceiling')
    print("ladder")
    for k in LADDER:
        if k not in stats:
            continue
        s = stats[k]
        bar = ''
        if floor and ceil and floor['mean'] > ceil['mean']:
            frac = (floor['mean'] - s['mean']) / (floor['mean'] - ceil['mean'])
            bar = f"   {100*frac:>6.1f}% of headroom"
        print(f"  {k:<16}{s['mean']:>9.2f} +/- {s['sd']:<6.3f}{bar}")
    print()

    if not floor or not ceil:
        print("  No floor/ceiling pair -- cannot express results as headroom.")
    elif floor['mean'] <= ceil['mean']:
        print("  Ceiling is NOT faster than floor. Either the tuning does not")
        print("  help on this benchmark at this size, or a config is broken.")
        print("  The experiment cannot discriminate anything. Stop here.")
    else:
        span = floor['mean'] - ceil['mean']
        print(f"  total headroom: {floor['mean']:.2f}s -> {ceil['mean']:.2f}s "
              f"= {span:.2f}s ({100*span/floor['mean']:.1f}% of floor)")
        t, dof, p = welch(by['floor'], by['ceiling'])
        if p is not None:
            print(f"  floor vs ceiling: t={t:.2f}, dof={dof:.1f}, p={p:.2e}"
                  f"{'  (significant)' if p < 0.05 else '  (NOT significant)'}")
        print()
        print("  For scale, ZeroSum's ladder on miniQMC: 63.67s default ->")
        print("  27.33s with `-c 7` (2.33x, one flag) -> 27.40s with thread")
        print("  binding on top (null). Most of their headroom sat in one")
        print("  documented flag, and the refinement above it measured nothing.")
    print()

    # ---- the arm comparison, which is the actual question ----
    a, b = 'no-artifact', 'with-artifact'
    if a in by and b in by and not work_ok:
        _report_decomposition(stats, by)
        print("ARM COMPARISON: SUPPRESSED -- the arms did different amounts of")
        print("work (see the equal-work check above). A number here would be")
        print("read as a result, so none is printed.")
    elif a in by and b in by:
        t, dof, p = welch(by[a], by[b])
        gap = stats[a]['mean'] - stats[b]['mean']
        pct = 100 * gap / stats[a]['mean']
        print("ARM COMPARISON  (positive = with-artifact faster)")
        print(f"  {a}   {stats[a]['mean']:.2f} +/- {stats[a]['sd']:.3f}  (n={stats[a]['n']})")
        print(f"  {b} {stats[b]['mean']:.2f} +/- {stats[b]['sd']:.3f}  (n={stats[b]['n']})")
        print(f"  difference: {gap:+.2f}s ({pct:+.1f}%)")
        if p is None:
            # welch() also returns None when BOTH groups have zero variance,
            # which is not a sample-size problem and pointing at n sends the
            # reader to the wrong place. It happened when a parser read a
            # 2-significant-figure field and flattened every pass to one value.
            if stats[a]['sd'] == 0 and stats[b]['sd'] == 0:
                print("  ZERO VARIANCE in both arms -- every pass reported an identical")
                print("  value. On a shared machine that is a parsing artefact, not a")
                print("  measurement. Check what field the parser is reading before")
                print("  believing the difference.")
            else:
                print("  Too few runs for a t-test. Need n>=2 per arm; ZeroSum used 10.")
        else:
            print(f"  Welch t={t:.3f}, dof={dof:.1f}, p={p:.4g}")
            if p < 0.05:
                faster = b if gap > 0 else a
                print(f"  -> SIGNIFICANT at p<0.05. {faster} is faster.")
                if floor and ceil and floor['mean'] > ceil['mean']:
                    frac = abs(gap) / (floor['mean'] - ceil['mean'])
                    print(f"     The gap is {100*frac:.1f}% of total headroom -- report it")
                    print("     as a position on the ladder, not as a bare percentage.")
                print("     Attribution is NOT established: the two configs differ in")
                print("     several dimensions at once. Which fact caused this needs a")
                print("     one-knob-at-a-time follow-up before any causal claim.")
            else:
                print("  -> NULL at p<0.05. Report as null, not as a small win.")
                print("     ZeroSum reported exactly this outcome for thread binding")
                print("     (27.33 vs 27.40 s) and said only that a longer-running")
                print("     application might differ. That is the honest form.")
                mde = 2.8 * math.sqrt(stats[a]['sd']**2/stats[a]['n']
                                      + stats[b]['sd']**2/stats[b]['n'])
                print(f"     With this spread and n, the smallest detectable effect is")
                print(f"     about {mde:.2f}s ({100*mde/stats[a]['mean']:.1f}%). A real effect below that")
                print("     would not have shown up -- say so rather than claiming zero.")
    else:
        print("ARM COMPARISON: both arms not present in this CSV.")

    _report_decomposition(stats, by)

    if svg_out:
        write_svg(stats, svg_out)
        print(f"\nwrote {svg_out}")


def _report_decomposition(stats, by):
    """Isolate `-t coarse`, which only the with-artifact arm passes.

    That flag drops miniQMC's per-electron timer instrumentation. It is an
    APPLICATION knob, not machine knowledge, and the arm itself estimated it at
    "a couple of percent" -- the same order as the placement effect under test.
    Without subtracting it, a win cannot be attributed to the artifact at all.
    """
    a, b, c = 'no-artifact', 'with-artifact', 'no-artifact-hugepages'
    if c not in stats or a not in stats:
        return
    print()
    print("DECOMPOSITION -- isolating craype-hugepages2M")
    print("  The arms converged on the same geometry (8x7x7), the same -t coarse,")
    print("  the same -march=znver3 and the same compiler. They differ on huge")
    print("  pages: no-artifact CONSIDERED AND REJECTED the module (\"bandwidth-")
    print("  bound, not TLB-latency-bound... payoff is small\"); with-artifact took")
    print("  it, citing the measured 2.4x penalty at a ~32 MB working set.")
    print()
    eff = stats[a]['mean'] - stats[c]['mean']
    t, dof, p = welch(by[a], by[c])
    print(f"  no-artifact            {stats[a]['mean']:.2f} +/- {stats[a]['sd']:.3f}")
    print(f"  no-artifact+hugepages  {stats[c]['mean']:.2f} +/- {stats[c]['sd']:.3f}")
    print(f"  huge pages alone are worth: {eff:+.2f}s ({100*eff/stats[a]['mean']:+.1f}%)"
          + (f"   p={p:.4g}" if p is not None else ""))
    if b not in stats:
        return
    gap = stats[a]['mean'] - stats[b]['mean']
    print()
    print(f"  full arm gap                 {gap:+.2f}s ({100*gap/stats[a]['mean']:+.1f}%)")
    print(f"  explained by huge pages      {eff:+.2f}s ({100*eff/max(abs(gap),1e-9):.0f}% of the gap)")
    resid = gap - eff
    print(f"  residual (everything else)   {resid:+.2f}s")
    tr, dr, pr = welch(by[c], by[b])
    if pr is not None:
        print(f"  residual: Welch t={tr:.3f}, dof={dr:.1f}, p={pr:.4g}"
              f"{'  SIGNIFICANT' if pr < 0.05 else '  NULL'}")
        if pr >= 0.05 and p is not None and p < 0.05:
            print("  -> The gap is the huge-page decision and nothing else. The")
            print("     artifact's contribution on this benchmark is ONE measured")
            print("     fact, and that is exactly what should be claimed.")
        elif pr < 0.05:
            print("  -> Something beyond huge pages also differs (OMP_PLACES, BLAS")
            print("     linkage). Do not attribute the residual without isolating it.")


# ----------------------------------------------------------------------- svg
def write_svg(stats, path):
    """Horizontal ladder, one measure, error bars at +/- 1 sd.

    Deliberately one axis: seconds. Nothing is plotted against a second scale.
    """
    order = [k for k in LADDER if k in stats]
    if not order:
        return
    W, rowh, pad_l, pad_r, pad_t = 720, 46, 132, 96, 54
    H = pad_t + rowh * len(order) + 30
    vmax = max(s['mean'] + s['sd'] for s in stats.values()) * 1.08
    plot_w = W - pad_l - pad_r

    # One hue for magnitude; the two arms carry the accent, references stay grey.
    def fill(k):
        return {'floor': '#9aa3ae', 'ceiling': '#9aa3ae',
                'no-artifact': '#6a8cc7', 'with-artifact': '#2f5c9e'}[k]

    p = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" '
         f'width="100%" role="img" aria-label="Experiment B ladder">',
         '<style>'
         '.lbl{font:13px system-ui,sans-serif;fill:#3b4048}'
         '.val{font:600 13px system-ui,sans-serif;fill:#22262b}'
         '.ax{font:11px system-ui,sans-serif;fill:#6b7280}'
         '.ttl{font:600 14px system-ui,sans-serif;fill:#22262b}'
         '@media (prefers-color-scheme:dark){'
         '.lbl{fill:#c2c8d0}.val{fill:#eceff3}.ttl{fill:#eceff3}.ax{fill:#98a1ad}}'
         '</style>',
         f'<text class="ttl" x="12" y="24">AMG on Frontier — wall clock, '
         f'mean ± 1 sd</text>']

    for i, k in enumerate(order):
        s = stats[k]
        y = pad_t + i * rowh
        w = plot_w * s['mean'] / vmax
        p.append(f'<text class="lbl" x="{pad_l-10}" y="{y+18}" '
                 f'text-anchor="end">{k}</text>')
        p.append(f'<rect x="{pad_l}" y="{y+4}" width="{w:.1f}" height="20" '
                 f'rx="4" fill="{fill(k)}"/>')
        if s['sd'] > 0:
            e = plot_w * s['sd'] / vmax
            x0, x1 = pad_l + w - e, pad_l + w + e
            p.append(f'<line x1="{x0:.1f}" x2="{x1:.1f}" y1="{y+14}" y2="{y+14}" '
                     f'stroke="#22262b" stroke-opacity=".55" stroke-width="1.5"/>')
            for xx in (x0, x1):
                p.append(f'<line x1="{xx:.1f}" x2="{xx:.1f}" y1="{y+9}" y2="{y+19}" '
                         f'stroke="#22262b" stroke-opacity=".55" stroke-width="1.5"/>')
        p.append(f'<text class="val" x="{pad_l+w+14:.1f}" y="{y+19}">'
                 f'{s["mean"]:.1f}s</text>')

    ybase = pad_t + rowh * len(order)
    p.append(f'<line x1="{pad_l}" x2="{W-pad_r}" y1="{ybase}" y2="{ybase}" '
             f'stroke="#c9ced6"/>')
    for frac in (0, .25, .5, .75, 1.0):
        x = pad_l + plot_w * frac
        p.append(f'<text class="ax" x="{x:.0f}" y="{ybase+16}" '
                 f'text-anchor="middle">{vmax*frac:.0f}</text>')
    p.append('</svg>')
    open(path, 'w').write('\n'.join(p))


if __name__ == '__main__':
    args = [a for a in sys.argv[1:]]
    svg = None
    if '--svg' in args:
        i = args.index('--svg')
        svg = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        sys.exit(__doc__)
    main(args[0], svg)
