/*
 * engine_snapshot.c — the read side: published-state snapshots + visualization
 * reads (S1 split from engine.c).
 *
 * THREAD OWNERSHIP: control thread (a render-rate poll from Dart). Every function
 * here only LOADS the per-field atomics the audio thread publishes — it never
 * mutates engine state — so a reader may see a one-frame-stale mix across fields,
 * which is fine for metering / UI. le_max_fx_latency scans the published fx
 * type/count atomics (the only race-free seam; see its comment). Behaviour
 * unchanged.
 */
#include <stdint.h>

#include "engine_core.h"    /* le_lanes_active */
#include "engine_fx.h"      /* le_octaver_latency */
#include "engine_private.h" /* le_engine, le_track, le_lane, load/store helpers */
#include "loopy_engine_api.h"

/* Lane 0's input channel as a legacy track input bitmask (1 << channel, or 0
 * when lane 0 records no input). */
static uint32_t le_lane_input_bits(le_lane* ln) {
  const int32_t ic = load_i32(&ln->a_input_channel);
  return ic >= 0 ? (1u << ic) : 0u;
}

/* Fills a track snapshot from the track's transport plus lane 0's content (the
 * backward-compatible per-track view). When [active] is false the track index
 * is past track_count; report an empty track. */
static void le_fill_track_snapshot(le_track* tr, int active,
                                   le_track_snapshot* out) {
  le_lane* l0 = &tr->lanes[0];
  out->state = active ? load_i32(&tr->a_state) : LE_TRACK_EMPTY;
  out->volume = load_f32(&l0->a_vol_bits);
  out->muted = load_i32(&l0->a_muted);
  out->length_frames = load_i32(&l0->a_len);
  out->multiple = load_i32(&tr->a_multiple);
  out->undo_depth = load_i32(&tr->a_undo_depth);
  out->clear_restore = load_i32(&tr->a_clear_restore);
  out->redo_depth = load_i32(&tr->a_redo_depth);
  out->rms = load_f32(&l0->a_rms_bits);
  out->peak = load_f32(&l0->a_peak_bits);
  out->input_mask = le_lane_input_bits(l0);
  out->output_mask =
      atomic_load_explicit(&l0->a_output_mask, memory_order_relaxed);
  out->lane_count = le_lanes_active(tr);
  out->layer_in_flight =
      atomic_load_explicit(&tr->a_layer_in_flight, memory_order_acquire);
  out->pending = load_i32(&tr->a_pending);
  out->length_preset_bars = load_i32(&tr->a_length_preset_bars);
  out->sync_divisor = load_i32(&tr->a_sync_divisor);
}

/* Max added latency (frames) across every active octaver in any record-route or
 * monitor lane chain — the value the snapshot surfaces so the UI can warn about
 * monitoring lag (part 5). Scanned here on the control thread (a render-rate
 * poll) rather than cached on an fx-change atomic: an fx's type and count are
 * committed by the audio thread's ring handler, so a control-thread setter can't
 * see the post-commit chain — a pull-time scan of the published a_fx_type /
 * a_fx_count atomics is the only race-free seam. The audio thread never reads
 * this. Today only the octaver contributes (le_octaver_latency); the max keeps
 * it forward-compatible, and a chain with no octaver yields 0. */
static int32_t le_max_fx_latency(le_engine* engine) {
  int32_t max_lat = 0;
  for (int32_t t = 0; t < engine->track_count; ++t) {
    le_track* tr = &engine->tracks[t];
    for (int32_t l = 0; l < tr->lane_count; ++l) {
      le_lane* ln = &tr->lanes[l];
      int32_t n = load_i32(&ln->a_fx_count);
      if (n > LE_FX_MAX) n = LE_FX_MAX;
      for (int32_t s = 0; s < n; ++s) {
        const int32_t lat =
            le_fx_added_latency(&ln->fx, s, load_i32(&ln->a_fx_type[s]));
        if (lat > max_lat) max_lat = lat;
      }
    }
  }
  for (int32_t c = 0; c < LE_MAX_INPUTS; ++c) {
    le_monitor_input* m = &engine->monitors[c];
    int32_t n = load_i32(&m->a_fx_count);
    if (n > LE_FX_MAX) n = LE_FX_MAX;
    for (int32_t s = 0; s < n; ++s) {
      const int32_t lat =
          le_fx_added_latency(&m->fx, s, load_i32(&m->a_fx_type[s]));
      if (lat > max_lat) max_lat = lat;
    }
  }
  return max_lat;
}

/* FNV-1a mix of one 32-bit value, byte by byte in little-endian order so the
 * hash is endianness-independent (both this and the Dart mirror process the
 * value's low byte first). */
static uint64_t le_fx_fp_u32(uint64_t h, uint32_t v) {
  for (int b = 0; b < 4; ++b) {
    h ^= (uint8_t)(v >> (8 * b));
    h *= 0x100000001b3ULL;
  }
  return h;
}

/* Order-sensitive fingerprint of a published fx chain (a_fx_count active of the
 * a_fx_type / a_fx_param arrays). Built-ins fold in their type + LE_FX_PARAMS
 * float-bit params; a plugin entry (LE_FX_PLUGIN) folds in its type only. The
 * Dart repository computes the identical hash over its cache. */
static uint64_t le_fx_chain_fingerprint(
    _Atomic int32_t* a_count, _Atomic int32_t* a_type,
    _Atomic uint32_t (*a_param)[LE_FX_PARAMS]) {
  uint64_t h = 0xcbf29ce484222325ULL; /* FNV-1a 64-bit offset basis */
  int32_t n = load_i32(a_count);
  if (n < 0) n = 0;
  if (n > LE_FX_MAX) n = LE_FX_MAX;
  for (int32_t i = 0; i < n; ++i) {
    const int32_t type = load_i32(&a_type[i]);
    h = le_fx_fp_u32(h, (uint32_t)type);
    if (type == LE_FX_PLUGIN) continue; /* plugin params live in the host */
    for (int32_t p = 0; p < LE_FX_PARAMS; ++p) {
      h = le_fx_fp_u32(
          h, atomic_load_explicit(&a_param[i][p], memory_order_relaxed));
    }
  }
  return h;
}

uint64_t le_engine_lane_fx_fingerprint(le_engine* engine, int32_t channel,
                                       int32_t lane) {
  if (engine == NULL || channel < 0 || channel >= engine->track_count ||
      lane < 0 || lane >= LE_MAX_LANES) {
    return 0;
  }
  le_lane* ln = &engine->tracks[channel].lanes[lane];
  return le_fx_chain_fingerprint(&ln->a_fx_count, ln->a_fx_type, ln->a_fx_param);
}

uint64_t le_engine_monitor_fx_fingerprint(le_engine* engine, int32_t input) {
  if (engine == NULL || input < 0 || input >= LE_MAX_INPUTS) return 0;
  le_monitor_input* m = &engine->monitors[input];
  return le_fx_chain_fingerprint(&m->a_fx_count, m->a_fx_type, m->a_fx_param);
}

void le_engine_get_snapshot(le_engine* engine, le_snapshot* out) {
  if (engine == NULL || out == NULL) return;
  /* Collect retired per-pass undo layers (and replenish shadow spares) on the
   * UI's poll cadence, so undo depths stay fresh and queued undo taps apply. */
  le_engine_drain_events(engine);
  out->running = atomic_load_explicit(&engine->a_running, memory_order_acquire);
  out->device_present =
      atomic_load_explicit(&engine->a_device_present, memory_order_acquire);
  out->sample_rate = load_i32(&engine->a_sample_rate);
  out->buffer_frames = load_i32(&engine->a_buffer_frames);
  out->input_channels = load_i32(&engine->a_in_channels);
  out->output_channels = load_i32(&engine->a_out_channels);
  out->excluded_input_mask =
      atomic_load_explicit(&engine->a_excluded_input_mask, memory_order_relaxed);
  out->frames_processed =
      atomic_load_explicit(&engine->a_frames, memory_order_relaxed);
  out->xrun_count = atomic_load_explicit(&engine->a_xruns, memory_order_relaxed);
  out->input_rms = load_f32(&engine->a_in_rms_bits);
  out->input_peak = load_f32(&engine->a_in_peak_bits);
  out->output_rms = load_f32(&engine->a_out_rms_bits);
  out->latency_state = load_i32(&engine->a_latency_state);
  out->measured_latency_ms = bits_to_f64(
      atomic_load_explicit(&engine->a_latency_ms_bits, memory_order_relaxed));
  out->master_length_frames = load_i32(&engine->a_master_len);
  out->master_position_frames = load_i32(&engine->a_master_pos);
  out->record_offset_frames = load_i32(&engine->a_record_offset);
  out->fx_added_latency_frames = le_max_fx_latency(engine);
  out->master_gain = load_f32(&engine->a_master_gain_bits);
  out->active_backend = load_i32(&engine->a_active_backend);
  out->output_enabled_mask =
      atomic_load_explicit(&engine->a_output_enabled_mask, memory_order_relaxed);
  out->perf_armed = load_i32(&engine->a_perf_armed);
  out->perf_frames =
      atomic_load_explicit(&engine->a_perf_frames, memory_order_relaxed);
  out->perf_overruns =
      atomic_load_explicit(&engine->a_perf_overruns, memory_order_relaxed);
  out->track_count = engine->track_count;
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    le_fill_track_snapshot(&engine->tracks[t], t < engine->track_count,
                           &out->tracks[t]);
  }
  /* Tempo grid (trailing block; grid-off defaults read 0/4/4/1/0/0/0/0). */
  out->tempo_bpm = load_f32(&engine->a_tempo_bpm_bits);
  out->ts_num = load_i32(&engine->a_ts_num);
  out->ts_den = load_i32(&engine->a_ts_den);
  out->sync_tempo = load_i32(&engine->a_sync_tempo);
  out->quantize_div = load_i32(&engine->a_quantize_div);
  out->tempo_source = load_i32(&engine->a_tempo_source);
  out->loop_bars = load_i32(&engine->a_loop_bars);
  out->current_beat = load_i32(&engine->a_current_beat);
  /* Click + count-in (trailing block; click-off defaults read 0/0/1/0/0/0). */
  out->click_mode = load_i32(&engine->a_click_mode);
  out->click_mask =
      atomic_load_explicit(&engine->a_click_mask, memory_order_relaxed);
  out->click_volume = load_f32(&engine->a_click_volume_bits);
  out->count_in_bars = load_i32(&engine->a_count_in_bars);
  out->counting_in = load_i32(&engine->a_counting_in);
  out->count_in_beats_left = load_i32(&engine->a_count_in_beats_left);
  /* Looper mode (B2a, D4; trailing block; default reads 0 = MULTI). */
  out->looper_mode = load_i32(&engine->a_looper_mode);
  /* Primary track (B3, D18; trailing block; default reads -1 = none). */
  out->primary_track = load_i32(&engine->a_primary_track);
}

void le_engine_get_track(le_engine* engine, int32_t channel,
                         le_track_snapshot* out) {
  if (engine == NULL || out == NULL) return;
  if (channel < 0 || channel >= engine->track_count) {
    out->state = LE_TRACK_EMPTY;
    out->volume = 1.0f;
    out->muted = 0;
    out->length_frames = 0;
    out->multiple = 1;
    out->undo_depth = 0;
    out->clear_restore = 0;
    out->redo_depth = 0;
    out->rms = 0.0f;
    out->peak = 0.0f;
    out->input_mask = 0x1u;
    out->output_mask = 0x3u;
    out->lane_count = 1;
    out->layer_in_flight = 0;
    out->pending = 0;
    out->length_preset_bars = 0;
    out->sync_divisor = 0;
    return;
  }
  le_fill_track_snapshot(&engine->tracks[channel], 1, out);
}

void le_engine_get_lane(le_engine* engine, int32_t channel, int32_t lane,
                        le_lane_snapshot* out) {
  if (engine == NULL || out == NULL) return;
  if (channel < 0 || channel >= engine->track_count || lane < 0 ||
      lane >= LE_MAX_LANES) {
    out->input_channel = -1;
    out->output_mask = 0x3u;
    out->volume = 1.0f;
    out->muted = 0;
    out->length_frames = 0;
    out->rms = 0.0f;
    out->peak = 0.0f;
    return;
  }
  le_lane* ln = &engine->tracks[channel].lanes[lane];
  out->input_channel = load_i32(&ln->a_input_channel);
  out->output_mask =
      atomic_load_explicit(&ln->a_output_mask, memory_order_relaxed);
  out->volume = load_f32(&ln->a_vol_bits);
  out->muted = load_i32(&ln->a_muted);
  out->length_frames = load_i32(&ln->a_len);
  out->rms = load_f32(&ln->a_rms_bits);
  out->peak = load_f32(&ln->a_peak_bits);
}

int32_t le_engine_read_visual(le_engine* engine, float* out,
                              int32_t max_points) {
  if (engine == NULL || out == NULL || max_points <= 0) return 0;
  const int32_t n = max_points < LE_VIZ_POINTS ? max_points : LE_VIZ_POINTS;
  /* Loop-indexed, bucket 0 = loop start. A bucket updated concurrently is
   * benign for a waveform. */
  for (int32_t i = 0; i < n; ++i) {
    out[i] = load_f32(&engine->a_loop_viz[i]);
  }
  return n;
}

int32_t le_engine_read_track_visual(le_engine* engine, int32_t channel,
                                    float* out, int32_t max_points) {
  if (engine == NULL || out == NULL || max_points <= 0) return 0;
  if (channel < 0 || channel >= engine->track_count) return 0;
  const int32_t n = max_points < LE_VIZ_POINTS ? max_points : LE_VIZ_POINTS;
  for (int32_t i = 0; i < n; ++i) {
    out[i] = load_f32(&engine->a_track_viz[channel][i]);
  }
  return n;
}
