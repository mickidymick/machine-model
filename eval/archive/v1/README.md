# v1 — 2026-08-10, superseded

First run. Opus 4.8, effort High, separate fresh claude.ai conversations.
Result: control 8/14, treatment 13/14; confidently wrong 1 vs 0.

Superseded because BOTH arms' inputs changed afterwards:

- **control** was over-supplied. Five of six operational notes were our own
  discoveries rather than facility documentation, including the 22.7/45.1/90.3
  NIC scaling measured that same afternoon. `provenance: documented|measured`
  now gates what reaches it; two notes are withheld and the measured figures
  are stripped from the rest.
- **treatment** was missing a finding. `gpu.die_parity` had been promoted out of
  `flagged` into `observations`, and `render.py` rendered only `flagged` — so
  the promotion silently deleted it from the briefing. v1's treatment numbers
  are therefore a lower bound.

Kept because the comparison is still informative: v1 is the over-supplied
control, v2 the honest one, and the gap between them is itself a result.
