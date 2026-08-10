#!/usr/bin/env python3
"""Assemble the two arm prompts for the machine-knowledge evaluation.

    python3 eval/build_prompts.py

Writes eval/arm_control.txt and eval/arm_treatment.txt. Both contain the same
questions in the same order with the same instructions; the ONLY difference is
which rendering of the descriptor is pasted above them.

Answer each in a separate, fresh session. Do not answer them in the same
context -- the treatment arm's content would leak into the control.
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

INSTRUCTIONS = """\
You are advising a user who is about to run a job on this machine. Below is the
information you have about it, followed by {n} questions about the machine and
{m} configuration scenarios for a real application.

Answer each question in 2-4 sentences. Be specific and give numbers where you
have them.

Important: if you do not actually know something, say so plainly rather than
producing a plausible answer. An answer stated confidently and wrongly is worse
than "the information I have does not cover this". You will be scored on both
correctness and on whether your confidence matched what you could actually
support.

Answer in the format:

  Q1: <answer>
  Q2: <answer>
  ...
  S1: <the srun line, env vars, and one sentence per choice>
  S2: ...
"""


def main():
    qs = json.load(open(os.path.join(HERE, 'questions.json')))
    sc = json.load(open(os.path.join(HERE, 'scenarios.json')))
    questions = qs['questions']
    scenarios = sc['scenarios']

    arms = {
        'control': os.path.join(ROOT, 'prompts', 'frontier-declared.md'),
        'treatment': os.path.join(ROOT, 'prompts', 'frontier-compute.md'),
    }

    # The WEB arm has no descriptor-derived context at all -- just the machine's
    # name and permission to look things up. This is the baseline a real user
    # actually has today: they type "I'm on Frontier, how do I configure this"
    # and the model searches. The curated `control` document only exists because
    # we already did the work, so it is an expert's best case, not a baseline.
    WEB_CONTEXT = (
        "You are advising a user who is about to run a job on Frontier, the "
        "supercomputer at the Oak Ridge Leadership Computing Facility (OLCF) at "
        "Oak Ridge National Laboratory.\n\n"
        "You have web access and may look things up if you want to."
    )

    qblock = '\n\n'.join(
        f"Q{i+1}. {q['q']}" for i, q in enumerate(questions))

    # Application context goes to BOTH arms verbatim. It is a fact about
    # QMCPACK, not about the machine; withholding it would vary two things at
    # once and the experiment would measure nothing.
    app = sc['app_context']
    appblock = '\n'.join(f"- {v}" for k, v in app.items())
    sblock = '\n\n'.join(
        f"S{i+1}. {s['name']}\n{s['prompt']}" for i, s in enumerate(scenarios))

    for arm, path in list(arms.items()) + [('web', None)]:
        if path is None:
            context = WEB_CONTEXT
        else:
            if not os.path.exists(path):
                sys.exit(f"missing {path} -- generate it first")
            with open(path) as f:
                context = f.read()

        out = os.path.join(HERE, f'arm_{arm}.txt')
        with open(out, 'w') as f:
            f.write(INSTRUCTIONS.format(n=len(questions),
                                        m=len(scenarios)))
            f.write('\n' + '=' * 70 + '\n')
            f.write('MACHINE INFORMATION\n')
            f.write('=' * 70 + '\n\n')
            f.write(context)
            f.write('\n\n' + '=' * 70 + '\n')
            f.write('PART 1 - QUESTIONS ABOUT THE MACHINE\n')
            f.write('=' * 70 + '\n\n')
            f.write(qblock + '\n')
            f.write('\n\n' + '=' * 70 + '\n')
            f.write('PART 2 - CONFIGURING AN APPLICATION\n')
            f.write('=' * 70 + '\n\n')
            f.write('The application:\n\n' + appblock + '\n\n')
            f.write(sc['output_format'] + '\n\n')
            f.write(sblock + '\n')
            if arm == 'web':
                f.write('\n\n' + '=' * 70 + '\n')
                f.write('SOURCES\n')
                f.write('=' * 70 + '\n\n')
                f.write('At the end, list which sources you consulted and which '
                        'questions you could not find a source for.\n')

        n = os.path.getsize(out)
        print(f"{arm:<10} {out}  {n} bytes  ~{n//4000}k tokens")

    print(f"\n{len(questions)} questions.")
    cats = {}
    for q in questions:
        cats[q['category']] = cats.get(q['category'], 0) + 1
    for c, n in sorted(cats.items()):
        print(f"  {c:<18} {n}")
    print("\nAnswer each arm in a SEPARATE fresh session, then record answers in")
    print("eval/answers_<arm>.json and run eval/score.py.")


if __name__ == '__main__':
    main()
