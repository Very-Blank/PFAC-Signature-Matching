#include "hip.h"

__global__ void PFAC_KERNEL(FSM fsm, Blob blob, Matches* matches) {
  const size_t offset = (size_t)blockIdx.x * (size_t)blockDim.x + (size_t)threadIdx.x;
  uint16_t next_state = TRAP_STATE;

  if (blob.len <= offset + 1 ||
      fsm.prefix_table[blob.ptr[offset] * PERMUTATIONS + blob.ptr[offset + 1]] == TRAP_STATE) {
    goto end_matching;
  }

  next_state = fsm.transition_table
                   [fsm.prefix_table[blob.ptr[offset] * PERMUTATIONS + blob.ptr[offset + 1]] - 1];

  for (size_t j = offset + 2; j < blob.len; j += 1) {
    if (next_state <= fsm.signatures) {
      const size_t len = atomicAdd(&matches->count, 1);
      if (len <= matches->capacity) {
        matches->ids[len] = next_state;
      }
    }

    next_state = fsm.postfix_table[blob.ptr[j] + (next_state - 1) * PERMUTATIONS];

    if (next_state == TRAP_STATE) {
      goto end_matching;
    }
  }

  if (next_state <= fsm.signatures) {
    const size_t len = atomicAdd(&matches->count, 1);
    if (len <= matches->capacity) {
      matches->ids[len] = next_state;
    }
  }

end_matching:;
  __syncthreads();
}

void pfac(LaunchOptions launch_options, FSM fsm, Blob blob, Matches* matches) {
  PFAC_KERNEL<<<dim3(launch_options.warps), dim3(launch_options.threads), 0,
                launch_options.stream>>>(fsm, blob, matches);
}

__global__ void WARM_UP_KERNEL() {}

void warm_up() {
  WARM_UP_KERNEL<<<dim3(1), dim3(1), 0, 0>>>();
}
