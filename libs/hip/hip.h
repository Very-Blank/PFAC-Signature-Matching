#ifndef HIP
#define HIP

#include <hip/hip_runtime.h>
#include <stddef.h>
#include <stdint.h>

const size_t TRAP_STATE = 0;
const size_t PERMUTATIONS = 1 << 8;
const size_t TRANSITIONS = 255;  // Zero is reversed for TRAP_STATE

typedef struct LaunchOptions {
  size_t warps;
  size_t threads;
  hipStream_t stream;
} LaunchOptions;

typedef struct Blob {
  size_t len;
  uint8_t* ptr;
} Blob;

// NOTE: If we run out of capacity, PFAC kernel will increase the len without writing to buffer!!
typedef struct Matches {
  uint16_t* ids;
  size_t count;
  size_t capacity;
} Matches;

typedef struct {
  uint8_t* prefix_table;
  uint16_t* transition_table;
  uint16_t* postfix_table;
  uint16_t signatures;
} FSM;

#ifdef __cplusplus
extern "C" {
#endif

void pfac(LaunchOptions launch_options, FSM fsm, Blob blob, Matches* matches);
void warm_up();

#ifdef __cplusplus
}
#endif  // __cplusplus

#endif  // HIP
