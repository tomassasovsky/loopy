/*
 * engine_session.c — session persistence (export / import / commit).
 *
 * THREAD OWNERSHIP: control thread. Export reads, and import fills, lane 0's loop
 * buffer directly — safe because both target a track the audio thread is not
 * recording (export when not capturing; import only into an EMPTY track, whose
 * buffers the audio thread does not touch). Commit is the one ring-posted step
 * (le_push), so the audio thread establishes the master and starts the imported
 * tracks in lockstep. Split out of engine.c (S1); behaviour unchanged.
 *
 * Lane buffers are mono (one sample per frame), so a stem is just the loop
 * samples; routing to channels is a playback concern, not stored. Export/import
 * operate on lane 0 — multi-lane stems are a later revision.
 */
#include <stdint.h>
#include <string.h>

#include "engine_core.h"     /* le_push */
#include "engine_private.h"  /* le_engine, le_track, le_lane, load/store_i32 */
#include "loopy_engine_api.h"

int32_t le_engine_export_track(le_engine* engine, int32_t channel, float* out,
                               int32_t max_frames) {
  if (engine == NULL || out == NULL) return 0;
  if (channel < 0 || channel >= engine->track_count) return 0;
  if (max_frames <= 0) return 0;
  le_lane* ln = &engine->tracks[channel].lanes[0];
  int32_t n = load_i32(&ln->a_len);
  if (n > max_frames) n = max_frames;
  if (n <= 0) return 0;
  const int live = load_i32(&ln->a_live);
  if (ln->pool[live] == NULL) return 0;
  memcpy(out, ln->pool[live], (size_t)n * sizeof(float));
  return n;
}

int32_t le_engine_import_track(le_engine* engine, int32_t channel,
                               const float* pcm, int32_t frames) {
  if (engine == NULL || pcm == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (frames <= 0) return LE_ERR_INVALID;
  le_track* t = &engine->tracks[channel];
  /* Importing targets an empty track: its buffers are not read by the audio
   * thread, so the control thread can fill lane 0 directly. */
  if (load_i32(&t->a_state) != LE_TRACK_EMPTY) return LE_ERR_INVALID;
  /* Reject (rather than silently truncate) a stem that exceeds the buffer cap,
   * so a corrupted/foreign loop fails loudly instead of loading clipped. */
  if (frames > engine->max_loop_frames) return LE_ERR_INVALID;
  le_lane* ln = &t->lanes[0];
  const int live = load_i32(&ln->a_live);
  if (ln->pool[live] == NULL) return LE_ERR_INVALID;
  const size_t span = (size_t)frames;
  const size_t cap = (size_t)engine->max_loop_frames;
  memcpy(ln->pool[live], pcm, span * sizeof(float));
  if (span < cap) {
    memset(ln->pool[live] + span, 0, (cap - span) * sizeof(float));
  }
  store_i32(&ln->a_len, frames);
  t->start_iter = 0;
  return LE_OK;
}

int32_t le_engine_commit_session(le_engine* engine, int32_t base_frames) {
  return le_push(engine, LE_CMD_COMMIT_SESSION, base_frames, 0.0f);
}
