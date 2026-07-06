/*
 * layer_staging_ring.h — single-producer/single-consumer ring of retired
 * overdub-layer PCM copies, staged for persistence (part 5, D-LAYER).
 *
 * The hazard this exists to close: a completed overdub pass ("layer") lives
 * in a fixed-size per-track pool (LE_POOL_SLOTS). When the pool fills, the
 * oldest undo layer's slot is evicted and reused; clearing a track, or
 * starting a fresh punch-in after an undo (redo-invalidation), reclaims
 * slots the same way. None of that touches the buffer's bytes directly, but
 * the NEXT write to a reclaimed slot overwrites them — so audio that
 * genuinely played can be silently destroyed with no record it ever existed.
 *
 * The fix: while performance capture is armed, every retiring layer's PCM is
 * copied into a fresh heap buffer (control thread, at the moment
 * le_handle_retired processes its LE_EVT_LAYER_RETIRED event — see
 * engine_commands.c) and handed to this ring. perf_drain.c's background
 * thread pops entries and writes them to numbered files, independent of
 * whatever the live pool slot goes on to do afterward.
 *
 * Control-thread-producer, drain-thread-consumer — the same single-producer
 * discipline as every other ring in this engine, and the same "control
 * allocates, drain thread frees" ownership handoff perf_drain.c already uses
 * for nothing else (this is the first ring in this engine whose entries own
 * heap memory rather than being flat PODs — see the struct doc below).
 */
#ifndef LOOPY_LAYER_STAGING_RING_H
#define LOOPY_LAYER_STAGING_RING_H

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

#include "loopy_engine_api.h" /* LE_MAX_LANES */

#ifdef __cplusplus
extern "C" {
#endif

/* One retiring layer's staged PCM. `lane_pcm[i]` for `i < lane_count` is a
 * heap buffer of `frame_count` floats (mono per lane — the same shape as the
 * live pool buffer it was copied from); entries at `i >= lane_count` are
 * unused. The consumer (perf_drain.c) takes ownership on pop and must free
 * every `lane_pcm[i] < lane_count` once written.
 *
 * `frame` is a control-thread snapshot of a_perf_frames taken when the copy
 * was made — a best-effort anchor for the on-disk filename/manifest, NOT
 * sample-accurate (unlike part 3's event log). Exact-frame correlation is
 * available by cross-referencing events.log's LE_PLOG_LAYER_RETIRED entry,
 * which carries the same (channel, slot, generation) key sample-accurately —
 * see docs/design/performance-event-log-format.md. */
typedef struct le_staged_layer {
  int32_t channel;
  int32_t lane_count;
  float* lane_pcm[LE_MAX_LANES];
  int32_t frame_count;
  int32_t slot;
  uint32_t generation;
  uint64_t frame;
} le_staged_layer;

/* Fixed-capacity SPSC ring of le_staged_layer. `capacity` is a power of two;
 * one slot is kept empty to distinguish full from empty, so usable slots ==
 * capacity - 1. */
typedef struct le_layer_staging_ring {
  le_staged_layer* buffer;
  size_t capacity; /* power of two */
  size_t mask;     /* capacity - 1 */
  _Atomic size_t head; /* consumer index (drain thread reads) */
  _Atomic size_t tail; /* producer index (control thread writes) */
} le_layer_staging_ring;

/* Initialises `ring` to use `buffer` of `capacity` entries. `capacity` must
 * be a power of two and >= 2. Returns 1 on success, 0 on invalid arguments. */
int le_layer_staging_ring_init(le_layer_staging_ring* ring,
                               le_staged_layer* buffer, size_t capacity);

/* Producer side (control thread). Returns 1 if the entry was enqueued, 0 if
 * the ring is full — the caller (le_stage_retired_layer, engine_commands.c)
 * frees every lane_pcm buffer itself in that case, since nothing will ever
 * pop and free them otherwise; this is logged as a dropped layer (a
 * dedicated overrun atomic — see engine_private.h), not a silent leak. */
int le_layer_staging_ring_push(le_layer_staging_ring* ring,
                               le_staged_layer entry);

/* Consumer side (drain thread). Writes the next entry into *out and returns
 * 1, or returns 0 if the ring is empty. The caller takes ownership of every
 * lane_pcm[i] for i < lane_count and must free each one. */
int le_layer_staging_ring_pop(le_layer_staging_ring* ring,
                              le_staged_layer* out);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_LAYER_STAGING_RING_H */
