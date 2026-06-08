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

/* Metronome / tempo. */
#define LE_BEATS_PER_BAR 4
#define LE_CLICK_AMP 0.25f
#define LE_CLICK_MS 30
#define LE_CLICK_FREQ_BEAT 1000.0f
#define LE_CLICK_FREQ_DOWNBEAT 1500.0f
#define LE_TEMPO_MIN 30.0f
#define LE_TEMPO_MAX 300.0f
#define LE_TWO_PI 6.28318530717958647692f

/* Per-track buffer pool size: one live buffer plus up to LE_UNDO_SLOTS-1 undo/
 * redo snapshots. Buffers are allocated lazily, so memory grows only as deep as
 * the user actually overdubs. */
#define LE_UNDO_SLOTS 8

/* One looper track.
 *
 * The audio thread only reads pool[a_live] (and writes into it while recording/
 * overdubbing). All undo/redo bookkeeping — the pool, the stacks, and a_live
 * (whose sole writer is the control thread) — lives on the control thread, so
 * undo/redo never races the audio callback. */
typedef struct le_track {
  float* pool[LE_UNDO_SLOTS]; /* lazily allocated loop buffers */
  _Atomic int32_t a_live;     /* pool index the audio thread plays/records */

  /* Control-thread-owned undo/redo stacks of pool indices. */
  int32_t undo_stack[LE_UNDO_SLOTS];
  int undo_count;
  int32_t redo_stack[LE_UNDO_SLOTS];
  int redo_count;

  _Atomic int32_t a_state;
  _Atomic uint32_t a_vol_bits;
  _Atomic int32_t a_muted;
  _Atomic int32_t a_len;
  _Atomic int32_t a_undo_depth; /* published undo_count */
  _Atomic int32_t a_redo_depth; /* published redo_count */
  _Atomic uint32_t a_rms_bits;
  _Atomic uint32_t a_peak_bits;
  int32_t record_pos; /* audio-thread-local: defining-track record head */
} le_track;

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
  _Atomic int32_t a_monitor; /* input monitoring on/off (latency disables it) */

  /* Looper transport (master). */
  _Atomic int32_t a_master_len;
  _Atomic int32_t a_master_pos;

  /* Tempo / metronome (published). */
  _Atomic uint32_t a_tempo_bpm_bits;
  _Atomic int32_t a_metronome_on;
  _Atomic int32_t a_count_in_enabled;
  _Atomic int32_t a_counting_in;
  _Atomic int32_t a_current_beat;
  _Atomic int32_t a_record_offset; /* latency compensation in frames */

  /* Tracks. */
  le_track tracks[LE_MAX_TRACKS];
  int32_t track_count;

  /* Command ring + pre-allocated backing storage. */
  le_ring ring;
  le_command ring_storage[LE_RING_CAPACITY];

  /* Configuration. */
  int sample_rate;
  int channels;
  int32_t max_loop_frames;

  /* Audio-thread-local transport. */
  le_loop_clock clock;

  /* Audio-thread-local tempo / metronome state. */
  uint64_t frame_clock;     /* running frame counter (tap timing) */
  uint64_t last_tap_frame;
  int has_tap;
  int32_t metro_frame;      /* frames since the last beat */
  int32_t metro_beat;       /* 0..LE_BEATS_PER_BAR-1 */
  int32_t click_remaining;  /* frames left in the current click */
  int32_t click_len;
  float click_phase;
  float click_freq;
  int32_t count_in_remaining; /* frames left in a count-in */
  int32_t count_in_channel;

  /* Latency harness (audio-thread-local + published state). */
  int lat_active;
  int32_t lat_emit_remaining;
  uint64_t lat_frames_since_emit;
  int32_t lat_attempts_remaining;

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

/* Wraps `pos - offset` into [0, len). Used to write captured input at the
 * latency-compensated loop position so overdubs align with what was heard. */
static int32_t comp_pos(int32_t pos, int32_t offset, int32_t len) {
  if (len <= 0) return pos;
  int32_t p = (pos - offset) % len;
  if (p < 0) p += len;
  return p;
}

/* ---- tempo helpers (audio thread) ---- */

static float load_bpm(le_engine* e) {
  const float bpm = load_f32(&e->a_tempo_bpm_bits);
  return bpm > 0.0f ? bpm : 120.0f;
}

static int32_t frames_per_beat(le_engine* e) {
  const int sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  const int32_t fpb = (int32_t)((float)sr * 60.0f / load_bpm(e));
  return fpb > 0 ? fpb : 1;
}

static void trigger_click(le_engine* e, int downbeat) {
  const int sr = e->sample_rate > 0 ? e->sample_rate : 48000;
  e->click_len = sr * LE_CLICK_MS / 1000;
  if (e->click_len < 1) e->click_len = 1;
  e->click_remaining = e->click_len;
  e->click_phase = 0.0f;
  e->click_freq = downbeat ? LE_CLICK_FREQ_DOWNBEAT : LE_CLICK_FREQ_BEAT;
}

static void handle_tap(le_engine* e) {
  const uint64_t now = e->frame_clock;
  if (e->has_tap) {
    const uint64_t interval = now - e->last_tap_frame;
    const int sr = e->sample_rate > 0 ? e->sample_rate : 48000;
    if (interval > 0) {
      const double bpm = 60.0 * (double)sr / (double)interval;
      if (bpm >= (double)LE_TEMPO_MIN && bpm <= (double)LE_TEMPO_MAX) {
        store_f32(&e->a_tempo_bpm_bits, (float)bpm);
      }
    }
  }
  e->last_tap_frame = now;
  e->has_tap = 1;
}

/* ---- command handlers (audio thread) ---- */

static void finalize_master(le_engine* e, le_track* t) {
  const int32_t len = t->record_pos > 0 ? t->record_pos : 1;
  le_loop_clock_set_length(&e->clock, len);
  store_i32(&e->a_master_len, len);
  store_i32(&t->a_len, len);
  store_i32(&t->a_state, LE_TRACK_PLAYING);
}

static int valid_channel(le_engine* e, int32_t ch) {
  return ch >= 0 && ch < e->track_count;
}

/* There is a single input stream, so only one track may capture at a time.
 * Closes any track (other than `except_ch`) that is currently RECORDING or
 * OVERDUBBING, finalizing the master loop if the closed track was the defining
 * recording. Called before starting a new capture. */
static void close_active_capture(le_engine* e, int32_t except_ch) {
  for (int32_t t = 0; t < e->track_count; ++t) {
    if (t == except_ch) continue;
    le_track* tr = &e->tracks[t];
    const int32_t st = load_i32(&tr->a_state);
    if (st == LE_TRACK_RECORDING) {
      if (e->clock.length == 0) {
        finalize_master(e, tr); /* defines the master loop, -> PLAYING */
      } else {
        store_i32(&tr->a_len, e->clock.length);
        store_i32(&tr->a_state, LE_TRACK_PLAYING);
      }
    } else if (st == LE_TRACK_OVERDUBBING) {
      store_i32(&tr->a_state, LE_TRACK_PLAYING);
    }
  }
}

static void handle_record(le_engine* e, int32_t ch) {
  if (!valid_channel(e, ch)) return;
  /* Ignore record presses while a count-in is committing to a track. */
  if (e->count_in_remaining > 0) return;
  /* Enforce one-capturer-at-a-time: pressing record on a new track finalizes
   * whatever is currently capturing (chained hand-off). */
  close_active_capture(e, ch);
  le_track* t = &e->tracks[ch];
  switch (load_i32(&t->a_state)) {
    case LE_TRACK_EMPTY:
      /* First record overall (no master yet) defines the master loop; otherwise
       * the new track records by overwriting one master loop. Both are
       * RECORDING, distinguished by clock.length. */
      if (e->clock.length == 0) {
        if (load_i32(&e->a_count_in_enabled) && e->count_in_remaining == 0) {
          /* Defining recording with count-in: click one bar, then RECORDING. */
          e->count_in_remaining = frames_per_beat(e) * LE_BEATS_PER_BAR;
          e->count_in_channel = ch;
          e->metro_frame = 0;
          e->metro_beat = 0;
          store_i32(&e->a_counting_in, 1);
        } else {
          t->record_pos = 0;
          le_loop_clock_reset(&e->clock);
          store_i32(&t->a_state, LE_TRACK_RECORDING);
        }
      } else {
        store_i32(&t->a_state, LE_TRACK_RECORDING);
      }
      break;
    case LE_TRACK_RECORDING:
      if (e->clock.length == 0) finalize_master(e, t);
      break;
    case LE_TRACK_PLAYING:
    case LE_TRACK_STOPPED:
      /* Undo snapshot already taken on the calling thread by le_engine_record. */
      store_i32(&t->a_state, LE_TRACK_OVERDUBBING);
      break;
    case LE_TRACK_OVERDUBBING:
      store_i32(&t->a_state, LE_TRACK_PLAYING);
      break;
    default:
      break;
  }
}

static void handle_stop(le_engine* e, int32_t ch) {
  if (!valid_channel(e, ch)) return;
  le_track* t = &e->tracks[ch];
  const int32_t st = load_i32(&t->a_state);
  if (st == LE_TRACK_RECORDING) {
    if (e->clock.length == 0) {
      finalize_master(e, t);
    } else {
      store_i32(&t->a_len, e->clock.length);
    }
    store_i32(&t->a_state, LE_TRACK_STOPPED);
  } else if (st == LE_TRACK_PLAYING || st == LE_TRACK_OVERDUBBING) {
    store_i32(&t->a_state, LE_TRACK_STOPPED);
  }
}

static void handle_play(le_engine* e, int32_t ch) {
  if (!valid_channel(e, ch)) return;
  le_track* t = &e->tracks[ch];
  if (load_i32(&t->a_state) == LE_TRACK_STOPPED) {
    store_i32(&t->a_state, LE_TRACK_PLAYING);
  }
}

static void handle_clear(le_engine* e, int32_t ch) {
  if (!valid_channel(e, ch)) return;
  le_track* t = &e->tracks[ch];
  t->record_pos = 0;
  store_i32(&t->a_state, LE_TRACK_EMPTY);
  store_i32(&t->a_len, 0);
  /* Undo/redo stacks and a_live are reset by le_engine_clear on the control
   * thread; the audio thread only resets the state/transport here. */

  /* If every track is now empty, reset the master so a new loop can be defined.
   * Buffers are not zeroed here (RT-unsafe); a re-record overwrites a full loop
   * before the track is heard, so stale data never plays. */
  for (int32_t k = 0; k < e->track_count; ++k) {
    if (load_i32(&e->tracks[k].a_state) != LE_TRACK_EMPTY) return;
  }
  le_loop_clock_reset(&e->clock);
  store_i32(&e->a_master_len, 0);
  store_i32(&e->a_master_pos, 0);
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
      handle_record(e, cmd->arg_i);
      break;
    case LE_CMD_STOP:
      handle_stop(e, cmd->arg_i);
      break;
    case LE_CMD_PLAY:
      handle_play(e, cmd->arg_i);
      break;
    case LE_CMD_CLEAR:
      handle_clear(e, cmd->arg_i);
      break;
    /* Undo/redo are handled on the control thread (le_engine_undo/redo), not
     * via the command ring. */
    case LE_CMD_SET_VOLUME: {
      if (!valid_channel(e, cmd->arg_i)) break;
      float v = cmd->arg_f;
      if (v < 0.0f) v = 0.0f;
      if (v > 1.0f) v = 1.0f;
      store_f32(&e->tracks[cmd->arg_i].a_vol_bits, v);
      break;
    }
    case LE_CMD_SET_MUTE:
      if (valid_channel(e, cmd->arg_i)) {
        store_i32(&e->tracks[cmd->arg_i].a_muted, cmd->arg_f != 0.0f ? 1 : 0);
      }
      break;
    case LE_CMD_SET_TEMPO: {
      float bpm = cmd->arg_f;
      if (bpm < LE_TEMPO_MIN) bpm = LE_TEMPO_MIN;
      if (bpm > LE_TEMPO_MAX) bpm = LE_TEMPO_MAX;
      store_f32(&e->a_tempo_bpm_bits, bpm);
      break;
    }
    case LE_CMD_SET_METRONOME:
      store_i32(&e->a_metronome_on, cmd->arg_f != 0.0f ? 1 : 0);
      break;
    case LE_CMD_SET_COUNT_IN:
      store_i32(&e->a_count_in_enabled, cmd->arg_f != 0.0f ? 1 : 0);
      break;
    case LE_CMD_TAP_TEMPO:
      handle_tap(e);
      break;
    case LE_CMD_SET_RECORD_OFFSET:
      store_i32(&e->a_record_offset, cmd->arg_i > 0 ? cmd->arg_i : 0);
      break;
    default:
      break;
  }
}

/* ---- the real-time DSP core ---- */

void le_engine_process(le_engine* e, float* output, const float* input,
                       uint32_t frames) {
  const int ch = e->channels;
  const int tc = e->track_count;
  float* out = output;
  const float* in = input;

  le_command cmd;
  while (le_ring_pop(&e->ring, &cmd)) apply_command(e, &cmd);

  const int sr = e->sample_rate > 0 ? e->sample_rate : 48000;

  float in_sumsq = 0.0f;
  float in_peak = 0.0f;
  float out_sumsq = 0.0f;
  float trk_sumsq[LE_MAX_TRACKS] = {0};
  float trk_peak[LE_MAX_TRACKS] = {0};

  for (uint32_t f = 0; f < frames; ++f) {
    e->frame_clock++;
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
        /* The measured round-trip is exactly the record offset that aligns
         * overdubs; apply it automatically (the UI can override). */
        store_i32(&e->a_record_offset, (int32_t)e->lat_frames_since_emit);
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

    /* Snapshot per-track playback state once per frame (the live index can flip
     * only at a loop boundary, i.e. at the end of a frame). */
    int32_t st[LE_MAX_TRACKS];
    float* buf[LE_MAX_TRACKS];
    float vol[LE_MAX_TRACKS];
    int mut[LE_MAX_TRACKS];
    for (int t = 0; t < tc; ++t) {
      st[t] = load_i32(&e->tracks[t].a_state);
      buf[t] = e->tracks[t].pool[load_i32(&e->tracks[t].a_live)];
      vol[t] = load_f32(&e->tracks[t].a_vol_bits);
      mut[t] = load_i32(&e->tracks[t].a_muted);
    }
    /* Latency compensation: captured input is recorded this many frames earlier
     * so it aligns with what the player heard. Monitoring stays live (it is no
     * longer folded into the loop buffer at the playhead). */
    const int32_t offset = load_i32(&e->a_record_offset);
    const int monitor_on = load_i32(&e->a_monitor);
    const int32_t pos = e->clock.position;

    /* Metronome + count-in. Beat phase free-runs; a click is emitted at each
     * beat start when the metronome is on or a count-in is in progress. */
    const int counting = e->count_in_remaining > 0;
    if (e->metro_frame == 0) {
      store_i32(&e->a_current_beat, e->metro_beat);
      if (load_i32(&e->a_metronome_on) || counting) {
        trigger_click(e, e->metro_beat == 0);
      }
    }
    if (++e->metro_frame >= frames_per_beat(e)) {
      e->metro_frame = 0;
      e->metro_beat = (e->metro_beat + 1) % LE_BEATS_PER_BAR;
    }
    float click = 0.0f;
    if (e->click_remaining > 0) {
      const float env = (float)e->click_remaining / (float)e->click_len;
      click = LE_CLICK_AMP * env * sinf(e->click_phase);
      e->click_phase += LE_TWO_PI * e->click_freq / (float)sr;
      if (e->click_phase > LE_TWO_PI) e->click_phase -= LE_TWO_PI;
      e->click_remaining--;
    }
    if (counting) {
      if (--e->count_in_remaining <= 0) {
        e->count_in_remaining = 0;
        store_i32(&e->a_counting_in, 0);
        le_track* ct = &e->tracks[e->count_in_channel];
        ct->record_pos = 0;
        le_loop_clock_reset(&e->clock);
        store_i32(&ct->a_state, LE_TRACK_RECORDING);
        e->metro_frame = 0;
        e->metro_beat = 0;
      }
    }

    for (int c = 0; c < ch; ++c) {
      const float insample =
          e->mono_input ? mono : (in ? in[f * ch + c] : 0.0f);
      float mix = 0.0f;
      for (int t = 0; t < tc; ++t) {
        float loopsample = 0.0f;
        if (st[t] == LE_TRACK_RECORDING) {
          if (e->clock.length == 0) {
            /* defining track: no reference loop yet, so no compensation */
            if (e->tracks[t].record_pos < e->max_loop_frames) {
              buf[t][e->tracks[t].record_pos * ch + c] = insample;
            }
          } else {
            /* new track: overwrite one master loop, latency-compensated */
            const int32_t w = comp_pos(pos, offset, e->clock.length);
            buf[t][w * ch + c] = insample;
          }
        } else if (st[t] == LE_TRACK_OVERDUBBING) {
          /* Mix the existing loop (read before write); record the live input at
           * the compensated position for the next pass. */
          loopsample = buf[t][pos * ch + c];
          const int32_t w = comp_pos(pos, offset, e->clock.length);
          buf[t][w * ch + c] += insample;
        } else if (st[t] == LE_TRACK_PLAYING) {
          loopsample = buf[t][pos * ch + c];
        }

        if ((st[t] == LE_TRACK_PLAYING || st[t] == LE_TRACK_OVERDUBBING) &&
            !mut[t]) {
          mix += loopsample * vol[t];
        }
        const float la = fabsf(loopsample);
        if (la > trk_peak[t]) trk_peak[t] = la;
        trk_sumsq[t] += loopsample * loopsample;
      }

      const float monitor = monitor_on ? insample : 0.0f;
      const float sample = monitor + mix + click;
      out[f * ch + c] = sample;
      out_sumsq += sample * sample;
    }

    /* Advance the transport / record heads. */
    int defining = -1;
    for (int t = 0; t < tc; ++t) {
      if (st[t] == LE_TRACK_RECORDING && e->clock.length == 0) defining = t;
    }
    if (defining >= 0) {
      le_track* t = &e->tracks[defining];
      t->record_pos++;
      if (t->record_pos >= e->max_loop_frames) finalize_master(e, t);
    } else if (e->clock.length > 0) {
      if (le_loop_clock_tick(&e->clock)) {
        for (int t = 0; t < tc; ++t) {
          le_track* tr = &e->tracks[t];
          if (load_i32(&tr->a_state) == LE_TRACK_RECORDING) {
            /* new track finished overwriting one loop -> play it */
            store_i32(&tr->a_len, e->clock.length);
            store_i32(&tr->a_state, LE_TRACK_PLAYING);
          }
        }
      }
    }
  }

  const uint32_t total = frames * (uint32_t)ch;
  store_f32(&e->a_in_rms_bits, total ? sqrtf(in_sumsq / (float)total) : 0.0f);
  store_f32(&e->a_in_peak_bits, in_peak);
  store_f32(&e->a_out_rms_bits, total ? sqrtf(out_sumsq / (float)total) : 0.0f);
  for (int t = 0; t < tc; ++t) {
    store_f32(&e->tracks[t].a_rms_bits,
              total ? sqrtf(trk_sumsq[t] / (float)total) : 0.0f);
    store_f32(&e->tracks[t].a_peak_bits, trk_peak[t]);
    if (load_i32(&e->tracks[t].a_state) == LE_TRACK_RECORDING &&
        e->clock.length == 0) {
      store_i32(&e->tracks[t].a_len, e->tracks[t].record_pos);
    }
  }
  store_i32(&e->a_master_pos, e->clock.position);
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
  /* Default cap of 30 s/track keeps total memory modest across all tracks
   * (live + undo). Longer loops are configurable; stream-to-disk is deferred. */
  if (max_loop_frames <= 0) max_loop_frames = sample_rate * 30;

  const size_t samples = (size_t)max_loop_frames * (size_t)channels;
  engine->track_count = LE_MAX_TRACKS;
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    le_track* tr = &engine->tracks[t];
    /* Free any buffers from a previous configuration; allocate only the base
     * (live) buffer now — undo snapshots are allocated lazily on demand. */
    for (int i = 0; i < LE_UNDO_SLOTS; ++i) {
      free(tr->pool[i]);
      tr->pool[i] = NULL;
    }
    tr->pool[0] = (float*)calloc(samples, sizeof(float));
    if (tr->pool[0] == NULL) return LE_ERR_INVALID;
    tr->undo_count = 0;
    tr->redo_count = 0;
    store_i32(&tr->a_live, 0);
    store_i32(&tr->a_state, LE_TRACK_EMPTY);
    store_f32(&tr->a_vol_bits, 1.0f);
    store_i32(&tr->a_muted, 0);
    store_i32(&tr->a_len, 0);
    store_i32(&tr->a_undo_depth, 0);
    store_i32(&tr->a_redo_depth, 0);
    store_f32(&tr->a_rms_bits, 0.0f);
    store_f32(&tr->a_peak_bits, 0.0f);
    tr->record_pos = 0;
  }

  engine->sample_rate = sample_rate;
  engine->channels = channels;
  engine->max_loop_frames = max_loop_frames;
  le_loop_clock_reset(&engine->clock);

  /* Reset per-session tempo timing (tempo/metronome/count-in *settings*
   * persist across start/stop; only the running state is cleared). */
  engine->frame_clock = 0;
  engine->last_tap_frame = 0;
  engine->has_tap = 0;
  engine->metro_frame = 0;
  engine->metro_beat = 0;
  engine->click_remaining = 0;
  engine->count_in_remaining = 0;
  store_i32(&engine->a_counting_in, 0);
  store_i32(&engine->a_current_beat, 0);
  store_i32(&engine->a_record_offset, 0); /* re-measured per session */

  store_i32(&engine->a_sample_rate, sample_rate);
  store_i32(&engine->a_channels, channels);
  store_i32(&engine->a_master_len, 0);
  store_i32(&engine->a_master_pos, 0);
  atomic_store_explicit(&engine->a_configured, 1, memory_order_release);
  return LE_OK;
}

const char* le_version(void) {
  return "loopy_engine 0.3.0 (miniaudio " MA_VERSION_STRING ")";
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
  store_i32(&engine->a_latency_state, LE_LATENCY_IDLE);
  store_f32(&engine->a_tempo_bpm_bits, 120.0f);
  return engine;
}

void le_engine_destroy(le_engine* engine) {
  if (engine == NULL) return;
  if (engine->device_initialised) {
    ma_device_uninit(&engine->device);
    engine->device_initialised = 0;
  }
  le_uninit_context(engine);
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    for (int i = 0; i < LE_UNDO_SLOTS; ++i) {
      free(engine->tracks[t].pool[i]);
    }
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
    le_uninit_context(engine);
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
  out->tempo_bpm = load_bpm(engine);
  out->metronome_on = load_i32(&engine->a_metronome_on);
  out->count_in_enabled = load_i32(&engine->a_count_in_enabled);
  out->counting_in = load_i32(&engine->a_counting_in);
  out->current_beat = load_i32(&engine->a_current_beat);
  out->record_offset_frames = load_i32(&engine->a_record_offset);
  out->track_count = engine->track_count;
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    le_track* tr = &engine->tracks[t];
    out->tracks[t].state =
        t < engine->track_count ? load_i32(&tr->a_state) : LE_TRACK_EMPTY;
    out->tracks[t].volume = load_f32(&tr->a_vol_bits);
    out->tracks[t].muted = load_i32(&tr->a_muted);
    out->tracks[t].length_frames = load_i32(&tr->a_len);
    out->tracks[t].undo_depth = load_i32(&tr->a_undo_depth);
    out->tracks[t].redo_depth = load_i32(&tr->a_redo_depth);
    out->tracks[t].rms = load_f32(&tr->a_rms_bits);
    out->tracks[t].peak = load_f32(&tr->a_peak_bits);
  }
}

void le_engine_get_track(le_engine* engine, int32_t channel,
                         le_track_snapshot* out) {
  if (engine == NULL || out == NULL) return;
  if (channel < 0 || channel >= engine->track_count) {
    out->state = LE_TRACK_EMPTY;
    out->volume = 1.0f;
    out->muted = 0;
    out->length_frames = 0;
    out->undo_depth = 0;
    out->redo_depth = 0;
    out->rms = 0.0f;
    out->peak = 0.0f;
    return;
  }
  le_track* tr = &engine->tracks[channel];
  out->state = load_i32(&tr->a_state);
  out->volume = load_f32(&tr->a_vol_bits);
  out->muted = load_i32(&tr->a_muted);
  out->length_frames = load_i32(&tr->a_len);
  out->undo_depth = load_i32(&tr->a_undo_depth);
  out->redo_depth = load_i32(&tr->a_redo_depth);
  out->rms = load_f32(&tr->a_rms_bits);
  out->peak = load_f32(&tr->a_peak_bits);
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

/* Returns a pool slot that is neither live nor referenced by either stack,
 * allocating its buffer lazily. If the pool is full, evicts the oldest undo
 * entry and reuses its slot. Returns -1 only on allocation failure. */
static int track_acquire_slot(le_engine* e, le_track* t) {
  const int live = load_i32(&t->a_live);
  for (int i = 0; i < LE_UNDO_SLOTS; ++i) {
    if (i == live) continue;
    int used = 0;
    for (int k = 0; k < t->undo_count && !used; ++k) {
      if (t->undo_stack[k] == i) used = 1;
    }
    for (int k = 0; k < t->redo_count && !used; ++k) {
      if (t->redo_stack[k] == i) used = 1;
    }
    if (used) continue;
    if (t->pool[i] == NULL) {
      const size_t samples = (size_t)e->max_loop_frames * (size_t)e->channels;
      t->pool[i] = (float*)calloc(samples, sizeof(float));
      if (t->pool[i] == NULL) return -1;
    }
    return i;
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

int32_t le_engine_record(le_engine* engine, int32_t channel) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  /* Starting an overdub? Snapshot the pre-overdub content on this (control)
   * thread and push it onto the undo stack; a new action clears redo history.
   * The audio thread treats the live buffer as read-only at this point. */
  le_track* t = &engine->tracks[channel];
  const int32_t st = load_i32(&t->a_state);
  const int32_t len = load_i32(&engine->a_master_len);
  if ((st == LE_TRACK_PLAYING || st == LE_TRACK_STOPPED) && len > 0) {
    t->redo_count = 0;
    const int slot = track_acquire_slot(engine, t);
    if (slot >= 0) {
      const int live = load_i32(&t->a_live);
      const size_t n = (size_t)len * (size_t)engine->channels;
      memcpy(t->pool[slot], t->pool[live], n * sizeof(float));
      t->undo_stack[t->undo_count++] = slot;
      store_i32(&t->a_undo_depth, t->undo_count);
    }
    store_i32(&t->a_redo_depth, 0);
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
  }
  return le_push(engine, LE_CMD_CLEAR, channel, 0.0f);
}

/* Undo/redo run entirely on the control thread: they swap the track's live pool
 * index (atomic; the audio thread's only window into the buffers). Allowed only
 * when the track is not capturing, so the audio thread sees a stable a_live. */
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
  t->redo_stack[t->redo_count++] = load_i32(&t->a_live);
  store_i32(&t->a_live, prev);
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
  t->undo_stack[t->undo_count++] = load_i32(&t->a_live);
  store_i32(&t->a_live, next);
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

int32_t le_engine_set_tempo(le_engine* engine, float bpm) {
  return le_push(engine, LE_CMD_SET_TEMPO, 0, bpm);
}
int32_t le_engine_set_metronome(le_engine* engine, int32_t on) {
  return le_push(engine, LE_CMD_SET_METRONOME, 0, on ? 1.0f : 0.0f);
}
int32_t le_engine_set_count_in(le_engine* engine, int32_t on) {
  return le_push(engine, LE_CMD_SET_COUNT_IN, 0, on ? 1.0f : 0.0f);
}
int32_t le_engine_tap_tempo(le_engine* engine) {
  return le_push(engine, LE_CMD_TAP_TEMPO, 0, 0.0f);
}
int32_t le_engine_set_record_offset(le_engine* engine, int32_t frames) {
  return le_push(engine, LE_CMD_SET_RECORD_OFFSET, frames, 0.0f);
}
