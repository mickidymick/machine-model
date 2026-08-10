#!/bin/bash
# CEILING -- hand-tuned. Traces:
#   -n8            gpu.device_inventory -- 8 schedulable GCDs, not 4 packages.
#   -c7            8 x 7 = the 56 usable cores.
#   OMP=14         both SMT threads per core -> 112 walkers, matching the fixed
#                  walker count the problem statement pins.
#   map_gpu 1,3,5,7 + 0,2,4,6 ordering puts one ODD die first in each NUMA
#                  domain: gpu.die_parity (medium confidence) has odd GCDs at
#                  1224 ns host-memory latency against 1382 for even, with no
#                  overlap in any of three passes.
build() { echo "using the prebuilt gpu_real binary"; }
run() {
  export OMP_NUM_THREADS=14 OMP_PROC_BIND=close OMP_PLACES=threads
  export MPICH_GPU_SUPPORT_ENABLED=1
  srun -N1 -n8 -c7 --gpus-per-node=8 --gpu-bind=map_gpu:1,3,5,7,0,2,4,6 \
       --cpu-bind=cores $QMCPACK_BIN diamond_vmc.xml
}
