/*
 * loop_clock.h — master loop length + playhead with boundary detection.
 *
 * Pure value logic (no atomics, no allocation): the audio thread owns a clock
 * instance and ticks it once per frame. Quantization decisions (e.g. aligning
 * an overdub to the loop) are driven by le_loop_clock_tick's boundary return.
 */
#ifndef LOOPY_LOOP_CLOCK_H
#define LOOPY_LOOP_CLOCK_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct le_loop_clock {
  int32_t length;   /* loop length in frames; 0 means not yet set */
  int32_t position; /* current playhead in [0, length) */
} le_loop_clock;

/* Resets to an unset clock (length 0, position 0). */
void le_loop_clock_reset(le_loop_clock* clock);

/* Sets the loop length and rewinds the playhead to 0. A length <= 0 resets. */
void le_loop_clock_set_length(le_loop_clock* clock, int32_t length);

/* Advances the playhead by one frame. Returns 1 if the playhead wrapped back to
 * 0 (a loop boundary was crossed), else 0. A clock with length 0 never ticks. */
int le_loop_clock_tick(le_loop_clock* clock);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_LOOP_CLOCK_H */
