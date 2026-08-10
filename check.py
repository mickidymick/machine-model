#!/usr/bin/env python3
"""Join a machine descriptor against the claim registry and report on it.

    python3 check.py machines/frontier-compute.json

Three things, in order of how much they matter:

  1. Integrity -- every claim answered, no unknown ids, probe_validated present.
     A probe that never ran produces output indistinguishable from a
     confirmation, so this is checked before anything is reported.
  2. Declaration fidelity -- of the facts this machine declares, how many
     survive measurement? Confirmations count. The profile is the comparable
     quantity across machines, not the individual numbers.
  3. Work queue -- what is untested, confounded, or flagged.
"""
import json, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))

# Verdicts that mean "the machine declared something and we checked it".
# `undeclared` is excluded from fidelity on purpose: it measures the vendor's
# accuracy, and you cannot be inaccurate about a fact you never asserted.
DECLARED_VERDICTS = ('confirmed', 'contradicted', 'misleading',
                     'unfalsifiable_here', 'untested')
GOOD = ('confirmed',)
BAD = ('contradicted', 'misleading')

C = {'ok': '\033[32m', 'bad': '\033[31m', 'warn': '\033[33m',
     'dim': '\033[2m', 'b': '\033[1m', 'r': '\033[0m'}
if not sys.stdout.isatty():
    C = {k: '' for k in C}

MARK = {
    'confirmed': ('ok', 'confirmed'),
    'contradicted': ('bad', 'CONTRADICTED'),
    'misleading': ('warn', 'misleading'),
    'undeclared': ('dim', 'undeclared'),
    'untested': ('warn', 'untested'),
    'unfalsifiable_here': ('warn', 'unfalsifiable'),
    'not_applicable': ('dim', 'n/a'),
}


def load(path):
    with open(path) as f:
        return json.load(f)


def main(argv):
    if len(argv) != 2:
        sys.exit(__doc__)
    reg = load(os.path.join(HERE, 'registry', 'claims.json'))
    desc = load(argv[1])

    claims = {c['id']: c for c in reg['claims']}
    results = {r['claim']: r for r in desc['results']}

    m = desc['machine']
    print(f"\n{C['b']}{m['system']} / {m['node_type']}{C['r']}  "
          f"{C['dim']}{m['facility']}  ---  characterized {m['characterized']}{C['r']}")
    print(f"{C['dim']}registry {reg['registry_version']}  "
          f"schema {desc['schema_version']}  "
          f"nodes sampled: {m.get('node_count', '?')}{C['r']}\n")

    # ---- 1. integrity -------------------------------------------------
    problems = []
    for cid in results:
        if cid not in claims:
            problems.append(f"result for unknown claim id: {cid}")
    for cid, c in claims.items():
        r = results.get(cid)
        if r is None:
            problems.append(f"claim never answered: {cid}")
            continue
        if 'probe_validated' not in r:
            problems.append(f"{cid}: missing probe_validated -- a probe that "
                            f"did not run looks exactly like a confirmation")
        if r.get('verdict') in GOOD and r.get('probe_validated') == 'no':
            problems.append(f"{cid}: verdict '{r['verdict']}' but the probe "
                            f"never validated its own manipulation")
        # An undeclared claim must not carry a declared source, and vice versa.
        declared_in_registry = c.get('declared_source') is not None
        if r.get('verdict') == 'undeclared' and declared_in_registry:
            problems.append(f"{cid}: marked undeclared but the registry names "
                            f"a declaring source")
        # `not_applicable` is the one verdict that removes a claim from scoring
        # entirely, so it has to say why -- otherwise it becomes a place to put
        # anything inconvenient.
        if r.get('verdict') == 'not_applicable' and not r.get('reason'):
            problems.append(f"{cid}: not_applicable without a reason -- the "
                            f"reason is the result")

    if problems:
        print(f"{C['bad']}integrity{C['r']}")
        for p in problems:
            print(f"  ! {p}")
        print()
    else:
        print(f"{C['ok']}integrity ok{C['r']} -- "
              f"{len(claims)} claims, all answered\n")

    # ---- 2. fidelity --------------------------------------------------
    checked = [r for r in results.values()
               if r.get('verdict') in DECLARED_VERDICTS]
    resolved = [r for r in checked if r.get('verdict') in GOOD + BAD]
    good = [r for r in resolved if r['verdict'] in GOOD]
    undeclared = [r for r in results.values()
                  if r.get('verdict') == 'undeclared']

    pct = (100.0 * len(good) / len(resolved)) if resolved else float('nan')
    print(f"{C['b']}declaration fidelity{C['r']}  "
          f"{C['b']}{pct:.0f}%{C['r']}  "
          f"({len(good)} of {len(resolved)} resolved claims survive measurement)")
    print(f"{C['dim']}  {len(undeclared)} facts declared by nothing on the "
          f"machine -- measurement is the only source{C['r']}")
    print(f"{C['dim']}  {len(checked) - len(resolved)} declared claims not yet "
          f"resolved{C['r']}")
    na = [r for r in results.values() if r.get('verdict') == 'not_applicable']
    if na:
        print(f"{C['dim']}  {len(na)} claims have no referent on this machine "
              f"-- absent hardware, not an untested question{C['r']}")
    print()

    # by domain, so "structure reliable / cost a coin flip" is visible
    doms = {}
    for cid, c in claims.items():
        r = results.get(cid, {})
        doms.setdefault(c['domain'], []).append((cid, r.get('verdict', '?')))
    print(f"{C['b']}by domain{C['r']}")
    for dom in sorted(doms):
        rows = doms[dom]
        g = sum(1 for _, v in rows if v in GOOD)
        b = sum(1 for _, v in rows if v in BAD)
        u = sum(1 for _, v in rows if v == 'undeclared')
        na = sum(1 for _, v in rows if v == 'not_applicable')
        bits = []
        if g: bits.append(f"{C['ok']}{g} confirmed{C['r']}")
        if b: bits.append(f"{C['bad']}{b} wrong{C['r']}")
        if u: bits.append(f"{C['dim']}{u} undeclared{C['r']}")
        if na: bits.append(f"{C['dim']}{na} n/a{C['r']}")
        o = len(rows) - g - b - u - na
        if o: bits.append(f"{C['warn']}{o} open{C['r']}")
        print(f"  {dom:<9} {', '.join(bits)}")
    print()

    # ---- claim table --------------------------------------------------
    print(f"{C['b']}claims{C['r']}")
    for cid in claims:
        r = results.get(cid, {})
        v = r.get('verdict', 'missing')
        colour, label = MARK.get(v, ('bad', v))
        conf = r.get('confidence', '')
        pv = r.get('probe_validated', '')
        flag = ''
        if pv == 'no':
            flag = f" {C['warn']}[probe unvalidated]{C['r']}"
        elif pv == 'partial':
            flag = f" {C['warn']}[probe partial]{C['r']}"
        if r.get('confounded'):
            flag += f" {C['warn']}[confounded]{C['r']}"
        print(f"  {C[colour]}{label:<14}{C['r']} {cid:<28} "
              f"{C['dim']}{conf}{C['r']}{flag}")
    print()

    # ---- 3. work queue ------------------------------------------------
    queue = []
    for cid, r in results.items():
        if r.get('verdict') in ('untested', 'unfalsifiable_here'):
            queue.append((cid, r.get('next_step') or 'no next step recorded'))
        elif r.get('probe_validated') in ('no', 'partial') and r.get('verdict') != 'untested':
            queue.append((cid, r.get('probe_gap') or r.get('next_step')
                          or 'probe did not validate its own manipulation'))
    if queue:
        print(f"{C['b']}open work{C['r']}")
        for cid, step in queue:
            print(f"  {C['warn']}*{C['r']} {cid}\n    {C['dim']}{step}{C['r']}")
        print()

    flagged = desc.get('flagged', [])
    if flagged:
        print(f"{C['b']}flagged -- visible, deliberately not asserted{C['r']}")
        for f in flagged:
            print(f"  {C['dim']}~{C['r']} {f['id']}: {f['statement'][:88]}...")
            print(f"    {C['dim']}promote when: {f.get('promotion_criteria','-')}{C['r']}")
        print()

    oq = desc.get('open_questions', [])
    if oq:
        print(f"{C['b']}open questions{C['r']}")
        for q in oq:
            print(f"  {C['dim']}?{C['r']} {q}")
        print()

    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
