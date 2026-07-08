/*
 * audio_ring.h — single-producer/single-consumer lock-free ring for float audio
 * samples.
 *
 * lockfree_ring.h's le_ring stores fixed-size POD commands — the wrong shape for
 * raw audio. le_audio_ring is the audio counterpart: a flat float buffer with the
 * same wait-free push/pop discipline, but with the producer/consumer roles
 * reversed from le_ring — here the AUDIO thread is the producer (the
 * performance-capture taps in engine_process.c push into it) and the control
 * thread is the eventual consumer (a future drain thread; part 1 has none, so
 * pop only serves tests). push_frame writes `n` contiguous floats as one
 * all-or-nothing unit so a stereo/mono capture frame is never torn across a
 * fill/drop boundary: on a full ring it drops the whole frame and returns 0
 * rather than partially writing it.
 */
#ifndef LOOPY_AUDIO_RING_H
#define LOOPY_AUDIO_RING_H

#include <stdatomic.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Fixed-capacity SPSC float ring. `capacity` is a power of two, in SAMPLES (not
 * frames — a stereo capture stores 2 samples per frame); one slot is kept empty
 * to distinguish full from empty, so usable slots == capacity - 1. */
typedef struct le_audio_ring {
  float* buffer;
  size_t capacity; /* power of two */
  size_t mask;     /* capacity - 1 */
  _Atomic size_t head; /* consumer index */
  _Atomic size_t tail; /* producer index (audio thread writes) */
} le_audio_ring;

/* Initialises `ring` to use `buffer` of `capacity` samples. `capacity` must be a
 * power of two and >= 2. Does not allocate; the caller owns `buffer`'s lifetime.
 * Returns 1 on success, 0 on invalid arguments. */
int le_audio_ring_init(le_audio_ring* ring, float* buffer, size_t capacity);

/* Producer side: writes `n` contiguous samples as one all-or-nothing unit, so a
 * stereo/mono capture frame is never split across a fill/drop boundary. Returns
 * 1 if the frame was enqueued, 0 if fewer than `n` slots were free (nothing
 * written — the caller counts this as one dropped frame). Wait-free; never
 * allocates or blocks, so it is safe to call from the audio callback. */
int le_audio_ring_push_frame(le_audio_ring* ring, const float* samples,
                            size_t n);

/* Consumer side: pops up to `max` samples into `out`, returning the count
 * actually popped (0 if the ring is empty). Wait-free. Not called from the
 * audio thread in this slice (there is no drain thread yet); exists for
 * native-test bit-parity assertions and a future drain consumer. */
size_t le_audio_ring_pop(le_audio_ring* ring, float* out, size_t max);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_AUDIO_RING_H */
