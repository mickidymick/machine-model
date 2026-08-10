#!/usr/bin/env python3
"""Render the CONTROL arm: everything the machine declares about itself.

    python3 render_declared.py machines/frontier-compute.json > prompts/frontier-declared.md

This is the experimental control for "does the measured artifact help?".

The naive control is an empty context, and it proves nothing -- of course a
model handed a document about a machine answers questions about that machine
better than a model handed nothing. The honest control is **what a competent
user could already obtain without measuring**: the ACPI SLIT, hwloc's relay of
it, the vendor node diagram, `rocm-smi`, the facility spec sheet.

Generating it from the same descriptor guarantees the only difference between
the two arms is measurement. Nothing is paraphrased into or out of existence,
and the control cannot be accused of being a strawman built to lose: every
declared value here is real, current, and exactly what the machine will tell you
if you ask it.

Where the declaration is wrong, it is reproduced wrong. That is the point.
"""
import json, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))

out = []
def w(s=''):
    out.append(s)


def scalar(v):
    if isinstance(v, bool):
        return 'yes' if v else 'no'
    if isinstance(v, float):
        return f'{v:g}'
    return str(v)


def flatten(v, depth=0):
    pad = '  ' * depth
    if isinstance(v, dict):
        for k, val in v.items():
            label = k.replace('_', ' ')
            if isinstance(val, list) and val and all(
                    not isinstance(x, (dict, list)) for x in val):
                w(f'{pad}- **{label}**: {", ".join(scalar(x) for x in val)}')
            elif isinstance(val, (dict, list)):
                w(f'{pad}- **{label}**:')
                flatten(val, depth + 1)
            else:
                w(f'{pad}- **{label}**: {scalar(val)}')
    elif isinstance(v, list):
        for item in v:
            if isinstance(item, dict):
                if all(not isinstance(x, (dict, list)) for x in item.values()):
                    w(f'{pad}- ' + ', '.join(
                        f'{k.replace("_", " ")} {scalar(x)}'
                        for k, x in item.items()))
                else:
                    w(f'{pad}-')
                    flatten(item, depth + 1)
            else:
                w(f'{pad}- {scalar(item)}')
    else:
        w(f'{pad}- {scalar(v)}')


def main(argv):
    if len(argv) != 2:
        sys.exit(__doc__)
    reg = json.load(open(os.path.join(HERE, 'registry', 'claims.json')))
    d = json.load(open(argv[1]))
    claims = {c['id']: c for c in reg['claims']}
    m = d['machine']

    w(f"# {m['system']} ({m['node_type']} node) — system documentation")
    w()
    w(f"{m['facility']}.")
    w()
    w(f"- **CPU**: {m['cpu']}")
    w(f"- **Memory**: {m['memory']}")
    w(f"- **Accelerator**: {m['accelerator']}")
    w(f"- **Network**: {m['network']}")
    w()
    w('The following is what the system reports about itself through its '
      'standard interfaces — the ACPI tables, `hwloc`, `numactl`, vendor query '
      'tools and the facility documentation. This is the information available '
      'to any user on the machine.')
    w()

    # Group by domain so it reads like documentation rather than a checklist.
    by_domain = {}
    for r in d['results']:
        c = claims.get(r['claim'])
        if not c:
            continue
        dec = r.get('declared')
        if not dec:
            continue                      # nothing is declared about this
        if r.get('verdict') == 'not_applicable':
            continue                      # absent hardware
        by_domain.setdefault(c['domain'], []).append((c, r, dec))

    titles = {
        'cpu': 'Processor', 'numa': 'Memory topology', 'gpu': 'Accelerators',
        'memory': 'Memory configuration', 'network': 'Network',
    }
    for dom in ('cpu', 'numa', 'gpu', 'memory', 'network'):
        rows = by_domain.get(dom)
        if not rows:
            continue
        w(f"## {titles.get(dom, dom)}")
        w()
        for c, r, dec in rows:
            w(f"### {c['declares'].rstrip('.')}")
            w()
            src = dec.get('source') or dec.get('primary') or 'system interface'
            w(f"*Reported by: {src}*")
            w()
            body = {k: v for k, v in dec.items()
                    if k not in ('source', 'note', 'implication')}
            if body:
                flatten(body, 0)
                w()
            if dec.get('implication'):
                w(dec['implication'])
                w()
            if dec.get('note'):
                w(dec['note'])
                w()

    # Pitfalls are facility documentation, not measurement, so a well-informed
    # user could have them. Withholding them would build a strawman.
    # ONLY provenance == 'documented'. The rest were discovered by our own
    # measurement campaign, and handing them to the control means the control is
    # running on our results relabelled as documentation. That over-supply is
    # what made q05 untenable as a docs_misleading question in the 2026-08-10 run.
    docs = [p for p in d.get('pitfalls', [])
            if p.get('provenance') == 'documented']
    if docs:
        w('## Known operational notes')
        w()
        w('_Published by the facility or readable from the machine with standard '
          'tools._')
        w()
        for p in docs:
            pid = p.get('id', '')
            w(f"**{pid}** — {p.get('symptom','')} {p.get('cause','')} "
              f"{p.get('remedy','')}")
            w()
        skipped = len(d.get('pitfalls', [])) - len(docs)
        if skipped:
            w(f"_{skipped} further operational note(s) exist in the descriptor but "
              f"were discovered by measurement and are withheld from this "
              f"rendering._")
            w()

    w('---')
    w()
    w(f"Compiled from the declared topology of `{os.path.basename(argv[1])}`. "
      f"No performance measurements were taken; all values are as reported by "
      f"the system and its documentation.")

    print('\n'.join(out))


if __name__ == '__main__':
    main(sys.argv)
