/*
 * engine.c — implementation of loopy_engine_api.h on top of miniaudio.
 *
 * Real-time contract (le_engine_process / data_callback): no malloc/free, no
 * locks, no syscalls, no unbounded loops. State is published to Dart through
 * per-field atomics; control commands arrive through a pre-allocated SPSC ring
 * drained at the top of each block. All buffers are allocated before the device
 * starts (le_engine_configure).
 *
 * One-level undo is real-time-safe: le_engine_record takes the pre-overdub
 * snapshot on the *calling* (Dart) thread — the track buffer is read-only on the
 * audio thread while PLAYING/STOPPED — so the audio thread only performs an O(1)
 * buffer-index swap to undo, never a copy.
 */
#include <ctype.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "engine_internal.h"
#include "lockfree_ring.h"
#include "loop_clock.h"
#include "loopy_engine_api.h"
#include "miniaudio.h"

#define LE_RING_CAPACITY 256u
#define LE_MAX_CHANNELS 2
/* Loopback latency harness. The echo returns only mildly attenuated (~0.9 from
 * a full-scale pulse on a typical interface), so we emit a quiet calibration
 * tone rather than full scale to spare the user's monitors, and detect with a
 * threshold comfortably below the echo yet well above the noise floor. */
#define LE_LATENCY_PULSE_AMP 0.3f /* calibration pulse amplitude (0..1) */
#define LE_LATENCY_THRESHOLD 0.05f /* loopback detection level (0..1) */
#define LE_LATENCY_PULSE_DIV 100   /* pulse length = sample_rate / this (~10ms) */
#define LE_LATENCY_DEAD_DIV 400    /* dead-time   = sample_rate / this (~2.5ms) */
#define LE_LATENCY_RETRY_DIV 10    /* per-attempt = sample_rate / this (~100ms) */
#define LE_LATENCY_ATTEMPTS 5      /* re-emit this many pulses before timing out */

struct le_engine {
  ma_device device;
  int device_initialised;

  /* Snapshot, published as independent atomics. */
  _Atomic int32_t a_running;
  _Atomic int32_t a_configured;
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
  _Atomic int32_t a_monitor; /* live input-monitoring flag (see passthrough) */

  /* Looper, published. */
  _Atomic int32_t a_master_len;
  _Atomic int32_t a_master_pos;
  _Atomic int32_t a_track_state;
  _Atomic uint32_t a_track_vol_bits;
  _Atomic int32_t a_track_muted;
  _Atomic int32_t a_track_len;
  _Atomic int32_t a_track_undo_depth;
  _Atomic uint32_t a_track_rms_bits;
  _Atomic uint32_t a_track_peak_bits;
  _Atomic int32_t a_live_index;

  /* Command ring + pre-allocated backing storage. */
  le_ring ring;
  le_command ring_storage[LE_RING_CAPACITY];

  /* Configuration. */
  int sample_rate;
  int channels;
  int32_t max_loop_frames;

  /* Two interleaved track buffers: live + undo snapshot. */
  float* track_buf[2];

  /* Audio-thread-local looper state. */
  le_loop_clock clock;
  int32_t record_pos;
  int pending_undo;

  /* Latency harness (audio-thread-local + published state). */
  int lat_active;
  int32_t lat_emit_remaining;     /* frames left to broadcast the pulse */
  uint64_t lat_frames_since_emit; /* counted from the current pulse's start */
  int32_t lat_attempts_remaining; /* pulses left before declaring a timeout */

  char device_name[256];
  int passthrough; /* input monitoring */
  int mono_input;  /* average input channels and feed every output channel */

  /* Explicit context + capture device id, only used when capturing from a
   * detected loopback device (use_loopback_capture). */
  ma_context context;
  int context_initialised;
  ma_device_id capture_id;
};

/* ---- float/double <-> atomic-bits helpers ---- */

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
static float load_f32(_Atomic uint32_t* slot) {
  return bits_to_f32(atomic_load_explicit(slot, memory_order_relaxed));
}
static int32_t load_i32(_Atomic int32_t* slot) {
  return atomic_load_explicit(slot, memory_order_relaxed);
}
static void store_i32(_Atomic int32_t* slot, int32_t v) {
  atomic_store_explicit(slot, v, memory_order_relaxed);
}

/* ---- command handlers (audio thread) ---- */

static void finalize_loop(le_engine* e) {
  const int32_t len = e->record_pos > 0 ? e->record_pos : 1;
  le_loop_clock_set_length(&e->clock, len);
  store_i32(&e->a_master_len, len);
  store_i32(&e->a_track_len, len);
  store_i32(&e->a_track_state, LE_TRACK_PLAYING);
}

static void handle_record(le_engine* e) {
  switch (load_i32(&e->a_track_state)) {
    case LE_TRACK_EMPTY:
      e->record_pos = 0;
      le_loop_clock_reset(&e->clock);
      store_i32(&e->a_track_state, LE_TRACK_RECORDING);
      break;
    case LE_TRACK_RECORDING:
      finalize_loop(e);
      break;
    case LE_TRACK_PLAYING:
    case LE_TRACK_STOPPED:
      /* Undo snapshot already taken on the calling thread by le_engine_record. */
      store_i32(&e->a_track_state, LE_TRACK_OVERDUBBING);
      break;
    case LE_TRACK_OVERDUBBING:
      store_i32(&e->a_track_state, LE_TRACK_PLAYING);
      break;
    default:
      break;
  }
}

static void handle_stop(le_engine* e) {
  const int32_t st = load_i32(&e->a_track_state);
  if (st == LE_TRACK_RECORDING) {
    finalize_loop(e);
    store_i32(&e->a_track_state, LE_TRACK_STOPPED);
  } else if (st == LE_TRACK_PLAYING || st == LE_TRACK_OVERDUBBING) {
    store_i32(&e->a_track_state, LE_TRACK_STOPPED);
  }
}

static void handle_clear(le_engine* e) {
  le_loop_clock_reset(&e->clock);
  e->record_pos = 0;
  e->pending_undo = 0;
  store_i32(&e->a_master_len, 0);
  store_i32(&e->a_master_pos, 0);
  store_i32(&e->a_track_len, 0);
  store_i32(&e->a_track_undo_depth, 0);
  store_i32(&e->a_track_state, LE_TRACK_EMPTY);
}

static void apply_command(le_engine* e, const le_command* cmd) {
  switch (cmd->code) {
    case LE_CMD_MEASURE_LATENCY: {
      const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
      e->lat_active = 1;
      /* Emit for ~10 ms so the pulse survives D/A → cable → A/D. */
      e->lat_emit_remaining = sr / LE_LATENCY_PULSE_DIV;
      e->lat_frames_since_emit = 0;
      e->lat_attempts_remaining = LE_LATENCY_ATTEMPTS;
      store_i32(&e->a_latency_state, LE_LATENCY_MEASURING);
      /* A loopback measurement requires a physical out->in cable, which forms a
       * feedback loop with input monitoring (out -> cable -> in -> monitor ->
       * out). With loop gain > 1 that runs away to clipping and can overload the
       * interface. Disable monitoring for the rest of the session; it is
       * restored on the next start(). */
      store_i32(&e->a_monitor, 0);
      break;
    }
    case LE_CMD_RECORD:
      handle_record(e);
      break;
    case LE_CMD_STOP:
      handle_stop(e);
      break;
    case LE_CMD_PLAY:
      if (load_i32(&e->a_track_state) == LE_TRACK_STOPPED) {
        store_i32(&e->a_track_state, LE_TRACK_PLAYING);
      }
      break;
    case LE_CMD_CLEAR:
      handle_clear(e);
      break;
    case LE_CMD_UNDO:
      if (load_i32(&e->a_track_undo_depth) > 0) e->pending_undo = 1;
      break;
    case LE_CMD_SET_VOLUME: {
      float v = cmd->arg_f;
      if (v < 0.0f) v = 0.0f;
      if (v > 1.0f) v = 1.0f;
      store_f32(&e->a_track_vol_bits, v);
      break;
    }
    case LE_CMD_SET_MUTE:
      store_i32(&e->a_track_muted, cmd->arg_f != 0.0f ? 1 : 0);
      break;
    default:
      break;
  }
}

/* ---- the real-time DSP core ---- */

void le_engine_process(le_engine* e, float* output, const float* input,
                       uint32_t frames) {
  const int ch = e->channels;
  float* out = output;
  const float* in = input;

  le_command cmd;
  while (le_ring_pop(&e->ring, &cmd)) apply_command(e, &cmd);

  const int sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  const float vol = load_f32(&e->a_track_vol_bits);
  const int muted = load_i32(&e->a_track_muted);

  float in_sumsq = 0.0f;
  float in_peak = 0.0f;
  float out_sumsq = 0.0f;
  float trk_sumsq = 0.0f;
  float trk_peak = 0.0f;

  for (uint32_t f = 0; f < frames; ++f) {
    float frame_mag = 0.0f;
    float mono = 0.0f;
    for (int c = 0; c < ch; ++c) {
      const float s = in ? in[f * ch + c] : 0.0f;
      const float a = fabsf(s);
      if (a > frame_mag) frame_mag = a;
      in_sumsq += s * s;
      mono += s;
    }
    mono /= (float)ch; /* clip-safe average fold-down */
    if (frame_mag > in_peak) in_peak = frame_mag;

    /* Latency harness takes over the output entirely while measuring.
     *
     * Each attempt broadcasts a quiet ~10 ms pulse, then silence, and listens
     * for the echo. lat_frames_since_emit counts from the current pulse's first
     * frame. A short dead-time suppresses direct output bleed before we start
     * checking input; thereafter we check every frame (the echo can arrive while
     * a small-buffer pulse is still emitting). If an attempt's window elapses
     * with no echo, we re-emit — a single dropped period at device startup costs
     * one retry instead of a full timeout. After LE_LATENCY_ATTEMPTS misses we
     * report a timeout. The retry interval (~100 ms) is far longer than any real
     * round-trip, so an echo is never mis-attributed to the wrong pulse. */
    if (e->lat_active) {
      float broadcast = 0.0f;
      if (e->lat_emit_remaining > 0) {
        broadcast = LE_LATENCY_PULSE_AMP;
        e->lat_emit_remaining--;
      }
      e->lat_frames_since_emit++;

      const uint64_t dead_frames = (uint64_t)(sr / LE_LATENCY_DEAD_DIV);
      const uint64_t attempt_frames = (uint64_t)(sr / LE_LATENCY_RETRY_DIV);
      if (e->lat_frames_since_emit > dead_frames &&
          frame_mag >= LE_LATENCY_THRESHOLD) {
        const double ms = (double)e->lat_frames_since_emit * 1000.0 / (double)sr;
        atomic_store_explicit(&e->a_latency_ms_bits, f64_to_bits(ms),
                              memory_order_relaxed);
        store_i32(&e->a_latency_state, LE_LATENCY_DONE);
        e->lat_active = 0;
      } else if (e->lat_frames_since_emit >= attempt_frames) {
        if (e->lat_attempts_remaining > 1) {
          e->lat_attempts_remaining--;
          e->lat_emit_remaining = sr / LE_LATENCY_PULSE_DIV;
          e->lat_frames_since_emit = 0;
        } else {
          store_i32(&e->a_latency_state, LE_LATENCY_TIMEOUT);
          e->lat_active = 0;
        }
      }
      for (int c = 0; c < ch; ++c) {
        out[f * ch + c] = broadcast;
        out_sumsq += broadcast * broadcast;
      }
      continue;
    }

    /* Looper. The live buffer index can change (undo swap); reload per frame. */
    const int32_t state = load_i32(&e->a_track_state);
    const int live = load_i32(&e->a_live_index);
    float* loop = e->track_buf[live];
    const int32_t pos = e->clock.position;
    const int monitor_on =
        load_i32(&e->a_monitor) && state != LE_TRACK_OVERDUBBING;

    for (int c = 0; c < ch; ++c) {
      const float insample =
          e->mono_input ? mono : (in ? in[f * ch + c] : 0.0f);
      float loopsample = 0.0f;

      if (state == LE_TRACK_RECORDING) {
        if (e->record_pos < e->max_loop_frames) {
          loop[e->record_pos * ch + c] = insample;
        }
      } else if (state == LE_TRACK_OVERDUBBING) {
        loop[pos * ch + c] += insample;
        loopsample = loop[pos * ch + c];
      } else if (state == LE_TRACK_PLAYING) {
        loopsample = loop[pos * ch + c];
      }

      float loopout = 0.0f;
      if ((state == LE_TRACK_PLAYING || state == LE_TRACK_OVERDUBBING) &&
          !muted) {
        loopout = loopsample * vol;
      }
      const float monitor = monitor_on ? insample : 0.0f;
      const float sample = monitor + loopout;
      out[f * ch + c] = sample;
      out_sumsq += sample * sample;

      const float la = fabsf(loopsample);
      if (la > trk_peak) trk_peak = la;
      trk_sumsq += loopsample * loopsample;
    }

    /* Advance the transport / record head. */
    if (state == LE_TRACK_RECORDING) {
      e->record_pos++;
      if (e->record_pos >= e->max_loop_frames) finalize_loop(e);
    } else if (e->clock.length > 0 &&
               (state == LE_TRACK_PLAYING || state == LE_TRACK_OVERDUBBING)) {
      if (le_loop_clock_tick(&e->clock) && e->pending_undo) {
        const int swapped = live ^ 1;
        store_i32(&e->a_live_index, swapped);
        store_i32(&e->a_track_undo_depth, 0);
        e->pending_undo = 0;
      }
    }
  }

  const uint32_t total = frames * (uint32_t)ch;
  store_f32(&e->a_in_rms_bits, total ? sqrtf(in_sumsq / (float)total) : 0.0f);
  store_f32(&e->a_in_peak_bits, in_peak);
  store_f32(&e->a_out_rms_bits, total ? sqrtf(out_sumsq / (float)total) : 0.0f);
  store_f32(&e->a_track_rms_bits,
            total ? sqrtf(trk_sumsq / (float)total) : 0.0f);
  store_f32(&e->a_track_peak_bits, trk_peak);
  store_i32(&e->a_master_pos, e->clock.position);
  if (load_i32(&e->a_track_state) == LE_TRACK_RECORDING) {
    store_i32(&e->a_track_len, e->record_pos);
  }
  atomic_fetch_add_explicit(&e->a_frames, (uint64_t)frames,
                            memory_order_relaxed);
}

static void data_callback(ma_device* device, void* output, const void* input,
                          ma_uint32 frame_count) {
  le_engine_process((le_engine*)device->pUserData, (float*)output,
                    (const float*)input, frame_count);
}

/* ---- configuration / lifecycle ---- */

int32_t le_engine_configure(le_engine* engine, int32_t sample_rate,
                            int32_t channels, int32_t max_loop_frames) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (channels <= 0) channels = 2;
  if (channels > LE_MAX_CHANNELS) channels = LE_MAX_CHANNELS;
  if (sample_rate <= 0) sample_rate = 48000;
  if (max_loop_frames <= 0) max_loop_frames = sample_rate * 120; /* 2 min */

  /* (Re)allocate the track buffers (live + undo). */
  const size_t samples = (size_t)max_loop_frames * (size_t)channels;
  for (int i = 0; i < 2; ++i) {
    free(engine->track_buf[i]);
    engine->track_buf[i] = (float*)calloc(samples, sizeof(float));
    if (engine->track_buf[i] == NULL) return LE_ERR_INVALID;
  }

  engine->sample_rate = sample_rate;
  engine->channels = channels;
  engine->max_loop_frames = max_loop_frames;
  le_loop_clock_reset(&engine->clock);
  engine->record_pos = 0;
  engine->pending_undo = 0;

  store_i32(&engine->a_sample_rate, sample_rate);
  store_i32(&engine->a_channels, channels);
  store_i32(&engine->a_master_len, 0);
  store_i32(&engine->a_master_pos, 0);
  store_i32(&engine->a_track_state, LE_TRACK_EMPTY);
  store_i32(&engine->a_track_len, 0);
  store_i32(&engine->a_track_undo_depth, 0);
  store_i32(&engine->a_track_muted, 0);
  store_i32(&engine->a_live_index, 0);
  store_f32(&engine->a_track_vol_bits, 1.0f);
  atomic_store_explicit(&engine->a_configured, 1, memory_order_release);
  return LE_OK;
}

const char* le_version(void) {
  return "loopy_engine 0.2.0 (miniaudio " MA_VERSION_STRING ")";
}

/* ---- loopback detection ---- */

static int contains_ci(const char* haystack, const char* needle) {
  if (haystack == NULL || needle == NULL) return 0;
  const size_t nlen = strlen(needle);
  if (nlen == 0) return 1;
  for (const char* h = haystack; *h != '\0'; ++h) {
    size_t i = 0;
    while (i < nlen && h[i] != '\0' &&
           tolower((unsigned char)h[i]) == tolower((unsigned char)needle[i])) {
      ++i;
    }
    if (i == nlen) return 1;
  }
  return 0;
}

le_loopback_kind le_classify_capture_device(const char* name) {
  if (name == NULL) return LE_LOOPBACK_NONE;
  if (contains_ci(name, "monitor of")) return LE_LOOPBACK_MONITOR;
  static const char* const virtual_names[] = {
      "blackhole", "soundflower", "loopback audio", "loopback",
      "vb-audio",  "vb-cable",    "cable output",   "voicemeeter",
  };
  for (size_t i = 0; i < sizeof(virtual_names) / sizeof(virtual_names[0]); ++i) {
    if (contains_ci(name, virtual_names[i])) return LE_LOOPBACK_VIRTUAL;
  }
  return LE_LOOPBACK_NONE;
}

/* Enumerates capture devices on `ctx`, returning the first loopback candidate.
 * Fills *out (always); when found and out_id != NULL, copies the device id. */
static void find_loopback(ma_context* ctx, le_loopback_info* out,
                          ma_device_id* out_id) {
  out->available = 0;
  out->kind = LE_LOOPBACK_NONE;
  out->device_name[0] = '\0';

  ma_device_info* playback = NULL;
  ma_uint32 playback_count = 0;
  ma_device_info* capture = NULL;
  ma_uint32 capture_count = 0;
  if (ma_context_get_devices(ctx, &playback, &playback_count, &capture,
                             &capture_count) != MA_SUCCESS) {
    return;
  }

  for (ma_uint32 i = 0; i < capture_count; ++i) {
    const le_loopback_kind kind = le_classify_capture_device(capture[i].name);
    if (kind != LE_LOOPBACK_NONE) {
      out->available = 1;
      out->kind = kind;
      strncpy(out->device_name, capture[i].name, sizeof(out->device_name) - 1);
      out->device_name[sizeof(out->device_name) - 1] = '\0';
      if (out_id != NULL) *out_id = capture[i].id;
      return;
    }
  }

  /* No named capture loopback; fall back to WASAPI's built-in output loopback
   * (Windows). Reported, but not auto-routed through the duplex path. */
  if (ma_context_is_loopback_supported(ctx)) {
    out->available = 1;
    out->kind = LE_LOOPBACK_WASAPI;
  }
}

int32_t le_detect_loopback(le_loopback_info* out) {
  if (out == NULL) return LE_ERR_INVALID;
  ma_context ctx;
  if (ma_context_init(NULL, 0, NULL, &ctx) != MA_SUCCESS) {
    out->available = 0;
    out->kind = LE_LOOPBACK_NONE;
    out->device_name[0] = '\0';
    return LE_ERR_INVALID;
  }
  find_loopback(&ctx, out, NULL);
  ma_context_uninit(&ctx);
  return LE_OK;
}

static void le_uninit_context(le_engine* engine) {
  if (engine->context_initialised) {
    ma_context_uninit(&engine->context);
    engine->context_initialised = 0;
  }
}

le_engine* le_engine_create(void) {
  le_engine* engine = (le_engine*)calloc(1, sizeof(le_engine));
  if (engine == NULL) return NULL;
  le_ring_init(&engine->ring, engine->ring_storage, LE_RING_CAPACITY);
  store_f32(&engine->a_track_vol_bits, 1.0f);
  store_i32(&engine->a_latency_state, LE_LATENCY_IDLE);
  return engine;
}

void le_engine_destroy(le_engine* engine) {
  if (engine == NULL) return;
  if (engine->device_initialised) {
    ma_device_uninit(&engine->device);
    engine->device_initialised = 0;
  }
  le_uninit_context(engine);
  free(engine->track_buf[0]);
  free(engine->track_buf[1]);
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
  engine->mono_input = config->merge_to_mono ? 1 : 0;
  store_i32(&engine->a_monitor, engine->passthrough);

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

  /* When requested, capture from a detected loopback device so latency can be
   * measured without a physical cable. Requires an explicit context (for both
   * enumeration and the matching device id). Playback stays on the default. */
  ma_context* pContext = NULL;
  if (config->use_loopback_capture) {
    if (ma_context_init(NULL, 0, NULL, &engine->context) == MA_SUCCESS) {
      engine->context_initialised = 1;
      pContext = &engine->context;
      le_loopback_info info;
      find_loopback(&engine->context, &info, &engine->capture_id);
      if (info.available && info.device_name[0] != '\0') {
        cfg.capture.pDeviceID = &engine->capture_id;
      }
    }
  }

  if (ma_device_init(pContext, &cfg, &engine->device) != MA_SUCCESS) {
    if (engine->context_initialised) {
      ma_context_uninit(&engine->context);
      engine->context_initialised = 0;
    }
    return LE_ERR_DEVICE;
  }
  engine->device_initialised = 1;

  const int32_t sr = (int32_t)engine->device.sampleRate;
  if (le_engine_configure(engine, sr, channels, config->max_loop_frames) !=
      LE_OK) {
    ma_device_uninit(&engine->device);
    engine->device_initialised = 0;
    le_uninit_context(engine);
    return LE_ERR_INVALID;
  }
  store_i32(&engine->a_buffer_frames,
            (int32_t)engine->device.playback.internalPeriodSizeInFrames);
  store_i32(&engine->a_latency_state, LE_LATENCY_IDLE);
  engine->lat_active = 0;
  engine->lat_emit_remaining = 0;
  engine->lat_attempts_remaining = 0;

  strncpy(engine->device_name, engine->device.playback.name,
          sizeof(engine->device_name) - 1);
  engine->device_name[sizeof(engine->device_name) - 1] = '\0';

  if (ma_device_start(&engine->device) != MA_SUCCESS) {
    ma_device_uninit(&engine->device);
    engine->device_initialised = 0;
    le_uninit_context(engine);
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
  le_uninit_context(engine);
  engine->device_name[0] = '\0';
  atomic_store_explicit(&engine->a_running, 0, memory_order_release);
  return LE_OK;
}

void le_engine_get_snapshot(le_engine* engine, le_snapshot* out) {
  if (engine == NULL || out == NULL) return;
  out->running = atomic_load_explicit(&engine->a_running, memory_order_acquire);
  out->sample_rate = load_i32(&engine->a_sample_rate);
  out->buffer_frames = load_i32(&engine->a_buffer_frames);
  out->channels = load_i32(&engine->a_channels);
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
  out->track_state = load_i32(&engine->a_track_state);
  out->track_volume = load_f32(&engine->a_track_vol_bits);
  out->track_muted = load_i32(&engine->a_track_muted);
  out->track_length_frames = load_i32(&engine->a_track_len);
  out->track_undo_depth = load_i32(&engine->a_track_undo_depth);
  out->track_rms = load_f32(&engine->a_track_rms_bits);
  out->track_peak = load_f32(&engine->a_track_peak_bits);
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
  const le_command cmd = {code, arg_i, arg_f};
  return le_ring_push(&engine->ring, cmd) ? LE_OK : LE_ERR_INVALID;
}

int32_t le_engine_measure_latency(le_engine* engine) {
  return le_engine_post_command(engine, LE_CMD_MEASURE_LATENCY, 0, 0.0f);
}

/* ---- looper control (push gated on `configured`, so tests work device-free) */

static int32_t le_push(le_engine* engine, int32_t code, int32_t arg_i,
                       float arg_f) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  const le_command cmd = {code, arg_i, arg_f};
  return le_ring_push(&engine->ring, cmd) ? LE_OK : LE_ERR_INVALID;
}

int32_t le_engine_record(le_engine* engine) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  /* Starting an overdub? Snapshot the pre-overdub loop on this (control) thread
   * while the audio thread treats the live buffer as read-only. */
  const int32_t st = load_i32(&engine->a_track_state);
  const int32_t len = load_i32(&engine->a_master_len);
  if ((st == LE_TRACK_PLAYING || st == LE_TRACK_STOPPED) && len > 0) {
    const int live = load_i32(&engine->a_live_index);
    const size_t n = (size_t)len * (size_t)engine->channels;
    memcpy(engine->track_buf[live ^ 1], engine->track_buf[live],
           n * sizeof(float));
    store_i32(&engine->a_track_undo_depth, 1);
  }
  return le_push(engine, LE_CMD_RECORD, 0, 0.0f);
}

int32_t le_engine_stop_track(le_engine* engine) {
  return le_push(engine, LE_CMD_STOP, 0, 0.0f);
}
int32_t le_engine_play(le_engine* engine) {
  return le_push(engine, LE_CMD_PLAY, 0, 0.0f);
}
int32_t le_engine_clear(le_engine* engine) {
  return le_push(engine, LE_CMD_CLEAR, 0, 0.0f);
}
int32_t le_engine_undo(le_engine* engine) {
  return le_push(engine, LE_CMD_UNDO, 0, 0.0f);
}
int32_t le_engine_set_track_volume(le_engine* engine, float volume) {
  return le_push(engine, LE_CMD_SET_VOLUME, 0, volume);
}
int32_t le_engine_set_track_mute(le_engine* engine, int32_t muted) {
  return le_push(engine, LE_CMD_SET_MUTE, 0, muted ? 1.0f : 0.0f);
}
