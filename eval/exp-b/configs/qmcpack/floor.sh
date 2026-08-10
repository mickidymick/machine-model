#!/bin/bash
# FLOOR -- naive default. Reproduces the starved single-rank case: one OpenMP
# thread, one of eight GCDs. 155.8 s in July against 68.0 s tuned.
build() { echo "using the prebuilt gpu_real binary"; }
run()   { srun -N1 -n1 $QMCPACK_BIN diamond_vmc.xml; }
