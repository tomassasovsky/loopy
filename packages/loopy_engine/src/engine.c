/*
 * engine.c — implementation of loopy_engine_api.h on top of miniaudio.
 *
 * Real-time contract (data_callback): no malloc/free, no locks, no syscalls, no
 * unbounded loops. State is published to Dart through per-field atomics; control
 * commands arrive through a pre-allocated SPSC ring drained at the top of each
 * callback. All buffers are allocated before the device starts.
 */
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "lockfree_ring.h"
#include "loopy_engine_api.h"
#include "miniaudio.h"

#define LE_RING_CAPACITY 256u
#define LE_MAX_CHANNELS 2
#define LE_LATENCY_THRESHOLD 0.3f /* loopback detection level (0..1) */

struct le_engine {
  ma_device device;
  int device_initialised;

  /* Snapshot, published as independent atomics (see header for rationale). */
  _Atomic int32_t a_running;
  _Atomic int32_t a_sample_rate;
  _Atomic int32_t a_buffer_frames;
  _Atomic int32_t a_channels;
  _Atomic uint64_t a_frames;
  _Atomic uint32_t a_xruns;
  _Atomic uint32_t a_in_rms_bits;
  _Atomic uint32_t a_in_peak_bits;
  _Atomic uint32_t a_out_rms_bits;
  _Atomic int32_t a_latency_state;
  _Atomic uint64_t a_latency_ms_bits;

  /* Command ring + its backing storage (pre-allocated, never resized). */
  le_ring ring;
  le_command ring_storage[LE_RING_CAPACITY];

  /* Audio-thread-local latency harness state (no atomics needed). */
  int lat_active;
  int lat_emitted;
  uint64_t lat_frames_since_emit;

  char device_name[256];
  int passthrough;
};

/* ---- float/double <-> atomic-bits helpers (lock-free publish of reals) ---- */

static uint32_t f32_to_bits(float v) {
  uint32_t b;
  memcpy(&b, &v, sizeof(b));
  return b;
}

static float bits_to_f32(uint32_t b) {
  float v;
  memcpy(&v, &b, sizeof(v));
  return v;
}

static uint64_t f64_to_bits(double v) {
  uint64_t b;
  memcpy(&b, &v, sizeof(b));
  return b;
}

static double bits_to_f64(uint64_t b) {
  double v;
  memcpy(&v, &b, sizeof(v));
  return v;
}

static void store_f32(_Atomic uint32_t* slot, float v) {
  atomic_store_explicit(slot, f32_to_bits(v), memory_order_relaxed);
}

/* ---- audio callback (real-time thread) ---- */

static void data_callback(ma_device* device, void* output, const void* input,
                          ma_uint32 frame_count) {
  le_engine* engine = (le_engine*)device->pUserData;
  const int channels = (int)device->capture.channels;
  float* out = (float*)output;
  const float* in = (const float*)input;

  /* Drain pending control commands (wait-free). */
  le_command cmd;
  while (le_ring_pop(&engine->ring, &cmd)) {
    if (cmd.code == LE_CMD_MEASURE_LATENCY) {
      engine->lat_active = 1;
      engine->lat_emitted = 0;
      engine->lat_frames_since_emit = 0;
      atomic_store_explicit(&engine->a_latency_state, LE_LATENCY_MEASURING,
                            memory_order_relaxed);
    }
  }

  const int sample_rate =
      atomic_load_explicit(&engine->a_sample_rate, memory_order_relaxed);
  const uint64_t timeout_frames = (uint64_t)(sample_rate > 0 ? sample_rate : 48000);

  float in_sumsq = 0.0f;
  float in_peak = 0.0f;
  float out_sumsq = 0.0f;

  for (ma_uint32 f = 0; f < frame_count; ++f) {
    /* Inspect the input frame (max magnitude drives loopback detection). */
    float frame_mag = 0.0f;
    for (int c = 0; c < channels; ++c) {
      const float s = in ? in[f * channels + c] : 0.0f;
      const float a = fabsf(s);
      if (a > frame_mag) frame_mag = a;
      in_sumsq += s * s;
    }
    if (frame_mag > in_peak) in_peak = frame_mag;

    /* Decide this frame's output value (broadcast to every channel for the
     * impulse/silence cases; passthrough copies each channel below).
     *   - During a measurement: a single full-scale impulse, then silence, so
     *     the only signal on the wire is the returning loopback (no feedback).
     *   - Otherwise: passthrough input, or silence. */
    int is_passthrough_frame = 0;
    float broadcast = 0.0f;
    if (engine->lat_active) {
      if (!engine->lat_emitted) {
        broadcast = 1.0f; /* full-scale impulse */
        engine->lat_emitted = 1;
        engine->lat_frames_since_emit = 0;
      } else {
        engine->lat_frames_since_emit++;
        if (frame_mag >= LE_LATENCY_THRESHOLD) {
          const double ms = sample_rate > 0
              ? (double)engine->lat_frames_since_emit * 1000.0 / sample_rate
              : 0.0;
          atomic_store_explicit(&engine->a_latency_ms_bits, f64_to_bits(ms),
                                memory_order_relaxed);
          atomic_store_explicit(&engine->a_latency_state, LE_LATENCY_DONE,
                                memory_order_relaxed);
          engine->lat_active = 0;
        } else if (engine->lat_frames_since_emit > timeout_frames) {
          atomic_store_explicit(&engine->a_latency_state, LE_LATENCY_TIMEOUT,
                                memory_order_relaxed);
          engine->lat_active = 0;
        }
      }
    } else {
      is_passthrough_frame = engine->passthrough && in;
    }

    for (int c = 0; c < channels; ++c) {
      const float sample =
          is_passthrough_frame ? in[f * channels + c] : broadcast;
      out[f * channels + c] = sample;
      out_sumsq += sample * sample;
    }
  }

  /* Publish block metering + frame count. */
  const ma_uint32 total_in = frame_count * (ma_uint32)channels;
  const ma_uint32 total_out = total_in;
  store_f32(&engine->a_in_rms_bits,
            total_in ? sqrtf(in_sumsq / (float)total_in) : 0.0f);
  store_f32(&engine->a_in_peak_bits, in_peak);
  store_f32(&engine->a_out_rms_bits,
            total_out ? sqrtf(out_sumsq / (float)total_out) : 0.0f);
  atomic_fetch_add_explicit(&engine->a_frames, (uint64_t)frame_count,
                            memory_order_relaxed);
}

/* ---- lifecycle ---- */

const char* le_version(void) { return "loopy_engine 0.1.0 (miniaudio " MA_VERSION_STRING ")"; }

le_engine* le_engine_create(void) {
  le_engine* engine = (le_engine*)calloc(1, sizeof(le_engine));
  if (engine == NULL) return NULL;
  le_ring_init(&engine->ring, engine->ring_storage, LE_RING_CAPACITY);
  atomic_store_explicit(&engine->a_latency_state, LE_LATENCY_IDLE,
                        memory_order_relaxed);
  return engine;
}

void le_engine_destroy(le_engine* engine) {
  if (engine == NULL) return;
  if (engine->device_initialised) {
    ma_device_uninit(&engine->device);
    engine->device_initialised = 0;
  }
  free(engine);
}

int32_t le_engine_start(le_engine* engine, const le_config* config) {
  if (engine == NULL || config == NULL) return LE_ERR_INVALID;
  if (atomic_load_explicit(&engine->a_running, memory_order_acquire)) {
    return LE_ERR_ALREADY_RUNNING;
  }

  int channels = config->channels > 0 ? config->channels : 2;
  if (channels > LE_MAX_CHANNELS) channels = LE_MAX_CHANNELS;
  engine->passthrough = config->passthrough ? 1 : 0;

  ma_device_config cfg = ma_device_config_init(ma_device_type_duplex);
  cfg.capture.format = ma_format_f32;
  cfg.capture.channels = (ma_uint32)channels;
  cfg.playback.format = ma_format_f32;
  cfg.playback.channels = (ma_uint32)channels;
  cfg.sampleRate = config->sample_rate > 0 ? (ma_uint32)config->sample_rate : 0;
  if (config->buffer_frames > 0) {
    cfg.periodSizeInFrames = (ma_uint32)config->buffer_frames;
    cfg.periods = 2;
  }
  cfg.dataCallback = data_callback;
  cfg.pUserData = engine;

  if (ma_device_init(NULL, &cfg, &engine->device) != MA_SUCCESS) {
    return LE_ERR_DEVICE;
  }
  engine->device_initialised = 1;

  /* Capture the negotiated parameters before the callback fires. */
  atomic_store_explicit(&engine->a_sample_rate,
                        (int32_t)engine->device.sampleRate, memory_order_relaxed);
  atomic_store_explicit(&engine->a_buffer_frames,
                        (int32_t)engine->device.playback.internalPeriodSizeInFrames,
                        memory_order_relaxed);
  atomic_store_explicit(&engine->a_channels, channels, memory_order_relaxed);
  atomic_store_explicit(&engine->a_frames, 0, memory_order_relaxed);
  atomic_store_explicit(&engine->a_xruns, 0, memory_order_relaxed);
  atomic_store_explicit(&engine->a_latency_state, LE_LATENCY_IDLE,
                        memory_order_relaxed);
  engine->lat_active = 0;
  engine->lat_emitted = 0;

  strncpy(engine->device_name, engine->device.playback.name,
          sizeof(engine->device_name) - 1);
  engine->device_name[sizeof(engine->device_name) - 1] = '\0';

  if (ma_device_start(&engine->device) != MA_SUCCESS) {
    ma_device_uninit(&engine->device);
    engine->device_initialised = 0;
    return LE_ERR_DEVICE;
  }
  atomic_store_explicit(&engine->a_running, 1, memory_order_release);
  return LE_OK;
}

int32_t le_engine_stop(le_engine* engine) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_running, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  ma_device_uninit(&engine->device);
  engine->device_initialised = 0;
  engine->device_name[0] = '\0';
  atomic_store_explicit(&engine->a_running, 0, memory_order_release);
  return LE_OK;
}

void le_engine_get_snapshot(le_engine* engine, le_snapshot* out) {
  if (engine == NULL || out == NULL) return;
  out->running = atomic_load_explicit(&engine->a_running, memory_order_acquire);
  out->sample_rate =
      atomic_load_explicit(&engine->a_sample_rate, memory_order_relaxed);
  out->buffer_frames =
      atomic_load_explicit(&engine->a_buffer_frames, memory_order_relaxed);
  out->channels = atomic_load_explicit(&engine->a_channels, memory_order_relaxed);
  out->frames_processed =
      atomic_load_explicit(&engine->a_frames, memory_order_relaxed);
  out->xrun_count = atomic_load_explicit(&engine->a_xruns, memory_order_relaxed);
  out->input_rms = bits_to_f32(
      atomic_load_explicit(&engine->a_in_rms_bits, memory_order_relaxed));
  out->input_peak = bits_to_f32(
      atomic_load_explicit(&engine->a_in_peak_bits, memory_order_relaxed));
  out->output_rms = bits_to_f32(
      atomic_load_explicit(&engine->a_out_rms_bits, memory_order_relaxed));
  out->latency_state =
      atomic_load_explicit(&engine->a_latency_state, memory_order_relaxed);
  out->measured_latency_ms = bits_to_f64(
      atomic_load_explicit(&engine->a_latency_ms_bits, memory_order_relaxed));
}

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
  le_command cmd = {code, arg_i, arg_f};
  return le_ring_push(&engine->ring, cmd) ? LE_OK : LE_ERR_INVALID;
}

int32_t le_engine_measure_latency(le_engine* engine) {
  return le_engine_post_command(engine, LE_CMD_MEASURE_LATENCY, 0, 0.0f);
}
