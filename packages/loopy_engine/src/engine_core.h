/*
 * engine_core.h — low-level engine helpers shared across the split core TUs.
 *
 * These are the small primitives the per-concern TUs (engine_transport.c,
 * engine_process.c, engine_snapshot.c, engine_session.c, engine_commands.c,
 * engine_lifecycle.c) all reach for. The tiny, hot ones are `static inline`
 * here; the rest are declared here and defined in engine.c (the residual shared
 * core). NOT the FFI surface (loopy_engine_api.h) and NOT the test surface
 * (engine_internal.h) — the private contract between the engine's own TUs, like
 * engine_private.h but for behaviour rather than the struct layout.
 */
#ifndef LOOPY_ENGINE_CORE_H
#define LOOPY_ENGINE_CORE_H

#include <stdint.h>

#include "engine_private.h" /* le_engine, le_track, store_i32, LE_MAX_LANES */

#ifdef __cplusplus
extern "C" {
#endif

/* Wraps `pos - offset` into [0, len). Used to write captured input at the
 * latency-compensated loop position so overdubs align with what was heard. */
static inline int32_t comp_pos(int32_t pos, int32_t offset, int32_t len) {
  if (len <= 0) return pos;
  int32_t p = (pos - offset) % len;
  if (p < 0) p += len;
  return p;
}

/* A track's active lane count, clamped to a usable range (a track always has at
 * least one lane). */
static inline int32_t le_lanes_active(const le_track* t) {
  int32_t n = t->lane_count;
  if (n < 1) n = 1;
  if (n > LE_MAX_LANES) n = LE_MAX_LANES;
  return n;
}

/* Whether `ch` is a usable track index. Defined in engine.c. */
int valid_channel(le_engine* e, int32_t ch);

/* Publishes a recorded length onto every active lane of a track (all lanes share
 * the one transport, so they share the length). Defined in engine.c. */
void le_track_set_len(le_track* t, int32_t len);

/* Lowest set bit of `mask` as a channel index, or -1 when no bit is set.
 * Collapses a legacy track input bitmask into lane 0's single input channel.
 * Defined in engine.c. */
int32_t le_mask_to_channel(uint32_t mask);

/* Posts a command into the engine's SPSC ring (control thread). Returns LE_OK,
 * LE_ERR_NOT_RUNNING (not configured), or LE_ERR_INVALID (null / ring full).
 * Defined in engine.c. */
int32_t le_push(le_engine* engine, int32_t code, int32_t arg_i, float arg_f);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_ENGINE_CORE_H */
