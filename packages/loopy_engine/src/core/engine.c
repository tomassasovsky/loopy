/*
 * engine.c — the engine's control-thread core, after the S1 split.
 *
 * What remains here: engine lifecycle (le_engine_create / destroy / configure /
 * start / stop / mark_started), the lane / monitor reset helpers, the shared
 * low-level helpers declared in engine_core.h (le_track_set_len, le_mask_to_channel,
 * valid_channel, le_push), the version / device-name / measure-latency thin
 * wrappers, and the deterministic-test entry points (engine_internal.h).
 *
 * The rest of the original monolith now lives in sibling TUs, all behind the
 * unchanged loopy_engine_api.h ABI:
 *   - engine_process.c   the real-time core (le_engine_process, transport state
 *                        machine, apply_command, latency harness) — the one
 *                        audio-thread TU, where the no-alloc/no-lock RT contract
 *                        holds.
 *   - engine_commands.c  control-thread command producers (the FFI setters,
 *                        record/undo machinery, lazy fx/lane allocation).
 *   - engine_fx.c        the effects DSP island (kernels, octaver, reverb, chain).
 *   - engine_devices.c   device discovery, loopback detection, backend selection.
 *   - engine_snapshot.c  published-state snapshots + visualization reads.
 *   - engine_session.c   session export / import / commit.
 *   - engine_convert.c   pure sample-format conversion + ASIO buffer math.
 *
 * Multi-track model (unchanged): a shared master loop clock plus N independent
 * tracks; the first to finish recording defines the master length, and one-level
 * undo stays RT-safe because the pre-overdub snapshot is taken on the calling
 * (Dart) thread (engine_commands.c) so the audio thread only swaps a buffer index.
 */
#include <ctype.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "engine_core.h" /* shared low-level helpers: le_push, valid_channel, ... */
#include "../host/plugin_slot.h" /* le_plugin_slot_destroy (teardown of slots) */
#include "engine_fx.h" /* effects DSP island: chain runner, reset/free, latency */
#include "engine_internal.h"
#include "engine_miniaudio.h"
#include "engine_platform.h"
#include "engine_private.h"
#include "lockfree_ring.h"
#include "loop_clock.h"
#include "loopy_engine_api.h"
#include "miniaudio.h"
#include "perf_drain.h" /* le_perf_drain_stop (reconfigure/destroy teardown) */
#include "perf_render.h" /* le_perf_render_cancel (reconfigure/destroy teardown) */

/* All platform-specific behavior (CoreAudio channel labels, JACK port-pinning,
 * PipeWire quantum forcing) lives behind the engine_platform.h seam, implemented
 * per OS in engine_apple.c / engine_linux.c / engine_windows.c. This file is
 * platform-agnostic — no #if defined(__APPLE__|__linux__|_WIN32) behavior. */


/* struct le_engine and its nested types (le_fx_state, le_lane,
 * le_monitor_input, le_track) plus LE_RING_CAPACITY / LE_POOL_SLOTS now live in
 * engine_private.h, shared with the per-OS translation units (engine_linux.c /
 * engine_apple.c / engine_windows.c). */

/* The float/double <-> atomic-bits helpers (f32_to_bits / load_f32 / …) and the
 * int32 helpers (load_i32 / store_i32) are static inline in engine_private.h,
 * shared by every engine TU. comp_pos and le_lanes_active are static inline in
 * engine_core.h. */

/* Publishes a recorded length onto every active lane of a track (all lanes of a
 * track share the one transport, so they share the length). Declared in
 * engine_core.h. */
void le_track_set_len(le_track* t, int32_t len) {
  const int32_t n = le_lanes_active(t);
  for (int32_t l = 0; l < n; ++l) store_i32(&t->lanes[l].a_len, len);
}

/* Ensures a pool slot holds >= [frames] frames (control thread; declared in
 * engine_core.h). Undo layers are quantized to the loop length, so a reused
 * slot may need to grow before serving a longer track — or to the full
 * max_loop_frames before becoming a recording target. Replaces rather than
 * preserves: every consumer writes the slot whole before it is read. */
int le_lane_ensure_slot(le_lane* ln, int32_t slot, int32_t frames) {
  if (frames <= 0) return 0;
  if (ln->pool[slot] != NULL && ln->pool_cap[slot] >= frames) return 1;
  free(ln->pool[slot]);
  ln->pool[slot] = (float*)calloc((size_t)frames, sizeof(float));
  ln->pool_cap[slot] = ln->pool[slot] != NULL ? frames : 0;
  return ln->pool[slot] != NULL;
}

/* Lowest set bit of `mask` as a channel index, or -1 when no bit is set. Used to
 * collapse a legacy track input bitmask into lane 0's single input channel. */
int32_t le_mask_to_channel(uint32_t mask) {
  if (mask == 0u) return -1;
  int32_t c = 0;
  while (!(mask & 1u)) {
    mask >>= 1;
    ++c;
  }
  return c;
}


int valid_channel(le_engine* e, int32_t ch) {
  return ch >= 0 && ch < e->track_count;
}

/* The entire audio-thread core — le_engine_process plus the transport state
 * machine (finalize_* / handle_* / close_active_capture), apply_command,
 * le_latency_resolve, le_fx_route, le_flush_denormals, and the latency / auto-
 * record tuning constants — moved to engine_process.c (S1). The miniaudio data +
 * notification callbacks, device-config build, and device lifecycle live behind
 * the device-backend seam in engine_miniaudio.c. This file keeps the control-
 * thread lifecycle dispatch (configure/start/stop/create/destroy) and the lane /
 * monitor reset helpers; the looper/effects setters are in engine_commands.c. */

/* ---- configuration / lifecycle ---- */

/* Resets a lane's routing/volume/mute/effects/metering to defaults (recording
 * hardware input [input_channel]), clearing its effect DSP state and releasing
 * its delay lines. Does NOT touch the pool buffers — the caller owns
 * allocation. Used at configure and when a lane is (re)activated by a growing
 * lane count. */
void le_lane_reset(le_lane* ln, int32_t input_channel) {
  atomic_store_explicit(&ln->a_input_channel, input_channel,
                        memory_order_relaxed);
  atomic_store_explicit(&ln->a_output_mask, 0x3u, memory_order_relaxed);
  store_f32(&ln->a_vol_bits, 1.0f);
  store_i32(&ln->a_muted, 0);
  ln->pending_mute = 0;
  store_i32(&ln->a_live, 0);
  store_i32(&ln->a_len, 0);
  store_f32(&ln->a_rms_bits, 0.0f);
  store_f32(&ln->a_peak_bits, 0.0f);
  store_i32(&ln->a_fx_count, 0);
  for (int s = 0; s < LE_FX_MAX; ++s) {
    store_i32(&ln->a_fx_type[s], LE_FX_NONE);
    for (int p = 0; p < LE_FX_PARAMS; ++p) {
      store_f32(&ln->a_fx_param[s][p], 0.0f);
    }
    free(ln->fx.delay[s][0]);
    ln->fx.delay[s][0] = NULL;
    free(ln->fx.delay[s][1]);
    ln->fx.delay[s][1] = NULL;
    le_fx_free_octaver(&ln->fx, s);
    le_fx_entry_reset(&ln->fx, s);
    /* Destroy any hosted plugin slot too. Reset runs from le_engine_configure
     * while the device is closed (no audio thread), so a direct destroy is safe
     * — mirrors le_engine_destroy. Without this, a start→stop→start or any
     * reconfigure leaks the live IPluginHost and its loaded plugin binary. */
    le_plugin_slot_destroy(
        atomic_load_explicit(&ln->fx.plugin[s], memory_order_relaxed));
    atomic_store_explicit(&ln->fx.plugin[s], NULL, memory_order_relaxed);
  }
}

/* Resets a live monitor input to defaults: disabled, full stereo output, unity
 * volume, unmuted, and an empty (clean) single chain — clearing its effect DSP
 * state and releasing its delay lines. Used at configure. */
static void le_monitor_input_reset(le_monitor_input* m) {
  store_i32(&m->a_enabled, 0);
  atomic_store_explicit(&m->a_output_mask, 0x3u, memory_order_relaxed);
  store_f32(&m->a_vol_bits, 1.0f);
  store_i32(&m->a_muted, 0);
  store_i32(&m->a_fx_count, 0);
  for (int s = 0; s < LE_FX_MAX; ++s) {
    store_i32(&m->a_fx_type[s], LE_FX_NONE);
    for (int p = 0; p < LE_FX_PARAMS; ++p) {
      store_f32(&m->a_fx_param[s][p], 0.0f);
    }
    free(m->fx.delay[s][0]);
    m->fx.delay[s][0] = NULL;
    free(m->fx.delay[s][1]);
    m->fx.delay[s][1] = NULL;
    le_fx_free_octaver(&m->fx, s);
    le_fx_entry_reset(&m->fx, s);
    /* Destroy any hosted plugin slot too (see le_lane_reset) — otherwise a
     * reconfigure leaks the monitor input's live plugin host + binary. */
    le_plugin_slot_destroy(
        atomic_load_explicit(&m->fx.plugin[s], memory_order_relaxed));
    atomic_store_explicit(&m->fx.plugin[s], NULL, memory_order_relaxed);
  }
}

int32_t le_engine_configure(le_engine* engine, int32_t sample_rate,
                            int32_t input_channels, int32_t output_channels,
                            int32_t max_loop_frames) {
  if (engine == NULL) return LE_ERR_INVALID;

  /* Performance-recording capture: stop and join the drain thread — if
   * still armed here, the engine is being reconfigured mid-session (a
   * device/sample-rate change) — BEFORE touching ANY other engine field
   * below. The drain thread is a real background thread (unlike the rest of
   * this function's state, which the audio thread alone would otherwise
   * race) and reads engine->sample_rate / perf.master_channels /
   * perf.input_mask directly (safe only because they are fixed for the
   * whole armed session); mutating them first and stopping the thread
   * second would let it observe a torn or already-new value mid-flush. The
   * rings themselves are freed after (mirrors the ring-drop below): the
   * device is stopped during configure (no audio thread), so freeing is
   * race-free once the drain thread — the rings' other reader — has been
   * joined here. */
  if (engine->perf.drain != NULL) {
    le_perf_drain_stop(engine->perf.drain, LE_PERF_STOP_DEVICE_CHANGED);
    engine->perf.drain = NULL;
  }
  /* An active render is independent of the arm/drain lifecycle above, but
   * still owned by this engine's perf struct (about to be zeroed below) —
   * cancel+join it first so a reconfigure never orphans its worker thread
   * (uncancellable, unpollable, and leaked once the handle is lost). */
  le_perf_render_cancel(engine);
  free(engine->perf.master_ring.buffer);
  for (int c = 0; c < LE_MAX_INPUTS; ++c) {
    free(engine->perf.monitor_ring[c].buffer);
  }
  engine->perf = (le_perf_capture){0};
  store_i32(&engine->a_perf_armed, 0);
  atomic_store_explicit(&engine->a_perf_frames, 0, memory_order_relaxed);
  atomic_store_explicit(&engine->a_perf_overruns, 0u, memory_order_relaxed);

  if (input_channels <= 0) input_channels = 2;
  if (input_channels > LE_MAX_CHANNELS) input_channels = LE_MAX_CHANNELS;
  if (output_channels <= 0) output_channels = 2;
  if (output_channels > LE_MAX_CHANNELS) output_channels = LE_MAX_CHANNELS;
  if (sample_rate <= 0) sample_rate = 48000;
  /* Default cap of 30 s/track keeps total memory modest across all tracks
   * (live + undo). Longer loops are configurable; stream-to-disk is deferred. */
  if (max_loop_frames <= 0) max_loop_frames = sample_rate * 30;

  /* Lane buffers are mono: one input channel in, routed out via the mask. */
  engine->track_count = LE_MAX_TRACKS;
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    le_track* tr = &engine->tracks[t];
    /* Track transport: one lane active by default, empty, one base loop. */
    tr->lane_count = 1;
    tr->undo_count = 0;
    tr->redo_count = 0;
    store_i32(&tr->a_state, LE_TRACK_EMPTY);
    store_i32(&tr->a_undo_depth, 0);
    store_i32(&tr->a_redo_depth, 0);
    store_i32(&tr->a_multiple, 1);
    store_i32(&tr->a_pending, 0);
    tr->pending_record = 0;
    tr->pending_trigger = 0;
    tr->record_pos = 0;
    tr->record_start = 0;
    tr->start_iter = 0;
    tr->od_gain = 0.0f;
    tr->xfade_capture = 0;
    /* Per-pass layer capture + its control-side bookkeeping: a reconfigure
     * (including a device-loss recovery mid-dub) starts from a clean slate —
     * no armed shadows, no in-flight layer, no queued taps, counters equal. */
    tr->dub_slot = -1;
    tr->dub_spare = -1;
    tr->dub_retire_slot = -1;
    tr->dub_count = -1;
    tr->dub_phase = 0;
    tr->dub_len = 0;
    tr->dub_offset = 0;
    tr->dub_draining = 0;
    tr->dub_gen_audio = 0;
    atomic_store_explicit(&tr->a_layer_in_flight, 0, memory_order_relaxed);
    tr->outstanding_count = 0;
    tr->queued_undo = 0;
    tr->empty_len = 0;
    tr->state_cmds_posted = 0;
    tr->pending_target = LE_TRACK_EMPTY;
    store_i32(&tr->a_state_acks, 0);
    tr->dub_generation = 0;
    engine->track_quantize[t] = -1; /* inherit the global quantize default */
    engine->target_multiple[t] = 0; /* inherit the global default multiple */

    for (int l = 0; l < LE_MAX_LANES; ++l) {
      le_lane* ln = &tr->lanes[l];
      /* Free any buffers from a previous configuration. */
      for (int i = 0; i < LE_POOL_SLOTS; ++i) {
        free(ln->pool[i]);
        ln->pool[i] = NULL;
        ln->pool_cap[i] = 0;
      }
      /* Lane l defaults to recording hardware input channel l; lane 0 thus
       * records input 0 and plays 0 + 1, preserving the prior single-track
       * stereo behaviour. */
      le_lane_reset(ln, l);
    }
    /* Only lane 0 is active by default; allocate its live buffer now at the
     * full recording cap (further lanes' buffers and all undo snapshots
     * allocate lazily, undo layers at the loop-length quantum). */
    if (!le_lane_ensure_slot(&tr->lanes[0], 0, max_loop_frames)) {
      return LE_ERR_INVALID;
    }
  }

  engine->sample_rate = sample_rate;
  engine->in_channels = input_channels;
  engine->out_channels = output_channels;
  engine->max_loop_frames = max_loop_frames;
  engine->fx_delay_frames = sample_rate; /* 1 s of delay line per slot */

  /* Drop any stale traffic from a previous configuration — BOTH rings. The
   * command ring can hold presses made while the device was stopped/lost
   * (le_push still accepts them); replaying them onto the freshly reset tracks
   * at the next start would fire surprise records and desync the
   * state_cmds_posted/a_state_acks counters. Retired-layer events reference
   * freed slots and restarted generations. The device is stopped during
   * configure, so re-initialising the SPSC rings is race-free. */
  le_ring_init(&engine->ring, engine->ring_storage, LE_RING_CAPACITY);
  le_ring_init(&engine->evt_ring, engine->evt_storage, LE_RING_CAPACITY);
  /* NOT redundant with the `engine->perf = (le_perf_capture){0}` reset above:
   * a zero-struct leaves capacity/mask/buffer at 0/0/NULL, which is not a
   * working ring — these calls are what actually point log_ring/log_ctrl_ring
   * back at their storage arrays with the right capacity, the same way the
   * two le_ring_init calls above are load-bearing despite ring/evt_ring also
   * having just been implicitly zeroed by the surrounding struct resets. */
  le_perf_log_ring_init(&engine->perf.log_ring, engine->perf.log_storage,
                        LE_PERF_LOG_RING_CAPACITY);
  le_perf_log_ring_init(&engine->perf.log_ctrl_ring,
                        engine->perf.log_ctrl_storage,
                        LE_PERF_LOG_CTRL_RING_CAPACITY);
  le_layer_staging_ring_init(&engine->perf.layer_staging_ring,
                             engine->perf.layer_staging_storage,
                             LE_LAYER_STAGING_RING_CAPACITY);

  /* Latency-measurement capture window (~100 ms): the audio thread fills it with
   * the input-magnitude envelope, the resolver cross-correlates it. */
  free(engine->lat_buf);
  engine->lat_buf_cap = sample_rate / LE_LATENCY_CAPTURE_DIV;
  engine->lat_buf = (float*)calloc((size_t)engine->lat_buf_cap, sizeof(float));
  engine->lat_buf_pos = 0;
  if (engine->lat_buf == NULL) engine->lat_buf_cap = 0;
  le_loop_clock_reset(&engine->clock);
  engine->loop_iteration = 0;

  /* Loop visualization: clear the master + per-track loop rings. */
  engine->loop_viz_bucket = -1;
  engine->loop_viz_accum = 0.0f;
  for (int i = 0; i < LE_VIZ_POINTS; ++i) {
    store_f32(&engine->a_loop_viz[i], 0.0f);
  }
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    engine->track_viz_accum[t] = 0.0f;
    for (int i = 0; i < LE_VIZ_POINTS; ++i) {
      store_f32(&engine->a_track_viz[t][i], 0.0f);
    }
  }

  store_i32(&engine->a_record_offset, 0); /* re-measured per session */
  atomic_store_explicit(&engine->a_xruns, 0u, memory_order_relaxed); /* per session */
  store_f32(&engine->a_master_gain_bits, 1.0f); /* unity on every fresh start */
  /* Limiter off by default (the app enables it); ceiling just below full scale.
   * Overdub feedback unity by default == classic additive overdub. */
  store_i32(&engine->a_limiter_enabled, 0);
  store_f32(&engine->a_limiter_ceiling_bits, 0.99f);
  engine->lim_gain = 1.0f;
  store_f32(&engine->a_overdub_fb_bits, 1.0f);

  store_i32(&engine->a_sample_rate, sample_rate);
  store_i32(&engine->a_in_channels, input_channels);
  store_i32(&engine->a_out_channels, output_channels);
  /* Default to the miniaudio backend; le_engine_start republishes the negotiated
   * backend after device open (ASIO on Windows, miniaudio on macOS/Linux). */
  store_i32(&engine->a_active_backend, LE_BACKEND_MINIAUDIO);
  /* Re-derived per device open in le_engine_start; default to none excluded. */
  atomic_store_explicit(&engine->a_excluded_input_mask, 0u,
                        memory_order_relaxed);
  /* Structural output gate: every output enabled by default (absence of any gate
   * == all outputs on). The control thread clears bits via LE_CMD_SET_OUTPUT_
   * ENABLED; the audio thread skips a cleared output in the mix fan-out. */
  atomic_store_explicit(&engine->a_output_enabled_mask, 0xFFFFFFFFu,
                        memory_order_relaxed);

  /* Per-input live monitors: all disabled by default (each defaults to full
   * stereo output, empty chain). Inputs are monitored only when explicitly
   * routed through the per-input monitor graph (le_engine_set_monitor_input). */
  for (int c = 0; c < LE_MAX_INPUTS; ++c) {
    le_monitor_input_reset(&engine->monitors[c]);
  }

  store_i32(&engine->a_master_len, 0);
  store_i32(&engine->a_master_pos, 0);
  atomic_store_explicit(&engine->a_configured, 1, memory_order_release);
  return LE_OK;
}

const char* le_version(void) {
  return "loopy_engine 0.3.0 (miniaudio " MA_VERSION_STRING ")";
}

/* Loopback detection + device enumeration moved to engine_devices.c (S1). */

/* Loopback channel exclusion is per-OS: macOS reads Core Audio channel labels
 * (engine_apple.c), Linux/Windows exclude nothing for now. The mask is fetched
 * through le_platform_excluded_input_mask (engine_platform.h) at device open. */

void le_engine_set_excluded_input_mask_for_test(le_engine* engine,
                                                uint32_t mask) {
  if (engine == NULL) return;
  atomic_store_explicit(&engine->a_excluded_input_mask, mask,
                        memory_order_relaxed);
}

int le_engine_lane_buffer_allocated_for_test(le_engine* engine, int32_t channel,
                                             int32_t lane) {
  if (engine == NULL) return 0;
  if (channel < 0 || channel >= engine->track_count) return 0;
  if (lane < 0 || lane >= LE_MAX_LANES) return 0;
  le_lane* ln = &engine->tracks[channel].lanes[lane];
  return ln->pool[load_i32(&ln->a_live)] != NULL ? 1 : 0;
}

int32_t le_engine_lane_slot_cap_for_test(le_engine* engine, int32_t channel,
                                         int32_t lane, int32_t slot) {
  if (engine == NULL) return -1;
  if (channel < 0 || channel >= engine->track_count) return -1;
  if (lane < 0 || lane >= LE_MAX_LANES) return -1;
  if (slot < 0) {
    /* slot < 0 selects the lane's LIVE slot. */
    slot = load_i32(&engine->tracks[channel].lanes[lane].a_live);
  }
  if (slot >= LE_POOL_SLOTS) return -1;
  return engine->tracks[channel].lanes[lane].pool_cap[slot];
}

void le_engine_set_lane_count_unsafe_for_test(le_engine* engine,
                                              int32_t channel, int32_t count) {
  if (engine == NULL) return;
  if (channel < 0 || channel >= engine->track_count) return;
  if (count < 1) count = 1;
  if (count > LE_MAX_LANES) count = LE_MAX_LANES;
  engine->tracks[channel].lane_count = count; /* no buffer allocation */
}

void le_engine_lane_fx_chain_for_test(le_engine* engine, int32_t channel,
                                      int32_t lane, float* l, float* r) {
  if (engine == NULL || l == NULL || r == NULL) return;
  if (channel < 0 || channel >= engine->track_count) return;
  if (lane < 0 || lane >= LE_MAX_LANES) return;
  le_lane* ln = &engine->tracks[channel].lanes[lane];
  int32_t count = load_i32(&ln->a_fx_count);
  if (count < 0) count = 0;
  if (count > LE_FX_MAX) count = LE_FX_MAX;
  int32_t types[LE_FX_MAX];
  float params[LE_FX_MAX][LE_FX_PARAMS];
  for (int s = 0; s < count; ++s) {
    types[s] = load_i32(&ln->a_fx_type[s]);
    for (int p = 0; p < LE_FX_PARAMS; ++p) {
      params[s][p] = load_f32(&ln->a_fx_param[s][p]);
    }
  }
  fx_apply_chain(&ln->fx, engine->sample_rate, engine->fx_delay_frames, l, r,
                 count, types, params);
}

/* Loopback detection, device enumeration / id resolution, and backend selection
 * (le_select_backend + the ASIO-driver enumeration stub) moved to
 * engine_devices.c (S1). The ASIO bridge math (deinterleave / interleave /
 * pick_buffer) lives in engine_convert.c. */

void le_engine_mark_started(le_engine* engine) {
  if (engine == NULL) return;
  atomic_store_explicit(&engine->a_device_present, 1, memory_order_release);
  atomic_store_explicit(&engine->a_running, 1, memory_order_release);
}

void le_engine_note_xrun(le_engine* engine) {
  if (engine == NULL) return;
  /* Relaxed: a monotonically-increasing dropout tally read by the snapshot
   * poller — no other state is ordered against it. Called from the device
   * backend's overload notification (e.g. the ASIO message thread), never from
   * le_engine_process; exists as a C helper so a C++ backend TU need not touch
   * the _Atomic field directly (mirrors le_engine_mark_started). */
  atomic_fetch_add_explicit(&engine->a_xruns, 1u, memory_order_relaxed);
}

void le_engine_mark_device_lost(le_engine* engine) {
  if (engine == NULL) return;
  /* Flip presence to 0 while a_running stays 1 (running-but-disconnected),
   * mirroring the miniaudio device-notification callback (relaxed store; a lone
   * presence flag carrying no other state). The Dart layer reads device_present
   * == 0 as "lost" and drives reconnection (stop -> start) from the control
   * thread — the only correct place to tear down and re-open a device, never the
   * driver's callback/message thread. Used by the ASIO reset-request and
   * sample-rate-change notifications so a driver reconfigured by another app
   * recovers instead of going silent. */
  atomic_store_explicit(&engine->a_device_present, 0, memory_order_relaxed);
}

le_engine* le_engine_create(void) {
  le_engine* engine = (le_engine*)calloc(1, sizeof(le_engine));
  if (engine == NULL) return NULL;
  le_ring_init(&engine->ring, engine->ring_storage, LE_RING_CAPACITY);
  le_ring_init(&engine->evt_ring, engine->evt_storage, LE_RING_CAPACITY);
  le_perf_log_ring_init(&engine->perf.log_ring, engine->perf.log_storage,
                        LE_PERF_LOG_RING_CAPACITY);
  le_perf_log_ring_init(&engine->perf.log_ctrl_ring,
                        engine->perf.log_ctrl_storage,
                        LE_PERF_LOG_CTRL_RING_CAPACITY);
  le_layer_staging_ring_init(&engine->perf.layer_staging_ring,
                             engine->perf.layer_staging_storage,
                             LE_LAYER_STAGING_RING_CAPACITY);
  store_i32(&engine->a_latency_state, LE_LATENCY_IDLE);
  store_f32(&engine->a_master_gain_bits, 1.0f); /* unity until set */
  store_i32(&engine->a_limiter_enabled, 0);     /* off until the app enables it */
  store_f32(&engine->a_limiter_ceiling_bits, 0.99f);
  engine->lim_gain = 1.0f;
  store_f32(&engine->a_overdub_fb_bits, 1.0f); /* classic additive overdub */
  atomic_store_explicit(&engine->a_output_enabled_mask, 0xFFFFFFFFu,
                        memory_order_relaxed); /* all outputs on until set */
  return engine;
}

void le_engine_destroy(le_engine* engine) {
  if (engine == NULL) return;
  /* Release the device + context through the backend that opened it. NULL until
   * the first successful start; close() is idempotent, so a create→destroy with
   * no start (and a stop→destroy) are both safe. */
  if (engine->backend != NULL) {
    engine->backend->close(engine);
  }
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    for (int l = 0; l < LE_MAX_LANES; ++l) {
      le_lane* ln = &engine->tracks[t].lanes[l];
      for (int i = 0; i < LE_POOL_SLOTS; ++i) {
        free(ln->pool[i]);
      }
      for (int s = 0; s < LE_FX_MAX; ++s) {
        free(ln->fx.delay[s][0]);
        free(ln->fx.delay[s][1]);
        le_fx_free_octaver(&ln->fx, s);
        /* The device is already closed (no audio thread), so any hosted plugin
         * slot — including one left behind by a stalled-callback clear — can be
         * destroyed directly without the quiescent handshake. */
        le_plugin_slot_destroy(
            atomic_load_explicit(&ln->fx.plugin[s], memory_order_relaxed));
      }
    }
  }
  for (int c = 0; c < LE_MAX_INPUTS; ++c) {
    for (int s = 0; s < LE_FX_MAX; ++s) {
      free(engine->monitors[c].fx.delay[s][0]);
      free(engine->monitors[c].fx.delay[s][1]);
      le_fx_free_octaver(&engine->monitors[c].fx, s);
      le_plugin_slot_destroy(atomic_load_explicit(
          &engine->monitors[c].fx.plugin[s], memory_order_relaxed));
    }
  }
  free(engine->lat_buf);
  /* The device is already closed (no audio thread), so the performance-capture
   * rings — including any left retracted-but-allocated by a disarm that could
   * not confirm quiescence — can be freed directly, without the handshake. The
   * drain thread is a plain background thread (not the audio callback) and may
   * still be alive if a prior disarm bailed out on the quiescent wait, so stop
   * and join it first — it is the rings' last reader. */
  if (engine->perf.drain != NULL) {
    le_perf_drain_stop(engine->perf.drain, LE_PERF_STOP_DISARM);
    engine->perf.drain = NULL;
  }
  /* Same reasoning as the reconfigure teardown above: cancel+join any active
   * render before this engine (and its perf.render handle) is freed. */
  le_perf_render_cancel(engine);
  free(engine->perf.master_ring.buffer);
  for (int c = 0; c < LE_MAX_INPUTS; ++c) {
    free(engine->perf.monitor_ring[c].buffer);
  }
  le_platform_on_engine_teardown(); /* Linux restores PipeWire's dynamic quantum */
  free(engine);
}

int32_t le_engine_start(le_engine* engine, const le_config* config) {
  if (engine == NULL || config == NULL) return LE_ERR_INVALID;
  if (atomic_load_explicit(&engine->a_running, memory_order_acquire)) {
    return LE_ERR_ALREADY_RUNNING;
  }

  /* Open the device through the selected backend (ASIO on Windows, miniaudio on
   * macOS/Linux). The backend builds the device config, resolves pins/loopback,
   * opens the device, and reports the negotiated parameters back. A requested
   * ASIO open that fails (no/missing driver, driver busy, init failure) is NOT
   * silently retried on another backend: Windows is ASIO-only, so the failure
   * surfaces (the app lands stopped and shows the no-driver / ASIO4ALL
   * affordance) rather than dropping to system audio behind the user's back. */
  const le_device_backend* be = le_select_backend(config->backend);
  le_device_open_result info;
  const int32_t open_result = be->open(engine, config, &info);
  if (open_result != LE_OK) {
    return open_result;
  }

  /* Remember the backend before start() publishes a_running, so the invariant
   * "running implies backend set" holds for any concurrent stop()/snapshot. */
  engine->backend = be;

  if (le_engine_configure(engine, info.sample_rate, info.input_channels,
                          info.output_channels,
                          config->max_loop_frames) != LE_OK) {
    be->close(engine);
    return LE_ERR_INVALID;
  }

  /* Publish the negotiated parameters (configure() reset them above). */
  store_i32(&engine->a_active_backend, info.active_backend);
  store_i32(&engine->a_buffer_frames, info.buffer_frames);
  store_i32(&engine->a_latency_state, LE_LATENCY_IDLE);
  engine->lat_active = 0;
  engine->lat_emit_remaining = 0;
  engine->lat_buf_pos = 0;

  strncpy(engine->device_name, info.device_name,
          sizeof(engine->device_name) - 1);
  engine->device_name[sizeof(engine->device_name) - 1] = '\0';

  /* Exclude any loopback-labelled capture channels. The ASIO backend already
   * read its channel labels from the open driver and reported the mask in
   * info.excluded_input_mask — re-running the per-OS label probe while ASIO
   * holds the device would tear it down (R1 re-entrancy). Every other backend
   * computes it here from the resolved capture-device UID: our explicit capture
   * id when one was pinned/loopback-routed (capture_id_set, set by the backend),
   * else the system default input (on string-id backends the id union is the
   * UID string). */
  uint32_t excluded_mask;
  if (info.active_backend == LE_BACKEND_ASIO) {
    excluded_mask = info.excluded_input_mask;
  } else {
    const char* capture_uid =
        engine->capture_id_set ? (const char*)&engine->capture_id : NULL;
    excluded_mask =
        le_platform_excluded_input_mask(capture_uid, info.input_channels);
  }
  /* relaxed: a lone published value, matching the other configuration atomics
   * (a_sample_rate, etc.) and the relaxed audio-thread / snapshot reads. */
  atomic_store_explicit(&engine->a_excluded_input_mask, excluded_mask,
                        memory_order_relaxed);

  if (be->start(engine) != LE_OK) {
    be->close(engine);
    return LE_ERR_DEVICE;
  }
  /* Per-OS post-start hook: Linux repins the JACK ports to the selected
   * interface (overriding miniaudio's connect-to-every-physical-port default)
   * so channels map to that device only. No-op elsewhere. */
  le_platform_after_device_start(engine, config);
  return LE_OK;
}

int32_t le_engine_stop(le_engine* engine) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_running, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  /* Release the device through the backend that opened it (always set while
   * running). */
  if (engine->backend != NULL) {
    engine->backend->stop(engine);
  }
  engine->device_name[0] = '\0';
  atomic_store_explicit(&engine->a_device_present, 0, memory_order_release);
  atomic_store_explicit(&engine->a_running, 0, memory_order_release);
  /* Per-OS teardown on stop (not only destroy) so a forced quantum doesn't
   * outlive a running engine for other PipeWire clients. No-op off Linux. */
  le_platform_on_engine_teardown();
  return LE_OK;
}

/* Published-state snapshots + visualization reads (le_engine_get_snapshot /
 * get_track / get_lane / read_visual / read_track_visual, with le_max_fx_latency
 * and the track-snapshot fill) moved to engine_snapshot.c (S1). */

const char* le_engine_device_name(le_engine* engine) {
  if (engine == NULL) return "";
  return engine->device_name;
}

int32_t le_engine_post_command(le_engine* engine, int32_t code, int32_t arg_i,
                               float arg_f) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_running, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  const le_command cmd = {.code = code, .arg_i = arg_i, .arg_f = arg_f};
  return le_ring_push(&engine->ring, cmd) ? LE_OK : LE_ERR_INVALID;
}

int32_t le_engine_measure_latency(le_engine* engine) {
  return le_engine_post_command(engine, LE_CMD_MEASURE_LATENCY, 0, 0.0f);
}

/* ---- looper control (push gated on `configured`, so tests work device-free) */

int32_t le_push_cmd(le_engine* engine, le_command cmd) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  return le_ring_push(&engine->ring, cmd) ? LE_OK : LE_ERR_INVALID;
}

int32_t le_push(le_engine* engine, int32_t code, int32_t arg_i, float arg_f) {
  le_command cmd = {.code = code, .arg_i = arg_i, .arg_f = arg_f};
  return le_push_cmd(engine, cmd);
}

int32_t le_engine_begin_latency_for_test(le_engine* engine) {
  /* Configured-gated (like the looper commands) so the harness's loopback
   * detection can be driven without opening a device. */
  return le_push(engine, LE_CMD_MEASURE_LATENCY, 0, 0.0f);
}

