/*
 * engine_commands.c — control-thread command producers + record/undo machinery.
 *
 * THREAD OWNERSHIP: control thread (the Dart-facing FFI setters). Almost every
 * function here validates its arguments and posts a command into the SPSC ring
 * (le_push) for the audio thread to apply; the exceptions do control-thread work
 * the audio thread is guaranteed not to race — taking the pre-overdub undo
 * snapshot (le_push_overdub_snapshot copies a read-only buffer), the O(1) undo/redo
 * buffer-index swaps, the quantize/auto-record arm bookkeeping, and the lazy
 * effect-buffer / lane allocation in le_fx_prepare_entry / le_engine_set_lane_count.
 *
 * Split verbatim out of engine.c (S1) behind the unchanged ABI. Shared helpers
 * (le_push, valid_channel, le_lanes_active, le_lane_reset, le_monitor_lane_reset)
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

/* Returns a pool slot INDEX that is neither the (shared) live index nor
 * referenced by either undo/redo stack. The same index names the snapshot in
 * every lane — the undo span is lockstep across lanes — so this works on the
 * track-level stacks plus lane 0's live index (all lanes share it). If the pool
 * is full, evicts the oldest undo entry and reuses its slot. Returns -1 only if
 * nothing can be freed. Allocation of the slot's buffer happens per lane in
 * le_push_overdub_snapshot. */
static int track_acquire_slot(le_track* t) {
  const int live = load_i32(&t->lanes[0].a_live);
  for (int i = 0; i < LE_UNDO_SLOTS; ++i) {
    if (i == live) continue;
    int used = 0;
    for (int k = 0; k < t->undo_count && !used; ++k) {
      if (t->undo_stack[k] == i) used = 1;
    }
    for (int k = 0; k < t->redo_count && !used; ++k) {
      if (t->redo_stack[k] == i) used = 1;
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
    return slot;
  }
  return -1;
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
    if (ln->pool[live] != NULL) memset(ln->pool[live], 0, n * sizeof(float));
  }
}

/* Snapshots a track's pre-overdub content onto the one undo span (control
 * thread), clearing redo history; the audio thread treats the live buffers as
 * read-only at this point. The same slot index holds the snapshot in every
 * active lane (lockstep), each lane's buffer lazily allocated here. [len] is the
 * track's current length (k * base). */
static void le_push_overdub_snapshot(le_engine* engine, le_track* t,
                                     int32_t len) {
  t->redo_count = 0;
  const int slot = track_acquire_slot(t);
  if (slot >= 0) {
    const size_t n = (size_t)len;                          /* mono */
    const size_t cap = (size_t)engine->max_loop_frames;
    const int32_t lanes = le_lanes_active(t);
    for (int32_t l = 0; l < lanes; ++l) {
      le_lane* ln = &t->lanes[l];
      const int live = load_i32(&ln->a_live);
      if (ln->pool[live] == NULL) continue; /* lane has no content yet */
      if (ln->pool[slot] == NULL) {
        ln->pool[slot] = (float*)calloc(cap, sizeof(float));
        if (ln->pool[slot] == NULL) continue; /* OOM: skip this lane */
      }
      memcpy(ln->pool[slot], ln->pool[live], n * sizeof(float));
    }
    t->undo_stack[t->undo_count++] = slot;
    store_i32(&t->a_undo_depth, t->undo_count);
  }
  store_i32(&t->a_redo_depth, 0);
}

/* Reverses the most recent undo layer pushed by le_push_overdub_snapshot, used
 * when a pending quantized overdub is cancelled. The freed slot returns to the
 * pool; redo history was already cleared (a new action clears it). */
static void le_pop_overdub_snapshot(le_track* t) {
  if (t->undo_count > 0) {
    t->undo_count--;
    store_i32(&t->a_undo_depth, t->undo_count);
  }
}

/* The effective quantize state for [channel]: its per-track override, or the
 * global default when the track inherits (override < 0). */
static int le_effective_quantize(const le_engine* engine, int32_t channel) {
  const int ov = engine->track_quantize[channel];
  return ov < 0 ? engine->quantize : ov;
}

/* Cancels a pending quantized arm (control thread): disarms, reverses any
 * pre-overdub snapshot, and tells the audio thread to clear the pending flag.
 * No-op when the track is not armed. */
static void le_cancel_arm(le_engine* engine, int32_t channel) {
  if (!engine->armed[channel]) return;
  engine->armed[channel] = 0;
  if (engine->arm_snapshotted[channel]) {
    le_pop_overdub_snapshot(&engine->tracks[channel]);
    engine->arm_snapshotted[channel] = 0;
  }
  le_push(engine, LE_CMD_DISARM, channel, 0.0f);
}

int32_t le_engine_record(le_engine* engine, int32_t channel) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  le_track* t = &engine->tracks[channel];
  const int32_t st = load_i32(&t->a_state);
  /* The track's length (k * base) — all lanes share it, so lane 0 is canonical. */
  const int32_t len = load_i32(&t->lanes[0].a_len);
  const int has_master = load_i32(&engine->a_master_len) > 0;

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
    engine->arm_snapshotted[channel] = 0;
    engine->armed_trigger[channel] = 1; /* input-level trigger */
    le_prepare_new_capture(engine, t);
    return le_push(engine, LE_CMD_ARM, channel, 1.0f);
  }

  /* Quantized: defer the action to the next base-loop top instead of acting on
   * the press, so captures align to the grid. The defining recording (no master
   * yet) always acts immediately — it sets the grid. Per-track overrides win
   * over the global default. */
  if (le_effective_quantize(engine, channel) && has_master) {
    /* If we armed this track but the boundary already fired it, the arm is
     * spent (published a_pending cleared); fall through to a fresh decision on
     * the now-current state. */
    if (engine->armed[channel] && load_i32(&t->a_pending) == 0) {
      engine->armed[channel] = 0;
      engine->arm_snapshotted[channel] = 0;
    }
    if (engine->armed[channel]) {
      /* Second press before the boundary cancels the pending action. */
      engine->armed[channel] = 0;
      if (engine->arm_snapshotted[channel]) {
        le_pop_overdub_snapshot(t);
        engine->arm_snapshotted[channel] = 0;
      }
      return le_push(engine, LE_CMD_DISARM, channel, 0.0f);
    }
    /* Arm: do the one-time prep an immediate record would, then defer. */
    engine->armed[channel] = 1;
    engine->arm_snapshotted[channel] = 0;
    engine->armed_trigger[channel] = 0; /* loop-top trigger */
    if (st == LE_TRACK_EMPTY) {
      le_prepare_new_capture(engine, t);
    } else if ((st == LE_TRACK_PLAYING || st == LE_TRACK_STOPPED) && len > 0) {
      le_push_overdub_snapshot(engine, t, len);
      engine->arm_snapshotted[channel] = 1;
    }
    return le_push(engine, LE_CMD_ARM, channel, 0.0f);
  }

  /* Immediate (quantize off, or the defining recording). */
  if (st == LE_TRACK_EMPTY && has_master) {
    le_prepare_new_capture(engine, t);
  }
  if ((st == LE_TRACK_PLAYING || st == LE_TRACK_STOPPED) && len > 0) {
    le_push_overdub_snapshot(engine, t, len);
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
  if (engine != NULL && channel >= 0 && channel < engine->track_count) {
    le_track* t = &engine->tracks[channel];
    t->undo_count = 0;
    t->redo_count = 0;
    store_i32(&t->a_undo_depth, 0);
    store_i32(&t->a_redo_depth, 0);
    engine->armed[channel] = 0;
    engine->arm_snapshotted[channel] = 0;
  }
  return le_push(engine, LE_CMD_CLEAR, channel, 0.0f);
}

/* Undo/redo run entirely on the control thread: they swap the live pool index
 * (atomic; the audio thread's only window into the buffers) on EVERY active lane
 * in lockstep, so the one undo span moves all lanes together. Allowed only when
 * the track is not capturing, so the audio thread sees a stable a_live. */
int32_t le_engine_undo(le_engine* engine, int32_t channel) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  le_track* t = &engine->tracks[channel];
  const int32_t st = load_i32(&t->a_state);
  if (st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING) {
    return LE_ERR_INVALID;
  }
  if (t->undo_count == 0) return LE_ERR_INVALID;
  const int32_t prev = t->undo_stack[--t->undo_count];
  const int32_t lanes = le_lanes_active(t);
  t->redo_stack[t->redo_count++] = load_i32(&t->lanes[0].a_live);
  for (int32_t l = 0; l < lanes; ++l) store_i32(&t->lanes[l].a_live, prev);
  store_i32(&t->a_undo_depth, t->undo_count);
  store_i32(&t->a_redo_depth, t->redo_count);
  return LE_OK;
}

int32_t le_engine_redo(le_engine* engine, int32_t channel) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  le_track* t = &engine->tracks[channel];
  const int32_t st = load_i32(&t->a_state);
  if (st == LE_TRACK_RECORDING || st == LE_TRACK_OVERDUBBING) {
    return LE_ERR_INVALID;
  }
  if (t->redo_count == 0) return LE_ERR_INVALID;
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

/* Track index travels in arg_f (small, exact in float); the value/mask travels
 * in arg_i so a 32-bit mask round-trips exactly (a float cannot). */
int32_t le_engine_set_input_mask(le_engine* engine, int32_t channel,
                                 int32_t mask) {
  return le_push(engine, LE_CMD_SET_INPUT_MASK, mask, (float)channel);
}
int32_t le_engine_set_output_mask(le_engine* engine, int32_t channel,
                                  int32_t mask) {
  return le_push(engine, LE_CMD_SET_OUTPUT_MASK, mask, (float)channel);
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

/* Musical default parameters for a freshly engaged effect type (so picking an
 * effect sounds like something before the user tweaks it). */
static void le_fx_default_params(int32_t type, float out[LE_FX_PARAMS]) {
  /* p3 is inert for every type today: non-octaver effects never read it, and the
   * octaver's mode (< .5 = phase vocoder) only wakes up in the formant-preserving
   * rewrite. Seed it to 0 everywhere so a later read never returns garbage. */
  out[3] = 0.0f;
  switch (type) {
    case LE_FX_DRIVE:
      out[0] = 0.5f; /* drive */
      out[1] = 0.8f; /* level */
      out[2] = 0.0f;
      break;
    case LE_FX_FILTER:
      out[0] = 0.5f; /* cutoff */
      out[1] = 0.2f; /* resonance */
      out[2] = 0.0f;
      break;
    case LE_FX_DELAY:
      out[0] = 0.35f; /* time */
      out[1] = 0.35f; /* feedback */
      out[2] = 0.35f; /* wet mix */
      break;
    case LE_FX_TREMOLO:
      out[0] = 0.3f; /* rate */
      out[1] = 0.7f; /* depth */
      out[2] = 0.0f;
      break;
    case LE_FX_OCTAVER:
      out[0] = 0.25f; /* shift: one octave down */
      out[1] = 0.5f;  /* tone */
      out[2] = 0.5f;  /* mix */
      /* p3 (mode) stays 0 = phase vocoder, seeded above; inert until parts 3-4 */
      break;
    case LE_FX_ECHO:
      out[0] = 0.45f; /* time */
      out[1] = 0.5f;  /* feedback */
      out[2] = 0.35f; /* wet mix */
      break;
    case LE_FX_REVERB:
      out[0] = 0.5f;  /* size */
      out[1] = 0.5f;  /* damping */
      out[2] = 0.35f; /* wet mix */
      break;
    default:
      out[0] = out[1] = out[2] = 0.0f;
      break;
  }
}

/* Allocates the delay ring(s) for a chain entry (control thread) when its type
 * needs them, keeping each for reuse once allocated, and seeds the type's musical
 * defaults only when the type actually changes (so a reorder doesn't wipe the
 * user's tweaks). The chain is full stereo, so a delay-ringed effect (DELAY /
 * ECHO / OCTAVER) owns a ring per channel (delay[index][0] and [1]); REVERB packs
 * both its banks into the single ring delay[index][0] and leaves [1] alone (a [1]
 * retained from a prior delay-type stays for reuse on a later reorder back —
 * fx_reverb ignores it, and the reset/destroy paths free it). On a partial OOM
 * (the second ring fails) only the ring this call newly allocated is freed,
 * never a ring the slot already owned. Returns LE_OK, or LE_ERR_INVALID on
 * allocation failure. */
static int32_t le_fx_prepare_entry(le_fx_state* fx, _Atomic int32_t* a_type,
                                   _Atomic uint32_t a_param[][LE_FX_PARAMS],
                                   int32_t index, int32_t type,
                                   int32_t delay_cap) {
  const int needs_ring = type == LE_FX_DELAY || type == LE_FX_ECHO ||
                         type == LE_FX_OCTAVER || type == LE_FX_REVERB;
  /* Reverb uses only ring 0; the other ringed types use both channels. */
  const int needs_right = needs_ring && type != LE_FX_REVERB;
  const int needs_pv = type == LE_FX_OCTAVER;

  /* N2 — explicit OOM free-order. This one call can make up to 8 allocations
   * (2 delay rings + 6 phase-vocoder buffers: out/last_phase/sum_phase per
   * channel). Record the slot of each buffer THIS call newly allocates; on any
   * failure, free exactly those in reverse order and null them, never touching a
   * ring or buffer the slot already owned from a prior type. */
  float** owned[8];
  int n_owned = 0;
  const int32_t cap = delay_cap > 0 ? delay_cap : 48000;

  if (needs_ring) {
    if (fx->delay[index][0] == NULL) {
      fx->delay[index][0] = (float*)calloc((size_t)cap, sizeof(float));
      if (fx->delay[index][0] == NULL) goto oom;
      owned[n_owned++] = &fx->delay[index][0];
    }
    if (needs_right && fx->delay[index][1] == NULL) {
      fx->delay[index][1] = (float*)calloc((size_t)cap, sizeof(float));
      if (fx->delay[index][1] == NULL) goto oom;
      owned[n_owned++] = &fx->delay[index][1];
    }
  }
  if (needs_pv) {
    /* Build the shared analysis/synthesis window once (guarded). Control-thread
     * only, before this slot can be processed, so the audio thread's read is
     * safe via the ring's release/acquire publication of the type change. */
    le_fx_ensure_hann();
    for (int chan = 0; chan < 2; ++chan) {
      le_octaver_state* o = &fx->oct[index][chan];
      if (o->out == NULL) {
        o->out = (float*)calloc((size_t)LE_PV_N, sizeof(float));
        if (o->out == NULL) goto oom;
        owned[n_owned++] = &o->out;
      }
      if (o->last_phase == NULL) {
        o->last_phase = (float*)calloc((size_t)LE_PV_BINS, sizeof(float));
        if (o->last_phase == NULL) goto oom;
        owned[n_owned++] = &o->last_phase;
      }
      if (o->sum_phase == NULL) {
        o->sum_phase = (float*)calloc((size_t)LE_PV_BINS, sizeof(float));
        if (o->sum_phase == NULL) goto oom;
        owned[n_owned++] = &o->sum_phase;
      }
    }
  }
  if (load_i32(a_type + index) != type) {
    float defaults[LE_FX_PARAMS];
    le_fx_default_params(type, defaults);
    for (int p = 0; p < LE_FX_PARAMS; ++p) {
      store_f32(&a_param[index][p], defaults[p]);
    }
  }
  return LE_OK;

oom:
  /* Free only what this call allocated, in reverse order; keep pre-existing
   * buffers the slot already owned. The slot stays its previous type. */
  for (int i = n_owned - 1; i >= 0; --i) {
    free(*owned[i]);
    *owned[i] = NULL;
  }
  return LE_ERR_INVALID;
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
  return le_push(engine, LE_CMD_SET_LANE_FX,
                 (channel << 16) | (lane << 8) | index, (float)type);
}

int32_t le_engine_set_lane_fx_count(le_engine* engine, int32_t channel,
                                    int32_t lane, int32_t count) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (count < 0) count = 0;
  if (count > LE_FX_MAX) count = LE_FX_MAX;
  return le_push(engine, LE_CMD_SET_LANE_FX_COUNT,
                 (channel << 16) | (lane << 8) | count, 0.0f);
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

/* Plain-int control-thread setter, mirroring le_engine_set_lane_count. Monitor
 * lanes carry no recording buffers, so a grow only resets the newly activated
 * lanes to clean defaults (before bumping lane_count, so the audio thread never
 * reads an uninitialised lane); no allocation. */
int32_t le_engine_set_monitor_lane_count(le_engine* engine, int32_t input,
                                         int32_t count) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  if (count < 1) count = 1;
  if (count > LE_MAX_LANES) count = LE_MAX_LANES;
  le_monitor_input* m = &engine->monitors[input];
  int32_t old = m->lane_count;
  if (old < 1) old = 1;
  if (old > LE_MAX_LANES) old = LE_MAX_LANES;
  for (int32_t l = old; l < count; ++l) le_monitor_lane_reset(&m->lanes[l]);
  m->lane_count = count;
  return LE_OK;
}

/* The monitor-lane setters address the lane by the same packed index
 * `input * LE_MAX_LANES + lane` the track lane setters use: output carries the
 * index in arg_f so the 32-bit mask rides in arg_i; volume/mute carry the index
 * in arg_i so the float value rides in arg_f. */
int32_t le_engine_set_monitor_lane_output(le_engine* engine, int32_t input,
                                          int32_t lane, int32_t mask) {
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_MONITOR_LANE_OUTPUT, mask,
                 (float)(input * LE_MAX_LANES + lane));
}

int32_t le_engine_set_monitor_lane_volume(le_engine* engine, int32_t input,
                                          int32_t lane, float volume) {
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_MONITOR_LANE_VOLUME,
                 input * LE_MAX_LANES + lane, volume);
}

int32_t le_engine_set_monitor_lane_mute(le_engine* engine, int32_t input,
                                        int32_t lane, int32_t muted) {
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_MONITOR_LANE_MUTE,
                 input * LE_MAX_LANES + lane, muted ? 1.0f : 0.0f);
}

int32_t le_engine_set_monitor_lane_fx(le_engine* engine, int32_t input,
                                      int32_t lane, int32_t index, int32_t type) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (type < LE_FX_NONE || type > LE_FX_REVERB) return LE_ERR_INVALID;
  le_monitor_lane* ln = &engine->monitors[input].lanes[lane];
  if (le_fx_prepare_entry(&ln->fx, ln->a_fx_type, ln->a_fx_param, index, type,
                          engine->fx_delay_frames) != LE_OK) {
    return LE_ERR_INVALID;
  }
  return le_push(engine, LE_CMD_SET_MONITOR_LANE_FX,
                 (input << 16) | (lane << 8) | index, (float)type);
}

int32_t le_engine_set_monitor_lane_fx_count(le_engine* engine, int32_t input,
                                            int32_t lane, int32_t count) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (count < 0) count = 0;
  if (count > LE_FX_MAX) count = LE_FX_MAX;
  return le_push(engine, LE_CMD_SET_MONITOR_LANE_FX_COUNT,
                 (input << 16) | (lane << 8) | count, 0.0f);
}

int32_t le_engine_set_monitor_lane_fx_param(le_engine* engine, int32_t input,
                                            int32_t lane, int32_t index,
                                            int32_t param, float value) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (param < 0 || param >= LE_FX_PARAMS) return LE_ERR_INVALID;
  if (value < 0.0f) value = 0.0f;
  if (value > 1.0f) value = 1.0f;
  store_f32(&engine->monitors[input].lanes[lane].a_fx_param[index][param],
            value);
  return LE_OK;
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
  const int32_t old = le_lanes_active(t);
  /* Lazily allocate the live buffer of each newly activated lane on this
   * (control) thread, before the audio thread reads it, and reset the lane to a
   * clean state so no stale content from a prior grow/shrink plays back. */
  if (count > old) {
    const size_t cap = (size_t)engine->max_loop_frames;
    for (int32_t l = old; l < count; ++l) {
      le_lane* ln = &t->lanes[l];
      le_lane_reset(ln, l); /* defaults to recording hardware input channel l */
      if (ln->pool[0] == NULL) {
        ln->pool[0] = (float*)calloc(cap, sizeof(float));
        if (ln->pool[0] == NULL) return LE_ERR_INVALID;
      } else {
        memset(ln->pool[0], 0, cap * sizeof(float));
      }
    }
  }
  t->lane_count = count;
  return LE_OK;
}

/* All four lane setters address the lane by the same packed index
 * `channel * LE_MAX_LANES + lane`. For input/output the index travels in arg_f
 * (small, exact in float) so the 32-bit input channel / output mask in arg_i
 * round-trips exactly; for volume/mute the index travels in arg_i so the float
 * value can ride in arg_f. The handlers validate channel/lane, so the setters
 * only range-check lane (to keep the packed index well-formed). */
int32_t le_engine_set_lane_input(le_engine* engine, int32_t channel,
                                 int32_t lane, int32_t input_channel) {
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_LANE_INPUT, input_channel,
                 (float)(channel * LE_MAX_LANES + lane));
}

int32_t le_engine_set_lane_output(le_engine* engine, int32_t channel,
                                  int32_t lane, int32_t mask) {
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_LANE_OUTPUT, mask,
                 (float)(channel * LE_MAX_LANES + lane));
}

int32_t le_engine_set_lane_volume(le_engine* engine, int32_t channel,
                                  int32_t lane, float volume) {
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_LANE_VOLUME, channel * LE_MAX_LANES + lane,
                 volume);
}

int32_t le_engine_set_lane_mute(le_engine* engine, int32_t channel, int32_t lane,
                                int32_t muted) {
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_LANE_MUTE, channel * LE_MAX_LANES + lane,
                 muted ? 1.0f : 0.0f);
}
