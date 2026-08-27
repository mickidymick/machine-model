# Why the problem statements are sized as they are

**Internal. This never reaches an arm.** It lived inside `problem-lulesh.md`
until 2026-08-27, which meant every arm was handed it -- see the leak note at
the bottom.

## LULESH — global 300^3, `-r 11 -b 0 -c 64`, `-i 50`

**v1 (round 3) ran 729,000 elements**, preserved as `problem-lulesh.v1.md`. That
was 230 MB on a 512 GB node -- cache-resident in every configuration, so almost
none of the artifact's claims could bind and the comparison could not have
tested them. Correction in `RESULTS.md`.

The size is anchored to a **published, measured** configuration:
`-s 300 -i 12 -r 11 -b 0 -c 64`, single rank, measured at **23.6 GB**. This spec
keeps that total problem and the region settings, and distributes it so the
decomposition is a real choice rather than fixed at one.

Two deliberate deviations from the published run:

- **Distributed rather than single-rank.** A single rank has no decomposition to
  choose, which removes most of the configuration surface under test.
- **`-i 50` rather than `-i 12`.** At 12 iterations the total work is about
  round 3's, giving runs of a few seconds; wall clock is the dependent variable
  here, so iterations are raised for timing stability.

Measured behaviour at this size is in `SPREAD-RESULTS.md`; the footprint
derivation and the MPI-only vs threaded bytes-per-element question are in
`eval/characterize/analytic-lulesh.md`.

---

## The leak this file exists to prevent

Round 4's first batch of six arms was **voided** because `problem-lulesh.md`
carried the section above. Both arms were therefore handed:

- the 2.36x allocation-flag effect,
- the 315 vs 874 bytes-per-element difference between the MPI-only and threaded
  paths,
- the 23.6 GB footprint,
- and a path into the repo.

It was **symmetric**, so it did not bias treatment against control. It was still
disqualifying: the bytes-per-element difference is the thing round 3's control
arm had to **derive from source**, and that derivation was the mechanism behind
round 3's entire result. Handing it to both arms removes the lever the
experiment exists to measure, and compresses the spread by pre-empting the most
likely mistake. Five of six arms stated `--threads-per-core` explicitly, which
is what we told them to do.

**The rule.** A problem statement may say what the fixed problem is, what the
constraints are, and what the environment exposes. It may not contain anything
we measured, any figure from our own results, or any path into this repo.
Experimental-design reasoning belongs here, not in front of an arm.

`setup.sh` now checks for this and refuses.
