/*
 * engine_miniaudio.c — the miniaudio device backend (le_device_backend.h).
 *
 * Owns the miniaudio device lifecycle behind the device-backend seam: building
 * the ma_device_config, initialising the context, resolving pinned / loopback
 * device ids, ma_device_init / start / uninit, and the real-time data +
 * device-notification callbacks. The portable
 * core (engine.c) drives this through le_select_backend and never calls
 * ma_device_* directly. The real-time core (le_engine_process), the command
 * ring, the snapshot, and the looper/lane/FX DSP all stay in engine.c and are
 * reused unchanged; the data callback here just pumps le_engine_process.
 *
 * Compiled unconditionally (like the per-OS platform-seam TUs); it is the only
 * device backend this build ships. The opt-in Windows ASIO backend lands later
 * as a second le_device_backend selected by le_select_backend.
 */
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h> /* getenv — appliance exclusive-mode check */
#include <string.h>

#include "engine_internal.h"  /* le_engine_process */
#include "engine_miniaudio.h" /* le_miniaudio_backend */
#include "engine_platform.h"  /* le_platform_backends / _before_context_init */
#include "engine_private.h"   /* struct le_engine, le_find_loopback, le_resolve_device_id */
#include "le_device_backend.h"
#include "loopy_engine_api.h"
#include "miniaudio.h"

/* The miniaudio data callback: forwards one interleaved block straight into the
 * portable real-time core. No allocation, locking, or I/O (see engine.c). */
static void data_callback(ma_device* device, void* output, const void* input,
                          ma_uint32 frame_count) {
  le_engine_process((le_engine*)device->pUserData, (float*)output,
                    (const float*)input, frame_count);
}

/* Device-state notifications from miniaudio. RT-adjacent: stores the presence
 * atomic only — never allocates, locks, or touches the device. A stopped /
 * rerouted / interrupted device flips presence to 0; (re)start / resume flips it
 * back to 1. Recovery from a 0 is the Dart layer's job (A2), not native's. */
static void notification_callback(const ma_device_notification* notification) {
  if (notification == NULL || notification->pDevice == NULL) return;
  le_engine* e = (le_engine*)notification->pDevice->pUserData;
  if (e == NULL) return;
  switch (notification->type) {
    case ma_device_notification_type_started:
    case ma_device_notification_type_interruption_ended:
      atomic_store_explicit(&e->a_device_present, 1, memory_order_relaxed);
      break;
    case ma_device_notification_type_stopped:
    case ma_device_notification_type_rerouted:
    case ma_device_notification_type_interruption_began:
      atomic_store_explicit(&e->a_device_present, 0, memory_order_relaxed);
      break;
    default:
      break;
  }
}

static void le_uninit_context(le_engine* engine) {
  if (engine->context_initialised) {
    ma_context_uninit(&engine->context);
    engine->context_initialised = 0;
  }
}

/* Releases any open device + context. Idempotent: safe on a partially-opened or
 * already-closed engine, so it is the cleanup path for open/configure/start
 * failures as well as the seam's close(). */
static void le_miniaudio_close(le_engine* engine) {
  if (engine->device_initialised) {
    /* Stop before uninit. miniaudio's ma_device_uninit has its "stop if started"
     * block compiled out (#if 0), so it only signals the worker's outer
     * wakeupEvent and joins — it does NOT wake a *running* data loop. On the ALSA
     * duplex backend the worker is then blocked in poll(-1) on the capture PCM
     * (only ma_device_stop -> onDeviceDataLoopWakeup writes the wakeup eventfd
     * that breaks it), so uninit-while-started dead­locks the join. This is
     * exactly the hang hit on every sample-rate / buffer change (which reopens
     * the device). ma_device_stop fires the wakeup and is a safe no-op on an
     * already-stopped device, so it is correct on every backend. */
    ma_device_stop(&engine->device);
    ma_device_uninit(&engine->device);
    engine->device_initialised = 0;
  }
  le_uninit_context(engine);
}

/* Opens (but does not start) the miniaudio device. On success fills *out with
 * the negotiated parameters and leaves engine->device / engine->context live;
 * on failure releases everything and returns an le_result error. */
static int32_t le_miniaudio_open(le_engine* engine, const le_config* config,
                                 le_device_open_result* out) {
  /* Capture and playback widths may differ (e.g. 2-in / 4-out). An unset (0)
   * count tells miniaudio to open the device's native channel count, so a
   * multichannel interface comes up with all its channels; the negotiated
   * counts are read back after init. */
  int in_channels = config->input_channels > 0 ? config->input_channels : 0;
  int out_channels = config->output_channels > 0 ? config->output_channels : 0;
  if (in_channels > LE_MAX_CHANNELS) in_channels = LE_MAX_CHANNELS;
  if (out_channels > LE_MAX_CHANNELS) out_channels = LE_MAX_CHANNELS;

  ma_device_config cfg = ma_device_config_init(ma_device_type_duplex);
  cfg.capture.format = ma_format_f32;
  cfg.capture.channels = (ma_uint32)in_channels;
  cfg.playback.format = ma_format_f32;
  cfg.playback.channels = (ma_uint32)out_channels;
  cfg.sampleRate = config->sample_rate > 0 ? (ma_uint32)config->sample_rate : 0;
  if (config->buffer_frames > 0) {
    cfg.periodSizeInFrames = (ma_uint32)config->buffer_frames;
    cfg.periods = 2;
  }
  cfg.dataCallback = data_callback;
  cfg.notificationCallback = notification_callback;
  cfg.pUserData = engine;
  /* Force plain readi/writei on ALSA (no MMAP). Only the ALSA backend reads this
   * field (ignored by JACK/CoreAudio/WASAPI). On the direct-ALSA appliance,
   * miniaudio's MMAP *duplex* read/write loop stalls in poll() — the device runs
   * (hardware pointer advances) but not one frame is read/written — whereas the
   * readi/writei path pumps correctly (verified against arecord). MMAP's only win
   * is a marginal CPU saving, irrelevant here. */
  cfg.alsa.noMMap = MA_TRUE;
#if defined(__linux__)
  /* Appliance (LOOPY_ALSA_ONLY): open the card EXCLUSIVELY (raw "hw:") rather
   * than miniaudio's default shared mode, which on ALSA routes through the dmix
   * (playback) / dsnoop (capture) plugins. Those plugins fail / misbehave for
   * this duplex USB interface ("dsnoop unable to open slave", capture avail stuck
   * at 0), whereas the raw hw device works perfectly (verified with speaker-test
   * + arecord). Single-app appliance, so exclusive access is correct anyway. Not
   * applied on macOS/Windows (there exclusive maps to WASAPI-exclusive / CoreAudio
   * hog mode, a behaviour change we don't want on the shipping desktop app). */
  if (getenv("LOOPY_ALSA_ONLY") != NULL) {
    cfg.capture.shareMode = ma_share_mode_exclusive;
    cfg.playback.shareMode = ma_share_mode_exclusive;
  }
#endif

  /* An explicit context lets us pick the backend (see below) and resolve a
   * pinned/loopback device id. We always open one; a detected loopback device
   * (use_loopback_capture) or a device pinned by id is resolved against it. */
  const int want_playback_pin = config->playback_device_id[0] != '\0';
  const int want_capture_pin = config->capture_device_id[0] != '\0';
  ma_context* pContext = NULL;
  engine->capture_id_set = 0;

  /* Per-OS backend preference + pre-context-init hook. Linux prefers
   * {jack, pulseaudio, alsa} and forces the PipeWire quantum; every other
   * platform keeps miniaudio's default backend priority and does nothing here. */
  const ma_backend* p_backends = NULL;
  ma_uint32 backend_count = 0;
  le_platform_backends(&p_backends, &backend_count);
  le_platform_before_context_init(config);

  /* Always open a context so the backend preference takes effect (it is also
   * needed to resolve a pinned/loopback device id). */
  if (ma_context_init(p_backends, backend_count, NULL, &engine->context) ==
      MA_SUCCESS) {
    engine->context_initialised = 1;
    pContext = &engine->context;
    if (config->use_loopback_capture) {
      /* Loopback capture overrides an explicit capture device id. */
      le_loopback_info info;
      le_find_loopback(&engine->context, &info, &engine->capture_id);
      if (info.available && info.device_name[0] != '\0') {
        cfg.capture.pDeviceID = &engine->capture_id;
        engine->capture_id_set = 1;
      }
    } else if (want_capture_pin) {
      if (le_resolve_device_id(&engine->context, /*capture=*/1,
                               config->capture_device_id, &engine->capture_id)) {
        cfg.capture.pDeviceID = &engine->capture_id;
        engine->capture_id_set = 1;
      }
    }
    if (want_playback_pin) {
      if (le_resolve_device_id(&engine->context, /*capture=*/0,
                               config->playback_device_id,
                               &engine->playback_id)) {
        cfg.playback.pDeviceID = &engine->playback_id;
      }
    }
  }

  /* Open the device in shared mode (miniaudio's default on every backend). The
   * OS mixer owns the device; this is the behaviour on macOS/Linux. On Windows
   * full device control goes through ASIO instead, not this path. */
  ma_result init_result = ma_device_init(pContext, &cfg, &engine->device);
  if (init_result != MA_SUCCESS) {
    le_uninit_context(engine);
    return LE_ERR_DEVICE;
  }
  engine->device_initialised = 1;

  /* Negotiated parameters (they may differ from requested). Channel counts are
   * clamped to the mask width the rest of the engine routes within. */
  int32_t neg_in = (int32_t)engine->device.capture.channels;
  int32_t neg_out = (int32_t)engine->device.playback.channels;
  if (neg_in > LE_MAX_CHANNELS) neg_in = LE_MAX_CHANNELS;
  if (neg_out > LE_MAX_CHANNELS) neg_out = LE_MAX_CHANNELS;
  out->sample_rate = (int32_t)engine->device.sampleRate;
  out->input_channels = neg_in;
  out->output_channels = neg_out;
  out->buffer_frames =
      (int32_t)engine->device.playback.internalPeriodSizeInFrames;
  out->active_backend = LE_BACKEND_MINIAUDIO;
  /* The loopback-excluded mask is computed in le_engine_start from the resolved
   * capture-device UID for this path; the backend reports none here. */
  out->excluded_input_mask = 0;
  strncpy(out->device_name, engine->device.playback.name,
          sizeof(out->device_name) - 1);
  out->device_name[sizeof(out->device_name) - 1] = '\0';
  return LE_OK;
}

/* Starts the real-time callback. Publishes device-present + running on success;
 * on failure the caller (le_engine_start) invokes close() to release. */
static int32_t le_miniaudio_start(le_engine* engine) {
  /* Promote the (idle) audio worker to real-time before it starts, so its first
   * reads run at the right priority (see le_platform_after_device_open). */
  le_platform_after_device_open(engine);
  if (ma_device_start(&engine->device) != MA_SUCCESS) {
    return LE_ERR_DEVICE;
  }
  le_engine_mark_started(engine);
  return LE_OK;
}

/* Stops + fully releases the device. The running/present flags and the per-OS
 * teardown hook are reset by le_engine_stop above the seam. For miniaudio,
 * le_miniaudio_close stops (explicitly — see the note there) then releases, so
 * stop() and close() coincide and stop() just delegates; the seam keeps them
 * separate because a future backend (ASIO, Part 2) may need a distinct
 * stop-without-release step. */
static int32_t le_miniaudio_stop(le_engine* engine) {
  le_miniaudio_close(engine);
  return LE_OK;
}

const le_device_backend le_miniaudio_backend = {
    .open = le_miniaudio_open,
    .start = le_miniaudio_start,
    .stop = le_miniaudio_stop,
    .close = le_miniaudio_close,
};
