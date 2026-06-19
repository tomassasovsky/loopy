/*
 * engine.c — implementation of loopy_engine_api.h on top of miniaudio.
 *
 * Real-time contract (le_engine_process / data_callback): no malloc/free, no
 * locks, no syscalls, no unbounded loops. State is published to Dart through
 * per-field atomics; control commands arrive through a pre-allocated SPSC ring
 * drained at the top of each block. All buffers are allocated before the device
 * starts (le_engine_configure).
 *
 * Multi-track: a shared master loop clock plus N independent tracks. The first
 * track to finish recording defines the master length; further tracks record
 * (overwriting one master loop) or overdub, all phase-locked to the master.
 *
 * One-level undo is real-time-safe: le_engine_record takes the pre-overdub
 * snapshot on the *calling* (Dart) thread — the track buffer is read-only on the
 * audio thread while PLAYING/STOPPED — so the audio thread only performs an O(1)
 * buffer-index swap to undo, never a copy.
 */
#include <ctype.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "engine_core.h" /* shared low-level helpers: le_push, valid_channel, ... */
#include "engine_fx.h" /* effects DSP island: chain runner, reset/free, latency */
#include "engine_internal.h"
#include "engine_miniaudio.h"
#include "engine_platform.h"
#include "engine_private.h"
#include "lockfree_ring.h"
#include "loop_clock.h"
#include "loopy_engine_api.h"
#include "miniaudio.h"

/* All platform-specific behavior (CoreAudio channel labels, JACK port-pinning,
 * PipeWire quantum forcing) lives behind the engine_platform.h seam, implemented
 * per OS in engine_apple.c / engine_linux.c / engine_windows.c. This file is
 * platform-agnostic — no #if defined(__APPLE__|__linux__|_WIN32) behavior. */


/* struct le_engine and its nested types (le_fx_state, le_lane,
 * le_monitor_input, le_track) plus LE_RING_CAPACITY / LE_UNDO_SLOTS now live in
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
 * thread lifecycle dispatch (configure/start/stop/create/destroy) and the
 * looper/effects setters (engine_commands.c is a later S1 increment). */

/* ---- configuration / lifecycle ---- */

/* Resets a lane's routing/volume/mute/effects/metering to defaults (recording
 * hardware input [input_channel]), clearing its effect DSP state and releasing
 * its delay lines. Does NOT touch the pool buffers — the caller owns
 * allocation. Used at configure and when a lane is (re)activated by a growing
 * lane count. */
static void le_lane_reset(le_lane* ln, int32_t input_channel) {
  atomic_store_explicit(&ln->a_input_channel, input_channel,
                        memory_order_relaxed);
  atomic_store_explicit(&ln->a_output_mask, 0x3u, memory_order_relaxed);
  store_f32(&ln->a_vol_bits, 1.0f);
  store_i32(&ln->a_muted, 0);
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
  }
}

/* Resets a live monitor lane to defaults (full stereo output, unity volume,
 * unmuted, empty/clean chain), clearing its effect DSP state and releasing its
 * delay lines. Used at configure and when a monitor's lane count grows. */
static void le_monitor_lane_reset(le_monitor_lane* ln) {
  atomic_store_explicit(&ln->a_output_mask, 0x3u, memory_order_relaxed);
  store_f32(&ln->a_vol_bits, 1.0f);
  store_i32(&ln->a_muted, 0);
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
  }
}

/* Resets a live monitor input to defaults: disabled, a single default (clean)
 * lane. Resets every lane slot (not just the active one) so a later grow starts
 * from a clean lane. */
static void le_monitor_input_reset(le_monitor_input* m) {
  store_i32(&m->a_enabled, 0);
  m->lane_count = 1;
  for (int l = 0; l < LE_MAX_LANES; ++l) {
    le_monitor_lane_reset(&m->lanes[l]);
  }
}

int32_t le_engine_configure(le_engine* engine, int32_t sample_rate,
                            int32_t input_channels, int32_t output_channels,
                            int32_t max_loop_frames) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (input_channels <= 0) input_channels = 2;
  if (input_channels > LE_MAX_CHANNELS) input_channels = LE_MAX_CHANNELS;
  if (output_channels <= 0) output_channels = 2;
  if (output_channels > LE_MAX_CHANNELS) output_channels = LE_MAX_CHANNELS;
  if (sample_rate <= 0) sample_rate = 48000;
  /* Default cap of 30 s/track keeps total memory modest across all tracks
   * (live + undo). Longer loops are configurable; stream-to-disk is deferred. */
  if (max_loop_frames <= 0) max_loop_frames = sample_rate * 30;

  /* Lane buffers are mono: one input channel in, routed out via the mask. */
  const size_t samples = (size_t)max_loop_frames;
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
    engine->track_quantize[t] = -1; /* inherit the global quantize default */
    engine->target_multiple[t] = 0; /* inherit the global default multiple */

    for (int l = 0; l < LE_MAX_LANES; ++l) {
      le_lane* ln = &tr->lanes[l];
      /* Free any buffers from a previous configuration. */
      for (int i = 0; i < LE_UNDO_SLOTS; ++i) {
        free(ln->pool[i]);
        ln->pool[i] = NULL;
      }
      /* Lane l defaults to recording hardware input channel l; lane 0 thus
       * records input 0 and plays 0 + 1, preserving the prior single-track
       * stereo behaviour. */
      le_lane_reset(ln, l);
    }
    /* Only lane 0 is active by default; allocate its live buffer now (further
     * lanes' buffers and all undo snapshots allocate lazily). */
    tr->lanes[0].pool[0] = (float*)calloc(samples, sizeof(float));
    if (tr->lanes[0].pool[0] == NULL) return LE_ERR_INVALID;
  }

  engine->sample_rate = sample_rate;
  engine->in_channels = input_channels;
  engine->out_channels = output_channels;
  engine->max_loop_frames = max_loop_frames;
  engine->fx_delay_frames = sample_rate; /* 1 s of delay line per slot */

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

le_engine* le_engine_create(void) {
  le_engine* engine = (le_engine*)calloc(1, sizeof(le_engine));
  if (engine == NULL) return NULL;
  le_ring_init(&engine->ring, engine->ring_storage, LE_RING_CAPACITY);
  store_i32(&engine->a_latency_state, LE_LATENCY_IDLE);
  store_f32(&engine->a_master_gain_bits, 1.0f); /* unity until set */
  store_i32(&engine->a_limiter_enabled, 0);     /* off until the app enables it */
  store_f32(&engine->a_limiter_ceiling_bits, 0.99f);
  engine->lim_gain = 1.0f;
  store_f32(&engine->a_overdub_fb_bits, 1.0f); /* classic additive overdub */
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
      for (int i = 0; i < LE_UNDO_SLOTS; ++i) {
        free(ln->pool[i]);
      }
      for (int s = 0; s < LE_FX_MAX; ++s) {
        free(ln->fx.delay[s][0]);
        free(ln->fx.delay[s][1]);
        le_fx_free_octaver(&ln->fx, s);
      }
    }
  }
  for (int c = 0; c < LE_MAX_INPUTS; ++c) {
    for (int l = 0; l < LE_MAX_LANES; ++l) {
      for (int s = 0; s < LE_FX_MAX; ++s) {
        free(engine->monitors[c].lanes[l].fx.delay[s][0]);
        free(engine->monitors[c].lanes[l].fx.delay[s][1]);
        le_fx_free_octaver(&engine->monitors[c].lanes[l].fx, s);
      }
    }
  }
  free(engine->lat_buf);
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
  const le_command cmd = {code, arg_i, arg_f};
  return le_ring_push(&engine->ring, cmd) ? LE_OK : LE_ERR_INVALID;
}

int32_t le_engine_measure_latency(le_engine* engine) {
  return le_engine_post_command(engine, LE_CMD_MEASURE_LATENCY, 0, 0.0f);
}

/* ---- looper control (push gated on `configured`, so tests work device-free) */

int32_t le_push(le_engine* engine, int32_t code, int32_t arg_i,
                float arg_f) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  const le_command cmd = {code, arg_i, arg_f};
  return le_ring_push(&engine->ring, cmd) ? LE_OK : LE_ERR_INVALID;
}

int32_t le_engine_begin_latency_for_test(le_engine* engine) {
  /* Configured-gated (like the looper commands) so the harness's loopback
   * detection can be driven without opening a device. */
  return le_push(engine, LE_CMD_MEASURE_LATENCY, 0, 0.0f);
}

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
