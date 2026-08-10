#!/usr/bin/env python3
"""Compare machine descriptors against each other.

    python3 compare.py machines/*.json

One machine tells you that machine is misdescribed. Several tell you whether
that is a property of a vendor, of a firmware table, or of the industry -- and
whether the registry's questions are portable at all. Four sections:

  1. Fidelity      -- the headline number per machine, side by side.
  2. Claim matrix  -- every claim x every machine.
  3. Agreements    -- claims that land the same way everywhere. A claim
                      contradicted on unrelated hardware from different vendors
                      is the strongest result the method can produce.
  4. Divergences   -- claims that land differently. Each is a question:
                      what about these machines differs?

`not_applicable` is never a divergence. A GPU claim is absent on a CPU-only box
because the hardware is absent, which is a fact about the machine, not a
disagreement between machines.
"""
import json, sys, os
from collections import OrderedDict

HERE = os.path.dirname(os.path.abspath(__file__))
GOOD = ('confirmed',)
BAD = ('contradicted', 'misleading')
RESOLVED = GOOD + BAD
SKIP = ('not_applicable',)

C = {'ok': '\033[32m', 'bad': '\033[31m', 'warn': '\033[33m',
     'dim': '\033[2m', 'b': '\033[1m', 'r': '\033[0m'}
if not sys.stdout.isatty():
    C = {k: '' for k in C}

SHORT = {
    'confirmed': ('ok', 'ok'),
    'contradicted': ('bad', 'WRONG'),
    'misleading': ('warn', 'mislead'),
    'undeclared': ('dim', 'undecl'),
    'untested': ('warn', 'untest'),
    'unfalsifiable_here': ('warn', 'unfals'),
    'not_applicable': ('dim', '--'),
}


def cell(v, w):
    colour, label = SHORT.get(v, ('bad', str(v)[:w]))
    return f"{C[colour]}{label:<{w}}{C['r']}"


def main(argv):
    paths = argv[1:]
    if len(paths) < 2:
        sys.exit("usage: compare.py <descriptor.json> <descriptor.json> [...]\n"
                 "       (at least two)")

    reg = json.load(open(os.path.join(HERE, 'registry', 'claims.json')))
    claims = OrderedDict((c['id'], c) for c in reg['claims'])

    machines = []
    for p in paths:
        d = json.load(open(p))
        machines.append({
            'name': d['machine']['id'],
            'system': d['machine']['system'],
            'desc': d,
            'res': {r['claim']: r for r in d['results']},
        })

    names = [m['name'] for m in machines]
    w = max(max(len(n) for n in names), 8)

    print(f"\n{C['b']}machine-model: cross-machine comparison{C['r']}  "
          f"{C['dim']}registry {reg['registry_version']}, "
          f"{len(machines)} machines, {len(claims)} claims{C['r']}\n")

    # ---- 1. fidelity ---------------------------------------------------
    print(f"{C['b']}declaration fidelity{C['r']}")
    print(f"  {'machine':<{w}}  {'fidelity':>9}  {'resolved':>9}  "
          f"{'undeclared':>11}  {'n/a':>5}  {'open':>5}")
    for m in machines:
        vals = [r.get('verdict') for r in m['res'].values()]
        resolved = [v for v in vals if v in RESOLVED]
        good = [v for v in resolved if v in GOOD]
        undecl = sum(1 for v in vals if v == 'undeclared')
        na = sum(1 for v in vals if v == 'not_applicable')
        openn = len(vals) - len(resolved) - undecl - na
        pct = (100.0 * len(good) / len(resolved)) if resolved else float('nan')
        col = 'bad' if pct < 50 else 'warn' if pct < 75 else 'ok'
        print(f"  {m['name']:<{w}}  {C[col]}{pct:8.0f}%{C['r']}  "
              f"{len(good):>4}/{len(resolved):<4}  {undecl:>11}  "
              f"{na:>5}  {openn:>5}")
    print(f"\n{C['dim']}  Fidelity counts only claims the machine actually "
          f"declares and a probe resolved.\n"
          f"  `undeclared` is excluded -- a vendor cannot be inaccurate about a "
          f"fact it never asserted.\n"
          f"  `n/a` is excluded -- the hardware is absent.{C['r']}\n")

    # ---- 2. claim matrix -----------------------------------------------
    print(f"{C['b']}claim matrix{C['r']}")
    cw = max(len(c) for c in claims) + 2
    hdr = ' ' * cw + ''.join(f"{n:<{w+2}}" for n in names)
    print(f"  {C['dim']}{hdr}{C['r']}")
    for cid in claims:
        row = f"  {cid:<{cw}}"
        for m in machines:
            v = m['res'].get(cid, {}).get('verdict', 'missing')
            row += cell(v, w + 2)
        print(row)
    print()

    # ---- 3. agreements --------------------------------------------------
    # A claim resolved the same way on every machine that could answer it.
    agree_bad, agree_good = [], []
    for cid in claims:
        vs = [m['res'].get(cid, {}).get('verdict') for m in machines]
        answering = [v for v in vs if v not in SKIP and v is not None]
        if len(answering) < 2:
            continue
        if all(v in BAD for v in answering):
            agree_bad.append((cid, answering))
        elif all(v in GOOD for v in answering):
            agree_good.append((cid, answering))

    if agree_bad:
        print(f"{C['b']}wrong everywhere{C['r']}  "
              f"{C['dim']}-- the strongest result the method produces{C['r']}")
        for cid, vs in agree_bad:
            print(f"  {C['bad']}{cid}{C['r']}  ({', '.join(vs)})")
            src = None
            for m in machines:
                d = m['res'].get(cid, {}).get('declared') or {}
                src = src or d.get('source')
            if src:
                print(f"    {C['dim']}declared by: {src}{C['r']}")
        # Section-level, not a property of the last claim printed.
        vendors = {m['desc']['machine'].get('cpu', '?').split(',')[0]
                   for m in machines}
        if len(vendors) > 1:
            print()
            print(f"  {C['b']}across unrelated hardware:{C['r']}")
            for v in sorted(vendors):
                print(f"    {v}")
            print(f"  {C['b']}-> not a vendor defect. a defect in the "
                  f"mechanism they share.{C['r']}")
        print()

    if agree_good:
        print(f"{C['b']}right everywhere{C['r']}  "
              f"{C['dim']}-- the control. without these, the above is "
              f"just complaining{C['r']}")
        for cid, vs in agree_good:
            print(f"  {C['ok']}{cid}{C['r']}")
        print()

    # ---- 4. divergences -------------------------------------------------
    div = []
    for cid in claims:
        pairs = [(m['name'], m['res'].get(cid, {}).get('verdict'))
                 for m in machines]
        answering = [(n, v) for n, v in pairs if v not in SKIP and v is not None]
        if len(answering) < 2:
            continue
        kinds = {v for _, v in answering}
        if len(kinds) > 1 and any(v in RESOLVED for _, v in answering):
            div.append((cid, answering))

    if div:
        print(f"{C['b']}divergences{C['r']}  "
              f"{C['dim']}-- each one is a question: what differs?{C['r']}")
        for cid, answering in div:
            print(f"  {cid}")
            for n, v in answering:
                colour, label = SHORT.get(v, ('bad', v))
                print(f"    {C[colour]}{label:<8}{C['r']} {n}")
            for m in machines:
                r = m['res'].get(cid, {})
                if r.get('verdict') in RESOLVED and r.get('margin'):
                    print(f"    {C['dim']}{m['name']}: "
                          f"{r['margin'][:96]}{C['r']}")
        print()

    # ---- registry portability ------------------------------------------
    answered_everywhere = sum(
        1 for cid in claims
        if all(m['res'].get(cid, {}).get('verdict') not in (None, 'missing')
               for m in machines))
    print(f"{C['b']}registry portability{C['r']}")
    print(f"  {answered_everywhere}/{len(claims)} claims carry a verdict on "
          f"every machine")
    na_counts = {m['name']: sum(1 for r in m['res'].values()
                                if r.get('verdict') == 'not_applicable')
                 for m in machines}
    for n, c in na_counts.items():
        if c:
            print(f"  {C['dim']}{n}: {c} claims have no referent "
                  f"(absent hardware){C['r']}")
    print(f"  {C['dim']}The registry moved between these machines unchanged. "
          f"Empty slots are\n  expected and meaningful, not gaps.{C['r']}")
    print()
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
