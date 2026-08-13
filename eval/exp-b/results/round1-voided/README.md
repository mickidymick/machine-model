# Round 1 -- voided for a spec bug, kept for two results that survive it

Round 1 was never timed. `problem-amg.md` v1 pinned the PER-RANK block and left
the total work free, so the arms solved problems 14x apart (224 ranks / 4.70e8
unknowns vs 16 ranks / 3.36e7). Both agents caught the ambiguity and said so in
their headers; they resolved it in opposite directions. Wall-clock between them
would have been uninterpretable, and it would have LOOKED like a large win for
the artifact arm.

Two findings do not depend on the timing, and both are recorded here because
they were observed before any allocation was spent:

1. **The pre-registered falsifier fired. BOTH arms load `craype-hugepages2M`
   at build time.** The no-artifact arm derived it independently -- Zen 3's L2
   TLB covers ~8 MB with 4 KB pages against a working set of tens of MiB, so the
   solve is TLB-bound -- and reasoned about 2M over 8M/64M. Huge pages were the
   pre-registered mechanism for the whole predicted CPU win.

2. **The arms differ in calibration, not conclusion.** with-artifact states which
   regime it cannot place the workload in ("somewhere between 15% and 2.4x, not
   a single number"); no-artifact asserts the mechanism with confidence. That
   echoes Experiment A's Q13 result rather than contradicting it.

Round 2 fixes the global grid at 448^3 (2^6 x 7, so 4/7/8/14/16/28/32/56/64/112/
224 all divide cleanly -- every geometry either arm considered stays reachable).
