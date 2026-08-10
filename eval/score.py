#!/usr/bin/env python3
"""Score the two-arm machine-knowledge evaluation and emit a chart.

    python3 eval/score.py                       # terminal report
    python3 eval/score.py --html eval/results.html

Reads eval/answers_control.json and eval/answers_treatment.json, each:

    { "model": "...", "date": "...", "session": "fresh|...",
      "scores": { "q01": {"outcome": "correct", "note": "..."}, ... } }

outcome is one of: correct | hedged | wrong | confidently_wrong

Two figures, because there are two different results:

  HERO    confidently-wrong count per arm. The number a user would act on and
          be wrong about. Ignorance is recoverable; a confident wrong answer is
          not, because nothing prompts the user to check.

  CHART   correct-rate per question category. This is the more honest figure:
          it shows measurement does NOT help everywhere. It helps precisely
          where the declaration is misleading or silent, and the docs_sufficient
          bars should be level. If they are not, the control was built badly.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))

OUTCOMES = ['correct', 'hedged', 'wrong', 'confidently_wrong']

# `hedged` is a success ONLY where declining IS the right answer -- the honesty
# questions, which have no verified answer on either side.
#
# Counting it as success everywhere hid most of the 2026-08-10 result: on the
# measurement_only questions the control hedged (honest, but the user still
# leaves without an answer) while the treatment answered correctly, and both
# scored 4/4. Honest-and-unhelpful is not the same outcome as helpful.
SUCCESS = ('correct',)
HEDGE_OK_CATEGORIES = ('honesty',)


def is_success(outcome, category):
    if outcome in SUCCESS:
        return True
    return outcome == 'hedged' and category in HEDGE_OK_CATEGORIES

CATS = ['docs_sufficient', 'docs_misleading', 'measurement_only', 'honesty']
CAT_LABEL = {
    'docs_sufficient': 'Docs sufficient',
    'docs_misleading': 'Docs misleading',
    'measurement_only': 'Measurement only',
    'honesty': 'Neither knows',
}

C = {'ok': '\033[32m', 'bad': '\033[31m', 'warn': '\033[33m',
     'dim': '\033[2m', 'b': '\033[1m', 'r': '\033[0m'}
if not sys.stdout.isatty():
    C = {k: '' for k in C}


def load():
    qs = json.load(open(os.path.join(HERE, 'questions.json')))
    # `web` is optional -- it was added after the first pass. Order matters:
    # the arms form a ladder of increasing effort and should read left to right.
    arms = {}
    for arm in ('web', 'control', 'treatment'):
        p = os.path.join(HERE, f'answers_{arm}.json')
        if not os.path.exists(p):
            if arm == 'web':
                continue
            sys.exit(f"missing {p}\n\n"
                     f"Run eval/build_prompts.py, answer each arm in a SEPARATE\n"
                     f"fresh session, and record the outcomes there.")
        arms[arm] = json.load(open(p))
    return qs, arms


def tally(qs, arms):
    by_q = {q['id']: q for q in qs['questions']}
    out = {}
    for arm, data in arms.items():
        rec = {'outcomes': {o: 0 for o in OUTCOMES},
               'by_cat': {c: {'n': 0, 'ok': 0} for c in CATS},
               'per_q': {}}
        for qid, q in by_q.items():
            s = data['scores'].get(qid)
            if not s:
                sys.exit(f"{arm}: no score recorded for {qid}")
            o = s['outcome']
            if o not in OUTCOMES:
                sys.exit(f"{arm}/{qid}: unknown outcome {o!r}")
            rec['outcomes'][o] += 1
            cat = q['category']
            rec['by_cat'][cat]['n'] += 1
            if is_success(o, cat):
                rec['by_cat'][cat]['ok'] += 1
            rec['per_q'][qid] = o
        out[arm] = rec
    return by_q, out


def report(qs, arms, by_q, t):
    n = len(by_q)
    print(f"\n{C['b']}machine-knowledge evaluation{C['r']}  "
          f"{C['dim']}{qs['machine']}, {n} questions{C['r']}")
    for arm, data in arms.items():
        print(f"{C['dim']}  {arm:<10} {data.get('model','?')}, "
              f"{data.get('date','?')}{C['r']}")
    print()

    print(f"{C['b']}outcomes{C['r']}")
    print(f"  {'':<18}" + ''.join(f"{a:>18}" for a in t))
    for o in OUTCOMES:
        row = f"  {o:<18}"
        for arm in t:
            v = t[arm]['outcomes'][o]
            col = 'bad' if o == 'confidently_wrong' and v else \
                  'ok' if o in SUCCESS else 'warn'
            row += f"{C[col]}{v:>18}{C['r']}"
        print(row)
    print()

    cw = {a: t[a]['outcomes']['confidently_wrong'] for a in t}
    print(f"{C['b']}headline{C['r']}  confidently wrong:  " + ',  '.join(
        f"{a} {C['bad'] if cw[a] else C['ok']}{cw[a]}{C['r']}" for a in t)
        + f"  {C['dim']}of {n}{C['r']}")
    print(f"{C['dim']}  These are answers a user would act on without being "
          f"prompted to check.{C['r']}\n")

    print(f"{C['b']}correct rate by category{C['r']}")
    print(f"  {'category':<20}" + ''.join(f"{a:>14}" for a in t))
    for c in CATS:
        row = f"  {CAT_LABEL[c]:<20}"
        for arm in t:
            d = t[arm]['by_cat'][c]
            row += f"{d['ok']:>8}/{d['n']:<5}" if d['n'] else f"{'-':>14}"
        print(row)
    print(f"\n{C['dim']}  'Docs sufficient' should be level. If the treatment "
          f"wins there too, the\n  control was built badly and the whole result "
          f"is suspect.{C['r']}\n")

    # per-question detail, so a disagreement can be inspected
    print(f"{C['b']}per question{C['r']}")
    for qid in sorted(by_q):
        q = by_q[qid]
        cells = ''
        for arm in t:
            o = t[arm]['per_q'][qid]
            col = 'ok' if is_success(o, q['category']) else \
                  'bad' if o == 'confidently_wrong' else 'warn'
            cells += f"{C[col]}{o:<19}{C['r']}"
        print(f"  {qid}  {q['category']:<18}{cells}")
    print()


# --------------------------------------------------------------------- chart
HTML = """<!doctype html>
<meta charset="utf-8">
<title>Machine-knowledge evaluation — {machine}</title>
<style>
  :root {{ color-scheme: light; }}
  .viz-root {{
    --surface-1:#fcfcfb; --plane:#f9f9f7;
    --text-primary:#0b0b0b; --text-secondary:#52514e; --muted:#898781;
    --grid:#e1e0d9; --axis:#c3c2b7; --border:rgba(11,11,11,.10);
    --control:#2a78d6; --treatment:#eb6834; --critical:#d03b3b; --good:#0ca30c;
  }}
  @media (prefers-color-scheme: dark) {{
    :root:where(:not([data-theme="light"])) {{ color-scheme: dark; }}
    :root:where(:not([data-theme="light"])) .viz-root {{
      --surface-1:#1a1a19; --plane:#0d0d0d;
      --text-primary:#fff; --text-secondary:#c3c2b7; --muted:#898781;
      --grid:#2c2c2a; --axis:#383835; --border:rgba(255,255,255,.10);
      --control:#3987e5; --treatment:#d95926; --critical:#d03b3b; --good:#0ca30c;
    }}
  }}
  :root[data-theme="dark"] {{ color-scheme: dark; }}
  :root[data-theme="dark"] .viz-root {{
    --surface-1:#1a1a19; --plane:#0d0d0d;
    --text-primary:#fff; --text-secondary:#c3c2b7; --muted:#898781;
    --grid:#2c2c2a; --axis:#383835; --border:rgba(255,255,255,.10);
    --control:#3987e5; --treatment:#d95926; --critical:#d03b3b; --good:#0ca30c;
  }}
  body {{ margin:0; background:var(--plane); }}
  .viz-root {{
    font:15px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif;
    color:var(--text-primary); max-width:860px; margin:0 auto; padding:32px 20px 64px;
  }}
  h1 {{ font-size:21px; margin:0 0 4px; letter-spacing:-.01em; }}
  p.sub {{ color:var(--text-secondary); font-size:14px; margin:0 0 4px; }}
  .card {{ background:var(--surface-1); border:1px solid var(--border);
          border-radius:10px; padding:18px; margin-top:18px; }}
  h2 {{ font-size:15px; margin:0 0 2px; }}
  .note {{ color:var(--muted); font-size:12.5px; margin:8px 0 0; }}
  .hero {{ display:flex; gap:36px; flex-wrap:wrap; margin-top:6px; }}
  .hero div {{ min-width:130px; }}
  .hero .v {{ font-size:40px; font-weight:650; letter-spacing:-.02em; line-height:1.05; }}
  .hero .k {{ font-size:12.5px; color:var(--text-secondary); margin-top:2px; }}
  .legend {{ display:flex; gap:16px; font-size:13px; color:var(--text-secondary);
            margin:0 0 6px; flex-wrap:wrap; }}
  .legend span {{ display:inline-flex; align-items:center; gap:6px; }}
  .sw {{ width:11px; height:11px; border-radius:3px; }}
  svg {{ display:block; width:100%; height:auto; overflow:visible; }}
  text {{ font:11.5px system-ui,sans-serif; fill:var(--text-secondary); }}
  text.val {{ font-weight:650; fill:var(--text-primary); font-variant-numeric:tabular-nums; }}
  table {{ border-collapse:collapse; font-size:12.5px; margin-top:12px; width:100%; }}
  th,td {{ border:1px solid var(--border); padding:4px 8px; text-align:right; }}
  th {{ color:var(--text-secondary); font-weight:600; }}
  td:first-child, th:first-child {{ text-align:left; }}
</style>
<div class="viz-root">
<h1>Does measured cost change what a model knows about the machine?</h1>
<p class="sub">{machine} &middot; {n} questions &middot; both arms generated from the
same descriptor, so the only difference between them is measurement.</p>
<p class="note">Control = what the machine declares about itself (ACPI SLIT, hwloc,
rocm-smi, vendor diagram, facility notes). The control is additionally given
operational notes that were in fact discovered by measurement &mdash; more than a real
user would have &mdash; which biases against the treatment arm.</p>

<div class="card">
  <h2>Answers a user would act on and be wrong about</h2>
  <p class="note" style="margin-top:2px">Confidently wrong: incorrect, stated as fact,
  with no hedge. Ignorance is recoverable because it prompts the user to check. This
  does not.</p>
  <div class="hero">
    <div><div class="v" style="color:var(--critical)">{cw_control}</div>
         <div class="k">control &mdash; declared only</div></div>
    <div><div class="v" style="color:var(--good)">{cw_treatment}</div>
         <div class="k">treatment &mdash; measured briefing</div></div>
  </div>
</div>

<div class="card">
  <h2>Where measurement actually helps</h2>
  <p class="note" style="margin-top:2px">Success rate per question category. Declining
  to answer counts as success where neither arm can know.</p>
  <div class="legend">
    <span><i class="sw" style="background:var(--control)"></i>control</span>
    <span><i class="sw" style="background:var(--treatment)"></i>treatment</span>
  </div>
  {chart}
  <p class="note">If the treatment also won on <b>docs sufficient</b>, the control was
  built badly and the rest of this figure would not be trustworthy.</p>
  {table}
</div>
</div>
"""


def svg_chart(t):
    W, H = 800, 300
    padl, padr, padt, padb = 44, 12, 14, 54
    pw = W - padl - padr
    ph = H - padt - padb
    ncat = len(CATS)
    slot = pw / ncat
    bw = min(46, slot / 3.2)
    gap = 2                      # surface gap between adjacent bars

    s = [f'<svg viewBox="0 0 {W} {H}" role="img" '
         f'aria-label="Success rate by question category, control versus treatment">']

    for frac in (0, .25, .5, .75, 1):
        y = padt + ph - frac * ph
        s.append(f'<line x1="{padl}" y1="{y:.1f}" x2="{W-padr}" y2="{y:.1f}" '
                 f'stroke="var(--grid)" stroke-width="1"/>')
        s.append(f'<text x="{padl-8}" y="{y+4:.1f}" text-anchor="end">'
                 f'{int(frac*100)}%</text>')

    arms = list(t.keys())
    for i, c in enumerate(CATS):
        cx = padl + slot * (i + .5)
        for j, arm in enumerate(arms):
            d = t[arm]['by_cat'][c]
            if not d['n']:
                continue
            frac = d['ok'] / d['n']
            h = frac * ph
            x = cx - (len(arms) * bw + (len(arms) - 1) * gap) / 2 + j * (bw + gap)
            y = padt + ph - h
            col = f'var(--arm-{j})'
            # 4px rounded data-end, square foot on the baseline
            r = min(4, h)
            s.append(
                f'<path d="M{x:.1f},{padt+ph:.1f} V{y+r:.1f} '
                f'q0,-{r:.1f} {r:.1f},-{r:.1f} H{x+bw-r:.1f} '
                f'q{r:.1f},0 {r:.1f},{r:.1f} V{padt+ph:.1f} Z" fill="{col}"/>')
            s.append(f'<text class="val" x="{x+bw/2:.1f}" y="{y-6:.1f}" '
                     f'text-anchor="middle">{d["ok"]}/{d["n"]}</text>')
        s.append(f'<text x="{cx:.1f}" y="{padt+ph+20:.1f}" '
                 f'text-anchor="middle">{CAT_LABEL[c]}</text>')

    s.append(f'<line x1="{padl}" y1="{padt+ph}" x2="{W-padr}" y2="{padt+ph}" '
             f'stroke="var(--axis)" stroke-width="1"/>')
    s.append('</svg>')
    return '\n'.join(s)


def svg_table(t):
    rows = ['<table><tr><th>category</th><th>control</th><th>treatment</th></tr>']
    for c in CATS:
        a = t['control']['by_cat'][c]
        b = t['treatment']['by_cat'][c]
        rows.append(f"<tr><td>{CAT_LABEL[c]}</td>"
                    f"<td>{a['ok']}/{a['n']}</td><td>{b['ok']}/{b['n']}</td></tr>")
    rows.append('</table>')
    return '\n'.join(rows)


def main(argv):
    qs, arms = load()
    by_q, t = tally(qs, arms)
    report(qs, arms, by_q, t)

    if '--html' in argv:
        out = argv[argv.index('--html') + 1]
        html = HTML.format(
            machine=qs['machine'], n=len(by_q),
            cw_control=t['control']['outcomes']['confidently_wrong'],
            cw_treatment=t['treatment']['outcomes']['confidently_wrong'],
            cw_web=t.get('web', {}).get('outcomes', {}).get('confidently_wrong', '--'),
            chart=svg_chart(t), table=svg_table(t))
        with open(out, 'w') as f:
            f.write(html)
        print(f"wrote {out}")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
