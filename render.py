#!/usr/bin/env python3
"""Render a machine descriptor into an LLM-consumable briefing.

    python3 render.py machines/frontier-compute.json > prompts/frontier-compute.md

One renderer among several possible ones. The contract it has to honour:

  * Lead with the corrected value where declared and measured disagree, but keep
    the declared value visible -- a consumer reasoning about why other tools give
    different advice needs to see what those tools were told.
  * Never flatten `flagged` into an assertion. Those entries are leads.
  * Carry conditions with every number. A value without its page size, thread
    count, or link count is not reusable.
  * State the limits explicitly. A briefing that does not say what it cannot
    support invites confident extrapolation past the data.
"""
import json, sys, os

HERE = os.path.dirname(os.path.abspath(__file__))
BAD = ('contradicted', 'misleading')
OPEN = ('untested', 'unfalsifiable_here')

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
    """Render a heterogeneous measured/declared block as indented bullets.

    v0.1 leaves these blocks free-form, which is why this is generic rather
    than typed -- see the note at the end of README. Constraining the shape is
    a v0.2 job; until then, print faithfully rather than guess at semantics.
    """
    pad = '  ' * depth
    if isinstance(v, dict):
        for k, val in v.items():
            label = k.replace('_', ' ')
            # A list of plain scalars is a set of values, not a structure --
            # inline it rather than burning eight lines on a core mask.
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
                # inline one-liner for small records, nested otherwise
                if all(not isinstance(x, (dict, list)) for x in item.values()):
                    bits = ', '.join(f'{k.replace("_", " ")} {scalar(x)}'
                                     for k, x in item.items())
                    w(f'{pad}- {bits}')
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

    # ---------------------------------------------------------------- header
    w(f"# Machine briefing: {m['system']} ({m['node_type']} node)")
    w()
    w(f"{m['facility']}. Characterized {m['characterized']}.")
    w()
    w(f"- **CPU**: {m['cpu']}")
    w(f"- **Memory**: {m['memory']}")
    w(f"- **Accelerator**: {m['accelerator']}")
    w(f"- **Network**: {m['network']}")
    w()

    # -------------------------------------------------------- reading rules
    w('## How to use this document')
    w()
    w('This is a **measured** description of one node type, not a spec sheet. '
      'Where the machine\'s own topology interfaces (hwloc, ACPI tables, vendor '
      'query tools) disagree with measurement, the measured value is given first '
      'and the declared value is shown alongside it, because other tools on this '
      'system are still acting on the declared one.')
    w()
    w('Rules for reasoning with what follows:')
    w()
    w('1. **Do not upgrade a hedge.** Items under *Unverified* and *Leads* are '
      'not established. Do not present them as facts, and do not build a '
      'recommendation whose correctness depends on them.')
    w('2. **Conditions are part of every number.** A latency measured on 4K '
      'pages, or a bandwidth measured across one of four network links, does not '
      'generalise to other conditions. The conditions are stated; carry them.')
    w('3. **Regime-dependent costs are not scalars.** Several costs here change '
      'sign or magnitude with working-set size, offered load, or message size. '
      'Answer with the regime, not an average.')
    w('4. **Say when the answer is not in here.** This document covers one node '
      'type and, for topology, effectively one node. If a question needs data it '
      'does not contain, say so rather than interpolating.')
    w()
    w(f"**Measurement provenance.** {m['tool_validation']}")
    w()
    w(f"**Coverage.** {m['coverage_caveat']}")
    w()

    # ------------------------------------------------- corrections (headline)
    wrong = [r for r in d['results'] if r.get('verdict') in BAD]
    if wrong:
        w('## Where this machine misdescribes itself')
        w()
        w('Read this section before acting on any topology query you run '
          'yourself, or on any advice derived from vendor documentation.')
        w()
        for r in wrong:
            c = claims[r['claim']]
            w(f"### {(c['declares'] or r['claim']).rstrip('.')}")
            w()
            w(f"`{r['claim']}` — **{r['verdict']}**"
              f"{' (confidence: ' + r['confidence'] + ')' if r.get('confidence') else ''}")
            w()
            dec = r.get('declared') or {}
            src = dec.get('source', 'declared source')
            w(f"**Declared** ({src}):")
            flatten({k: v for k, v in dec.items() if k != 'source'}, 0)
            w()
            if r.get('measured') is not None:
                w('**Measured**:')
                flatten(r['measured'], 0)
                w()
            if r.get('margin'):
                w(f"**Margin**: {r['margin']}")
                w()
            cons = r.get('consequence') or c.get('consequence_if_wrong')
            if cons:
                w(f"**What goes wrong if you trust the declared value**: {cons}")
                w()
            for key, label in (('conditions_caveat', 'Conditions'),
                               ('working_path', 'Working path'),
                               ('secondary_defect', 'Further complication'),
                               ('probe_gap', 'Probe incomplete'),
                               ('note', 'Note')):
                if r.get(key):
                    w(f"**{label}**: {r[key]}")
                    w()

    # ------------------------------------------------------------- confirmed
    good = [r for r in d['results'] if r.get('verdict') == 'confirmed']
    if good:
        w('## What the machine reports accurately')
        w()
        w('These may be trusted from the system\'s own interfaces. Listed so a '
          'consumer knows which queries are reliable here, not only which are not.')
        w()
        for r in good:
            c = claims[r['claim']]
            src = (r.get('declared') or {}).get('source', '')
            w(f"**{c['declares'].rstrip('.')}** — `{r['claim']}`"
              f"{' via ' + src if src else ''}. {r.get('margin','')}")
            if r.get('measured') is not None:
                flatten(r['measured'], 0)
            if r.get('note'):
                w(f"  - _{r['note']}_")
            w()

    # ------------------------------------------------ regime-dependent costs
    undecl = [r for r in d['results'] if r.get('verdict') == 'undeclared'
              and not r.get('confounded')]
    if undecl:
        w('## Costs that nothing on the machine reports')
        w()
        w('No topology interface, table, or spec sheet carries these. They are '
          'measurement-only, and most are **curves rather than single values** — '
          'the cost depends on a named regime variable. Answer with the regime.')
        w()
        for r in undecl:
            c = claims[r['claim']]
            w(f"### {r['claim']}")
            w()
            w(c['why_it_matters'])
            w()
            flatten(r['measured'], 0)
            w()
            if r.get('margin'):
                w(f"**Shape**: {r['margin']}")
                w()
            for key, label in (('consequence', 'Consequence'),
                               ('control', 'Control'),
                               ('practical', 'Practical reading'),
                               ('cross_validation', 'Cross-validation'),
                               ('note', 'Note'),
                               ('open', 'Open'),
                               ('not_measured', 'Not measured')):
                if r.get(key):
                    w(f"**{label}**: {r[key]}")
                    w()

    # --------------------------------------------------------------- gotchas
    if d.get('pitfalls'):
        w('## Operational pitfalls')
        w()
        w('Each of these presents as something other than its cause. Symptom, '
          'cause, remedy.')
        w()
        for p in d['pitfalls']:
            w(f"**{p['id']}**")
            w(f"- Symptom: {p['symptom']}")
            w(f"- Cause: {p['cause']}")
            w(f"- Remedy: {p['remedy']}")
            if p.get('sting'):
                w(f"- Further: {p['sting']}")
            w()

    # ------------------------------------------------------------ unverified
    # Anything already shown under corrections stays there -- repeating the
    # whole block here just doubles the token cost of the same fact.
    openr = [r for r in d['results']
             if r.get('verdict') not in BAD
             and (r.get('verdict') in OPEN
                  or r.get('probe_validated') in ('no', 'partial')
                  or r.get('confounded'))]
    if openr:
        w('## Unverified — do not rely on these')
        w()
        for r in openr:
            c = claims[r['claim']]
            w(f"### {r['claim']} — {r['verdict']}")
            w()
            w(c['why_it_matters'])
            w()
            if r.get('declared'):
                w('Declared but **not confirmed by measurement**:')
                flatten({k: v for k, v in r['declared'].items() if k != 'source'}, 0)
                w()
            for a in r.get('probe_attempts', []):
                w(f"- Probe `{a['probe']}` → **{a['outcome']}**: {a['detail']}")
            if r.get('confounded'):
                w(f"- **Confounded**: {r.get('confound','')}")
            if r.get('probe_gap'):
                w(f"- **Not run**: {r['probe_gap']}")
            w()
            if r.get('unplanned_finding'):
                u = r['unplanned_finding']
                w(f"Side finding (confidence: {u.get('confidence','?')}): "
                  f"{u['statement']}")
                w()
            if r.get('consequence'):
                w(f"**Why it matters that this is open**: {r['consequence']}")
                w()

    # ---------------------------------------------------------- observations
    # Findings that were promoted out of `flagged`. Without this section a
    # promotion DELETES the finding from the briefing: it leaves `flagged`,
    # nothing renders it, and the only trace is an open question referring to a
    # result the reader never saw. Exactly what happened to gpu.die_parity.
    if d.get('observations'):
        w('## Measured, no declared source')
        w()
        w('Established by measurement and reported by nothing on the machine. '
          'These are results, not leads -- distinct from the section below.')
        w()
        for o in d['observations']:
            w(f"**{o['id']}** — {o['statement']}")
            w()
            if o.get('measured'):
                flatten(o['measured'], 0)
                w()
            for key, label in (('why_promoted', 'Why this is now a result'),
                               ('secondary_structure', 'Further structure'),
                               ('consequence', 'Consequence'),
                               ('remaining_caveat', 'Remaining caveat'),
                               ('confidence', 'Confidence')):
                if o.get(key):
                    w(f"- **{label}**: {o[key]}")
            w()

    # ----------------------------------------------------------------- leads
    if d.get('flagged'):
        w('## Leads — observed, deliberately not asserted')
        w()
        w('Each of these looks like structure and sits at or inside the noise '
          'band of its measurement. They are recorded so they are not lost. '
          '**They are not results.** Do not build advice on them, and do not '
          'repeat them as findings.')
        w()
        for f in d['flagged']:
            w(f"**{f['id']}** — {f['statement']}")
            w()
            if f.get('margin'):
                w(f"- Margin: {f['margin']}")
            if f.get('supporting_structure'):
                w(f"- Corroborating structure: {f['supporting_structure']}")
            if f.get('not_explained_by'):
                w(f"- Ruled out: {f['not_explained_by']}")
            if f.get('prediction'):
                w(f"- If true, would predict: {f['prediction']}")
            w(f"- **Why not asserted**: {f['why_flagged']}")
            w()

    # ---------------------------------------------------------------- limits
    w('## Limits of this briefing')
    w()
    w('Questions this document cannot answer. If asked one, say so.')
    w()
    for q in d.get('open_questions', []):
        w(f'- {q}')
    w()
    w(f"Generated from `{os.path.basename(argv[1])}` "
      f"(schema {d['schema_version']}, registry {d['registry_version']}) "
      f"by render.py. Values are measurements with stated conditions, not "
      f"specifications.")

    print('\n'.join(out))


if __name__ == '__main__':
    main(sys.argv)
