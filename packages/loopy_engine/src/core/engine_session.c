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

/* Maps an export ordinal (0 = oldest undo layer ... undo_count = live ...
 * up to undo_count+redo_count = newest redo layer) to the pool slot that holds
 * it. The linear timeline is undo_stack[0..undo_count) then a_live then the
 * redo stack read newest-adjacent-first (redo_stack[redo_count-1] is the layer
 * immediately above live — see le_undo_swap in engine_commands.c). Returns -1
 * for an ordinal past the end. */
static int32_t le_layer_slot_for_ordinal(const le_track* t, int32_t ordinal,
                                          int32_t live) {
  const int32_t undo_c = t->undo_count;
  const int32_t redo_c = t->redo_count;
  if (ordinal < undo_c) return t->undo_stack[ordinal];
  if (ordinal == undo_c) return live;
  const int32_t j = ordinal - undo_c - 1; /* 0-based into the post-live run */
  if (j >= redo_c) return -1;
  return t->redo_stack[redo_c - 1 - j];
}

int32_t le_engine_export_layer(le_engine* engine, int32_t channel, int32_t lane,
                               int32_t ordinal, float* out, int32_t max_frames) {
  if (engine == NULL || out == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (ordinal < 0 || max_frames <= 0) return LE_ERR_INVALID;
  le_track* t = &engine->tracks[channel];
  if (ordinal >= t->undo_count + 1 + t->redo_count) return LE_ERR_INVALID;
  le_lane* ln = &t->lanes[lane];
  /* a_live is written in lockstep across lanes, so any lane's copy names the
   * shared live slot; the undo/redo stacks are track-owned slot indices. */
  const int32_t slot =
      le_layer_slot_for_ordinal(t, ordinal, load_i32(&ln->a_live));
  if (slot < 0) return LE_ERR_INVALID;
  int32_t n = load_i32(&ln->a_len);
  if (n > max_frames) n = max_frames;
  if (n <= 0) return 0;
  if (ln->pool[slot] == NULL) return 0;
  memcpy(out, ln->pool[slot], (size_t)n * sizeof(float));
  return n;
}

int32_t le_engine_import_layer(le_engine* engine, int32_t channel, int32_t lane,
                               int32_t ordinal, const float* pcm,
                               int32_t frames) {
  if (engine == NULL || pcm == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  /* The slot index IS the ordinal (le_engine_finalize_layers rebuilds the
   * stacks on the same numbering), so it must fit the pool (R1 cap). */
  if (ordinal < 0 || ordinal >= LE_POOL_SLOTS) return LE_ERR_INVALID;
  if (frames <= 0 || frames > engine->max_loop_frames) return LE_ERR_INVALID;
  le_track* t = &engine->tracks[channel];
  if (load_i32(&t->a_state) != LE_TRACK_EMPTY) return LE_ERR_INVALID;
  if (t->state_cmds_posted >
      atomic_load_explicit(&t->a_state_acks, memory_order_acquire)) {
    return LE_ERR_INVALID;
  }
  /* Activate the lane if this is the first layer landing on it; a grown lane
   * takes its standard record route (input == lane index). Never reset a lane
   * already being filled. */
  if (lane >= t->lane_count) {
    for (int32_t l = t->lane_count; l <= lane; ++l) {
      le_lane_reset(&t->lanes[l], l);
    }
    t->lane_count = lane + 1;
  }
  le_lane* ln = &t->lanes[lane];
  /* Undo/redo layers are quantized to the loop length (as the live rig sizes
   * them); no path record-grows an imported slot, so full max_loop_frames is
   * unnecessary. The final size must be allocated BEFORE the copy — a later
   * ensure_slot to a larger size frees and re-zeroes the buffer. */
  int32_t want =
      ((frames + LE_LAYER_QUANTUM - 1) / LE_LAYER_QUANTUM) * LE_LAYER_QUANTUM;
  if (want > engine->max_loop_frames) want = engine->max_loop_frames;
  if (!le_lane_ensure_slot(ln, ordinal, want)) return LE_ERR_INVALID;
  memcpy(ln->pool[ordinal], pcm, (size_t)frames * sizeof(float));
  if (frames < want) {
    memset(ln->pool[ordinal] + frames, 0,
           (size_t)(want - frames) * sizeof(float));
  }
  /* Every layer of a lane shares the loop length; set it idempotently. */
  store_i32(&ln->a_len, frames);
  return LE_OK;
}

int32_t le_engine_finalize_layers(le_engine* engine, int32_t channel,
                                  int32_t undo_count, int32_t redo_count) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (undo_count < 0 || redo_count < 0) return LE_ERR_INVALID;
  const int32_t total = undo_count + 1 + redo_count;
  if (total > LE_POOL_SLOTS) return LE_ERR_INVALID; /* R1 cap */
  le_track* t = &engine->tracks[channel];
  if (load_i32(&t->a_state) != LE_TRACK_EMPTY) return LE_ERR_INVALID;
  if (t->state_cmds_posted >
      atomic_load_explicit(&t->a_state_acks, memory_order_acquire)) {
    return LE_ERR_INVALID;
  }
  const int32_t lanes = le_lanes_active(t);
  const int32_t len = load_i32(&t->lanes[0].a_len);
  if (len <= 0) return LE_ERR_INVALID;
  /* Every active lane must hold the full layer set at the same length (the
   * stacks are shared in lockstep) — reject a torn/partial reconstruction
   * rather than publish it. */
  for (int32_t l = 0; l < lanes; ++l) {
    if (load_i32(&t->lanes[l].a_len) != len) return LE_ERR_INVALID;
    for (int32_t s = 0; s < total; ++s) {
      /* Every restored slot must be allocated AND large enough to hold the loop
       * length: a mismatched-length stage (differing frames per ordinal) could
       * leave a slot shorter than `len`, which playback/export would then read
       * past. Reject rather than publish an out-of-bounds layer. */
      if (t->lanes[l].pool[s] == NULL) return LE_ERR_INVALID;
      if (t->lanes[l].pool_cap[s] < len) return LE_ERR_INVALID;
    }
  }
  /* Slot index == ordinal: undo layers occupy [0, undo_count), the live buffer
   * sits at undo_count, and the redo layers occupy the top slots newest-last
   * (mirror of le_layer_slot_for_ordinal). */
  for (int32_t i = 0; i < undo_count; ++i) t->undo_stack[i] = i;
  t->undo_count = undo_count;
  for (int32_t k = 0; k < redo_count; ++k) {
    t->redo_stack[k] = undo_count + redo_count - k;
  }
  t->redo_count = redo_count;
  t->empty_len = 0;
  t->start_iter = 0;
  const int32_t live = undo_count;
  for (int32_t l = 0; l < lanes; ++l) store_i32(&t->lanes[l].a_live, live);
  store_i32(&t->a_undo_depth, undo_count);
  store_i32(&t->a_redo_depth, redo_count);
  return LE_OK;
}

int32_t le_engine_commit_session(le_engine* engine, int32_t base_frames) {
  return le_push(engine, LE_CMD_COMMIT_SESSION, base_frames, 0.0f);
}
