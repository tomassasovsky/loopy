/*
 * engine_commands.c — control-thread command producers + record/undo machinery.
 *
 * THREAD OWNERSHIP: control thread (the Dart-facing FFI setters). Almost every
 * function here validates its arguments and posts a command into the SPSC ring
 * (le_push) for the audio thread to apply; the exceptions do control-thread work
 * the audio thread is guaranteed not to race — the O(1) undo/redo buffer-index
 * swaps, the shadow-slot supply + retired-layer collection (le_engine_drain_events),
 * the quantize/auto-record arm bookkeeping, and the lazy effect-buffer / lane
 * allocation in le_fx_prepare_entry / le_engine_set_lane_count.
 *
 * Undo layers are captured PER OVERDUB PASS on the audio thread (backup-on-write
 * into a pre-posted shadow slot — see engine_process.c); completed layers come
 * back through the evt_ring and are pushed onto the control-side stacks here.
 * Control mutations follow push-then-mutate: state is only changed after the
 * matching ring command was accepted, so a full ring never desyncs the two sides.
 *
 * Split verbatim out of engine.c (S1) behind the unchanged ABI. Shared helpers
 * (le_push, valid_channel, le_lanes_active, le_lane_reset)
 * come from engine_core.h; the octaver Hann init + PV sizes from engine_fx.h. The
 * matching audio-thread consumers (apply_command + handlers) are in
 * engine_process.c.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "audio_ring.h"  /* le_audio_ring_init (performance-recording rings) */
#include "engine_core.h" /* le_push, valid_channel, le_lanes_active, le_*_reset */
#include "engine_fx.h"   /* le_fx_ensure_hann, LE_PV_N / LE_PV_BINS */
#include "engine_private.h"
#include "layer_staging_ring.h" /* le_layer_staging_ring_push (retired-layer persistence) */
#include "loopy_engine_api.h"
#include "perf_drain.h"     /* le_perf_drain_start/stop (capture-to-disk thread) */
#include "perf_log_ring.h"  /* le_perf_log_ring_push (control-side event log) */
#include "tempo_grid.h"     /* le_grid_signature_valid, le_grid_div bounds */

/* Whether the track's history is entirely erased-take material — i.e. its top
 * entry is a clear restore point, so everything on the stack belongs to a take
 * the user cleared. Such history yields to a fresh recording (it never outranks
 * one), which is what le_grid_still_needed and le_drop_clear_history rely on. */
static int le_history_is_cleared(const le_track* t) {
  return t->undo_count > 0 &&
         t->undo_stack[t->undo_count - 1].kind == LE_HIST_CLEAR;
}

/* Republishes what the host may read off a snapshot: how many overdub layers
 * undo can peel RIGHT NOW, and whether the next undo restores a cleared take.
 *
 * a_undo_depth is not the raw entry count. Its published contract is "available
 * undo steps (overdub layers)" (loopy_engine_api.h), and a cleared track's
 * layers are not steps yet — they sit under a restore point and only become
 * peelable once it is undone. Publishing the raw count there would report peel
 * depth on an EMPTY track, breaking both that contract and the host's
 * EMPTY => undoDepth == 0 invariant. The restore point gets its own flag
 * instead, so "undo does something" stays answerable without conflating the two.
 *
 * The pair is stored non-atomically with respect to each other; a host reading
 * between them sees at worst a stale flag on the next poll, the same tolerance
 * every other published depth already carries. */
static void le_publish_undo_depth(le_track* t) {
  const int cleared = le_history_is_cleared(t);
  store_i32(&t->a_undo_depth, cleared ? 0 : t->undo_count);
  store_i32(&t->a_clear_restore, cleared ? 1 : 0);
}

/* Returns a pool slot INDEX that is neither the (shared) live index, nor
 * referenced by either undo/redo stack, nor posted to the audio thread as a
 * shadow (outstanding). The same index names the snapshot in every lane — the
 * undo span is lockstep across lanes — so this works on the track-level stacks
 * plus lane 0's live index (all lanes share it). If the pool is full, evicts
 * the oldest undo entry and reuses its slot (never an audio-held one). Returns
 * -1 only if nothing can be freed. Allocation of the slot's buffers happens per
 * lane in le_post_dub_shadows. */
static int track_acquire_slot(le_track* t) {
  const int live = load_i32(&t->lanes[0].a_live);
  for (int i = 0; i < LE_POOL_SLOTS; ++i) {
    if (i == live) continue;
    int used = 0;
    for (int k = 0; k < t->undo_count && !used; ++k) {
      if (t->undo_stack[k].slot == i) used = 1;
    }
    for (int k = 0; k < t->redo_count && !used; ++k) {
      if (t->redo_stack[k].slot == i) used = 1;
    }
    for (int k = 0; k < t->outstanding_count && !used; ++k) {
      if (t->outstanding_slots[k] == i) used = 1;
    }
    if (!used) return i;
  }
  /* Pool full: evict the oldest evictable undo entry. Layers are fair game —
   * losing the deepest one costs peel depth and nothing else.
   *
   * The LE_HIST_CLEAR skip is belt-and-braces, NOT a live path: a restore point
   * only sits on the undo stack while its track is EMPTY, and an EMPTY track
   * posts no dub shadows, so nothing acquires against a stack holding one. (Once
   * undone it moves to the redo stack, where the `used` scan above pins its slot
   * — and a punch-in discards it via le_clear_redo before acquiring anyway.)
   * The invariant is subtle and lives in three places, so this stays: if it ever
   * breaks, degrading peel depth is survivable and recycling the erased take's
   * buffer into a live recording is not. Deliberately untested — the mutation
   * that removes it cannot be caught, because the path cannot be reached. */
  for (int e = 0; e < t->undo_count; ++e) {
    if (t->undo_stack[e].kind == LE_HIST_CLEAR) continue;
    const int slot = t->undo_stack[e].slot;
    for (int k = e + 1; k < t->undo_count; ++k) {
      t->undo_stack[k - 1] = t->undo_stack[k];
    }
    t->undo_count--;
    le_publish_undo_depth(t);
    return slot;
  }
  return -1;
}

/* How many shadow slots control keeps posted to the audio thread per capturing
 * track: the armed one plus one spare, so a pass boundary can rotate without
 * waiting a control round-trip. */
#define LE_DUB_SHADOWS 2

/* The track's SETTLED loop length, or 0 when it has none yet. A track still
 * RECORDING publishes a_len as its GROWING record position (the per-block
 * publish in engine_process.c), not the final loop length — so a_len must never
 * be used to size an undo-layer slot mid-capture. The pass that fills such a
 * slot covers the FINAL length (le_dub_session_start latches dub_len at
 * finalize), so a slot sized to a partial length would be written past its end
 * by the audio thread's backup-on-write. Callers read 0 as "not settled": size
 * at the cap, and don't resize. */
static int32_t le_track_settled_len(le_track* t) {
  if (load_i32(&t->a_state) == LE_TRACK_RECORDING) return 0;
  return load_i32(&t->lanes[0].a_len);
}

/* The buffer an undo layer for a settled `len`-frame loop needs: the length
 * rounded up to LE_LAYER_QUANTUM, capped at the recording cap — a 2 s loop's
 * layer costs ~2 s of floats, not the cap. `len <= 0` (not settled — a pre-arm
 * posted while the loop is still being recorded) can only be served by the full
 * cap; le_handle_retired shrinks such a slot back to size once its pass retires
 * and the real length is known. */
static int32_t le_layer_slot_frames(const le_engine* engine, int32_t len) {
  if (len <= 0) return engine->max_loop_frames;
  const int32_t want =
      ((len + LE_LAYER_QUANTUM - 1) / LE_LAYER_QUANTUM) * LE_LAYER_QUANTUM;
  return want > engine->max_loop_frames ? engine->max_loop_frames : want;
}

/* Tops the track's posted shadow slots up to `target` (control thread):
 * acquires a free pool slot, lazily allocates its buffer on every active lane,
 * and posts it via LE_CMD_DUB_SHADOW. Push-then-mutate: the slot only becomes
 * `outstanding` once the ring accepted the command (a lazily allocated buffer
 * stays in the pool either way). The audio thread arms the slot as its next
 * shadow; the ring's release/acquire publishes the fresh buffers, exactly like
 * the fx delay-line pattern.
 *
 * `target` is LE_DUB_SHADOWS (armed + spare) for a running dub session, but 1
 * for a pre-arm during RECORDING: the length is not settled there, so each slot
 * costs the full recording cap, and only the first wrap's pass needs one — its
 * spare arrives from the running session's replenish right after finalize, when
 * the length is settled and the slot is loop-length-quantized. Capped at
 * LE_DUB_SHADOWS. */
static void le_post_dub_shadows(le_engine* engine, int32_t channel,
                                int32_t target) {
  le_track* t = &engine->tracks[channel];
  const int32_t lanes = le_lanes_active(t);
  const int32_t want = le_layer_slot_frames(engine, le_track_settled_len(t));
  if (target > LE_DUB_SHADOWS) target = LE_DUB_SHADOWS;
  while (t->outstanding_count < target) {
    const int slot = track_acquire_slot(t);
    if (slot < 0) return; /* pool exhausted beyond eviction: skip boundaries */
    int ok = 1;
    for (int32_t l = 0; l < lanes; ++l) {
      if (!le_lane_ensure_slot(&t->lanes[l], slot, want)) {
        ok = 0; /* OOM: do not post a torn slot */
      }
    }
    if (!ok) return;
    if (le_push_cmd(engine, (le_command){.code = LE_CMD_DUB_SHADOW,
                                         .lanei = {channel, 0, slot}}) !=
        LE_OK) {
      return; /* ring full: try again on the next drain/press */
    }
    t->outstanding_slots[t->outstanding_count++] = slot;
  }
}

/* Whether a fresh capture on [channel] is bound to continue straight into
 * overdub, so its shadow slots are worth pre-arming during RECORDING — letting
 * the first wrap's pass back up on write and retire as its own undo layer
 * instead of merging into the base. rec/dub mode continues any second-press
 * finalize into overdub, so any capture qualifies when it is on. With rec/dub
 * off, only a non-defining capture (master already exists) with a fixed loop
 * multiple auto-finalizes into overdub; a defining capture, or one with an auto
 * multiple, finalizes to playback and is skipped so it never strands a pre-armed
 * slot (cap-sized, since the length is unknown until finalize).
 *
 * Known, deliberate exclusion: an auto-multiple capture that records all the
 * way to the buffer cap rolls into overdub (advance_transport_frame's
 * record_pos >= max_loop_frames auto-finalize) with no pre-armed slot, so that
 * first wrap merges into the base — the pre-fix behaviour. Covering it would
 * mean pre-arming every auto-multiple capture, stranding a cap-sized slot on
 * the common record-to-playback flow, to benefit only a capture held for the
 * entire cap (30 s+) without a press.
 *
 * `has_master` comes from the CALLER, never re-read from a_master_len here: a
 * caller that just pushed the internal grid-redefine CLEAR (le_engine_record's
 * fresh-take branch) already knows the capture will be defining, while the
 * atomic stays stale until the audio thread applies that CLEAR — re-reading it
 * would pre-arm exactly the defining capture this gate exists to skip. */
static int le_capture_may_overdub(le_engine* engine, int32_t channel,
                                  int has_master) {
  if (engine->rec_dub) return 1;
  if (!has_master) return 0;
  return le_effective_multiple(engine, channel) > 0;
}

/* Pushes onto the redo stack, refusing rather than running off the end.
 *
 * Most entries name a distinct pool slot, so live + undo + redo + outstanding <=
 * LE_POOL_SLOTS bounds the stacks implicitly. Two pushes escape that bound by
 * naming the ALREADY-live slot and consuming no new one: undo-to-empty's, and
 * the clear restore point's (#219). Today the totals still fit — LE_DUB_SHADOWS
 * keeps 2 slots outstanding while dubbing, so undo tops out at LE_POOL_SLOTS - 3
 * and redo peaks one index short of the end — but that is a one-slot margin
 * resting on a constant that has nothing to do with undo. Bound it explicitly
 * instead of leaving the arrays safe by coincidence. */
static int le_redo_push(le_track* t, le_hist_entry e) {
  if (t->redo_count >= LE_POOL_SLOTS) return 0;
  t->redo_stack[t->redo_count++] = e;
  return 1;
}

/* One undo step on a track that has stacked layers (control thread): swap the
 * live pool index back to the top undo snapshot and push the previous live onto
 * the redo stack — every active lane in lockstep (the one undo span). The
 * caller has verified the track is not capturing and no layer is in flight.
 *
 * The redo push cannot fail here: it moves one entry off the undo stack for the
 * one it adds, so the total is unchanged. Losing the redo step would still beat
 * corrupting the struct, hence the guard rather than an assert. */
static void le_undo_swap(le_track* t) {
  const int32_t prev = t->undo_stack[--t->undo_count].slot;
  const int32_t lanes = le_lanes_active(t);
  (void)le_redo_push(t, le_hist_layer(load_i32(&t->lanes[0].a_live)));
  for (int32_t l = 0; l < lanes; ++l) store_i32(&t->lanes[l].a_live, prev);
  le_publish_undo_depth(t);
  store_i32(&t->a_redo_depth, t->redo_count);
}

/* Clears a track's redo history (control thread) — a fresh action (punch-in,
 * new recording, session import) invalidates the resurrect path, including the
 * undone-to-empty length. */
static void le_clear_redo(le_track* t) {
  t->redo_count = 0;
  t->empty_len = 0;
  store_i32(&t->a_redo_depth, 0);
}


/* Drops a track's clear restore point(s) and the erased take beneath them
 * (control thread). A fresh capture on this track is about to record into the
 * live slot a restore point names (le_begin_empty_capture regrows and the audio
 * thread writes pool[live] in place), so the way back is gone whether or not the
 * bookkeeping admits it — and the layers under the mark belong to the erased
 * take, which the new recording replaces wholesale. Dropping both restores the
 * pre-#219 semantic exactly: after clear-then-record, undo depth is 0. */
static void le_drop_clear_history(le_track* t) {
  if (!le_history_is_cleared(t)) return;
  t->undo_count = 0;
  le_publish_undo_depth(t);
}

/* The track's effective state for control-side decisions: the target of a
 * posted-but-unapplied state-flip command (UNDO_TO_EMPTY / REDO_FROM_EMPTY /
 * CLEAR), or the published a_state once everything posted has been acked.
 * Ring FIFO makes this deterministic — no observation race. */
static int32_t le_effective_state(le_track* t) {
  /* Acquire pairs with the audio thread's release on the ack bump, so once the
   * counters match, the a_state store that preceded the ack is visible. */
  if (t->state_cmds_posted >
      atomic_load_explicit(&t->a_state_acks, memory_order_acquire)) {
    return t->pending_target;
  }
  return load_i32(&t->a_state);
}

/* Marks a successfully posted state-flip command (control thread). */
static void le_mark_state_cmd(le_track* t, int32_t target) {
  t->state_cmds_posted++;
  t->pending_target = target;
}

/* Defined below with the quantize machinery; needed by the undo-to-empty
 * paths so a pending arm can't fire a surprise recording on an emptied track. */
static void le_cancel_arm(le_engine* engine, int32_t channel);

/* Applies undo taps that were queued while a layer was in flight (control
 * thread, called from the event drain once the flight flag cleared). Each
 * queued tap peels one layer; past the last stacked layer it falls through to
 * the undo-to-empty path exactly like a live tap would. */
static void le_apply_queued_undo(le_engine* engine, int32_t channel) {
  le_track* t = &engine->tracks[channel];
  while (t->queued_undo > 0) {
    t->queued_undo--;
    if (t->undo_count > 0) {
      le_undo_swap(t);
      continue;
    }
    const int32_t st = le_effective_state(t);
    const int32_t len = load_i32(&t->lanes[0].a_len);
    if ((st != LE_TRACK_PLAYING && st != LE_TRACK_STOPPED) || len <= 0) break;
    /* Checked BEFORE the command is posted: an undo-to-empty whose resurrect
     * slot did not make it onto the redo stack would empty the track with no
     * way back — worse than declining the tap. */
    if (t->redo_count >= LE_POOL_SLOTS) break;
    if (le_push(engine, LE_CMD_UNDO_TO_EMPTY, channel, 0.0f) != LE_OK) break;
    le_cancel_arm(engine, channel);
    (void)le_redo_push(t, le_hist_layer(load_i32(&t->lanes[0].a_live)));
    t->empty_len = len;
    le_mark_state_cmd(t, LE_TRACK_EMPTY);
    le_track_set_len(t, 0); /* coherent snapshot before the audio thread
                             * applies — a poll must never see EMPTY with a
                             * stale nonzero length (mirrors the live-tap and
                             * clear paths) */
    store_i32(&t->a_multiple, 1);
    store_i32(&t->a_sync_divisor, 0); /* B3: coherent-snapshot mirror */
    store_i32(&t->a_redo_depth, t->redo_count);
    break; /* empty now — further queued taps are no-ops */
  }
  t->queued_undo = 0;
}

/* Retired-layer persistence (part 5, D-LAYER): copies a retiring layer's PCM
 * into a fresh heap buffer per active lane and hands it to the drain thread
 * via layer_staging_ring — BEFORE any pool-reclaim path (eviction, clear,
 * redo-invalidation) can let the slot's memory be overwritten by a later
 * write. No-op when not armed (checked via the published atomic — this is
 * control-thread code, so e->perf.armed, the audio-thread-local mirror, must
 * not be read here).
 *
 * Called from le_handle_retired UNCONDITIONALLY, before its generation check:
 * a generation mismatch there means "this event predates a clear," but the
 * audio genuinely played and was captured into the pool slot right up until
 * that clear — skipping the copy would silently destroy it, which is exactly
 * the hazard this part exists to close. A dropped copy (OOM, or the staging
 * ring itself full — see LE_LAYER_STAGING_RING_CAPACITY) increments a
 * dedicated overrun atomic rather than corrupting state. */
static void le_stage_retired_layer(le_engine* engine, int32_t channel,
                                   int32_t slot, uint32_t generation) {
  if (!atomic_load_explicit(&engine->a_perf_armed, memory_order_acquire)) {
    return;
  }
  if (channel < 0 || channel >= engine->track_count) return;
  le_track* t = &engine->tracks[channel];
  const int32_t frame_count = load_i32(&t->lanes[0].a_len);
  if (frame_count <= 0) return; /* nothing recorded into this slot */
  const int32_t lane_count = le_lanes_active(t);

  le_staged_layer entry = {0};
  entry.channel = channel;
  entry.lane_count = lane_count;
  entry.frame_count = frame_count;
  entry.slot = slot;
  entry.generation = generation;
  entry.frame = atomic_load_explicit(&engine->a_perf_frames,
                                     memory_order_relaxed);

  for (int32_t l = 0; l < lane_count; ++l) {
    const float* src = t->lanes[l].pool[slot];
    if (src == NULL) {
      /* Shouldn't happen for an active lane whose track just retired a pass
       * on this slot (le_post_dub_shadows allocates every active lane's
       * buffer before posting it) — fail closed rather than copy garbage. */
      for (int32_t k = 0; k < l; ++k) free(entry.lane_pcm[k]);
      atomic_fetch_add_explicit(&engine->a_perf_layer_overruns, 1u,
                                memory_order_relaxed);
      return;
    }
    float* copy = (float*)malloc((size_t)frame_count * sizeof(float));
    if (copy == NULL) {
      for (int32_t k = 0; k < l; ++k) free(entry.lane_pcm[k]);
      atomic_fetch_add_explicit(&engine->a_perf_layer_overruns, 1u,
                                memory_order_relaxed);
      return;
    }
    memcpy(copy, src, (size_t)frame_count * sizeof(float));
    entry.lane_pcm[l] = copy;
  }

  if (!le_layer_staging_ring_push(&engine->perf.layer_staging_ring, entry)) {
    for (int32_t l = 0; l < lane_count; ++l) free(entry.lane_pcm[l]);
    atomic_fetch_add_explicit(&engine->a_perf_layer_overruns, 1u,
                              memory_order_relaxed);
  }
}

/* Handles one retired-layer event (control thread): returns the slot from the
 * audio thread's hands (`outstanding`) onto the undo stack, right-sizes it, and
 * replenishes the spare while the dub session keeps running. */
static void le_handle_retired(le_engine* engine, const le_command* evt) {
  const int32_t ch = evt->evt.channel;
  if (ch < 0 || ch >= engine->track_count) return;
  le_track* t = &engine->tracks[ch];
  le_stage_retired_layer(engine, ch, evt->evt.slot, evt->evt.generation);
  if (evt->evt.generation != t->dub_generation) {
    return; /* pre-clear era: the slot was already reclaimed by the clear */
  }
  for (int k = 0; k < t->outstanding_count; ++k) {
    if (t->outstanding_slots[k] == evt->evt.slot) {
      t->outstanding_slots[k] = t->outstanding_slots[--t->outstanding_count];
      break;
    }
  }
  /* Right-size a slot that was pre-armed at the recording cap because the loop
   * length was not settled while it was still being recorded (the first wrap's
   * layer, and its spare). The length is settled now and the audio thread has
   * handed the slot back — the retire event IS that hand-off, and the slot is
   * never the live one — so the control thread can shrink it to the same
   * loop-length-quantized size every other layer gets. Without this the cap
   * (30 s by default, up to minutes if the user raised it) would stay pinned
   * per lane for the rest of the session. The retired PCM is preserved: the
   * shrink keeps the leading frames, and the staging copy above already ran.
   * An unsettled length (a fresh capture already re-armed this track) skips the
   * resize rather than risk truncating the layer — leaving it oversized is
   * always safe. */
  const int32_t len = le_track_settled_len(t);
  if (len > 0) {
    const int32_t want = le_layer_slot_frames(engine, len);
    const int32_t lanes = le_lanes_active(t);
    for (int32_t l = 0; l < lanes; ++l) {
      le_lane_shrink_slot(&t->lanes[l], evt->evt.slot, want);
    }
  }
  if (t->undo_count < LE_POOL_SLOTS) {
    t->undo_stack[t->undo_count++] = le_hist_layer(evt->evt.slot);
    le_publish_undo_depth(t);
  }
  if (load_i32(&t->a_layer_in_flight)) {
    /* the dub continues: keep armed + spare posted */
    le_post_dub_shadows(engine, ch, LE_DUB_SHADOWS);
  }
}

void le_engine_drain_events(le_engine* engine) {
  if (engine == NULL) return;
  le_command evt;
  while (le_ring_pop(&engine->evt_ring, &evt)) {
    if (evt.code == LE_EVT_LAYER_RETIRED) le_handle_retired(engine, &evt);
  }
  /* Queued undo taps apply once their track's flight flag clears. The audio
   * thread pushes the final retire event BEFORE clearing the flag (the push is
   * the release), so after an acquire-load reads 0 one more pop pass is
   * guaranteed to see that event — then the stack is complete and the queued
   * taps peel the layers the user asked for.
   *
   * The same sweep replenishes shadow slots for any in-flight session (armed +
   * spare), and pre-arms ONE for a track that is still RECORDING but bound to
   * run straight into overdub (rec/dub, or a non-defining fixed multiple). The
   * length is not settled mid-capture, so a pre-armed slot is cap-sized
   * (le_post_dub_shadows) — one is all the first wrap needs, and its spare
   * comes from this same sweep's in-flight branch right after finalize, when
   * the slot is loop-length-quantized. Arming BEFORE the finalize->overdub
   * transition is what lets the first wrap's pass back up on write and retire
   * as its own undo layer — instead of running un-backed and merging into the
   * base. A base loop so short it finalizes before this post lands falls back
   * to the merge, the same coherent behaviour as spare starvation. */
  for (int32_t ch = 0; ch < engine->track_count; ++ch) {
    le_track* t = &engine->tracks[ch];
    const int in_flight =
        atomic_load_explicit(&t->a_layer_in_flight, memory_order_acquire);
    /* Effective state, not raw a_state: a CLEAR / undo-to-empty pushed but not
     * yet applied means this track is about to be EMPTY — pre-arming it would
     * post a cap-sized slot straight into the clear's path (the same unacked
     * window every control-side decision in this file guards with
     * le_effective_state). */
    const int recording = le_effective_state(t) == LE_TRACK_RECORDING;
    if (in_flight) {
      le_post_dub_shadows(engine, ch, LE_DUB_SHADOWS);
    } else if (recording &&
               le_capture_may_overdub(engine, ch,
                                      load_i32(&engine->a_master_len) > 0)) {
      /* The a_master_len read is safe here BECAUSE effective state said
       * RECORDING: that required acquiring the ack of every pending state
       * command, and handle_clear stores its master reset before its ack's
       * release — so a defining capture behind an internal grid-redefine
       * clear always reads 0, never the dead grid's stale length. */
      le_post_dub_shadows(engine, ch, 1);
    }
    if (t->queued_undo <= 0) continue;
    if (in_flight) continue; /* still capturing/draining: keep waiting */
    while (le_ring_pop(&engine->evt_ring, &evt)) {
      if (evt.code == LE_EVT_LAYER_RETIRED) le_handle_retired(engine, &evt);
    }
    le_apply_queued_undo(engine, ch);
  }
}

/* Zeroes every active lane's live buffer (control thread) before a fresh capture
 * over an existing master, so any unrecorded tail of a rounded-up multi-loop
 * length plays as silence. The track is EMPTY, so the audio thread is not
 * reading it. (Defining recordings — no master yet — use record_pos bounds and
 * need none.) */
static void le_prepare_new_capture(le_engine* engine, le_track* t) {
  const size_t n = (size_t)engine->max_loop_frames; /* mono */
  const int32_t lanes = le_lanes_active(t);
  for (int32_t l = 0; l < lanes; ++l) {
    le_lane* ln = &t->lanes[l];
    const int live = load_i32(&ln->a_live);
    /* A recording target must hold the full cap: undo may have swapped a
     * loop-length-quantized snapshot slot into a_live. Grow-only-if-allocated:
     * a never-used lane stays lazily NULL (the audio thread's null guard
     * plays/records it as silence, unchanged). The track is EMPTY, so the
     * audio thread never dereferences the slot while it regrows. */
    if (ln->pool[live] == NULL) continue;
    if (!le_lane_ensure_slot(ln, live, engine->max_loop_frames)) continue;
    memset(ln->pool[live], 0, n * sizeof(float));
  }
}

/* The effective quantize state for [channel]: its per-track override, or the
 * global default when the track inherits (override < 0). */
static int le_effective_quantize(const le_engine* engine, int32_t channel) {
  const int ov = engine->track_quantize[channel];
  return ov < 0 ? engine->quantize : ov;
}

/* Cancels a pending quantized arm (control thread): disarms and tells the
 * audio thread to clear the pending flag. Arming creates no undo layer (layers
 * are captured per pass once the overdub actually runs), so there is nothing
 * to reverse. No-op when the track is not armed. */
static void le_cancel_arm(le_engine* engine, int32_t channel) {
  if (!engine->armed[channel]) return;
  engine->armed[channel] = 0;
  le_push(engine, LE_CMD_DISARM, channel, 0.0f);
}

/* Whether any track is driving the loop clock (playing or capturing). A
 * quantized action can only fire at a loop top if the transport is actually
 * ticking — with everything parked or empty the clock is HELD at the top
 * (advance_transport_frame's idle branch), so a deferred action would wait
 * forever. Callers act immediately instead: the held position IS the top. */
static int le_transport_active(le_engine* engine) {
  for (int32_t c = 0; c < engine->track_count; ++c) {
    const int32_t st = le_effective_state(&engine->tracks[c]);
    if (st == LE_TRACK_PLAYING || st == LE_TRACK_RECORDING ||
        st == LE_TRACK_OVERDUBBING) {
      return 1;
    }
  }
  return 0;
}

/* Whether the kept master grid is still needed by any track OTHER than
 * [channel]: content (or a pending length), an undo history, or an
 * undone-to-empty redo history that would resurrect onto that grid. When
 * nothing needs it, a fresh recording is free to redefine the tempo. */
static int le_grid_still_needed(le_engine* engine, int32_t channel) {
  for (int32_t c = 0; c < engine->track_count; ++c) {
    le_track* o = &engine->tracks[c];
    if (c == channel) continue;
    if (le_effective_state(o) != LE_TRACK_EMPTY) return 1;
    if (load_i32(&o->lanes[0].a_len) > 0) return 1;
    /* A cleared sibling's history does NOT hold the grid: its restore point
     * yields to this fresh recording (le_drop_clear_history runs when the take
     * starts), exactly as the pre-#219 clear — which reset the stack outright —
     * left nothing here to find. Counting it would lock the new loop to the
     * dead tempo, the very ghost-grid bug this function exists to prevent. */
    if (le_history_is_cleared(o)) continue;
    if (o->undo_count > 0 || o->redo_count > 0 || o->empty_len > 0) return 1;
  }
  return 0;
}

/* One-time bookkeeping for a capture starting (or arming) on an EMPTY track
 * (control thread): a fresh take invalidates redo history (including the
 * undone-to-empty resurrect length), cancels queued undo taps, and unmutes
 * every active lane so the new recording is always audible — a Stop-muted or
 * cleared track never records into silence. The mute commands ride the ring so
 * they order before the record/arm command that follows.
 *
 * NO shadow slots are posted here: the loop length is unknown until finalize,
 * so a slot allocated now would have to be recording-cap-sized — defeating the
 * loop-length quantization. Instead the capture start DROPS any leftover armed
 * slots audio-side (handle_record's EMPTY case; they may be sized for a
 * previous, shorter loop) and `outstanding` is reclaimed here — safe because
 * an EMPTY track can have no layer in flight, hence no retire events to
 * mis-attribute, and nothing re-posts this track's slots until content exists.
 * A capture that runs straight into overdub (rec/dub, fixed multiple) instead
 * gets cap-sized slots pre-armed after the RECORD command (le_engine_record) or
 * by the RECORDING branch of le_engine_drain_events, so they are in hand at the
 * finalize->overdub transition and the first wrap's pass backs up on write as
 * its own undo layer. Only if the loop finalizes before that post lands does
 * the first pass go un-backed and merge into the next boundary — coherent,
 * never torn, the spare-starvation fallback. */
static void le_begin_empty_capture(le_engine* engine, int32_t channel) {
  le_track* t = &engine->tracks[channel];
  le_clear_redo(t);
  /* Same invalidation, one level up: a fresh take also kills any way back to a
   * cleared one, because the loop below regrows pool[live] and the audio thread
   * then records into that very slot — the one a restore point names. */
  le_drop_clear_history(t);
  t->queued_undo = 0;
  const int32_t lanes = le_lanes_active(t);
  for (int32_t l = 0; l < lanes; ++l) {
    /* A fresh capture can grow to the recording cap, but undo may have left a
     * loop-length-quantized snapshot slot live — regrow it first
     * (grow-only-if-allocated: never-used lanes stay lazily NULL). Safe here:
     * the track is (effectively) EMPTY, so the audio thread reads the pointer
     * but never dereferences it, and the RECORD/ARM command that changes that
     * is only pushed after this returns (ring FIFO). Same pattern as
     * le_engine_set_lane_count's live-lane allocation. */
    le_lane* ln = &t->lanes[l];
    const int live = load_i32(&ln->a_live);
    if (ln->pool[live] != NULL) {
      le_lane_ensure_slot(ln, live, engine->max_loop_frames);
    }
    le_push_cmd(engine, (le_command){.code = LE_CMD_SET_LANE_MUTE,
                                     .lanef = {channel, l, 0.0f}});
  }
  t->outstanding_count = 0; /* reclaim; audio drops its armed slots at start */
}

/* One-time bookkeeping for an overdub punch-in (or arm) over existing content
 * (control thread): invalidates redo, cancels queued undo taps, and supplies
 * the audio thread's shadow slots for per-pass layer capture. No snapshot is
 * copied here — the first pass's backup-on-write captures the pre-dub content
 * incrementally on the audio thread. */
static void le_begin_punch_in(le_engine* engine, int32_t channel) {
  le_track* t = &engine->tracks[channel];
  /* Part 5 (D-LAYER): le_clear_redo below discards redo_stack's slot
   * references — the redo-invalidation hazard (undo, then a fresh punch-in)
   * the plan calls out by name. The caller (le_engine_record) already drained
   * once at its own top, but a previous dub session's tail can still be
   * draining/retiring asynchronously (a_layer_in_flight can outlive the
   * state's return to PLAYING/STOPPED, which is this function's own
   * precondition) — so a fresh retire event could have landed in evt_ring in
   * the interim. Draining again here, immediately before the discard,
   * shrinks that window from "however long since the last poll" to the
   * handful of instructions in between (it can't be fully closed without
   * blocking on the audio thread, which this control-thread-only fix
   * deliberately does not do — see le_stage_retired_layer, which persists
   * the event's PCM regardless of by the time it IS drained). */
  le_engine_drain_events(engine);
  le_clear_redo(t);
  t->queued_undo = 0;
  le_post_dub_shadows(engine, channel, LE_DUB_SHADOWS);
}

int32_t le_engine_record(le_engine* engine, int32_t channel) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  le_engine_drain_events(engine);
  le_track* t = &engine->tracks[channel];
  const int32_t st = le_effective_state(t);
  /* The track's length (k * base) — all lanes share it, so lane 0 is canonical.
   * Kept coherent with the effective state: the undo-to-empty / redo-from-empty
   * paths store it control-side when they post. */
  const int32_t len = load_i32(&t->lanes[0].a_len);
  int has_master = load_i32(&engine->a_master_len) > 0;

  /* A fresh take on an otherwise-empty looper redefines the grid. Undo-to-
   * empty deliberately keeps the master (redo needs it), but once the user
   * records fresh — invalidating this track's redo — a ghost grid would lock
   * the new loop to the dead tempo (and a quantized press would arm for a
   * loop top the held clock never reaches). An internal clear resets the
   * master through handle_clear's all-empty path, making this the defining
   * recording — unless a sibling still needs the grid (content, undo, or an
   * undone-to-empty redo that resurrects onto it). */
  if (st == LE_TRACK_EMPTY && !le_grid_still_needed(engine, channel)) {
    /* Nothing else holds the grid, so this take defines it — which is the rule
     * that retires every cleared track's restore point (#219), not just this
     * track's. A restore point records the master length it was cleared under;
     * once a new take redefines that base, putting the old take back would drop
     * it onto a grid it was never cut to. The way back dies with the old tempo.
     *
     * This runs whether or not there is a master to reset (a whole-rig clear
     * already zeroed it), so it must sit outside the has_master check below —
     * that one only decides whether an internal CLEAR is needed to reset a grid
     * that is still standing. */
    for (int32_t c = 0; c < engine->track_count; ++c) {
      le_drop_clear_history(&engine->tracks[c]);
    }
    if (has_master && le_engine_clear(engine, channel) == LE_OK) {
      has_master = 0; /* the CLEAR ahead of us in the ring resets the grid */
    }
  }

  /* No engine self-snapshot on record: the host (LooperRepository) is the sole
   * record-time snapshot authority and pushes each take's lane FX through the
   * command ring like any other lane edit. The engine is a pure sink — it holds
   * only what the host pushes, so there is no second, ring-deferred computation
   * to race or diverge (the dry-take-when-FX-monitored bug). The internal CLEAR
   * that may ride ahead of us (grid redefinition, above) resets only the master
   * grid / buffers via handle_clear — it does NOT touch lane FX — so the host's
   * pushed chain, queued before this record command, is never clobbered. */

  /* Sound-activated: a record press on an empty track arms a signal-triggered
   * start (LE_CMD_ARM with trigger 1); the audio thread begins recording the
   * first frame the input crosses the threshold. A second press cancels. Takes
   * precedence over quantize for the start — finalize/overdub presses (the
   * track is no longer EMPTY) fall through to the quantize/immediate paths.
   * A DEFINING press with count-in enabled skips this arm entirely (D9:
   * count-in wins when both are somehow set at once) and falls through to the
   * immediate path, where the audio thread starts the count-in. */
  if (engine->auto_record && st == LE_TRACK_EMPTY &&
      !(engine->count_in_bars > 0 && !has_master)) {
    if (engine->armed[channel] && load_i32(&t->a_pending) == 0) {
      engine->armed[channel] = 0; /* spent: the signal already fired it */
    }
    if (engine->armed[channel]) {
      /* B3b BUG 2 (adversarial review): armed[]/armed_trigger[] is shared
       * across every arm-capable command on this channel (auto-record here,
       * the quantize arm below, and le_engine_toggle_section's trigger 2).
       * A pending arm belonging to a DIFFERENT trigger must be rejected,
       * not silently cancelled — treating "someone else's live arm" as
       * "my own second press" would swallow their pending action with no
       * error to either caller. */
      if (engine->armed_trigger[channel] != 1) return LE_ERR_INVALID;
      engine->armed[channel] = 0;
      return le_push(engine, LE_CMD_DISARM, channel, 0.0f);
    }
    engine->armed[channel] = 1;
    engine->armed_trigger[channel] = 1; /* input-level trigger */
    le_begin_empty_capture(engine, channel);
    le_prepare_new_capture(engine, t);
    return le_push(engine, LE_CMD_ARM, channel, 1.0f);
  }

  /* Quantized: defer the action to the next base-loop top instead of acting on
   * the press, so captures align to the grid. The defining recording (no master
   * yet) always acts immediately — it sets the grid. So does a press while the
   * transport is held (everything parked/empty): the clock never ticks then, a
   * deferred arm would deadlock, and the held position IS the loop top, so
   * immediate is on-grid by definition. Per-track overrides win over the
   * global default.
   *
   * B3, D16: a Sync/Band non-primary EMPTY track's DEFINING recording is
   * ALSO force-armed here, regardless of the ordinary quantize setting —
   * the manual's "automatically quantized to keep them in sync with the
   * primary track" (song-mode-spec.md §1). Scoped to st == EMPTY only:
   * this is what makes the take START at the loop top (record_pos seeds to
   * e->clock.position, which the fire lands on exactly 0), the
   * precondition finalize_new_track's division-playback formula depends on
   * (mix_tracks_frame reads a division phase-locked to the primary's top,
   * which only holds if the take BEGAN there). Finalize / punch-in
   * quantization is unaffected — governed only by the ordinary setting,
   * unchanged. */
  const int sync_force_arm =
      st == LE_TRACK_EMPTY && le_sync_quantize_active(engine, channel);
  if ((le_effective_quantize(engine, channel) || sync_force_arm) &&
      has_master && le_transport_active(engine)) {
    /* If we armed this track but the boundary already fired it, the arm is
     * spent (published a_pending cleared); fall through to a fresh decision on
     * the now-current state. */
    if (engine->armed[channel] && load_i32(&t->a_pending) == 0) {
      engine->armed[channel] = 0;
    }
    if (engine->armed[channel]) {
      /* B3b BUG 2 (adversarial review, see the auto-record branch above for
       * the full rationale): reject rather than cancel a DIFFERENT
       * trigger's pending arm. */
      if (engine->armed_trigger[channel] != 0) return LE_ERR_INVALID;
      /* Second press before the boundary cancels the pending action. */
      engine->armed[channel] = 0;
      return le_push(engine, LE_CMD_DISARM, channel, 0.0f);
    }
    /* Arm: do the one-time prep an immediate record would, then defer. */
    engine->armed[channel] = 1;
    engine->armed_trigger[channel] = 0; /* loop-top trigger */
    if (st == LE_TRACK_EMPTY) {
      le_begin_empty_capture(engine, channel);
      le_prepare_new_capture(engine, t);
    } else if ((st == LE_TRACK_PLAYING || st == LE_TRACK_STOPPED) && len > 0) {
      le_begin_punch_in(engine, channel);
    }
    return le_push(engine, LE_CMD_ARM, channel, 0.0f);
  }

  /* Immediate (quantize off, or the defining recording). A pending Band
   * section-transport arm (trigger 2, le_engine_toggle_section) belongs to
   * a DIFFERENT command and must not be silently discarded here — B3b
   * BUG 2: LE_CMD_RECORD unconditionally zeroes pending_record/a_pending on
   * the audio thread with no way to tell whose arm it was clearing, so an
   * immediate record on a channel with a live toggle-section arm would
   * otherwise swallow the user's original toggle with zero error to either
   * caller. A genuinely spent arm (already fired: a_pending reads 0) still
   * decays as normal, regardless of trigger — nothing to protect there.
   * Scoped to trigger 2 specifically (not "any armed[channel]"): a stale
   * trigger-0/1 arm reaching here (e.g. quantize toggled off mid-arm)
   * predates B3b and must keep its existing behavior — falling through to
   * an immediate record — bit-identical for Multi/Sync. */
  if (engine->armed[channel] && load_i32(&t->a_pending) == 0) {
    engine->armed[channel] = 0;
  }
  if (engine->armed[channel] && engine->armed_trigger[channel] == 2) {
    return LE_ERR_INVALID;
  }
  if (st == LE_TRACK_EMPTY) {
    le_begin_empty_capture(engine, channel);
    if (has_master) le_prepare_new_capture(engine, t);
  }
  if ((st == LE_TRACK_PLAYING || st == LE_TRACK_STOPPED) && len > 0) {
    le_begin_punch_in(engine, channel);
  }
  const int32_t rc = le_push(engine, LE_CMD_RECORD, channel, 0.0f);
  /* Pre-arm ONE shadow slot for a fresh capture that is bound to run straight
   * into overdub (rec/dub, or a non-defining fixed multiple). Posted AFTER the
   * RECORD command so it orders behind handle_record's EMPTY-case drop of any
   * stale armed slots — the audio thread then arms this one during RECORDING,
   * and the finalize->overdub transition finds it already in hand, so the first
   * wrap's pass backs up on write and becomes its own undo layer. One slot, not
   * LE_DUB_SHADOWS: it is cap-sized (the length is not settled until finalize),
   * and the running session's replenish supplies the quantized spare right
   * after finalize. Not done for the deferred arm paths above: their
   * EMPTY->RECORDING transition fires later on the audio thread and would drop
   * a slot posted now — the RECORDING branch of le_engine_drain_events
   * pre-arms those instead. */
  if (rc == LE_OK && st == LE_TRACK_EMPTY &&
      le_capture_may_overdub(engine, channel, has_master)) {
    le_post_dub_shadows(engine, channel, 1);
  }
  return rc;
}

int32_t le_engine_stop_track(le_engine* engine, int32_t channel) {
  return le_push(engine, LE_CMD_STOP, channel, 0.0f);
}
int32_t le_engine_play(le_engine* engine, int32_t channel) {
  return le_push(engine, LE_CMD_PLAY, channel, 0.0f);
}
/* Builds the restore point for a clear about to be posted on `t` (control
 * thread), or returns 0 when there is nothing worth restoring — an already-empty
 * or zero-length track, or a history with no room left. Every field is read
 * BEFORE the caller mutates any of them.
 *
 * The mutes are snapshotted from the published atomics, so a mute command posted
 * but not yet applied is not seen here. That is the same snapshot tolerance the
 * rest of the control-side bookkeeping already accepts (le_track_set_len and
 * friends), and the failure mode is cosmetic: a restore may miss a mute the user
 * flipped in the same instant as the clear. */
static int le_build_restore_point(le_engine* engine, le_track* t,
                                  le_hist_entry* out) {
  if (t->undo_count >= LE_POOL_SLOTS) return 0; /* no room to push it */
  const int32_t st = le_effective_state(t);
  if (st != LE_TRACK_PLAYING && st != LE_TRACK_STOPPED) return 0;
  const int32_t len = load_i32(&t->lanes[0].a_len);
  if (len <= 0) return 0;

  le_hist_entry e = {0};
  e.kind = LE_HIST_CLEAR;
  e.slot = load_i32(&t->lanes[0].a_live);
  e.len = len;
  e.multiple = load_i32(&t->a_multiple);
  e.state = st;
  e.master_len = load_i32(&engine->a_master_len);
  const int32_t lanes = le_lanes_active(t);
  for (int32_t l = 0; l < lanes; ++l) {
    if (load_i32(&t->lanes[l].a_muted)) e.muted_mask |= 1u << l;
  }
  *out = e;
  return 1;
}

/* The shared body of both clears. `push_restore` decides which one this is:
 * le_engine_clear_undoable keeps the track's history and pushes a LE_HIST_CLEAR
 * on top of it; le_engine_clear resets the history outright. Everything else —
 * the posted command, the generation bump, the reclaim — is identical, because
 * the audio thread's view of a clear does not depend on whether control kept a
 * way back. */
static int32_t le_clear_track(le_engine* engine, int32_t channel,
                              int push_restore) {
  if (engine == NULL || channel < 0 || channel >= engine->track_count) {
    return le_push(engine, LE_CMD_CLEAR, channel, 0.0f);
  }
  le_engine_drain_events(engine);
  le_track* t = &engine->tracks[channel];
  le_hist_entry restore = {0};
  const int keep = push_restore && le_build_restore_point(engine, t, &restore);
  /* Push-then-mutate: only a clear the audio thread will actually apply may
   * reset the control-side bookkeeping (and bump the generation the audio
   * thread mirrors in handle_clear — one bump per applied CLEAR keeps the two
   * counters equal without sharing a variable). */
  const int32_t rc = le_push(engine, LE_CMD_CLEAR, channel, 0.0f);
  if (rc != LE_OK) return rc;
  /* Part 5 (D-LAYER): drain again, immediately before the reclaim below —
   * the initial drain at the top of this function catches whatever was
   * already in evt_ring, but the audio thread runs concurrently and could
   * push a fresh retire event for this track in the interim (a dub session's
   * tail can still be draining/retiring after punch-out, independent of
   * whatever triggered this clear). Every layer that reaches le_handle_retired
   * gets staged (le_stage_retired_layer) regardless of the generation check
   * that follows it, so this call's only job is to make sure any such event
   * is popped and staged BEFORE the generation bump below would otherwise
   * leave it sitting undrained while its slot becomes reclaimable — the same
   * race this part's own docs describe as narrowed, not eliminated, by a
   * control-thread-only fix. */
  le_engine_drain_events(engine);
  /* An undoable clear keeps the stack and pushes the restore point ON TOP of it:
   * the erased take's layers stay put beneath, which is what makes them peelable
   * again once the restore point is undone. A plain clear drops the lot.
   *
   * Either way the redo branch dies (le_clear_redo): a clear is a fresh action,
   * and standard undo semantics discard the redo path at one. That also keeps
   * the two stacks unambiguous — the restore point owns the redo slot from here,
   * so it cannot collide with a pre-clear redo layer. */
  if (keep) {
    t->undo_stack[t->undo_count++] = restore;
  } else {
    t->undo_count = 0;
  }
  le_clear_redo(t);
  le_publish_undo_depth(t);
  /* Reclaim every shadow slot the audio thread holds: it drops them when the
   * CLEAR applies, and any later re-post travels the command ring behind that
   * CLEAR, so a reclaimed slot can never be armed twice. The generation bump
   * makes any still-in-ring retire event from before the clear stale. */
  t->outstanding_count = 0;
  t->queued_undo = 0;
  t->dub_generation++;
  le_mark_state_cmd(t, LE_TRACK_EMPTY);
  le_track_set_len(t, 0); /* coherent snapshot before the audio thread applies */
  engine->armed[channel] = 0;
  return LE_OK;
}

int32_t le_engine_clear(le_engine* engine, int32_t channel) {
  return le_clear_track(engine, channel, 0);
}

int32_t le_engine_clear_undoable(le_engine* engine, int32_t channel) {
  return le_clear_track(engine, channel, 1);
}

/* Performance event log, control-thread side (part 3, docs/design/
 * performance-event-log-format.md): the direct-atomic setters below (FX/
 * monitor params, the limiter, overdub feedback) and the common in-track
 * undo/redo swap bypass the command ring entirely, so they push into
 * perf.log_ctrl_ring instead of relying on apply_command's emission. Reads
 * a_perf_frames as a snapshot — accurate within one buffer, which is the
 * documented tolerance for these control-side events. No-op when not armed,
 * checked via the published atomic (this runs on the control thread, not the
 * audio thread, so e->perf.armed — the audio-thread-local mirror — must not
 * be read here). */
static void le_plog_push_ctrl(le_engine* engine, le_command cmd) {
  if (!atomic_load_explicit(&engine->a_perf_armed, memory_order_acquire)) {
    return;
  }
  const uint64_t frame =
      atomic_load_explicit(&engine->a_perf_frames, memory_order_relaxed);
  const le_perf_log_entry entry = {.frame = frame, .cmd = cmd};
  if (!le_perf_log_ring_push(&engine->perf.log_ctrl_ring, entry)) {
    atomic_fetch_add_explicit(&engine->a_perf_log_ctrl_overruns, 1u,
                              memory_order_relaxed);
  }
}

/* Undo/redo run on the control thread: they swap the live pool index (atomic;
 * the audio thread's only window into the buffers) on EVERY active lane in
 * lockstep, so the one undo span moves all lanes together. Allowed only when
 * the track is not capturing AND no layer is in flight (tail/drain still
 * writing), so the audio thread sees a stable a_live — an undo tapped during
 * that window is queued and applied when the layer retires, never lost. */
/* Applies a clear restore point (control thread): the track comes back exactly
 * as the clear found it — content, length, multiple, state, mutes, and the
 * master grid if that clear reset it — with the erased take's layers still
 * stacked beneath, so undo keeps peeling from where it left off.
 *
 * Mirrors the redo-from-empty path's shape: control owns a_live and the
 * control-side length snapshot, the audio thread owns the state flip. The mutes
 * ride the ring AHEAD of the state flip, exactly as the resurrect path does, so
 * the track is never briefly audible with the wrong mute. */
static int32_t le_restore_clear(le_engine* engine, int32_t channel) {
  le_track* t = &engine->tracks[channel];
  const le_hist_entry e = t->undo_stack[t->undo_count - 1];
  const int32_t lanes = le_lanes_active(t);

  for (int32_t l = 0; l < lanes; ++l) {
    const float muted = (e.muted_mask & (1u << l)) ? 1.0f : 0.0f;
    le_push_cmd(engine, (le_command){.code = LE_CMD_SET_LANE_MUTE,
                                     .lanef = {channel, l, muted}});
  }
  le_command cmd = {.code = LE_CMD_RESTORE_CLEAR};
  cmd.restore.channel = channel;
  cmd.restore.len = e.len;
  cmd.restore.state = e.state;
  cmd.restore.master_len = e.master_len;
  if (le_push_cmd(engine, cmd) != LE_OK) return LE_ERR_INVALID;

  t->undo_count--;
  /* Cannot fail: one entry off the undo stack for the one added here. */
  (void)le_redo_push(t, e);
  for (int32_t l = 0; l < lanes; ++l) store_i32(&t->lanes[l].a_live, e.slot);
  /* Leftover armed shadows may be sized for a different loop; the audio thread
   * drops them when the command applies (same reclaim rule as redo-from-empty:
   * an EMPTY track has no layer in flight, so no retire event can be
   * mis-attributed). */
  t->outstanding_count = 0;
  le_mark_state_cmd(t, e.state);
  /* Length and multiple are DELIBERATELY not stored control-side here, unlike
   * the paths that empty a track. Those publish len 0 up front so a poll can
   * never catch EMPTY next to a stale nonzero length; this one runs the other
   * way, so doing the same would publish the restored length while a_state is
   * still EMPTY — manufacturing the very pair (EMPTY, len > 0) that the host's
   * 'depths-sane' invariant rejects. handle_restore_clear sets both, in that
   * order, so the track is only ever seen empty-and-lengthless or
   * restored-and-sized. Control-side decisions in the gap are safe without it:
   * le_mark_state_cmd below already makes le_effective_state report the
   * restored state. */
  le_publish_undo_depth(t);
  store_i32(&t->a_redo_depth, t->redo_count);
  le_plog_push_ctrl(engine,
                    (le_command){.code = LE_PLOG_UNDO, .arg_i = channel});
  return LE_OK;
}

int32_t le_engine_undo_restores_clear(le_engine* engine, int32_t channel) {
  if (engine == NULL) return 0;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return 0;
  }
  if (channel < 0 || channel >= engine->track_count) return 0;
  /* Drain first, for the same reason le_engine_undo does: a retire event still
   * in the ring would push a layer on top of the restore point, making the next
   * tap a peel rather than a restore. Answering from the undrained stack would
   * hand the caller a stale verdict it is about to act on. */
  le_engine_drain_events(engine);
  return le_history_is_cleared(&engine->tracks[channel]) ? 1 : 0;
}

int32_t le_engine_undo(le_engine* engine, int32_t channel) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  le_engine_drain_events(engine);
  le_track* t = &engine->tracks[channel];
  const int32_t st = le_effective_state(t);
  if (st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING) {
    return LE_ERR_INVALID;
  }
  if (atomic_load_explicit(&t->a_layer_in_flight, memory_order_acquire)) {
    t->queued_undo++; /* applied on retire — see le_engine_drain_events */
    return LE_OK;
  }
  /* The flight flag cleared: its final retire event was pushed before the
   * clear, so one more drain is guaranteed to have it on the stack. */
  le_engine_drain_events(engine);
  /* A clear restore point on top means the last thing that happened to this
   * track was a clear, so undoing it puts the take back rather than peeling a
   * layer. Checked before the layer path: the layers beneath the mark are the
   * erased take's, and they only become peelable again once it is restored. */
  if (le_history_is_cleared(t)) return le_restore_clear(engine, channel);
  if (t->undo_count > 0) {
    le_undo_swap(t);
    le_plog_push_ctrl(engine,
                      (le_command){.code = LE_PLOG_UNDO, .arg_i = channel});
    return LE_OK;
  }
  /* No stacked layers left: undoing the base recording itself empties the
   * track (pedal/UI see no content) while the redo stack keeps the live slot,
   * so redo can reinstate it layer by layer. The master grid is deliberately
   * kept — redo needs it, and a full reset stays Clear's job. */
  const int32_t len = load_i32(&t->lanes[0].a_len);
  if ((st != LE_TRACK_PLAYING && st != LE_TRACK_STOPPED) || len <= 0) {
    return LE_ERR_INVALID;
  }
  /* Checked BEFORE the command is posted: an undo-to-empty whose resurrect slot
   * did not make it onto the redo stack would empty the track with no way back —
   * worse than declining the tap. */
  if (t->redo_count >= LE_POOL_SLOTS) return LE_ERR_INVALID;
  if (le_push(engine, LE_CMD_UNDO_TO_EMPTY, channel, 0.0f) != LE_OK) {
    return LE_ERR_INVALID;
  }
  /* An emptied track must not have a quantized/auto-record arm still pending —
   * it would fire a surprise fresh recording at the next loop top. */
  le_cancel_arm(engine, channel);
  (void)le_redo_push(t, le_hist_layer(load_i32(&t->lanes[0].a_live)));
  t->empty_len = len;
  le_mark_state_cmd(t, LE_TRACK_EMPTY);
  le_track_set_len(t, 0); /* coherent snapshot before the audio thread applies */
  store_i32(&t->a_multiple, 1);
  store_i32(&t->a_sync_divisor, 0); /* B3: coherent-snapshot mirror */
  store_i32(&t->a_redo_depth, t->redo_count);
  return LE_OK;
}

int32_t le_engine_redo(le_engine* engine, int32_t channel) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  le_engine_drain_events(engine);
  le_track* t = &engine->tracks[channel];
  const int32_t st = le_effective_state(t);
  if (st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING) {
    return LE_ERR_INVALID;
  }
  if (atomic_load_explicit(&t->a_layer_in_flight, memory_order_acquire)) {
    return LE_ERR_INVALID; /* a fresh dub is in flight: nothing to redo */
  }
  if (t->redo_count == 0) return LE_ERR_INVALID;
  /* Redo of a restored clear: re-apply the clear the undo took back. It rides
   * the same undoable path, so the restore point returns to the undo stack and
   * the pair stays symmetric under repeated undo/redo. */
  if (t->redo_stack[t->redo_count - 1].kind == LE_HIST_CLEAR) {
    /* le_clear_track discards the whole redo branch on success (le_clear_redo),
     * so this entry goes either way — but only pop it once the clear is actually
     * posted. Popping first would drop the restore point on a failed push (ring
     * full), leaving the user with neither the redo nor the undo they had. */
    const int32_t rc = le_clear_track(engine, channel, 1);
    if (rc != LE_OK) return rc;
    le_plog_push_ctrl(engine,
                      (le_command){.code = LE_PLOG_REDO, .arg_i = channel});
    return LE_OK;
  }
  if (st == LE_TRACK_EMPTY) {
    /* Reinstate an undone-to-empty track: the redo-top slot is its base
     * content. The audio thread restores state/len/multiple on apply; the
     * length is stored control-side too so snapshots (and a racing record
     * press) are coherent immediately. */
    const int32_t len = t->empty_len;
    if (len <= 0) return LE_ERR_INVALID;
    /* Resurrection is always audible: a leftover Stop-mute would otherwise
     * bring the track back playing-but-silent (dark LED, no sound). Mirrors
     * the record-from-empty rule; the unmutes ride the ring ahead of the
     * state flip. */
    const int32_t lanes = le_lanes_active(t);
    for (int32_t l = 0; l < lanes; ++l) {
      le_push_cmd(engine, (le_command){.code = LE_CMD_SET_LANE_MUTE,
                                       .lanef = {channel, l, 0.0f}});
    }
    if (le_push_cmd(engine, (le_command){.code = LE_CMD_REDO_FROM_EMPTY,
                                         .lanei = {channel, 0, len}}) !=
        LE_OK) {
      return LE_ERR_INVALID;
    }
    const int32_t next = t->redo_stack[--t->redo_count].slot;
    for (int32_t l = 0; l < lanes; ++l) store_i32(&t->lanes[l].a_live, next);
    t->empty_len = 0;
    /* Leftover armed shadows may be sized for a different loop; the audio
     * thread drops them when the command applies. Same no-in-flight argument
     * as the record-from-empty reclaim. */
    t->outstanding_count = 0;
    le_mark_state_cmd(t, LE_TRACK_PLAYING);
    le_track_set_len(t, len);
    store_i32(&t->a_redo_depth, t->redo_count);
    return LE_OK;
  }
  const int32_t next = t->redo_stack[--t->redo_count].slot;
  const int32_t lanes = le_lanes_active(t);
  t->undo_stack[t->undo_count++] = le_hist_layer(load_i32(&t->lanes[0].a_live));
  for (int32_t l = 0; l < lanes; ++l) store_i32(&t->lanes[l].a_live, next);
  le_publish_undo_depth(t);
  store_i32(&t->a_redo_depth, t->redo_count);
  le_plog_push_ctrl(engine,
                    (le_command){.code = LE_PLOG_REDO, .arg_i = channel});
  return LE_OK;
}
int32_t le_engine_set_track_volume(le_engine* engine, int32_t channel,
                                   float volume) {
  return le_push(engine, LE_CMD_SET_VOLUME, channel, volume);
}
int32_t le_engine_set_track_mute(le_engine* engine, int32_t channel,
                                 int32_t muted) {
  return le_push(engine, LE_CMD_SET_MUTE, channel, muted ? 1.0f : 0.0f);
}

int32_t le_engine_set_input_mask(le_engine* engine, int32_t channel,
                                 int32_t mask) {
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_INPUT_MASK,
                                          .trackmask = {channel,
                                                        (uint32_t)mask}});
}
int32_t le_engine_set_output_mask(le_engine* engine, int32_t channel,
                                  int32_t mask) {
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_OUTPUT_MASK,
                                          .trackmask = {channel,
                                                        (uint32_t)mask}});
}

int32_t le_engine_set_record_offset(le_engine* engine, int32_t frames) {
  return le_push(engine, LE_CMD_SET_RECORD_OFFSET, frames, 0.0f);
}

int32_t le_engine_set_quantize(le_engine* engine, int32_t enabled) {
  if (engine == NULL) return LE_ERR_INVALID;
  engine->quantize = enabled ? 1 : 0;
  /* Cancel loop-top arms that are now effective-off so nothing is stuck waiting
   * for a loop top; force-on tracks and signal arms keep their arm. */
  for (int32_t c = 0; c < engine->track_count; ++c) {
    if (engine->armed_trigger[c] == 0 && !le_effective_quantize(engine, c)) {
      le_cancel_arm(engine, c);
    }
  }
  return LE_OK;
}

int32_t le_engine_set_track_quantize(le_engine* engine, int32_t channel,
                                     int32_t mode) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  /* mode: < 0 inherit the global default, 0 force off, > 0 force on. */
  engine->track_quantize[channel] = mode < 0 ? -1 : (mode > 0 ? 1 : 0);
  if (engine->armed_trigger[channel] == 0 &&
      !le_effective_quantize(engine, channel)) {
    le_cancel_arm(engine, channel);
  }
  return LE_OK;
}

/* ---- tempo grid (state + locks; see loopy_engine_api.h's tempo section) ----
 * Plain le_push producers: validation that needs no engine state runs here on
 * the control thread; the D6 tempo lock is enforced on the AUDIO thread
 * (apply_command), the only side that owns track states — a locked command is
 * accepted by these wrappers and dropped there. */

int32_t le_engine_set_tempo(le_engine* engine, float bpm) {
  /* Clamped to 30..300 by the audio thread on apply (matching the old stack's
   * observable clamp-on-read behaviour). */
  return le_push(engine, LE_CMD_SET_TEMPO, 0, bpm);
}

int32_t le_engine_set_time_signature(le_engine* engine, int32_t num,
                                     int32_t den) {
  /* Reject unsupported signatures outright (the audio thread re-validates so
   * a raw post_command cannot sneak one through either). */
  if (!le_grid_signature_valid(num, den)) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_TIME_SIGNATURE, num, (float)den);
}

int32_t le_engine_tap_tempo(le_engine* engine) {
  return le_push(engine, LE_CMD_TAP_TEMPO, 0, 0.0f);
}

int32_t le_engine_set_sync_tempo(le_engine* engine, int32_t on) {
  return le_push(engine, LE_CMD_SET_SYNC_TEMPO, 0, on ? 1.0f : 0.0f);
}

int32_t le_engine_set_quantize_div(le_engine* engine, int32_t div) {
  if (div < LE_GRID_DIV_OFF || div > LE_GRID_DIV_SIXTEENTH) {
    return LE_ERR_INVALID;
  }
  return le_push(engine, LE_CMD_SET_QUANTIZE_DIV, div, 0.0f);
}

/* ---- looper mode (B2a, D4; see loopy_engine_api.h's looper-mode section) ----
 * Plain le_push producer: validation that needs no engine state runs here on
 * the control thread; the D4 content lock is enforced on the AUDIO thread
 * (apply_command, le_looper_mode_locked), the only side that owns track
 * states — a locked command is accepted by this wrapper and dropped there. */

int32_t le_engine_set_looper_mode(le_engine* engine, int32_t mode) {
  if (mode < LE_LOOPER_MODE_MULTI || mode > LE_LOOPER_MODE_FREE) {
    return LE_ERR_INVALID;
  }
  return le_push(engine, LE_CMD_SET_LOOPER_MODE, mode, 0.0f);
}

/* ---- primary track / Sync + Band (B3/B3b, D16/D18) ---- */

int32_t le_engine_crown_primary(le_engine* engine, int32_t channel) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_CROWN_PRIMARY, channel, 0.0f);
}

/* ---- One Shot (B4, Sheeran manual §5.9.4; see loopy_engine_api.h's
 * LE_CMD_SET_ONE_SHOT / le_engine_set_one_shot docs for the full mode-
 * gating rationale) ---- */

int32_t le_engine_set_one_shot(le_engine* engine, int32_t channel,
                               int32_t enabled) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_ONE_SHOT, channel, enabled ? 1.0f : 0.0f);
}

/* Reuses le_engine_record's own quantize-arm TOGGLE shape (armed[] /
 * armed_trigger[], LE_CMD_ARM/DISARM) with trigger 2 instead of inventing
 * parallel bookkeeping. B3b BUG 2 (adversarial review): armed[]/
 * armed_trigger[] is shared with le_engine_record's own trigger-0/1 arms —
 * "a section-transport arm and a record arm can never coexist on the same
 * channel" is true only because BOTH sides now check armed_trigger[]
 * before treating a live arm as their own to cancel (see this function's
 * body and le_engine_record's two arm-check branches + its Immediate path)
 * — a DIFFERENT trigger's pending arm is rejected, never silently
 * cancelled. */
int32_t le_engine_toggle_section(le_engine* engine, int32_t channel) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (load_i32(&engine->a_looper_mode) != LE_LOOPER_MODE_BAND) {
    return LE_ERR_INVALID;
  }
  const int32_t primary = load_i32(&engine->a_primary_track);
  if (primary < 0 || channel == primary) return LE_ERR_INVALID;
  /* B3b BUG 1 (adversarial review): every other primary-relative decision
   * in B3/B3b consults le_sync_quantize_active before trusting e->clock as
   * "the primary's cycle" — this entry point didn't. Without an
   * established primary, D16's own fallback applies: whoever records
   * first defines e->clock, which may be a NON-primary track (the crowned
   * primary itself might still be EMPTY). Arming trigger 2 in that state
   * would fire against that other track's own clock at its own loop top,
   * not "the primary's" — directly contradicting this function's
   * documented guarantee. Reject instead: section-transport is meaningless
   * without an established primary reference. */
  if (!le_sync_quantize_active(engine, channel)) return LE_ERR_INVALID;
  le_track* t = &engine->tracks[channel];
  const int32_t st = le_effective_state(t);
  if (st == LE_TRACK_EMPTY) return LE_ERR_INVALID;
  if (!le_transport_active(engine)) {
    /* The transport is HELD (every track stopped/empty): the primary's
     * clock never ticks then, so a deferred arm would never fire — the
     * same deadlock le_engine_record's quantize branch avoids for record
     * arms (see its comment above). The held position IS the primary's
     * loop top by definition, so act immediately instead of arming. */
    return le_push(engine, st == LE_TRACK_STOPPED ? LE_CMD_PLAY : LE_CMD_STOP,
                   channel, 0.0f);
  }
  if (engine->armed[channel] && load_i32(&t->a_pending) == 0) {
    engine->armed[channel] = 0; /* spent: the boundary already fired it */
  }
  if (engine->armed[channel]) {
    /* B3b BUG 2 (adversarial review): reject rather than cancel a
     * DIFFERENT trigger's pending arm (le_engine_record's quantize arm,
     * trigger 0, or its auto-record arm, trigger 1) — see this function's
     * header doc. */
    if (engine->armed_trigger[channel] != 2) return LE_ERR_INVALID;
    /* Second call before the boundary fires cancels the pending toggle. */
    engine->armed[channel] = 0;
    return le_push(engine, LE_CMD_DISARM, channel, 0.0f);
  }
  engine->armed[channel] = 1;
  engine->armed_trigger[channel] = 2; /* Band section-transport trigger */
  return le_push(engine, LE_CMD_ARM, channel, 2.0f);
}

/* ---- click + count-in (A2; see loopy_engine_api.h's click section) ---- */

int32_t le_engine_set_click_mode(le_engine* engine, int32_t mode) {
  if (mode < LE_CLICK_OFF || mode > LE_CLICK_PLAY_REC) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_CLICK_MODE, mode, 0.0f);
}

int32_t le_engine_set_click_output(le_engine* engine, int32_t mask) {
  /* trackmask arm (channel unused) so all 32 mask bits round-trip exactly,
   * like the other mask commands. Bits beyond the negotiated output range are
   * simply never summed into. */
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_CLICK_OUTPUT,
                                          .trackmask = {0, (uint32_t)mask}});
}

int32_t le_engine_set_click_volume(le_engine* engine, float volume) {
  /* Clamped to 0..LE_MAX_GAIN by the audio thread on apply (the SET_VOLUME
   * pattern). */
  return le_push(engine, LE_CMD_SET_CLICK_VOLUME, 0, volume);
}

int32_t le_engine_set_count_in(le_engine* engine, int32_t bars) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (bars < 0 || bars > LE_COUNT_IN_MAX_BARS) return LE_ERR_INVALID;
  engine->count_in_bars = bars; /* control-side mirror (D9 exclusion below) */
  if (bars > 0 && engine->auto_record) {
    /* D9 mutual exclusion, count-in's direction: enabling count-in clears
     * sound-activated record outright — the mode AND any tracks still
     * waiting on the input threshold (le_engine_set_auto_record(0) cancels
     * those arms). */
    le_engine_set_auto_record(engine, 0);
  }
  return le_push(engine, LE_CMD_SET_COUNT_IN, bars, 0.0f);
}

int32_t le_engine_set_track_multiple(le_engine* engine, int32_t channel,
                                     int32_t multiple) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  /* 0 = inherit the global default; >= 1 fixes the next recording to that many
   * base loops. Applies to the next finalize; existing content is unchanged. */
  engine->target_multiple[channel] = multiple < 0 ? 0 : multiple;
  return LE_OK;
}

int32_t le_engine_set_default_multiple(le_engine* engine, int32_t multiple) {
  if (engine == NULL) return LE_ERR_INVALID;
  /* 0 = auto (round up on stop); >= 1 fixes inheriting tracks to K base loops. */
  engine->default_multiple = multiple < 0 ? 0 : multiple;
  return LE_OK;
}

/* ---- track length presets (A6, D17; see loopy_engine_api.h's section doc for
 * the full preset x click-mode matrix) ---- */

int32_t le_engine_set_track_length_preset(le_engine* engine, int32_t channel,
                                          int32_t bars) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (bars < 0 || bars > LE_LENGTH_PRESET_MAX_BARS) return LE_ERR_INVALID;
  if (bars > 0) {
    /* D17 allocation guard: `bars` bars of the CURRENT time signature at the
     * slowest possible tempo (30 BPM, LE_GRID_TEMPO_MIN) must fit within
     * max_loop_frames — checked here, before recording starts, rather than
     * discovered mid-take. Any signature is possible pre-lock, so this reads
     * the signature live rather than assuming 4/4. A tempo at or above 30 BPM
     * (the engine's floor) only ever needs FEWER frames per bar, so passing
     * this check at 30 BPM guarantees every reachable actual tempo fits too. */
    int32_t num = load_i32(&engine->a_ts_num);
    if (num <= 0) num = 4;
    const int32_t sr = engine->sample_rate > 0 ? engine->sample_rate : 48000;
    const le_tempo_grid worst = {LE_GRID_TEMPO_MIN, num,
                                 load_i32(&engine->a_ts_den), sr};
    const double fpbar = le_grid_frames_per_bar(&worst);
    if (fpbar > 0.0 && (double)bars * fpbar > (double)engine->max_loop_frames) {
      return LE_ERR_CAPACITY;
    }
  }
  return le_push(engine, LE_CMD_SET_LENGTH_PRESET, channel, (float)bars);
}

int32_t le_engine_set_rec_dub(le_engine* engine, int32_t enabled) {
  if (engine == NULL) return LE_ERR_INVALID;
  engine->rec_dub = enabled ? 1 : 0;
  return LE_OK;
}

int32_t le_engine_set_master_gain(le_engine* engine, float gain) {
  /* Posted through the ring (drained on the audio thread, which clamps to 0..1
   * and publishes to a_master_gain_bits) so it orders with the rest of the
   * command stream, exactly like le_engine_set_track_volume. */
  return le_push(engine, LE_CMD_SET_MASTER_GAIN, 0, gain);
}

int32_t le_engine_set_auto_record(le_engine* engine, int32_t enabled) {
  if (engine == NULL) return LE_ERR_INVALID;
  engine->auto_record = enabled ? 1 : 0;
  /* Turning it off cancels any tracks still waiting for an input-level start. */
  if (!engine->auto_record) {
    for (int32_t c = 0; c < engine->track_count; ++c) {
      if (engine->armed_trigger[c] == 1) le_cancel_arm(engine, c);
    }
  } else if (engine->count_in_bars > 0) {
    /* D9 mutual exclusion, auto-record's direction: enabling sound-activated
     * record clears the count-in setting (the SET_COUNT_IN(0) it posts also
     * cancels a count-in already in flight). If both are somehow set at once
     * anyway — raw command posts — count-in still wins at press time
     * (le_engine_record checks it before the auto-record arm). The push's
     * result is deliberately ignored: pre-configure there is no ring, and
     * the zeroed control mirror is already authoritative for press
     * decisions. */
    engine->count_in_bars = 0;
    (void)le_push(engine, LE_CMD_SET_COUNT_IN, 0, 0.0f);
  }
  return LE_OK;
}

int32_t le_engine_set_limiter(le_engine* engine, int32_t enabled,
                              float ceiling) {
  if (engine == NULL) return LE_ERR_INVALID;
  /* Independent published atomics (no ordering vs. the command stream), so the
   * control thread stores them directly. Clamp the ceiling to a sane (0,1]. */
  if (ceiling <= 0.0f) ceiling = 0.99f;
  if (ceiling > 1.0f) ceiling = 1.0f;
  store_f32(&engine->a_limiter_ceiling_bits, ceiling);
  store_i32(&engine->a_limiter_enabled, enabled ? 1 : 0);
  le_plog_push_ctrl(engine, (le_command){.code = LE_PLOG_SET_LIMITER,
                                        .arg_i = enabled ? 1 : 0,
                                        .arg_f = ceiling});
  return LE_OK;
}

int32_t le_engine_set_overdub_feedback(le_engine* engine, float feedback) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (feedback < 0.0f) feedback = 0.0f;
  if (feedback > 1.0f) feedback = 1.0f;
  store_f32(&engine->a_overdub_fb_bits, feedback);
  le_plog_push_ctrl(engine, (le_command){.code = LE_PLOG_SET_OVERDUB_FEEDBACK,
                                        .arg_f = feedback});
  return LE_OK;
}

/* Prepares a chain entry for [type]: lazily allocates its heap buffers and seeds
 * the type's default params only when the type actually changes (so a reorder
 * does not wipe the user's tweaks). The per-type allocation and defaults live
 * behind the effect vtable (engine_fx.c: le_fx_prepare / le_fx_defaults), so this
 * stays generic — adding an effect needs no edit here. Returns LE_OK, or
 * LE_ERR_INVALID on allocation failure (buffers left as they were). */
static int32_t le_fx_prepare_entry(le_fx_state* fx, _Atomic int32_t* a_type,
                                   _Atomic uint32_t a_param[][LE_FX_PARAMS],
                                   int32_t index, int32_t type,
                                   int32_t delay_cap) {
  const int32_t cap = delay_cap > 0 ? delay_cap : 48000;
  if (le_fx_prepare(fx, index, type, cap) != LE_OK) return LE_ERR_INVALID;
  if (load_i32(a_type + index) != type) {
    float defaults[LE_FX_PARAMS];
    le_fx_defaults(type, defaults);
    for (int p = 0; p < LE_FX_PARAMS; ++p) {
      store_f32(&a_param[index][p], defaults[p]);
    }
  }
  return LE_OK;
}

int32_t le_engine_set_lane_fx(le_engine* engine, int32_t channel, int32_t lane,
                              int32_t index, int32_t type) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (type < LE_FX_NONE || type > LE_FX_REVERB) return LE_ERR_INVALID;
  le_lane* ln = &engine->tracks[channel].lanes[lane];
  if (le_fx_prepare_entry(&ln->fx, ln->a_fx_type, ln->a_fx_param, index, type,
                          engine->fx_delay_frames) != LE_OK) {
    return LE_ERR_INVALID;
  }
  /* Publish the type via the ring so the audio thread resets the entry's DSP
   * state in lockstep. The delay pointer written above is made visible to the
   * audio thread by the ring's release/acquire pairing. */
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_LANE_FX,
                                          .fx = {channel, lane, index, type}});
}

int32_t le_engine_set_lane_fx_count(le_engine* engine, int32_t channel,
                                    int32_t lane, int32_t count) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (count < 0) count = 0;
  if (count > LE_FX_MAX) count = LE_FX_MAX;
  return le_push_cmd(engine,
                     (le_command){.code = LE_CMD_SET_LANE_FX_COUNT,
                                  .fxcount = {channel, lane, count}});
}

int32_t le_engine_set_lane_fx_param(le_engine* engine, int32_t channel,
                                    int32_t lane, int32_t index, int32_t param,
                                    float value) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (param < 0 || param >= LE_FX_PARAMS) return LE_ERR_INVALID;
  if (value < 0.0f) value = 0.0f;
  if (value > 1.0f) value = 1.0f;
  /* Params are plain published atomics read once per buffer; a direct store is
   * race-free and needs no ring command (unlike the type, which also resets
   * audio-thread DSP state). Works whether or not the device is running. */
  store_f32(&engine->tracks[channel].lanes[lane].a_fx_param[index][param],
            value);
  le_plog_push_ctrl(
      engine, (le_command){.code = LE_PLOG_SET_LANE_FX_PARAM,
                           .fx = {channel, lane,
                                  LE_PLOG_FX_PARAM_PACK(index, param),
                                  (int32_t)f32_to_bits(value)}});
  return LE_OK;
}

int32_t le_engine_set_monitor_input(le_engine* engine, int32_t input,
                                    int32_t enabled) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_MONITOR_INPUT, input,
                 enabled ? 1.0f : 0.0f);
}

/* The single-chain monitor setters address the input only. Output rides the
 * typed `trackmask` arm (channel = input); volume/mute the generic
 * { arg_i = input, arg_f = value } arm; FX type/count the `fx` / `fxcount` arms
 * (channel = input, lane field unused). */
int32_t le_engine_set_monitor_input_output(le_engine* engine, int32_t input,
                                           int32_t mask) {
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  return le_push_cmd(engine,
                     (le_command){.code = LE_CMD_SET_MONITOR_INPUT_OUTPUT,
                                  .trackmask = {input, (uint32_t)mask}});
}

int32_t le_engine_set_monitor_input_volume(le_engine* engine, int32_t input,
                                           float volume) {
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_MONITOR_INPUT_VOLUME, input, volume);
}

int32_t le_engine_set_monitor_input_mute(le_engine* engine, int32_t input,
                                         int32_t muted) {
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_MONITOR_INPUT_MUTE, input,
                 muted ? 1.0f : 0.0f);
}

int32_t le_engine_set_monitor_input_fx(le_engine* engine, int32_t input,
                                       int32_t index, int32_t type) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (type < LE_FX_NONE || type > LE_FX_REVERB) return LE_ERR_INVALID;
  le_monitor_input* m = &engine->monitors[input];
  if (le_fx_prepare_entry(&m->fx, m->a_fx_type, m->a_fx_param, index, type,
                          engine->fx_delay_frames) != LE_OK) {
    return LE_ERR_INVALID;
  }
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_MONITOR_INPUT_FX,
                                          .fx = {input, 0, index, type}});
}

int32_t le_engine_set_monitor_input_fx_count(le_engine* engine, int32_t input,
                                             int32_t count) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  if (count < 0) count = 0;
  if (count > LE_FX_MAX) count = LE_FX_MAX;
  return le_push_cmd(engine,
                     (le_command){.code = LE_CMD_SET_MONITOR_INPUT_FX_COUNT,
                                  .fxcount = {input, 0, count}});
}

int32_t le_engine_set_monitor_input_fx_param(le_engine* engine, int32_t input,
                                             int32_t index, int32_t param,
                                             float value) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (param < 0 || param >= LE_FX_PARAMS) return LE_ERR_INVALID;
  if (value < 0.0f) value = 0.0f;
  if (value > 1.0f) value = 1.0f;
  store_f32(&engine->monitors[input].a_fx_param[index][param], value);
  le_plog_push_ctrl(
      engine, (le_command){.code = LE_PLOG_SET_MONITOR_FX_PARAM,
                           .fx = {input, -1,
                                  LE_PLOG_FX_PARAM_PACK(index, param),
                                  (int32_t)f32_to_bits(value)}});
  return LE_OK;
}

/* ---- structural output gate ---- */

int32_t le_engine_set_output_enabled(le_engine* engine, int32_t output,
                                     int32_t enabled) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (output < 0 || output >= LE_MAX_CHANNELS) return LE_ERR_INVALID;
  /* Posted through the ring so the gate edit orders with the rest of the command
   * stream and applies between buffers (RT-safe, no mid-buffer artifact). A gate
   * for an output beyond the device channel count is stored but never sounded. */
  return le_push(engine, LE_CMD_SET_OUTPUT_ENABLED, output,
                 enabled ? 1.0f : 0.0f);
}

/* Session persistence (le_engine_export_track / import_track / commit_session)
 * moved to engine_session.c (S1). */

/* ---- multi-lane control ---- */

int32_t le_engine_set_lane_count(le_engine* engine, int32_t channel,
                                 int32_t count) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (count < 1) count = 1;
  if (count > LE_MAX_LANES) count = LE_MAX_LANES;
  le_track* t = &engine->tracks[channel];
  /* Growing lanes mid-capture would leave the new lanes without buffers in
   * the armed shadow slot (a later undo would swap their a_live to NULL —
   * silencing them) and races the audio thread's shared write head. Reject
   * while the track captures or a layer is still in flight; the caller
   * retries trivially once the take settles. */
  const int32_t st = le_effective_state(t);
  if (st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING ||
      atomic_load_explicit(&t->a_layer_in_flight, memory_order_acquire)) {
    return LE_ERR_INVALID;
  }
  const int32_t old = le_lanes_active(t);
  /* Lazily allocate the live buffer of each newly activated lane on this
   * (control) thread, before the audio thread reads it, and reset the lane to a
   * clean state so no stale content from a prior grow/shrink plays back. */
  if (count > old) {
    const size_t cap = (size_t)engine->max_loop_frames;
    for (int32_t l = old; l < count; ++l) {
      le_lane* ln = &t->lanes[l];
      le_lane_reset(ln, l); /* defaults to recording hardware input channel l */
      if (!le_lane_ensure_slot(ln, 0, engine->max_loop_frames)) {
        return LE_ERR_INVALID;
      }
      memset(ln->pool[0], 0, cap * sizeof(float));
    }
  }
  t->lane_count = count;
  return LE_OK;
}

/* The four lane setters address the lane by (channel, lane), carried as named
 * fields in the typed union. The handlers validate channel/lane, so the setters
 * only range-check lane here. */
int32_t le_engine_set_lane_input(le_engine* engine, int32_t channel,
                                 int32_t lane, int32_t input_channel) {
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_LANE_INPUT,
                                          .lanei = {channel, lane,
                                                    input_channel}});
}

int32_t le_engine_set_lane_output(le_engine* engine, int32_t channel,
                                  int32_t lane, int32_t mask) {
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_LANE_OUTPUT,
                                          .lanei = {channel, lane, mask}});
}

int32_t le_engine_set_lane_volume(le_engine* engine, int32_t channel,
                                  int32_t lane, float volume) {
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  return le_push_cmd(engine, (le_command){.code = LE_CMD_SET_LANE_VOLUME,
                                          .lanef = {channel, lane, volume}});
}

int32_t le_engine_set_lane_mute(le_engine* engine, int32_t channel, int32_t lane,
                                int32_t muted) {
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  return le_push_cmd(engine,
                     (le_command){.code = LE_CMD_SET_LANE_MUTE,
                                  .lanef = {channel, lane,
                                            muted ? 1.0f : 0.0f}});
}

/* ---- performance recording (arm/disarm the RT capture taps) ----
 * Control-thread lifecycle for le_perf_arm/disarm (loopy_engine_api.h): ring
 * allocation/free lives here, following the control-allocates/publish pattern
 * le_post_dub_shadows and the FX delay lines use for RT-owned buffers, and
 * (for the free side) the plugin-slot quiescent-teardown handshake
 * (engine_plugin.c's clear_slot). */

#if defined(_WIN32)
#include <windows.h>
static void le_perf_sleep_ms(int ms) { Sleep((DWORD)ms); }
#else
#include <time.h>
static void le_perf_sleep_ms(int ms) {
  struct timespec t = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&t, NULL);
}
#endif

/* The handshake budget: two processed-buffer boundaries prove the audio thread
 * has drained LE_CMD_PERF_DISARM (cleared its local `armed` flag) and made its
 * last ring push, so the frees below can never race it; the 1 ms-per-spin cap
 * bounds teardown so it can never hang on a stalled device (mirrors
 * engine_plugin.c's clear_slot). */
#define LE_PERF_QUIESCE_BOUNDARIES 2
#define LE_PERF_QUIESCE_MAX_SPINS 200

static size_t le_perf_next_pow2(size_t n) {
  size_t p = 1;
  while (p < n) p <<= 1;
  return p;
}

/* Ring capacity in SAMPLES for `channels` at `sample_rate`: at least
 * LE_PERF_CAPTURE_SECONDS of audio, rounded up to the power of two
 * le_audio_ring requires. */
static size_t le_perf_ring_capacity(int32_t channels, int32_t sample_rate) {
  const size_t want =
      (size_t)channels * (size_t)sample_rate * LE_PERF_CAPTURE_SECONDS;
  return le_perf_next_pow2(want < 2 ? 2 : want);
}

/* The first one or two ENABLED output channels, in ascending index order — the
 * master capture pair (mono when only one is enabled). Returns the count found
 * (0, 1, or 2); out_ch[1] is left at -1 when only one is found. */
static int le_perf_first_enabled_pair(le_engine* e, int32_t out_ch[2]) {
  out_ch[0] = -1;
  out_ch[1] = -1;
  const uint32_t mask =
      atomic_load_explicit(&e->a_output_enabled_mask, memory_order_relaxed);
  int found = 0;
  for (int32_t c = 0; c < e->out_channels && c < LE_MAX_CHANNELS; ++c) {
    if (!(mask & (1u << c))) continue;
    out_ch[found++] = c;
    if (found == 2) break;
  }
  return found;
}

/* Frees every ring allocated by an arm attempt that never reached the audio
 * thread (the command was never pushed, or push failed) — plain control-thread
 * cleanup, not a quiescent teardown, since nothing was published. */
static void le_perf_free_unpublished(le_engine* e, uint32_t monitors_done) {
  free(e->perf.master_ring.buffer);
  e->perf.master_ring = (le_audio_ring){0};
  for (int32_t c = 0; c < LE_MAX_INPUTS; ++c) {
    if (monitors_done & (1u << c)) {
      free(e->perf.monitor_ring[c].buffer);
      e->perf.monitor_ring[c] = (le_audio_ring){0};
    }
  }
}

int32_t le_perf_arm(le_engine* engine, const char* capture_dir) {
  if (engine == NULL || capture_dir == NULL || capture_dir[0] == '\0') {
    return LE_ERR_INVALID;
  }
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (atomic_load_explicit(&engine->a_perf_armed, memory_order_acquire)) {
    return LE_OK; /* already armed: idempotent */
  }
  if (engine->perf.drain != NULL) {
    /* A previous disarm's quiescent wait bailed out (a stalled device
     * callback) before it could stop+join the drain thread and free the
     * rings — the audio thread had already applied LE_CMD_PERF_DISARM
     * (a_perf_armed reads 0), but the OLD session's rings and thread are
     * still live (le_perf_disarm leaves them exactly as-is in that case, so
     * a later retry — once the callback recovers — can still clean them up).
     * Arming now would reallocate engine->perf.master_ring / monitor_ring in
     * place while that old thread is still popping from them: refuse until
     * a successful disarm actually clears `drain`. */
    return LE_ERR_DEVICE;
  }

  int32_t out_ch[2];
  const int found = le_perf_first_enabled_pair(engine, out_ch);
  if (found == 0) return LE_ERR_INVALID; /* nothing enabled to capture */

  const int32_t sr = engine->sample_rate > 0 ? engine->sample_rate : 48000;
  const size_t master_cap = le_perf_ring_capacity(found, sr);
  float* master_buf = (float*)malloc(master_cap * sizeof(float));
  if (master_buf == NULL) return LE_ERR_INVALID;
  le_audio_ring_init(&engine->perf.master_ring, master_buf, master_cap);
  engine->perf.master_channels = found;
  engine->perf.master_out_ch[0] = out_ch[0];
  engine->perf.master_out_ch[1] = out_ch[1];

  /* The monitor capture set is frozen at arm: whichever inputs are enabled
   * right now, and no others — an input enabled later is logged, not tapped
   * (umbrella scope for this part). Every captured monitor ring is stereo
   * (the monitor's own chain, e.g. a reverb, may decorrelate l/r). */
  uint32_t input_mask = 0;
  const size_t monitor_cap = le_perf_ring_capacity(2, sr);
  for (int32_t c = 0; c < LE_MAX_INPUTS; ++c) {
    if (!load_i32(&engine->monitors[c].a_enabled)) continue;
    float* buf = (float*)malloc(monitor_cap * sizeof(float));
    if (buf == NULL) {
      le_perf_free_unpublished(engine, input_mask);
      return LE_ERR_INVALID;
    }
    le_audio_ring_init(&engine->perf.monitor_ring[c], buf, monitor_cap);
    input_mask |= (1u << c);
  }
  engine->perf.input_mask = input_mask;

  atomic_store_explicit(&engine->a_perf_frames, 0, memory_order_relaxed);
  atomic_store_explicit(&engine->a_perf_overruns, 0u, memory_order_relaxed);
  atomic_store_explicit(&engine->a_perf_log_overruns, 0u, memory_order_relaxed);
  atomic_store_explicit(&engine->a_perf_log_ctrl_overruns, 0u,
                        memory_order_relaxed);
  atomic_store_explicit(&engine->a_perf_layer_overruns, 0u,
                        memory_order_relaxed);
  /* Reset both perf-log rings so a fresh session never sees a stale entry
   * left over from a previous one — safe here (before LE_CMD_PERF_ARM is
   * pushed below) the same way publishing the audio rings above is: the
   * audio thread has not yet been told to start producing into log_ring, and
   * this control thread is the only producer for log_ctrl_ring. */
  le_perf_log_ring_init(&engine->perf.log_ring, engine->perf.log_storage,
                        LE_PERF_LOG_RING_CAPACITY);
  le_perf_log_ring_init(&engine->perf.log_ctrl_ring,
                        engine->perf.log_ctrl_storage,
                        LE_PERF_LOG_CTRL_RING_CAPACITY);
  /* The layer-staging ring (part 5) needs a free-then-init, not a blind
   * re-init: the previous session's drain thread usually empties it in its
   * unconditional final drain cycle, but a drain thread that SELF-stopped
   * (write failure) died before later retires were staged — those entries
   * still own heap PCM and have no consumer left. le_perf_arm refuses to
   * run while a stale drain thread is alive, so this pop is race-free. */
  le_layer_staging_ring_drain_free(&engine->perf.layer_staging_ring);
  le_layer_staging_ring_init(&engine->perf.layer_staging_ring,
                             engine->perf.layer_staging_storage,
                             LE_LAYER_STAGING_RING_CAPACITY);

  /* Spawn the drain thread before publishing to the audio thread: it only
   * ever reads through le_audio_ring_pop (never allocates/frees the ring
   * buffers themselves), so starting it slightly early is harmless — it just
   * finds empty rings until the audio thread begins producing. Arming without
   * a working drain thread would silently drop every captured frame, so a
   * failure here aborts the whole arm. */
  engine->perf.drain = le_perf_drain_start(engine, capture_dir);
  if (engine->perf.drain == NULL) {
    le_perf_free_unpublished(engine, input_mask);
    engine->perf.input_mask = 0;
    return LE_ERR_DEVICE;
  }

  /* Push-then-mutate would be backwards here: the ring set must be fully
   * published (visible via the command ring's release/acquire pairing) BEFORE
   * the audio thread may touch it, so every field above is written first and
   * this push is what makes them visible. */
  const int32_t rc = le_push(engine, LE_CMD_PERF_ARM, 0, 0.0f);
  if (rc != LE_OK) {
    le_perf_drain_stop(engine->perf.drain, LE_PERF_STOP_DISARM);
    engine->perf.drain = NULL;
    le_perf_free_unpublished(engine, input_mask);
    engine->perf.input_mask = 0;
    return rc;
  }
  return LE_OK;
}

int32_t le_perf_disarm(le_engine* engine) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_perf_armed, memory_order_acquire)) {
    return LE_OK; /* already disarmed: idempotent */
  }
  const int32_t rc = le_push(engine, LE_CMD_PERF_DISARM, 0, 0.0f);
  if (rc != LE_OK) return rc; /* ring full: caller retries; still armed */

  /* Quiescent handshake (mirrors engine_plugin.c's clear_slot): wait for the
   * audio thread to cycle past two buffer boundaries after it pops the disarm
   * command, so no in-flight ring push can race the frees below. Only
   * meaningful while a device is actually driving the callback; a stopped or
   * never-started engine (the native test pump) has no concurrent writer, so
   * the wait is skipped and teardown is immediate. */
  if (load_i32(&engine->a_running)) {
    uint64_t last =
        atomic_load_explicit(&engine->a_frames, memory_order_acquire);
    int boundaries = 0;
    for (int spins = 0; spins < LE_PERF_QUIESCE_MAX_SPINS &&
                        boundaries < LE_PERF_QUIESCE_BOUNDARIES;
         ++spins) {
      le_perf_sleep_ms(1);
      const uint64_t now =
          atomic_load_explicit(&engine->a_frames, memory_order_acquire);
      if (now != last) {
        ++boundaries;
        last = now;
      }
    }
    if (boundaries < LE_PERF_QUIESCE_BOUNDARIES) {
      /* The callback is stalled — do NOT free (a possible in-flight push
       * would be a use-after-free). The rings stay retracted (armed == 0, so
       * nothing dispatches to them again) and allocated; a later successful
       * disarm (once the callback recovers) or le_engine_destroy reclaims
       * them. */
      return LE_ERR_DEVICE;
    }
  }

  /* The audio thread has confirmed quiescent (or there is no concurrent
   * writer at all — the device-free test pump). Stop and join the drain
   * thread BEFORE freeing the rings below: it is the rings' last reader
   * (le_audio_ring_pop), and its own final drain-and-flush pass needs them
   * intact. */
  le_perf_drain_stop(engine->perf.drain, LE_PERF_STOP_DISARM);
  engine->perf.drain = NULL;

  free(engine->perf.master_ring.buffer);
  engine->perf.master_ring = (le_audio_ring){0};
  for (int32_t c = 0; c < LE_MAX_INPUTS; ++c) {
    if (engine->perf.input_mask & (1u << c)) {
      free(engine->perf.monitor_ring[c].buffer);
      engine->perf.monitor_ring[c] = (le_audio_ring){0};
    }
  }
  engine->perf.input_mask = 0;
  return LE_OK;
}

/* ---- performance-recording capture test seams (engine_internal.h) ---- *
 * Part 1 has no drain thread; these drain the rings directly for native-test
 * bit-parity assertions only. Single-threaded in tests (le_engine_process is
 * called synchronously, never concurrently with these), so no ring-pop race
 * against the audio-thread push side. */

int32_t le_engine_perf_master_pop_for_test(le_engine* engine, float* out,
                                           int32_t max_frames) {
  if (engine == NULL || out == NULL || max_frames <= 0) return 0;
  const int32_t ch = engine->perf.master_channels;
  if (ch <= 0) return 0;
  const size_t popped = le_audio_ring_pop(&engine->perf.master_ring, out,
                                          (size_t)max_frames * (size_t)ch);
  return (int32_t)(popped / (size_t)ch);
}

int32_t le_engine_perf_master_channels_for_test(le_engine* engine) {
  return engine == NULL ? 0 : engine->perf.master_channels;
}

int32_t le_engine_perf_monitor_pop_for_test(le_engine* engine, int32_t input,
                                            float* out, int32_t max_frames) {
  if (engine == NULL || out == NULL || max_frames <= 0) return 0;
  if (input < 0 || input >= LE_MAX_INPUTS) return 0;
  if (!(engine->perf.input_mask & (1u << input))) return 0;
  const size_t popped = le_audio_ring_pop(&engine->perf.monitor_ring[input],
                                          out, (size_t)max_frames * 2);
  return (int32_t)(popped / 2);
}
