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
  _Atomic int32_t a_multiple; /* track length in whole base loops (>= 1) */
  _Atomic uint32_t a_input_mask;   /* bitmask of input channels to record from */
  _Atomic uint32_t a_output_mask;  /* bitmask of output channels to play to */
  int32_t record_pos; /* audio-thread-local record head. Defining track: linear
                       * frame count. New track over a master: the absolute
                       * phase (segment*base + position), seeded at press so
                       * writes stay phase-locked to the master loop. */
  uint64_t start_iter; /* loop_iteration when this track's recording began */
} le_track;

struct le_engine {
  ma_device device;
  int device_initialised;

  /* Snapshot, published as independent atomics. */
  _Atomic int32_t a_running;
  /* 1 while the device is present, 0 once a device-lost/rerouted/stopped
   * notification fires. Written only by the RT-adjacent notification callback
   * (store-only, no work) and the lifecycle calls; read into the snapshot.
   * The callback stores `relaxed` (it carries no other state and must not block
   * the audio thread); the lifecycle store and the snapshot load use
   * release/acquire to match the `a_running` publication they sit beside. The
   * flag is a single independent value, so plain visibility is all that's
   * required either way. */
  _Atomic int32_t a_device_present;
  _Atomic int32_t a_configured;
  _Atomic int32_t a_sample_rate;
  _Atomic int32_t a_buffer_frames;
  _Atomic int32_t a_in_channels;    /* negotiated hardware capture channels */
  _Atomic int32_t a_out_channels;   /* negotiated hardware playback channels */
  _Atomic uint64_t a_frames;
  _Atomic uint32_t a_xruns;
  _Atomic uint32_t a_in_rms_bits;
  _Atomic uint32_t a_in_peak_bits;
  _Atomic uint32_t a_out_rms_bits;
  /* Loop-indexed visualization (float bits): one peak per loop bucket, spanning
   * exactly one master loop and refreshed as the playhead sweeps. a_loop_viz is
   * the mixed output; a_track_viz is each track's own contribution. */
  _Atomic uint32_t a_loop_viz[LE_VIZ_POINTS];
  _Atomic uint32_t a_track_viz[LE_MAX_TRACKS][LE_VIZ_POINTS];
  _Atomic int32_t a_latency_state;
  _Atomic uint64_t a_latency_ms_bits;
  _Atomic int32_t a_monitor; /* input monitoring on/off (latency disables it) */

  /* Looper transport (master). */
  _Atomic int32_t a_master_len;
  _Atomic int32_t a_master_pos;

  _Atomic int32_t a_record_offset; /* latency compensation in frames */

  /* Tracks. */
  le_track tracks[LE_MAX_TRACKS];
  int32_t track_count;

  /* Command ring + pre-allocated backing storage. */
  le_ring ring;
  le_command ring_storage[LE_RING_CAPACITY];

  /* Configuration. */
  int sample_rate;
  int in_channels;  /* hardware capture channels */
  int out_channels; /* hardware playback channels */
  int32_t max_loop_frames;

  /* Audio-thread-local transport. */
  le_loop_clock clock;
  uint64_t loop_iteration; /* free-running count of base-loop wraps */

  /* Loop-viz bucketing (audio-thread-local): peaks accumulate within the
   * current loop bucket and publish when the playhead crosses into the next. */
  int32_t loop_viz_bucket;
  float loop_viz_accum;
  float track_viz_accum[LE_MAX_TRACKS];

  /* Latency harness (audio-thread-local + published state). */
  int lat_active;
  int32_t lat_emit_remaining;
  uint64_t lat_frames_since_emit;
  int32_t lat_attempts_remaining;

  char device_name[256];
  int passthrough; /* input monitoring */
  int mono_input;  /* average input channels and feed every output channel */

  /* Explicit context + resolved device ids, used when capturing from a detected
   * loopback device (use_loopback_capture) or when a device is pinned by id. */
  ma_context context;
  int context_initialised;
  ma_device_id capture_id;
  ma_device_id playback_id;
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

/* ---- command handlers (audio thread) ---- */

static void finalize_master(le_engine* e, le_track* t) {
  const int32_t len = t->record_pos > 0 ? t->record_pos : 1;
  le_loop_clock_set_length(&e->clock, len);
  e->loop_iteration = 0; /* the base loop just (re)started */
  store_i32(&e->a_master_len, len);
  store_i32(&t->a_len, len);
  store_i32(&t->a_multiple, 1); /* the defining track is one base loop */
  store_i32(&t->a_state, LE_TRACK_PLAYING);
  t->start_iter = 0;
}

/* Finalizes a non-defining track that recorded freely across one or more base
 * loops: rounds its length UP to the nearest whole base loop (the locked #4
 * behaviour), publishes the multiple, and moves it to `end_state`. A track that
 * captured nothing (never reached the loop top) returns to EMPTY. */
static void finalize_new_track(le_engine* e, le_track* t, int32_t end_state) {
  const int32_t base = e->clock.length > 0 ? e->clock.length : 1;
  if (t->record_pos <= 0) { /* nothing captured */
    store_i32(&t->a_state, LE_TRACK_EMPTY);
    store_i32(&t->a_len, 0);
    store_i32(&t->a_multiple, 1);
    t->record_pos = 0;
    return;
  }
  int32_t k = (t->record_pos + base - 1) / base; /* ceil to whole base loops */
  const int32_t maxk = e->max_loop_frames / base;
  if (k < 1) k = 1;
  if (maxk >= 1 && k > maxk) k = maxk;
  store_i32(&t->a_multiple, k);
  store_i32(&t->a_len, k * base);
  store_i32(&t->a_state, end_state);
  t->record_pos = 0;
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
        finalize_new_track(e, tr, LE_TRACK_PLAYING); /* round up to whole loops */
      }
    } else if (st == LE_TRACK_OVERDUBBING) {
      store_i32(&tr->a_state, LE_TRACK_PLAYING);
    }
  }
}

/* Acts on a record/overdub press: finalizes any other capture (one-capturer
 * hand-off), then advances this track's state machine. */
static void handle_record(le_engine* e, int32_t ch) {
  if (!valid_channel(e, ch)) return;
  close_active_capture(e, ch);
  le_track* t = &e->tracks[ch];
  switch (load_i32(&t->a_state)) {
    case LE_TRACK_EMPTY:
      /* First record overall (no master yet) defines the master loop; otherwise
       * the new track records freely from the loop top. Both are RECORDING,
       * distinguished by clock.length. */
      if (e->clock.length == 0) {
        t->record_pos = 0;
        le_loop_clock_reset(&e->clock);
        store_i32(&t->a_state, LE_TRACK_RECORDING);
      } else {
        /* New track over an existing master: begin capturing immediately at the
         * current loop phase — no waiting for the loop top. record_pos seeds to
         * the master position and start_iter to the current iteration, so it
         * stays equal to (loop_iteration - start_iter)*base + position; buffer
         * writes are therefore phase-locked to the master and the slice before
         * the press in this first segment stays silent (the live buffer was
         * zeroed on the control thread). Spans one or more base loops, rounded
         * up on stop. */
        t->record_pos = e->clock.position;
        t->start_iter = e->loop_iteration;
        store_i32(&t->a_state, LE_TRACK_RECORDING);
      }
      break;
    case LE_TRACK_RECORDING:
      if (e->clock.length == 0) {
        finalize_master(e, t);
      } else {
        finalize_new_track(e, t, LE_TRACK_PLAYING); /* toggle: stop + round up */
      }
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
      store_i32(&t->a_state, LE_TRACK_STOPPED);
    } else {
      finalize_new_track(e, t, LE_TRACK_STOPPED); /* round up to whole loops */
    }
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
  t->start_iter = 0;
  store_i32(&t->a_state, LE_TRACK_EMPTY);
  store_i32(&t->a_len, 0);
  store_i32(&t->a_multiple, 1);
  /* Undo/redo stacks and a_live are reset by le_engine_clear on the control
   * thread; the audio thread only resets the state/transport here. */

  /* If every track is now empty, reset the master so a new loop can be defined.
   * Buffers are not zeroed here (RT-unsafe); a re-record overwrites a full loop
   * before the track is heard, so stale data never plays. */
  for (int32_t k = 0; k < e->track_count; ++k) {
    if (load_i32(&e->tracks[k].a_state) != LE_TRACK_EMPTY) return;
  }
  le_loop_clock_reset(&e->clock);
  e->loop_iteration = 0;
  store_i32(&e->a_master_len, 0);
  store_i32(&e->a_master_pos, 0);
  /* Clear the loop waveform so a re-record starts from silence. */
  e->loop_viz_bucket = -1;
  for (int i = 0; i < LE_VIZ_POINTS; ++i) {
    store_f32(&e->a_loop_viz[i], 0.0f);
    for (int t = 0; t < e->track_count; ++t) {
      store_f32(&e->a_track_viz[t][i], 0.0f);
    }
  }
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
    case LE_CMD_SET_RECORD_OFFSET:
      store_i32(&e->a_record_offset, cmd->arg_i > 0 ? cmd->arg_i : 0);
      break;
    /* Unlike SET_VOLUME/SET_MUTE (track in arg_i), these two carry the track in
     * arg_f and the mask in arg_i — so a 32-bit mask round-trips exactly (a
     * float cannot). See le_engine_set_input_mask/set_output_mask. */
    case LE_CMD_SET_INPUT_MASK: {
      const int32_t ch = (int32_t)cmd->arg_f;
      if (!valid_channel(e, ch)) break;
      const uint32_t valid = e->in_channels >= 32
                                 ? 0xFFFFFFFFu
                                 : ((1u << e->in_channels) - 1u);
      atomic_store_explicit(&e->tracks[ch].a_input_mask,
                            (uint32_t)cmd->arg_i & valid, memory_order_relaxed);
      break;
    }
    case LE_CMD_SET_OUTPUT_MASK: {
      const int32_t ch = (int32_t)cmd->arg_f;
      if (!valid_channel(e, ch)) break;
      const uint32_t valid = e->out_channels >= 32
                                 ? 0xFFFFFFFFu
                                 : ((1u << e->out_channels) - 1u);
      atomic_store_explicit(&e->tracks[ch].a_output_mask,
                            (uint32_t)cmd->arg_i & valid, memory_order_relaxed);
      break;
    }
    default:
      break;
  }
}

/* ---- the real-time DSP core ---- */

void le_engine_process(le_engine* e, float* output, const float* input,
                       uint32_t frames) {
  const int ch_in = e->in_channels > 0 ? e->in_channels : 1;
  const int ch_out = e->out_channels > 0 ? e->out_channels : 1;
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
    float frame_mag = 0.0f;
    float mono = 0.0f;
    for (int c = 0; c < ch_in; ++c) {
      const float s = in ? in[f * ch_in + c] : 0.0f;
      const float a = fabsf(s);
      if (a > frame_mag) frame_mag = a;
      in_sumsq += s * s;
      mono += s;
    }
    mono /= (float)ch_in; /* clip-safe average fold-down */
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
      for (int c = 0; c < ch_out; ++c) {
        out[f * ch_out + c] = broadcast;
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
    uint32_t in_mask[LE_MAX_TRACKS];
    uint32_t out_mask[LE_MAX_TRACKS];
    for (int t = 0; t < tc; ++t) {
      st[t] = load_i32(&e->tracks[t].a_state);
      buf[t] = e->tracks[t].pool[load_i32(&e->tracks[t].a_live)];
      vol[t] = load_f32(&e->tracks[t].a_vol_bits);
      mut[t] = load_i32(&e->tracks[t].a_muted);
      in_mask[t] = atomic_load_explicit(&e->tracks[t].a_input_mask,
                                        memory_order_relaxed);
      out_mask[t] = atomic_load_explicit(&e->tracks[t].a_output_mask,
                                         memory_order_relaxed);
    }
    /* Latency compensation: captured input is recorded this many frames earlier
     * so it aligns with what the player heard. Monitoring stays live (it is no
     * longer folded into the loop buffer at the playhead). */
    const int32_t offset = load_i32(&e->a_record_offset);
    const int monitor_on = load_i32(&e->a_monitor);
    const int32_t pos = e->clock.position;

    /* Per-track read base for this frame: a track of multiple k plays its k-th
     * base-loop segment, cycling relative to where its recording began. k == 1
     * (the common case) collapses to the master position. */
    int32_t seg_base[LE_MAX_TRACKS];
    for (int t = 0; t < tc; ++t) {
      if (e->clock.length > 0) {
        int32_t k = load_i32(&e->tracks[t].a_multiple);
        if (k < 1) k = 1;
        const uint64_t seg =
            (e->loop_iteration - e->tracks[t].start_iter) % (uint64_t)k;
        seg_base[t] = (int32_t)seg * e->clock.length;
      } else {
        seg_base[t] = 0;
      }
    }

    float frame_out_peak = 0.0f; /* max |output| this frame, for the viz tap */
    float frame_trk_peak[LE_MAX_TRACKS] = {0}; /* per-track, this frame */

    /* The looper mix is additive: clear this output frame, then sum each
     * track's mono contribution into the output channels its mask selects. */
    for (int c = 0; c < ch_out; ++c) out[f * ch_out + c] = 0.0f;

    for (int t = 0; t < tc; ++t) {
      /* Each track records the average of its selected input channels into its
       * mono buffer. Averaging (not summing) keeps the captured level stable
       * and clip-safe regardless of how many inputs are armed. */
      float insample;
      if (e->mono_input) {
        insample = mono;
      } else if (in) {
        float sum = 0.0f;
        int cnt = 0;
        for (int c = 0; c < ch_in; ++c) {
          if (in_mask[t] & (1u << c)) {
            sum += in[f * ch_in + c];
            ++cnt;
          }
        }
        insample = cnt > 0 ? sum / (float)cnt : 0.0f;
      } else {
        insample = 0.0f;
      }

      float loopsample = 0.0f;
      if (st[t] == LE_TRACK_RECORDING) {
        if (e->clock.length == 0) {
          /* defining track: no reference loop yet, so no compensation */
          if (e->tracks[t].record_pos < e->max_loop_frames) {
            buf[t][e->tracks[t].record_pos] = insample;
          }
        } else {
          /* new track: phase-locked write head (record_pos == segment*base +
           * position), spanning one or more base loops; latency-compensated by
           * dropping the first `offset` frames so it aligns with what the
           * player heard. */
          const int32_t w = e->tracks[t].record_pos - offset;
          if (w >= 0 && w < e->max_loop_frames) {
            buf[t][w] = insample;
          }
        }
      } else if (st[t] == LE_TRACK_OVERDUBBING) {
        /* Mix the existing loop (read before write); record the live input at
         * the compensated position in the current segment for the next pass. */
        loopsample = buf[t][seg_base[t] + pos];
        const int32_t w = seg_base[t] + comp_pos(pos, offset, e->clock.length);
        buf[t][w] += insample;
      } else if (st[t] == LE_TRACK_PLAYING) {
        loopsample = buf[t][seg_base[t] + pos];
      }

      /* Route the track's mono sample to every output channel in its mask. */
      if ((st[t] == LE_TRACK_PLAYING || st[t] == LE_TRACK_OVERDUBBING) &&
          !mut[t]) {
        const float contrib = loopsample * vol[t];
        for (int c = 0; c < ch_out; ++c) {
          if (out_mask[t] & (1u << c)) out[f * ch_out + c] += contrib;
        }
      }

      const float la = fabsf(loopsample);
      if (la > trk_peak[t]) trk_peak[t] = la;
      if (la > frame_trk_peak[t]) frame_trk_peak[t] = la;
      trk_sumsq[t] += loopsample * loopsample;
    }

    /* Input monitoring (passthrough): route input channel c to output channel c
     * for the channels the two sides share. Kept deliberately simple. */
    if (monitor_on) {
      const int shared = ch_in < ch_out ? ch_in : ch_out;
      for (int c = 0; c < shared; ++c) {
        out[f * ch_out + c] += e->mono_input ? mono : (in ? in[f * ch_in + c]
                                                          : 0.0f);
      }
    }

    /* Output metering for this frame. */
    for (int c = 0; c < ch_out; ++c) {
      const float sample = out[f * ch_out + c];
      out_sumsq += sample * sample;
      const float sa = fabsf(sample);
      if (sa > frame_out_peak) frame_out_peak = sa;
    }

    /* Loop visualization tap: bucket the output (and per-track) peaks by loop
     * position. When the playhead crosses into a new bucket, publish the peaks
     * accumulated for the bucket it left, then start the new one — so each
     * bucket holds the most recent pass over that slice of the loop. RT-safe
     * (atomics only). Only meaningful once a master loop exists. */
    if (e->clock.length > 0) {
      int32_t bucket =
          (int32_t)((int64_t)pos * LE_VIZ_POINTS / e->clock.length);
      if (bucket >= LE_VIZ_POINTS) bucket = LE_VIZ_POINTS - 1;
      if (bucket != e->loop_viz_bucket) {
        const int32_t prev = e->loop_viz_bucket;
        if (prev >= 0 && prev < LE_VIZ_POINTS) {
          store_f32(&e->a_loop_viz[prev], e->loop_viz_accum);
          for (int t = 0; t < tc; ++t) {
            store_f32(&e->a_track_viz[t][prev], e->track_viz_accum[t]);
          }
        }
        e->loop_viz_bucket = bucket;
        e->loop_viz_accum = 0.0f;
        for (int t = 0; t < tc; ++t) e->track_viz_accum[t] = 0.0f;
      }
      if (frame_out_peak > e->loop_viz_accum) e->loop_viz_accum = frame_out_peak;
      for (int t = 0; t < tc; ++t) {
        if (frame_trk_peak[t] > e->track_viz_accum[t]) {
          e->track_viz_accum[t] = frame_trk_peak[t];
        }
      }
    }

    /* Advance the record heads, then the master transport. New tracks grow
     * freely (no auto-finalize at the loop boundary — they are rounded up to
     * whole base loops only when stopped); they cap at the per-track buffer. */
    for (int t = 0; t < tc; ++t) {
      if (st[t] != LE_TRACK_RECORDING) continue;
      le_track* tr = &e->tracks[t];
      if (e->clock.length == 0) {
        tr->record_pos++;
        if (tr->record_pos >= e->max_loop_frames) finalize_master(e, tr);
      } else {
        tr->record_pos++;
        if (tr->record_pos >= e->max_loop_frames) {
          finalize_new_track(e, tr, LE_TRACK_PLAYING);
        }
      }
    }
    if (e->clock.length > 0) {
      int any_active = 0;
      for (int t = 0; t < tc; ++t) {
        if (st[t] == LE_TRACK_PLAYING || st[t] == LE_TRACK_RECORDING ||
            st[t] == LE_TRACK_OVERDUBBING) {
          any_active = 1;
          break;
        }
      }
      if (any_active) {
        if (le_loop_clock_tick(&e->clock)) e->loop_iteration++;
      } else {
        /* Nothing is playing or recording: hold the transport at the top so the
         * next play starts from the beginning rather than looping in silence.
         * Resetting each track's start_iter keeps multi-loop tracks aligned to
         * their first segment on the next play. */
        e->clock.position = 0;
        e->loop_iteration = 0;
        for (int t = 0; t < tc; ++t) e->tracks[t].start_iter = 0;
      }
    }
  }

  const uint32_t total_in = frames * (uint32_t)ch_in;
  const uint32_t total_out = frames * (uint32_t)ch_out;
  store_f32(&e->a_in_rms_bits,
            total_in ? sqrtf(in_sumsq / (float)total_in) : 0.0f);
  store_f32(&e->a_in_peak_bits, in_peak);
  store_f32(&e->a_out_rms_bits,
            total_out ? sqrtf(out_sumsq / (float)total_out) : 0.0f);
  for (int t = 0; t < tc; ++t) {
    /* Track buffers are mono: one loop sample accumulated per frame. */
    store_f32(&e->tracks[t].a_rms_bits,
              frames ? sqrtf(trk_sumsq[t] / (float)frames) : 0.0f);
    store_f32(&e->tracks[t].a_peak_bits, trk_peak[t]);
    if (load_i32(&e->tracks[t].a_state) == LE_TRACK_RECORDING) {
      const int32_t rp = e->tracks[t].record_pos; /* -1 while waiting */
      store_i32(&e->tracks[t].a_len, rp > 0 ? rp : 0);
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

  /* Per-track buffers are mono: one input channel in, routed out via the mask. */
  const size_t samples = (size_t)max_loop_frames;
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
    store_i32(&tr->a_multiple, 1);
    /* Default routing preserves stereo behaviour: record input 0, play 0 + 1. */
    atomic_store_explicit(&tr->a_input_mask, 0x1u, memory_order_relaxed);
    atomic_store_explicit(&tr->a_output_mask, 0x3u, memory_order_relaxed);
    tr->record_pos = 0;
    tr->start_iter = 0;
  }

  engine->sample_rate = sample_rate;
  engine->in_channels = input_channels;
  engine->out_channels = output_channels;
  engine->max_loop_frames = max_loop_frames;
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

  store_i32(&engine->a_sample_rate, sample_rate);
  store_i32(&engine->a_in_channels, input_channels);
  store_i32(&engine->a_out_channels, output_channels);
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

/* ---- device enumeration & pinning ---- */

/* Serializes a miniaudio device id into a printable, round-trippable token.
 * On every string-id backend (CoreAudio, ALSA, PulseAudio, sndio, oss) the
 * union's active member is a NUL-terminated char string at offset 0, so reading
 * it as a C string is exact and matches byte-for-byte at resolve time. WASAPI
 * (a wchar string) is not represented here; pinning is a no-op there and the
 * engine falls back to the default device. */
static void device_id_to_str(const ma_device_id* id, char* out, size_t cap) {
  strncpy(out, (const char*)id, cap - 1);
  out[cap - 1] = '\0';
}

static void device_info_copy(le_device_info* dst, const ma_device_info* src) {
  device_id_to_str(&src->id, dst->id, sizeof(dst->id));
  strncpy(dst->name, src->name, sizeof(dst->name) - 1);
  dst->name[sizeof(dst->name) - 1] = '\0';
  dst->is_default = src->isDefault ? 1 : 0;
}

/* Fills `out` (room for `max`) with the host's playback or capture devices and
 * writes the count into *count. Uses a transient context so it never disturbs a
 * running device. `capture` selects the direction. */
static int32_t enumerate_devices(le_device_info* out, int32_t max,
                                 int32_t* count, int capture) {
  if (out == NULL || count == NULL || max <= 0) return LE_ERR_INVALID;
  *count = 0;
  ma_context ctx;
  if (ma_context_init(NULL, 0, NULL, &ctx) != MA_SUCCESS) return LE_ERR_INVALID;
  ma_device_info* playback = NULL;
  ma_uint32 playback_count = 0;
  ma_device_info* cap = NULL;
  ma_uint32 cap_count = 0;
  if (ma_context_get_devices(&ctx, &playback, &playback_count, &cap,
                             &cap_count) != MA_SUCCESS) {
    ma_context_uninit(&ctx);
    return LE_ERR_INVALID;
  }
  ma_device_info* list = capture ? cap : playback;
  ma_uint32 n = capture ? cap_count : playback_count;
  int32_t written = 0;
  for (ma_uint32 i = 0; i < n && written < max; ++i) {
    device_info_copy(&out[written++], &list[i]);
  }
  *count = written;
  ma_context_uninit(&ctx);
  return LE_OK;
}

int32_t le_enumerate_playback_devices(le_device_info* out, int32_t max,
                                      int32_t* count) {
  return enumerate_devices(out, max, count, /*capture=*/0);
}

int32_t le_enumerate_capture_devices(le_device_info* out, int32_t max,
                                     int32_t* count) {
  return enumerate_devices(out, max, count, /*capture=*/1);
}

/* Looks up the device whose serialized id equals `want` in the already-open
 * `ctx` and copies its native id into *out_id. Returns 1 on a match (out_id set)
 * or 0 if `want` is empty / unmatched / enumeration failed. */
static int resolve_device_id(ma_context* ctx, int capture, const char* want,
                             ma_device_id* out_id) {
  if (want == NULL || want[0] == '\0') return 0;
  ma_device_info* playback = NULL;
  ma_uint32 playback_count = 0;
  ma_device_info* cap = NULL;
  ma_uint32 cap_count = 0;
  if (ma_context_get_devices(ctx, &playback, &playback_count, &cap,
                             &cap_count) != MA_SUCCESS) {
    return 0;
  }
  ma_device_info* list = capture ? cap : playback;
  ma_uint32 n = capture ? cap_count : playback_count;
  char buf[256];
  for (ma_uint32 i = 0; i < n; ++i) {
    device_id_to_str(&list[i].id, buf, sizeof(buf));
    if (strcmp(buf, want) == 0) {
      *out_id = list[i].id;
      return 1;
    }
  }
  return 0;
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

le_engine* le_engine_create(void) {
  le_engine* engine = (le_engine*)calloc(1, sizeof(le_engine));
  if (engine == NULL) return NULL;
  le_ring_init(&engine->ring, engine->ring_storage, LE_RING_CAPACITY);
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

  /* Capture and playback widths may differ (e.g. 2-in / 4-out). An unset (0)
   * count tells miniaudio to open the device's native channel count, so a
   * multichannel interface comes up with all its channels; the negotiated
   * counts are read back after init. */
  int in_channels = config->input_channels > 0 ? config->input_channels : 0;
  int out_channels = config->output_channels > 0 ? config->output_channels : 0;
  if (in_channels > LE_MAX_CHANNELS) in_channels = LE_MAX_CHANNELS;
  if (out_channels > LE_MAX_CHANNELS) out_channels = LE_MAX_CHANNELS;
  engine->passthrough = config->passthrough ? 1 : 0;
  engine->mono_input = config->merge_to_mono ? 1 : 0;
  store_i32(&engine->a_monitor, engine->passthrough);

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

  /* An explicit context is needed to capture from a detected loopback device
   * (use_loopback_capture) or to pin playback/capture to a device by id. When
   * any of those is requested, open one context and resolve the relevant ids;
   * otherwise the default device is opened with no context. */
  const int want_playback_pin = config->playback_device_id[0] != '\0';
  const int want_capture_pin = config->capture_device_id[0] != '\0';
  ma_context* pContext = NULL;
  if (config->use_loopback_capture || want_playback_pin || want_capture_pin) {
    if (ma_context_init(NULL, 0, NULL, &engine->context) == MA_SUCCESS) {
      engine->context_initialised = 1;
      pContext = &engine->context;
      if (config->use_loopback_capture) {
        /* Loopback capture overrides an explicit capture device id. */
        le_loopback_info info;
        find_loopback(&engine->context, &info, &engine->capture_id);
        if (info.available && info.device_name[0] != '\0') {
          cfg.capture.pDeviceID = &engine->capture_id;
        }
      } else if (want_capture_pin) {
        if (resolve_device_id(&engine->context, /*capture=*/1,
                              config->capture_device_id, &engine->capture_id)) {
          cfg.capture.pDeviceID = &engine->capture_id;
        }
      }
      if (want_playback_pin) {
        if (resolve_device_id(&engine->context, /*capture=*/0,
                              config->playback_device_id,
                              &engine->playback_id)) {
          cfg.playback.pDeviceID = &engine->playback_id;
        }
      }
    }
  }

  if (ma_device_init(pContext, &cfg, &engine->device) != MA_SUCCESS) {
    le_uninit_context(engine);
    return LE_ERR_DEVICE;
  }
  engine->device_initialised = 1;

  const int32_t sr = (int32_t)engine->device.sampleRate;
  /* Use the device-negotiated channel counts (they may differ from requested). */
  const int32_t neg_in = (int32_t)engine->device.capture.channels;
  const int32_t neg_out = (int32_t)engine->device.playback.channels;
  if (le_engine_configure(engine, sr, neg_in, neg_out,
                          config->max_loop_frames) != LE_OK) {
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
  atomic_store_explicit(&engine->a_device_present, 1, memory_order_release);
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
  atomic_store_explicit(&engine->a_device_present, 0, memory_order_release);
  atomic_store_explicit(&engine->a_running, 0, memory_order_release);
  return LE_OK;
}

void le_engine_get_snapshot(le_engine* engine, le_snapshot* out) {
  if (engine == NULL || out == NULL) return;
  out->running = atomic_load_explicit(&engine->a_running, memory_order_acquire);
  out->device_present =
      atomic_load_explicit(&engine->a_device_present, memory_order_acquire);
  out->sample_rate = load_i32(&engine->a_sample_rate);
  out->buffer_frames = load_i32(&engine->a_buffer_frames);
  out->input_channels = load_i32(&engine->a_in_channels);
  out->output_channels = load_i32(&engine->a_out_channels);
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
  out->track_count = engine->track_count;
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    le_track* tr = &engine->tracks[t];
    out->tracks[t].state =
        t < engine->track_count ? load_i32(&tr->a_state) : LE_TRACK_EMPTY;
    out->tracks[t].volume = load_f32(&tr->a_vol_bits);
    out->tracks[t].muted = load_i32(&tr->a_muted);
    out->tracks[t].length_frames = load_i32(&tr->a_len);
    out->tracks[t].multiple = load_i32(&tr->a_multiple);
    out->tracks[t].undo_depth = load_i32(&tr->a_undo_depth);
    out->tracks[t].redo_depth = load_i32(&tr->a_redo_depth);
    out->tracks[t].rms = load_f32(&tr->a_rms_bits);
    out->tracks[t].peak = load_f32(&tr->a_peak_bits);
    out->tracks[t].input_mask =
        atomic_load_explicit(&tr->a_input_mask, memory_order_relaxed);
    out->tracks[t].output_mask =
        atomic_load_explicit(&tr->a_output_mask, memory_order_relaxed);
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
    out->multiple = 1;
    out->undo_depth = 0;
    out->redo_depth = 0;
    out->rms = 0.0f;
    out->peak = 0.0f;
    out->input_mask = 0x1u;
    out->output_mask = 0x3u;
    return;
  }
  le_track* tr = &engine->tracks[channel];
  out->state = load_i32(&tr->a_state);
  out->volume = load_f32(&tr->a_vol_bits);
  out->muted = load_i32(&tr->a_muted);
  out->length_frames = load_i32(&tr->a_len);
  out->multiple = load_i32(&tr->a_multiple);
  out->undo_depth = load_i32(&tr->a_undo_depth);
  out->redo_depth = load_i32(&tr->a_redo_depth);
  out->rms = load_f32(&tr->a_rms_bits);
  out->peak = load_f32(&tr->a_peak_bits);
  out->input_mask =
      atomic_load_explicit(&tr->a_input_mask, memory_order_relaxed);
  out->output_mask =
      atomic_load_explicit(&tr->a_output_mask, memory_order_relaxed);
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
      const size_t samples = (size_t)e->max_loop_frames; /* mono */
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
  const int32_t len = load_i32(&t->a_len); /* this track's length (k * base) */
  /* Starting a new-track recording (a fresh capture over an existing loop)?
   * Zero its live buffer on this (control) thread so any unrecorded tail of a
   * rounded-up multi-loop length plays as silence. The track is EMPTY, so the
   * audio thread is not reading the buffer. (Defining recordings — no master yet
   * — use record_pos bounds instead and need no zeroing.) */
  if (st == LE_TRACK_EMPTY && load_i32(&engine->a_master_len) > 0) {
    const int live = load_i32(&t->a_live);
    if (t->pool[live] != NULL) {
      const size_t n = (size_t)engine->max_loop_frames; /* mono */
      memset(t->pool[live], 0, n * sizeof(float));
    }
  }
  if ((st == LE_TRACK_PLAYING || st == LE_TRACK_STOPPED) && len > 0) {
    t->redo_count = 0;
    const int slot = track_acquire_slot(engine, t);
    if (slot >= 0) {
      const int live = load_i32(&t->a_live);
      const size_t n = (size_t)len; /* mono */
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
