/*
 * le_device_backend.h — the internal device-backend seam.
 *
 * A thin vtable (a struct of function pointers) plus a negotiated-info
 * out-struct that le_engine_start / le_engine_stop / le_engine_destroy drive
 * instead of calling ma_device_* directly. The engine selects one backend with
 * le_select_backend (engine.c) and owns the device lifecycle exclusively
 * through this interface. The real-time core (le_engine_process), the SPSC
 * command ring, the atomic snapshot, and the looper/lane/FX DSP are reused
 * unchanged; a backend impl only opens/starts/stops/closes the device and
 * pumps le_engine_process from its real-time callback.
 *
 * In this build the only implementation is the miniaudio backend
 * (engine_miniaudio.c). The opt-in Windows ASIO backend slots in later behind
 * le_select_backend.
 *
 * This is DISTINCT from the per-OS engine_platform.h seam: that seam covers
 * per-OS *capabilities* (Core Audio labels, JACK pinning) over a single shared
 * miniaudio device, whereas this seam swaps the device backend itself.
 *
 * Purely internal: NOT part of the FFI surface (loopy_engine_api.h) or ffigen.
 */
#ifndef LOOPY_ENGINE_DEVICE_BACKEND_H
#define LOOPY_ENGINE_DEVICE_BACKEND_H

#include <stdint.h>

#include "loopy_engine_api.h"  /* le_engine (opaque), le_config, LE_MAX_CHANNELS */

#ifdef __cplusplus
extern "C" {
#endif

/* Negotiated device parameters a backend reports back after a successful open.
 * The engine publishes these into its atomics and feeds the channel counts /
 * sample rate into le_engine_configure. */
typedef struct le_device_open_result {
  int32_t sample_rate;
  int32_t input_channels;   /* negotiated capture channels, clamped to LE_MAX_CHANNELS */
  int32_t output_channels;  /* negotiated playback channels, clamped to LE_MAX_CHANNELS */
  int32_t buffer_frames;    /* internal device period size in frames */
  int32_t exclusive_active; /* 1 = opened OS-exclusive (miniaudio only; 0 for ASIO) */
  int32_t active_backend;   /* le_audio_backend actually opened */
  char    device_name[256]; /* human-readable name of the active playback device */
  /* Loopback-excluded input channels computed by the backend from its own
   * channel labels, when it can read them WITHOUT a re-probe (the ASIO backend
   * reads ASIOGetChannelInfo names at open). 0 when the backend does not supply
   * it — the miniaudio path instead computes the mask in le_engine_start from
   * the resolved capture-device UID (the per-OS le_platform_excluded_input_mask
   * label probe), which must not run while an ASIO device is open (R1). */
  uint32_t excluded_input_mask;
} le_device_open_result;

/* One device backend. open()/start()/stop()/close() are driven in that order by
 * le_engine_start; close() is also the cleanup path on an open/configure/start
 * failure and is idempotent. The impl owns engine->device / engine->context and
 * calls le_engine_process from its real-time data callback. */
typedef struct le_device_backend {
  /* Opens (but does not start) the device with `cfg` and fills `out` with the
   * negotiated parameters. Returns LE_OK or an le_result error; on failure it
   * leaves the device fully released (close() need not be called). */
  int32_t (*open)(le_engine* e, const le_config* cfg, le_device_open_result* out);
  /* Starts the real-time callback. Returns LE_OK or an le_result error. */
  int32_t (*start)(le_engine* e);
  /* Stops and fully releases the device. Returns LE_OK or an le_result error. */
  int32_t (*stop)(le_engine* e);
  /* Releases any open device/context. Idempotent; used for failure cleanup and
   * teardown. */
  void (*close)(le_engine* e);
} le_device_backend;

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_ENGINE_DEVICE_BACKEND_H */
