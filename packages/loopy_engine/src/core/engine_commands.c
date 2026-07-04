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

#include "engine_core.h" /* le_push, valid_channel, le_lanes_active, le_*_reset */
#include "engine_fx.h"   /* le_fx_ensure_hann, LE_PV_N / LE_PV_BINS */
#include "engine_private.h"
#include "loopy_engine_api.h"

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
      if (t->undo_stack[k] == i) used = 1;
    }
    for (int k = 0; k < t->redo_count && !used; ++k) {
      if (t->redo_stack[k] == i) used = 1;
    }
    for (int k = 0; k < t->outstanding_count && !used; ++k) {
      if (t->outstanding_slots[k] == i) used = 1;
    }
    if (!used) return i;
  }
  /* Pool full: evict the oldest undo entry (bottom of the stack). */
  if (t->undo_count > 0) {
    const int slot = t->undo_stack[0];
    for (int k = 1; k < t->undo_count; ++k) {
      t->undo_stack[k - 1] = t->undo_stack[k];
    }
    t->undo_count--;
    store_i32(&t->a_undo_depth, t->undo_count);
    return slot;
  }
  return -1;
}

/* How many shadow slots control keeps posted to the audio thread per capturing
 * track: the armed one plus one spare, so a pass boundary can rotate without
 * waiting a control round-trip. */
#define LE_DUB_SHADOWS 2

/* Tops the track's posted shadow slots up to LE_DUB_SHADOWS (control thread):
 * acquires a free pool slot, lazily allocates its buffer on every active lane,
 * and posts it via LE_CMD_DUB_SHADOW. Push-then-mutate: the slot only becomes
 * `outstanding` once the ring accepted the command (a lazily allocated buffer
 * stays in the pool either way). The audio thread arms the slot as its next
 * shadow; the ring's release/acquire publishes the fresh buffers, exactly like
 * the fx delay-line pattern. */
static void le_post_dub_shadows(le_engine* engine, int32_t channel) {
  le_track* t = &engine->tracks[channel];
  const int32_t lanes = le_lanes_active(t);
  /* Undo layers are sized to the loop length rounded to LE_LAYER_QUANTUM — a
   * 2 s loop's layer costs ~2 s of floats, not the recording cap. An
   * EMPTY-start post (rec/dub, fixed multiple — final length unknown until
   * finalize) still sizes at the full cap. */
  const int32_t len = load_i32(&t->lanes[0].a_len);
  int32_t want = engine->max_loop_frames;
  if (len > 0) {
    want =
        ((len + LE_LAYER_QUANTUM - 1) / LE_LAYER_QUANTUM) * LE_LAYER_QUANTUM;
    if (want > engine->max_loop_frames) want = engine->max_loop_frames;
  }
  while (t->outstanding_count < LE_DUB_SHADOWS) {
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

/* One undo step on a track that has stacked layers (control thread): swap the
 * live pool index back to the top undo snapshot and push the previous live onto
 * the redo stack — every active lane in lockstep (the one undo span). The
 * caller has verified the track is not capturing and no layer is in flight. */
static void le_undo_swap(le_track* t) {
  const int32_t prev = t->undo_stack[--t->undo_count];
  const int32_t lanes = le_lanes_active(t);
  t->redo_stack[t->redo_count++] = load_i32(&t->lanes[0].a_live);
  for (int32_t l = 0; l < lanes; ++l) store_i32(&t->lanes[l].a_live, prev);
  store_i32(&t->a_undo_depth, t->undo_count);
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
    if (le_push(engine, LE_CMD_UNDO_TO_EMPTY, channel, 0.0f) != LE_OK) break;
    le_cancel_arm(engine, channel);
    t->redo_stack[t->redo_count++] = load_i32(&t->lanes[0].a_live);
    t->empty_len = len;
    le_mark_state_cmd(t, LE_TRACK_EMPTY);
    le_track_set_len(t, 0); /* coherent snapshot before the audio thread
                             * applies — a poll must never see EMPTY with a
                             * stale nonzero length (mirrors the live-tap and
                             * clear paths) */
    store_i32(&t->a_multiple, 1);
    store_i32(&t->a_redo_depth, t->redo_count);
    break; /* empty now — further queued taps are no-ops */
  }
  t->queued_undo = 0;
}

/* Handles one retired-layer event (control thread): returns the slot from the
 * audio thread's hands (`outstanding`) onto the undo stack, and replenishes the
 * spare while the dub session keeps running. */
static void le_handle_retired(le_engine* engine, const le_command* evt) {
  const int32_t ch = evt->evt.channel;
  if (ch < 0 || ch >= engine->track_count) return;
  le_track* t = &engine->tracks[ch];
  if (evt->evt.generation != t->dub_generation) {
    return; /* pre-clear era: the slot was already reclaimed by the clear */
  }
  for (int k = 0; k < t->outstanding_count; ++k) {
    if (t->outstanding_slots[k] == evt->evt.slot) {
      t->outstanding_slots[k] = t->outstanding_slots[--t->outstanding_count];
      break;
    }
  }
  if (t->undo_count < LE_POOL_SLOTS) {
    t->undo_stack[t->undo_count++] = evt->evt.slot;
    store_i32(&t->a_undo_depth, t->undo_count);
  }
  if (load_i32(&t->a_layer_in_flight)) {
    le_post_dub_shadows(engine, ch); /* the dub continues: keep 2 posted */
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
   * The same sweep replenishes shadow slots for any in-flight session that is
   * short (a capture that ran straight into overdub — rec/dub, fixed
   * multiple — starts with none; the length is known by now, so the slots are
   * loop-length-sized). */
  for (int32_t ch = 0; ch < engine->track_count; ++ch) {
    le_track* t = &engine->tracks[ch];
    const int in_flight =
        atomic_load_explicit(&t->a_layer_in_flight, memory_order_acquire);
    if (in_flight && t->outstanding_count < LE_DUB_SHADOWS) {
      le_post_dub_shadows(engine, ch);
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

/* Snapshots each active lane's recorded-input monitor FX chain onto the lane's
 * own FX chain — a deep copy of types + params, NOT a shared reference (D2/D3).
 * Control-thread only: runs in le_engine_record when a track first leaves EMPTY,
 * NEVER on the audio thread (NF-1). It reuses the proven per-entry lane-FX
 * setters, which prepare DSP / allocate delay lines on this thread and publish
 * the type/count through the command ring, so the audio thread applies them with
 * the same release/acquire ordering and DSP reset as a manual edit. The recorded
 * buffer stays clean; playback re-applies the snapshot. A lane that records no
 * monitorable input gets a cleared (clean) chain. */
static void le_snapshot_input_fx_to_lanes(le_engine* engine, le_track* t) {
  const int32_t ch = (int32_t)(t - engine->tracks);
  const int32_t lanes = le_lanes_active(t);
  for (int32_t l = 0; l < lanes; ++l) {
    le_lane* ln = &t->lanes[l];
    const int32_t ic = load_i32(&ln->a_input_channel);
    if (ic < 0 || ic >= LE_MAX_INPUTS) {
      le_engine_set_lane_fx_count(engine, ch, l, 0); /* no monitorable input */
      continue;
    }
    le_monitor_input* m = &engine->monitors[ic];
    int32_t n = load_i32(&m->a_fx_count);
    if (n < 0) n = 0;
    if (n > LE_FX_MAX) n = LE_FX_MAX;
    for (int32_t s = 0; s < n; ++s) {
      le_engine_set_lane_fx(engine, ch, l, s, load_i32(&m->a_fx_type[s]));
      for (int32_t p = 0; p < LE_FX_PARAMS; ++p) {
        le_engine_set_lane_fx_param(engine, ch, l, s, p,
                                    load_f32(&m->a_fx_param[s][p]));
      }
    }
    le_engine_set_lane_fx_count(engine, ch, l, n);
  }
  engine->snapshot_copy_count++;
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
 * A capture that runs straight into overdub (rec/dub, fixed multiple) gets its
 * correctly-sized slots from the poll-driven replenish in
 * le_engine_drain_events once the length is known; its first pass goes
 * un-backed and merges into the next boundary — coherent, never torn. */
static void le_begin_empty_capture(le_engine* engine, int32_t channel) {
  le_track* t = &engine->tracks[channel];
  le_clear_redo(t);
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
  le_clear_redo(t);
  t->queued_undo = 0;
  le_post_dub_shadows(engine, channel);
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
  if (st == LE_TRACK_EMPTY && has_master &&
      !le_grid_still_needed(engine, channel) &&
      le_engine_clear(engine, channel) == LE_OK) {
    has_master = 0; /* the CLEAR ahead of us in the ring resets the grid */
  }

  /* Snapshot-on-record (D2/D3): a track first leaving EMPTY deep-copies each
   * lane's recorded-input monitor chain onto the lane, so the take plays back
   * through the chain the performer monitored. Taken once here (control thread),
   * before the arm/immediate branches, so a later overdub or input-chain edit
   * never alters the take. Independent of the monitor enable gate (D8). */
  if (st == LE_TRACK_EMPTY) {
    le_snapshot_input_fx_to_lanes(engine, t);
  }

  /* Sound-activated: a record press on an empty track arms a signal-triggered
   * start (LE_CMD_ARM with trigger 1); the audio thread begins recording the
   * first frame the input crosses the threshold. A second press cancels. Takes
   * precedence over quantize for the start — finalize/overdub presses (the
   * track is no longer EMPTY) fall through to the quantize/immediate paths. */
  if (engine->auto_record && st == LE_TRACK_EMPTY) {
    if (engine->armed[channel] && load_i32(&t->a_pending) == 0) {
      engine->armed[channel] = 0; /* spent: the signal already fired it */
    }
    if (engine->armed[channel]) {
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
   * global default. */
  if (le_effective_quantize(engine, channel) && has_master &&
      le_transport_active(engine)) {
    /* If we armed this track but the boundary already fired it, the arm is
     * spent (published a_pending cleared); fall through to a fresh decision on
     * the now-current state. */
    if (engine->armed[channel] && load_i32(&t->a_pending) == 0) {
      engine->armed[channel] = 0;
    }
    if (engine->armed[channel]) {
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

  /* Immediate (quantize off, or the defining recording). */
  if (st == LE_TRACK_EMPTY) {
    le_begin_empty_capture(engine, channel);
    if (has_master) le_prepare_new_capture(engine, t);
  }
  if ((st == LE_TRACK_PLAYING || st == LE_TRACK_STOPPED) && len > 0) {
    le_begin_punch_in(engine, channel);
  }
  return le_push(engine, LE_CMD_RECORD, channel, 0.0f);
}

int32_t le_engine_stop_track(le_engine* engine, int32_t channel) {
  return le_push(engine, LE_CMD_STOP, channel, 0.0f);
}
int32_t le_engine_play(le_engine* engine, int32_t channel) {
  return le_push(engine, LE_CMD_PLAY, channel, 0.0f);
}
int32_t le_engine_clear(le_engine* engine, int32_t channel) {
  if (engine == NULL || channel < 0 || channel >= engine->track_count) {
    return le_push(engine, LE_CMD_CLEAR, channel, 0.0f);
  }
  le_engine_drain_events(engine);
  le_track* t = &engine->tracks[channel];
  /* Push-then-mutate: only a clear the audio thread will actually apply may
   * reset the control-side bookkeeping (and bump the generation the audio
   * thread mirrors in handle_clear — one bump per applied CLEAR keeps the two
   * counters equal without sharing a variable). */
  const int32_t rc = le_push(engine, LE_CMD_CLEAR, channel, 0.0f);
  if (rc != LE_OK) return rc;
  t->undo_count = 0;
  le_clear_redo(t);
  store_i32(&t->a_undo_depth, 0);
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

/* Undo/redo run on the control thread: they swap the live pool index (atomic;
 * the audio thread's only window into the buffers) on EVERY active lane in
 * lockstep, so the one undo span moves all lanes together. Allowed only when
 * the track is not capturing AND no layer is in flight (tail/drain still
 * writing), so the audio thread sees a stable a_live — an undo tapped during
 * that window is queued and applied when the layer retires, never lost. */
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
  if (t->undo_count > 0) {
    le_undo_swap(t);
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
  if (le_push(engine, LE_CMD_UNDO_TO_EMPTY, channel, 0.0f) != LE_OK) {
    return LE_ERR_INVALID;
  }
  /* An emptied track must not have a quantized/auto-record arm still pending —
   * it would fire a surprise fresh recording at the next loop top. */
  le_cancel_arm(engine, channel);
  t->redo_stack[t->redo_count++] = load_i32(&t->lanes[0].a_live);
  t->empty_len = len;
  le_mark_state_cmd(t, LE_TRACK_EMPTY);
  le_track_set_len(t, 0); /* coherent snapshot before the audio thread applies */
  store_i32(&t->a_multiple, 1);
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
    const int32_t next = t->redo_stack[--t->redo_count];
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
  const int32_t next = t->redo_stack[--t->redo_count];
  const int32_t lanes = le_lanes_active(t);
  t->undo_stack[t->undo_count++] = load_i32(&t->lanes[0].a_live);
  for (int32_t l = 0; l < lanes; ++l) store_i32(&t->lanes[l].a_live, next);
  store_i32(&t->a_undo_depth, t->undo_count);
  store_i32(&t->a_redo_depth, t->redo_count);
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
  return LE_OK;
}

int32_t le_engine_set_overdub_feedback(le_engine* engine, float feedback) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (feedback < 0.0f) feedback = 0.0f;
  if (feedback > 1.0f) feedback = 1.0f;
  store_f32(&engine->a_overdub_fb_bits, feedback);
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
