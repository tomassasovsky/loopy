/*
 * engine_session.c — session persistence (export / import / commit).
 *
 * THREAD OWNERSHIP: control thread. Export reads, and import fills, a lane's loop
 * buffer directly — safe because both target a track the audio thread is not
 * recording (export when not capturing; import only into an EMPTY track, whose
 * buffers the audio thread does not touch). Commit is the one ring-posted step
 * (le_push), so the audio thread establishes the master and starts the imported
 * tracks in lockstep. Split out of engine.c (S1).
 *
 * Lane buffers are mono (one sample per frame), so a stem is just the loop
 * samples; routing to channels is a playback concern, not stored. Export/import
 * address any lane: le_engine_export_track / le_engine_import_track are the
 * lane-0 conveniences over the _lane variants. Per-overdub-layer export/import
 * (undo/redo persistence) is a later revision.
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

int32_t le_engine_export_track_lane(le_engine* engine, int32_t channel,
                                    int32_t lane, float* out,
                                    int32_t max_frames) {
  if (engine == NULL || out == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (max_frames <= 0) return LE_ERR_INVALID;
  le_lane* ln = &engine->tracks[channel].lanes[lane];
  int32_t n = load_i32(&ln->a_len);
  if (n > max_frames) n = max_frames;
  if (n <= 0) return 0;
  const int live = load_i32(&ln->a_live);
  if (ln->pool[live] == NULL) return 0;
  memcpy(out, ln->pool[live], (size_t)n * sizeof(float));
  return n;
}

int32_t le_engine_import_track_lane(le_engine* engine, int32_t channel,
                                    int32_t lane, const float* pcm,
                                    int32_t frames) {
  if (engine == NULL || pcm == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (frames <= 0) return LE_ERR_INVALID;
  le_track* t = &engine->tracks[channel];
  /* Importing targets an empty track: its buffers are not read by the audio
   * thread, so the control thread can fill any lane directly. An undone-to-empty
   * track qualifies, but its redo stack must go first — the live buffer being
   * overwritten IS the redo-top snapshot, so advertising canRedo afterwards
   * would resurrect the imported content, not the undone take. */
  if (load_i32(&t->a_state) != LE_TRACK_EMPTY) return LE_ERR_INVALID;
  /* A posted-but-unapplied state flip (undo-to-empty / redo-from-empty /
   * clear) makes the raw EMPTY reading unreliable — reject rather than race
   * the command; session loads retry trivially. */
  if (t->state_cmds_posted >
      atomic_load_explicit(&t->a_state_acks, memory_order_acquire)) {
    return LE_ERR_INVALID;
  }
  /* Reject (rather than silently truncate) a stem that exceeds the buffer cap,
   * so a corrupted/foreign loop fails loudly instead of loading clipped. */
  if (frames > engine->max_loop_frames) return LE_ERR_INVALID;
  /* Lane 0 is the primary import: it resets the track's redo/empty accounting
   * (a fresh session take has no undo history). Additional lanes only fill
   * their own buffer — they share the track's one undo span, so they must not
   * touch its stacks. Growing lane_count activates the imported lane for
   * playback after commit; a newly activated lane defaults to its standard
   * record route (input == lane index) but is NEVER reset for lane 0, whose
   * buffer/config we are filling here. */
  if (lane == 0) {
    t->redo_count = 0;
    t->empty_len = 0;
    store_i32(&t->a_redo_depth, 0);
    t->start_iter = 0;
  }
  if (lane >= t->lane_count) {
    for (int32_t l = t->lane_count; l <= lane; ++l) {
      le_lane_reset(&t->lanes[l], l);
    }
    t->lane_count = lane + 1;
  }
  le_lane* ln = &t->lanes[lane];
  const int live = load_i32(&ln->a_live);
  /* The import target must hold the full cap (a later capture over it can
   * grow to max_loop_frames, and the tail is zeroed to the cap below); undo
   * may have left a quantized snapshot slot live. Track is EMPTY: safe. */
  if (!le_lane_ensure_slot(ln, live, engine->max_loop_frames)) {
    return LE_ERR_INVALID;
  }
  const size_t span = (size_t)frames;
  const size_t cap = (size_t)engine->max_loop_frames;
  memcpy(ln->pool[live], pcm, span * sizeof(float));
  if (span < cap) {
    memset(ln->pool[live] + span, 0, (cap - span) * sizeof(float));
  }
  store_i32(&ln->a_len, frames);
  return LE_OK;
}

int32_t le_engine_import_track(le_engine* engine, int32_t channel,
                               const float* pcm, int32_t frames) {
  return le_engine_import_track_lane(engine, channel, 0, pcm, frames);
}

int32_t le_engine_commit_session(le_engine* engine, int32_t base_frames) {
  return le_push(engine, LE_CMD_COMMIT_SESSION, base_frames, 0.0f);
}
