/*
 * lockfree_ring.h — single-producer / single-consumer lock-free command ring.
 *
 * The control side (Dart, via FFI) is the sole producer; the real-time audio
 * callback thread is the sole consumer. push/pop are wait-free and perform no
 * allocation, making them safe to call from the audio callback.
 *
 * Capacity must be a power of two. The ring stores fixed-size POD commands so
 * the audio thread never dereferences control-owned heap memory.
 */
#ifndef LOOPY_LOCKFREE_RING_H
#define LOOPY_LOCKFREE_RING_H

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A single engine command. `code` is an le_command_code; the payload is a tagged
 * union keyed on `code` so each producer fills, and the audio thread reads, NAMED
 * fields — no bit-packing. The generic { arg_i, arg_f } arm (a C11 anonymous
 * struct, so simple commands keep using cmd.arg_i / cmd.arg_f directly) carries
 * the single-int / single-float commands (record, volume, mute, gain, …); the
 * named arms carry the addressed commands that previously field-packed their
 * arguments. For the monitor-lane commands, the `channel` field holds the input
 * index. Exactly one arm is valid per `code`; see apply_command. */
typedef struct le_command {
  int32_t code;
  union {
    struct { /* generic single int + single float */
      int32_t arg_i;
      float arg_f;
    };
    struct { /* SET_INPUT_MASK / SET_OUTPUT_MASK */
      int32_t channel;
      uint32_t mask;
    } trackmask;
    struct { /* SET_LANE_FX / SET_MONITOR_INPUT_FX (channel = input, lane unused) */
      int32_t channel, lane, index, type;
    } fx;
    struct { /* SET_LANE_FX_COUNT / SET_MONITOR_INPUT_FX_COUNT (channel = input) */
      int32_t channel, lane, count;
    } fxcount;
    struct { /* lane int payload: SET_LANE_INPUT (input ch) / *_OUTPUT (mask) */
      int32_t channel, lane, value;
    } lanei;
    struct { /* lane float payload: SET_LANE_VOLUME / MUTE (+ monitor) */
      int32_t channel, lane;
      float value;
    } lanef;
  };
} le_command;

/* Fixed-capacity SPSC ring. `capacity` is a power of two; one slot is kept
 * empty to distinguish full from empty, so usable slots == capacity - 1. */
typedef struct le_ring {
  le_command* buffer;
  size_t capacity; /* power of two */
  size_t mask;     /* capacity - 1 */
  _Atomic size_t head; /* consumer index (audio thread reads) */
  _Atomic size_t tail; /* producer index (control thread writes) */
} le_ring;

/* Initialises `ring` to use `buffer` of `capacity` commands. `capacity` must be
 * a power of two and >= 2. Returns 1 on success, 0 on invalid arguments. */
int le_ring_init(le_ring* ring, le_command* buffer, size_t capacity);

/* Producer side. Returns 1 if the command was enqueued, 0 if the ring is full.
 * Wait-free; safe to call concurrently with le_ring_pop. */
int le_ring_push(le_ring* ring, le_command cmd);

/* Consumer side. Writes the next command into *out and returns 1, or returns 0
 * if the ring is empty. Wait-free; safe to call from the audio callback. */
int le_ring_pop(le_ring* ring, le_command* out);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_LOCKFREE_RING_H */
