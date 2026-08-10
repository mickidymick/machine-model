#!/bin/bash
# FLOOR -- the naive default. No tuning, no binding, no modules beyond what is
# needed to compile. This is what a user gets by not thinking about it, and it
# is what gives the arms' results a scale: "8% faster" means nothing without it.
build() { cd src && make -j16; }
run()   { srun -N1 -n1 ./test/amg -problem 2 -n 128 128 128; }
