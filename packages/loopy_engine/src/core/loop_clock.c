#include "loop_clock.h"

void le_loop_clock_reset(le_loop_clock* clock) {
  clock->length = 0;
  clock->position = 0;
}

void le_loop_clock_set_length(le_loop_clock* clock, int32_t length) {
  clock->length = length > 0 ? length : 0;
  clock->position = 0;
}

int le_loop_clock_tick(le_loop_clock* clock) {
  if (clock->length <= 0) return 0;
  clock->position++;
  if (clock->position >= clock->length) {
    clock->position = 0;
    return 1; /* wrapped: crossed a loop boundary */
  }
  return 0;
}
