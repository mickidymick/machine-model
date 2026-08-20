# Related work

Searched 2026-08-20. PDFs alongside. The question this search answered: is
anyone already doing LLM-based application classification or LLM-driven HPC
configuration, and does it overlap with what we are doing?

Short answer: **classification is occupied and done well; configuration from a
MEASURED machine descriptor is not.**

---

## THE ONE THAT MATTERS

### Can Large Language Models Predict Parallel Code Performance? — `arxiv_2505.03988.pdf`
<https://arxiv.org/abs/2505.03988>

Binary compute-bound vs bandwidth-bound classification of GPU kernels from
source, against a Roofline ground truth.

- 340 balanced kernels from HeCBench (of 446 CUDA + 303 OpenMP-offload
  profiled), single NVIDIA RTX 3080.
- 8 model variants: reasoning (o3-mini-high, o1, o3-mini, o1-mini) vs standard
  (gpt-4o, gpt-4o-mini, Gemini 2.0 Flash).
- **64% accuracy from source alone**, best reasoning models, zero-shot.
  Few-shot adds little. Fine-tuning degenerated to always predicting one class.
- **90-100% when given hardware peaks and the profiled arithmetic intensity.**

**READ THE SECOND NUMBER CAREFULLY.** The "with profiling" condition supplies
peak bandwidth, peak FLOP/s and the computed arithmetic intensity, then asks
which side of the ridge point it falls on. Arithmetic intensity IS essentially
the answer for a binary CB/BB question, so RQ1 tests whether the models know the
Roofline model -- not whether profiling deepens understanding. Do not cite the
64 -> 100 jump as "profiling is worth 36 points" without that caveat.

Profiling cost was low: SP/DP/INT op counts, execution time, global memory
read/write counts, **first execution of each kernel only**. Tool not named.

**Why it matters to us.** It lets us CITE the classification problem instead of
studying it. 64% on the easiest possible version of the task is independent
evidence that source-only regime identification is unreliable -- which is
exactly what our LULESH arm did when it called a cache-resident code
"bandwidth-saturated". A regime-dependent claim therefore cannot assume its
reader knows its own regime, and that is the constraint that motivates our
design changes.

---

## ADJACENT — code optimization, not run configuration

### MARCO: Multi-Agent Code Optimization with Real-Time Knowledge Integration — `arxiv_2505.03906.pdf`
<https://arxiv.org/abs/2505.03906>
Multi-agent kernel rewriting with retrieved knowledge. Rewrites code; does not
configure a run.

### VibeCodeHPC: Agent-Based Iterative Prompting Auto-Tuner — `arxiv_2510.00031.pdf`
<https://arxiv.org/abs/2510.00031>
Iterative prompting auto-tuner for HPC code generation. Again code-side.

---

## ADJACENT — scheduler-side configuration

### Evaluating the Efficacy of LLM-Based Reasoning for Multiobjective HPC Job Scheduling — `arxiv_2506.02025.pdf`
<https://arxiv.org/abs/2506.02025>
LLM reasoning over scheduling objectives. Node counts and walltime from the
scheduler's perspective, not the application's.

### Agentic Orchestration of HPC Applications in Cloud (Sochat et al.)
<https://arxiv.org/abs/2607.02925> — not downloaded
Agents handling preparatory steps, runtime parameters, resource requests,
topology and binding. Closest in spirit on the workflow side.

---

## CONTEXT

### The Landscape and Challenges of HPC Research and LLMs — `arxiv_2402.02018.pdf`
<https://arxiv.org/abs/2402.02018>
Survey. Useful for positioning and for the observation that LLMs are trained for
functional correctness rather than runtime performance.

Also referenced in the survey space: **ParEval**, showing a substantial gap
between LLM ability on serial versus parallel code.

---

## WHAT NOBODY APPEARS TO HAVE DONE

- Given an LLM a **measured** machine descriptor, as distinct from specs or
  documentation, and tested whether it improves configuration decisions.
- The declared-vs-measured **fidelity** framing.
- A measured case of a correct number **inverting** outside the regime it was
  measured in.
- **Displacement**: that supplying machine information changes where a model
  spends its reasoning, at a cost.

That is the space our work sits in.
