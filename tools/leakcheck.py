#!/usr/bin/env python3
"""Fail if a machine descriptor contains test-application properties.

A machine descriptor may carry machine and toolchain facts -- including ones
discovered while building application X -- and may name X as provenance. It may
NOT carry application properties, or any measurement of a test application's
performance or regime. Anything it does carry, the treatment arm gets and the
control arm does not.

    python3 leakcheck.py machines/frontier-compute.json eval/exp-b/configs
"""
import json, re, sys, pathlib

APPS = ["lulesh", "miniqmc", "qmcpack", "xsbench", "amg", "hypre", "openmc"]
# Words that turn a provenance mention into an answer.
ANSWER = re.compile(
    r"\b(bandwidth[- ]saturated|latency[- ]bound|compute[- ]bound|memory[- ]bound"
    r"|faster|slower|speedup|\d+(\.\d+)?\s*%|\d+(\.\d+)?\s*x\b"
    r"|\d+(\.\d+)?\s*s\b|job\s*\d{6,}|elements|GB\b)", re.I)

def strings(o, p=""):
    if isinstance(o, dict):
        for k, v in o.items(): yield from strings(v, f"{p}.{k}")
    elif isinstance(o, list):
        for i, v in enumerate(o): yield from strings(v, f"{p}[{i}]")
    elif isinstance(o, str):
        yield p, o

def main(path):
    d = json.load(open(path))
    crit, warn = [], []
    for p, s in strings(d):
        lo = s.lower()
        for a in APPS:
            if re.search(rf"\b{a}\b", lo):
                (crit if ANSWER.search(s) else warn).append((a, p, s))
                break
    print(f"{path}\n")
    if crit:
        print(f"CRITICAL -- {len(crit)} application measurement(s) in the artifact:")
        for a, p, s in crit:
            print(f"  [{a}] {p}\n      {s[:220]}\n")
    else:
        print("CRITICAL: none. No test-application measurement or regime claim.\n")
    if warn:
        print(f"provenance mentions ({len(warn)}) -- app named, no answer attached:")
        for a, p, _ in warn: print(f"  [{a}] {p}")
        print("\n  Legitimate if the FACT is a machine/toolchain fact. Not legitimate")
        print("  if it is a property of the application itself.")
    return 1 if crit else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "machines/frontier-compute.json"))
