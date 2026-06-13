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

#include "engine_internal.h"
#include "engine_miniaudio.h"
#include "engine_platform.h"
#include "engine_private.h"
#include "lockfree_ring.h"
#include "loop_clock.h"
#include "loopy_engine_api.h"
#include "miniaudio.h"
#if defined(_WIN32) && defined(LOOPY_ENABLE_ASIO)
#include "win_asio_device.h" /* le_asio_backend (selected by le_select_backend) */
#endif

/* All platform-specific behavior (CoreAudio channel labels, JACK port-pinning,
 * PipeWire quantum forcing) lives behind the engine_platform.h seam, implemented
 * per OS in engine_apple.c / engine_linux.c / engine_windows.c. This file is
 * platform-agnostic — no #if defined(__APPLE__|__linux__|_WIN32) behavior. */

/* Loopback latency harness. The echo returns only mildly attenuated (~0.9 from
 * a full-scale pulse on a typical interface), so we emit a quiet calibration
 * tone rather than full scale to spare the user's monitors, and detect with a
 * threshold comfortably below the echo yet well above the noise floor. */
#define LE_LATENCY_PULSE_AMP 0.9f  /* calibration tone amplitude (0..1) */
#define LE_LATENCY_TONE_HZ 1000.0f /* tone-burst freq (AC: survives AC-coupling) */
#define LE_LATENCY_PEAK_RATIO 2.5f /* correlation peak must exceed this x baseline */
#define LE_LATENCY_PULSE_DIV 100   /* pulse length = sample_rate / this (~10ms) */
#define LE_LATENCY_CAPTURE_DIV 10  /* capture window = sample_rate / this (~100ms) */

/* Input level (0..1) that triggers sound-activated recording (~-34 dBFS). */
#define LE_AUTO_RECORD_THRESHOLD 0.02f

/* struct le_engine and its nested types (le_fx_state, le_lane,
 * le_monitor_input, le_track) plus LE_RING_CAPACITY / LE_UNDO_SLOTS now live in
 * engine_private.h, shared with the per-OS translation units (engine_linux.c /
 * engine_apple.c / engine_windows.c). */

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
/* load_i32 / store_i32 are static inline in engine_private.h (shared with the
 * per-OS TUs); load_f32 / store_f32 / bits_to_f32 have no cross-TU consumer and
 * stay file-local here. */

/* Wraps `pos - offset` into [0, len). Used to write captured input at the
 * latency-compensated loop position so overdubs align with what was heard. */
static int32_t comp_pos(int32_t pos, int32_t offset, int32_t len) {
  if (len <= 0) return pos;
  int32_t p = (pos - offset) % len;
  if (p < 0) p += len;
  return p;
}

/* A track's active lane count, clamped to a usable range (a track always has at
 * least one lane). */
static int32_t le_lanes_active(const le_track* t) {
  int32_t n = t->lane_count;
  if (n < 1) n = 1;
  if (n > LE_MAX_LANES) n = LE_MAX_LANES;
  return n;
}

/* Publishes a recorded length onto every active lane of a track (all lanes of a
 * track share the one transport, so they share the length). */
static void le_track_set_len(le_track* t, int32_t len) {
  const int32_t n = le_lanes_active(t);
  for (int32_t l = 0; l < n; ++l) store_i32(&t->lanes[l].a_len, len);
}

/* Lowest set bit of `mask` as a channel index, or -1 when no bit is set. Used to
 * collapse a legacy track input bitmask into lane 0's single input channel. */
static int32_t le_mask_to_channel(uint32_t mask) {
  if (mask == 0u) return -1;
  int32_t c = 0;
  while (!(mask & 1u)) {
    mask >>= 1;
    ++c;
  }
  return c;
}

/* ---- command handlers (audio thread) ---- */

static void finalize_master(le_engine* e, le_track* t, int32_t end_state) {
  const int32_t len = t->record_pos > 0 ? t->record_pos : 1;
  le_loop_clock_set_length(&e->clock, len);
  e->loop_iteration = 0; /* the base loop just (re)started */
  store_i32(&e->a_master_len, len);
  le_track_set_len(t, len);
  store_i32(&t->a_multiple, 1); /* the defining track is one base loop */
  store_i32(&t->a_state, end_state);
  t->start_iter = 0;
}

/* Finalizes a non-defining track that recorded freely across one or more base
 * loops: rounds its length UP to the nearest whole base loop (the locked #4
 * behaviour), publishes the multiple, and moves it to `end_state`. A track that
 * captured nothing (never reached the loop top) returns to EMPTY. */
/* Track [ch]'s effective forced loop multiple: its per-track override, or the
 * global default when it inherits (target 0). 0 means auto (round up on stop). */
static int32_t le_effective_multiple(const le_engine* e, int32_t ch) {
  const int32_t ov = e->target_multiple[ch];
  return ov > 0 ? ov : e->default_multiple;
}

static void finalize_new_track(le_engine* e, le_track* t, int32_t end_state) {
  const int32_t base = e->clock.length > 0 ? e->clock.length : 1;
  if (t->record_pos <= 0) { /* nothing captured */
    store_i32(&t->a_state, LE_TRACK_EMPTY);
    le_track_set_len(t, 0);
    store_i32(&t->a_multiple, 1);
    t->record_pos = 0;
    return;
  }
  /* A forced multiple fixes the length to exactly K base loops; 0 (auto) rounds
   * up to whole base loops based on how much was recorded. */
  const int32_t forced = le_effective_multiple(e, (int32_t)(t - e->tracks));
  int32_t k = forced > 0 ? forced : (t->record_pos + base - 1) / base;
  const int32_t maxk = e->max_loop_frames / base;
  if (k < 1) k = 1;
  if (maxk >= 1 && k > maxk) k = maxk;
  store_i32(&t->a_multiple, k);
  le_track_set_len(t, k * base);
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
        finalize_master(e, tr, LE_TRACK_PLAYING); /* defines the master loop */
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
        t->record_start = 0;
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
         * up on stop — or exactly K with a fixed multiple (auto-finalized). */
        t->record_pos = e->clock.position;
        t->record_start = t->record_pos;
        t->start_iter = e->loop_iteration;
        store_i32(&t->a_state, LE_TRACK_RECORDING);
      }
      break;
    case LE_TRACK_RECORDING: {
      /* Second press finalizes. In rec/dub mode it continues into overdub
       * instead of playback (no undo snapshot for this auto-dub layer — a
       * later manual overdub snapshots normally). A stop press ends in
       * playback/stopped (handle_stop), never overdub. */
      const int32_t end = e->rec_dub ? LE_TRACK_OVERDUBBING : LE_TRACK_PLAYING;
      if (e->clock.length == 0) {
        finalize_master(e, t, end);
      } else {
        finalize_new_track(e, t, end);
      }
      break;
    }
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
      finalize_master(e, t, LE_TRACK_STOPPED);
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
  t->pending_record = 0;
  store_i32(&t->a_pending, 0);
  store_i32(&t->a_state, LE_TRACK_EMPTY);
  le_track_set_len(t, 0);
  store_i32(&t->a_multiple, 1);
  /* Undo/redo stacks and each lane's a_live are reset by le_engine_clear on the
   * control thread; the audio thread only resets the state/transport here. */

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

/* ---- per-track effects DSP ----
 *
 * Each helper processes one sample through one slot and advances that slot's
 * audio-thread-owned state in `t`. All are branch-light and allocation-free
 * (the delay line is pre-allocated by the control thread), so they are safe in
 * the audio callback. Parameters arrive normalized (0..1) and are mapped to
 * musical ranges here. */

#ifndef LE_PI
#define LE_PI 3.14159265358979323846f
#endif

/* Soft-clipping overdrive: tanh saturation with a pre-gain, then output trim. */
static float fx_drive(float x, const float* p) {
  const float drive = 1.0f + p[0] * 29.0f; /* 1x .. 30x pre-gain */
  const float level = p[1];                /* 0..1 output trim */
  return tanhf(x * drive) * level;
}

/* Resonant low-pass: a TPT state-variable filter (Cytomic/Zavalishin form).
 * p0 = cutoff (20 Hz .. ~18 kHz, log), p1 = resonance. */
static float fx_filter(le_fx_state* fx, int slot, int sr, float x,
                       const float* p) {
  float fc = 20.0f * powf(900.0f, p[0]); /* 20 * 900 = 18 kHz at p0 = 1 */
  const float nyq = 0.45f * (float)sr;
  if (fc > nyq) fc = nyq;
  const float g = tanf(LE_PI * fc / (float)sr);
  const float k = 2.0f - 1.8f * p[1]; /* damping: 2 (none) .. 0.2 (resonant) */
  const float a1 = 1.0f / (1.0f + g * (g + k));
  const float a2 = g * a1;
  const float a3 = g * a2;
  float* ic1 = &fx->svf_ic1[slot];
  float* ic2 = &fx->svf_ic2[slot];
  const float v3 = x - *ic2;
  const float v1 = a1 * (*ic1) + a2 * v3;
  const float v2 = *ic2 + a2 * (*ic1) + a3 * v3;
  *ic1 = 2.0f * v1 - *ic1;
  *ic2 = 2.0f * v2 - *ic2;
  return v2; /* low-pass output */
}

/* Feedback delay: p0 = time (0..1 s), p1 = feedback, p2 = wet mix. The ring is
 * the control-thread-allocated fx_delay line of e->fx_delay_frames samples. */
static float fx_delay(le_fx_state* fx, int slot, int cap, float x,
                      const float* p) {
  float* buf = fx->delay[slot];
  if (buf == NULL || cap <= 1) return x;
  int d = (int)(p[0] * (float)(cap - 1));
  if (d < 1) d = 1;
  int pos = fx->delay_pos[slot];
  int rp = pos - d;
  if (rp < 0) rp += cap;
  const float delayed = buf[rp];
  const float fb = p[1] * 0.95f; /* keep the feedback loop stable (< 1) */
  buf[pos] = x + delayed * fb;
  pos += 1;
  if (pos >= cap) pos = 0;
  fx->delay_pos[slot] = pos;
  const float mix = p[2];
  return x * (1.0f - mix) + delayed * mix;
}

/* Tremolo: sine LFO amplitude modulation. p0 = rate (0.1..12 Hz), p1 = depth. */
static float fx_tremolo(le_fx_state* fx, int slot, int sr, float x,
                        const float* p) {
  const float rate = 0.1f + p[0] * 11.9f;
  const float depth = p[1];
  float ph = fx->lfo[slot];
  const float lfo = 0.5f * (1.0f + sinf(2.0f * LE_PI * ph)); /* 0..1 */
  ph += rate / (float)sr;
  if (ph >= 1.0f) ph -= 1.0f;
  fx->lfo[slot] = ph;
  return x * (1.0f - depth * (1.0f - lfo));
}

/* Linearly interpolated read from a ring of [cap] samples, [d] samples behind
 * the head [head] (the index of the most recently written sample). [d] may be
 * fractional and is assumed in [0, cap). */
static float fx_read_frac(const float* buf, int cap, int head, float d) {
  float rp = (float)head - d;
  while (rp < 0.0f) rp += (float)cap;
  while (rp >= (float)cap) rp -= (float)cap;
  const int i0 = (int)rp;
  const float frac = rp - (float)i0;
  int i1 = i0 + 1;
  if (i1 >= cap) i1 = 0;
  return buf[i0] + frac * (buf[i1] - buf[i0]);
}

/* Octaver: a time-domain pitch shifter. Two read taps a half-grain apart walk
 * the input ring at rate (1 - ratio) and are Hann-crossfaded (the two windows
 * sum to 1, so the wrap is silent), turning input frequency f into ratio * f.
 * p0 = shift (0 = two octaves down, 0.5 = unison, 1 = two octaves up — so it
 * covers up and down, one or many octaves, and the intervals between), p1 = tone
 * (low-pass on the shifted voice), p2 = dry/wet mix. The grain ring is the
 * control-thread-allocated fx_delay line; grain_phase is the read phase and
 * fx_lp the tone memory. */
static float fx_octaver(le_fx_state* fx, int slot, int cap, float x,
                        const float* p) {
  float* buf = fx->delay[slot];
  if (buf == NULL || cap <= 4) return x;
  int w = cap / 32; /* grain window: ~30 ms of the 1 s ring */
  if (w < 2) w = 2;
  const float wf = (float)w;

  /* Write the dry input at the head, then advance. */
  const int head = fx->delay_pos[slot];
  buf[head] = x;
  int npos = head + 1;
  if (npos >= cap) npos = 0;
  fx->delay_pos[slot] = npos;

  /* Pitch ratio over +-2 octaves, unison at p0 = 0.5. The read phase walks at
   * (1 - ratio) per sample so the playback rate becomes the ratio. */
  const float semis = (p[0] - 0.5f) * 48.0f;
  const float ratio = powf(2.0f, semis / 12.0f);
  float ph = fx->grain_phase[slot] + (1.0f - ratio);
  while (ph >= wf) ph -= wf;
  while (ph < 0.0f) ph += wf;
  fx->grain_phase[slot] = ph;

  const float ph2 = ph >= wf * 0.5f ? ph - wf * 0.5f : ph + wf * 0.5f;
  const float g1 = 0.5f * (1.0f - cosf(2.0f * LE_PI * ph / wf));
  const float g2 = 0.5f * (1.0f - cosf(2.0f * LE_PI * ph2 / wf));
  const float wet = g1 * fx_read_frac(buf, cap, head, ph) +
                    g2 * fx_read_frac(buf, cap, head, ph2);

  /* Tone: a one-pole low-pass that opens up as p1 rises. */
  const float a = 0.05f + 0.9f * p[1];
  float lp = fx->fx_lp[slot];
  lp += a * (wet - lp);
  fx->fx_lp[slot] = lp;

  const float mix = p[2];
  return x * (1.0f - mix) + lp * mix;
}

/* Tape-style echo. Three things set it apart from the clean digital delay: a
 * slow wow LFO wobbles the read time (tape pitch flutter, read fractionally), a
 * heavy one-pole low-pass darkens the loop so each repeat loses highs, and the
 * fed-back signal is softly saturated (tape compression, which also self-limits
 * the feedback). The wet tap is that processed signal, so even the first repeat
 * is coloured rather than a clean copy. p0 = time (0..1 s), p1 = feedback,
 * p2 = wet mix. Shares the fx_delay ring; lfo is the wow phase, fx_lp the loop
 * low-pass. */
static float fx_echo(le_fx_state* fx, int slot, int sr, int cap, float x,
                     const float* p) {
  float* buf = fx->delay[slot];
  if (buf == NULL || cap <= 1) return x;

  /* Wow/flutter: a slow LFO wobbles the read time a few ms for tape wobble. */
  float ph = fx->lfo[slot];
  const float wow = sinf(2.0f * LE_PI * ph);
  ph += 0.7f / (float)sr; /* ~0.7 Hz wow */
  if (ph >= 1.0f) ph -= 1.0f;
  fx->lfo[slot] = ph;
  const float wob = 0.004f * (float)sr; /* ~4 ms wobble depth */
  float d = p[0] * (float)(cap - 1) + wow * wob;
  if (d < 1.0f) d = 1.0f;
  if (d > (float)(cap - 1)) d = (float)(cap - 1);

  const int pos = fx->delay_pos[slot];
  const float delayed = fx_read_frac(buf, cap, pos, d);

  /* Darken the loop (~1.4 kHz one-pole) then soft-saturate the repeats. */
  float lp = fx->fx_lp[slot];
  lp += 0.18f * (delayed - lp);
  fx->fx_lp[slot] = lp;
  const float wet = tanhf(lp);
  const float fb = p[1] * 0.97f;

  buf[pos] = x + wet * fb;
  int npos = pos + 1;
  if (npos >= cap) npos = 0;
  fx->delay_pos[slot] = npos;

  const float mix = p[2];
  return x * (1.0f - mix) + wet * mix;
}

/* Applies a chain to one sample, in chain order. The chain is stageless: every
 * active entry processes the sample. [count] is the active chain length;
 * [types]/[params] are the per-buffer snapshot. */
static float fx_apply_chain(le_fx_state* fx, int sr, int cap, float x, int count,
                            const int32_t* types,
                            const float params[LE_FX_MAX][LE_FX_PARAMS]) {
  for (int s = 0; s < count; ++s) {
    switch (types[s]) {
      case LE_FX_DRIVE:
        x = fx_drive(x, params[s]);
        break;
      case LE_FX_FILTER:
        x = fx_filter(fx, s, sr, x, params[s]);
        break;
      case LE_FX_DELAY:
        x = fx_delay(fx, s, cap, x, params[s]);
        break;
      case LE_FX_TREMOLO:
        x = fx_tremolo(fx, s, sr, x, params[s]);
        break;
      case LE_FX_OCTAVER:
        x = fx_octaver(fx, s, cap, x, params[s]);
        break;
      case LE_FX_ECHO:
        x = fx_echo(fx, s, sr, cap, x, params[s]);
        break;
      default:
        break;
    }
  }
  return x;
}

static void apply_command(le_engine* e, const le_command* cmd) {
  switch (cmd->code) {
    case LE_CMD_MEASURE_LATENCY: {
      const int32_t sr = e->sample_rate > 0 ? e->sample_rate : 48000;
      e->lat_active = 1;
      /* Emit for ~10 ms so the pulse survives D/A → cable → A/D. */
      e->lat_emit_remaining = sr / LE_LATENCY_PULSE_DIV;
      e->lat_buf_pos = 0; /* start a fresh capture window */
      store_i32(&e->a_latency_state, LE_LATENCY_MEASURING);
      /* A loopback measurement requires a physical out->in cable, which forms a
       * feedback loop with input monitoring (out -> cable -> in -> monitor ->
       * out). With loop gain > 1 that runs away to clipping and can overload the
       * interface. Disable every per-input monitor for the rest of the session;
       * the next start() restores defaults. */
      for (int c = 0; c < LE_MAX_INPUTS; ++c) {
        store_i32(&e->monitors[c].a_enabled, 0);
      }
      break;
    }
    case LE_CMD_RECORD:
      if (valid_channel(e, cmd->arg_i)) {
        e->tracks[cmd->arg_i].pending_record = 0;
        store_i32(&e->tracks[cmd->arg_i].a_pending, 0);
      }
      handle_record(e, cmd->arg_i);
      break;
    case LE_CMD_ARM:
      if (valid_channel(e, cmd->arg_i)) {
        /* arg_f carries the trigger: 0 = loop-top (quantize), 1 = input level
         * (sound-activated auto-record). */
        e->tracks[cmd->arg_i].pending_record = 1;
        e->tracks[cmd->arg_i].pending_trigger = cmd->arg_f != 0.0f ? 1 : 0;
        store_i32(&e->tracks[cmd->arg_i].a_pending, 1);
      }
      break;
    case LE_CMD_DISARM:
      if (valid_channel(e, cmd->arg_i)) {
        e->tracks[cmd->arg_i].pending_record = 0;
        e->tracks[cmd->arg_i].pending_trigger = 0;
        store_i32(&e->tracks[cmd->arg_i].a_pending, 0);
      }
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
      /* Track-addressed volume maps to lane 0 (backward compatibility). */
      store_f32(&e->tracks[cmd->arg_i].lanes[0].a_vol_bits, v);
      break;
    }
    case LE_CMD_SET_MUTE:
      if (valid_channel(e, cmd->arg_i)) {
        store_i32(&e->tracks[cmd->arg_i].lanes[0].a_muted,
                  cmd->arg_f != 0.0f ? 1 : 0);
      }
      break;
    case LE_CMD_SET_RECORD_OFFSET: {
      const int32_t frames = cmd->arg_i > 0 ? cmd->arg_i : 0;
      store_i32(&e->a_record_offset, frames);
      /* An explicitly set offset (a restored measurement, or a manual override)
       * is a known round-trip, so publish it as a completed measurement — the
       * UI then shows the loaded latency instead of "not measured". */
      if (frames > 0) {
        const int32_t osr = e->sample_rate > 0 ? e->sample_rate : 48000;
        atomic_store_explicit(
            &e->a_latency_ms_bits,
            f64_to_bits((double)frames * 1000.0 / (double)osr),
            memory_order_relaxed);
        store_i32(&e->a_latency_state, LE_LATENCY_DONE);
      }
      break;
    }
    /* Unlike SET_VOLUME/SET_MUTE (track in arg_i), these two carry the track in
     * arg_f and the mask in arg_i — so a 32-bit mask round-trips exactly (a
     * float cannot). See le_engine_set_input_mask/set_output_mask. */
    case LE_CMD_SET_INPUT_MASK: {
      const int32_t ch = (int32_t)cmd->arg_f;
      if (!valid_channel(e, ch)) break;
      const uint32_t valid = e->in_channels >= 32
                                 ? 0xFFFFFFFFu
                                 : ((1u << e->in_channels) - 1u);
      /* A lane can never record from a loopback-excluded channel. The legacy
       * track input mask collapses to lane 0's single input channel: the lowest
       * valid, non-excluded bit (or -1 when none remain). */
      const uint32_t excluded = atomic_load_explicit(
          &e->a_excluded_input_mask, memory_order_relaxed);
      const uint32_t m = (uint32_t)cmd->arg_i & valid & ~excluded;
      store_i32(&e->tracks[ch].lanes[0].a_input_channel, le_mask_to_channel(m));
      break;
    }
    case LE_CMD_SET_OUTPUT_MASK: {
      const int32_t ch = (int32_t)cmd->arg_f;
      if (!valid_channel(e, ch)) break;
      const uint32_t valid = e->out_channels >= 32
                                 ? 0xFFFFFFFFu
                                 : ((1u << e->out_channels) - 1u);
      atomic_store_explicit(&e->tracks[ch].lanes[0].a_output_mask,
                            (uint32_t)cmd->arg_i & valid, memory_order_relaxed);
      break;
    }
    /* The FX commands field-pack (channel<<16)|(lane<<8)|index in arg_i (each
     * field < 256). This is a DIFFERENT packing from the lane routing commands
     * below (SET_LANE_INPUT..MUTE), which use the flat channel*LE_MAX_LANES+lane
     * index — the routing ones also carry a 32-bit mask in arg_i, so they cannot
     * field-pack the address there. Keep the two producers (le_engine_set_lane_*)
     * and these consumers in sync. */
    case LE_CMD_SET_LANE_FX: {
      const int32_t ch = (cmd->arg_i >> 16) & 0xFF;
      const int32_t lane = (cmd->arg_i >> 8) & 0xFF;
      const int32_t index = cmd->arg_i & 0xFF;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES ||
          index < 0 || index >= LE_FX_MAX) {
        break;
      }
      le_lane* ln = &e->tracks[ch].lanes[lane];
      store_i32(&ln->a_fx_type[index], (int32_t)cmd->arg_f);
      /* Reset the entry's DSP state so a freshly engaged effect starts clean (no
       * filter blow-up from stale integrators, no delay-read of old content). */
      ln->fx.svf_ic1[index] = 0.0f;
      ln->fx.svf_ic2[index] = 0.0f;
      ln->fx.lfo[index] = 0.0f;
      ln->fx.delay_pos[index] = 0;
      ln->fx.fx_lp[index] = 0.0f;
      ln->fx.grain_phase[index] = 0.0f;
      break;
    }
    case LE_CMD_SET_LANE_FX_COUNT: {
      const int32_t ch = (cmd->arg_i >> 16) & 0xFF;
      const int32_t lane = (cmd->arg_i >> 8) & 0xFF;
      int32_t count = cmd->arg_i & 0xFF;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES) break;
      if (count < 0) count = 0;
      if (count > LE_FX_MAX) count = LE_FX_MAX;
      store_i32(&e->tracks[ch].lanes[lane].a_fx_count, count);
      break;
    }
    /* ---- multi-lane routing commands ----
     * Every lane command addresses its lane by the same packed index
     * `channel * LE_MAX_LANES + lane`. SET_LANE_INPUT/OUTPUT carry that index in
     * arg_f and an int value (channel / 32-bit mask) in arg_i, so a 32-bit mask
     * and a -1 channel round-trip exactly; SET_LANE_VOLUME/MUTE carry the index
     * in arg_i and the float value in arg_f. */
    case LE_CMD_SET_LANE_INPUT: {
      const int32_t idx = (int32_t)cmd->arg_f;
      const int32_t ch = idx / LE_MAX_LANES;
      const int32_t lane = idx % LE_MAX_LANES;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES) break;
      int32_t in_ch = cmd->arg_i;
      const uint32_t excluded = atomic_load_explicit(
          &e->a_excluded_input_mask, memory_order_relaxed);
      /* Reject an out-of-range or loopback-excluded channel by recording
       * nothing, so a lane never captures our own output. */
      if (in_ch < 0 || in_ch >= e->in_channels ||
          (excluded & (1u << in_ch))) {
        in_ch = -1;
      }
      store_i32(&e->tracks[ch].lanes[lane].a_input_channel, in_ch);
      break;
    }
    case LE_CMD_SET_LANE_OUTPUT: {
      const int32_t idx = (int32_t)cmd->arg_f;
      const int32_t ch = idx / LE_MAX_LANES;
      const int32_t lane = idx % LE_MAX_LANES;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES) break;
      const uint32_t valid = e->out_channels >= 32
                                 ? 0xFFFFFFFFu
                                 : ((1u << e->out_channels) - 1u);
      atomic_store_explicit(&e->tracks[ch].lanes[lane].a_output_mask,
                            (uint32_t)cmd->arg_i & valid, memory_order_relaxed);
      break;
    }
    case LE_CMD_SET_LANE_VOLUME: {
      const int32_t ch = cmd->arg_i / LE_MAX_LANES;
      const int32_t lane = cmd->arg_i % LE_MAX_LANES;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES) break;
      float v = cmd->arg_f;
      if (v < 0.0f) v = 0.0f;
      if (v > 1.0f) v = 1.0f;
      store_f32(&e->tracks[ch].lanes[lane].a_vol_bits, v);
      break;
    }
    case LE_CMD_SET_LANE_MUTE: {
      const int32_t ch = cmd->arg_i / LE_MAX_LANES;
      const int32_t lane = cmd->arg_i % LE_MAX_LANES;
      if (!valid_channel(e, ch) || lane < 0 || lane >= LE_MAX_LANES) break;
      store_i32(&e->tracks[ch].lanes[lane].a_muted, cmd->arg_f != 0.0f ? 1 : 0);
      break;
    }
    /* ---- per-input live monitor ----
     * SET_MONITOR_INPUT carries the input index + enabled bit in arg_f and the
     * 32-bit output mask in arg_i (so the mask round-trips exactly); the FX
     * commands pack (input << 8) | index/count in arg_i. */
    case LE_CMD_SET_MONITOR_INPUT: {
      const int32_t iv = (int32_t)cmd->arg_f;
      const int32_t input = iv & 0xFF;
      const int32_t enabled = (iv >> 8) & 1;
      if (input < 0 || input >= LE_MAX_INPUTS) break;
      const uint32_t excluded = atomic_load_explicit(
          &e->a_excluded_input_mask, memory_order_relaxed);
      /* A loopback-excluded input is never monitored (it carries our output). */
      const int on = (excluded & (1u << input)) ? 0 : enabled;
      const uint32_t valid = e->out_channels >= 32
                                 ? 0xFFFFFFFFu
                                 : ((1u << e->out_channels) - 1u);
      atomic_store_explicit(&e->monitors[input].a_output_mask,
                            (uint32_t)cmd->arg_i & valid, memory_order_relaxed);
      store_i32(&e->monitors[input].a_enabled, on);
      break;
    }
    case LE_CMD_SET_MONITOR_INPUT_DRY: {
      /* No excluded-input recheck (unlike SET_MONITOR_INPUT): the dry send is
       * gated by mon_on in process(), which already drops loopback inputs. */
      const int32_t input = (int32_t)cmd->arg_f & 0xFF;
      if (input < 0 || input >= LE_MAX_INPUTS) break;
      const uint32_t valid = e->out_channels >= 32
                                 ? 0xFFFFFFFFu
                                 : ((1u << e->out_channels) - 1u);
      atomic_store_explicit(&e->monitors[input].a_dry_output_mask,
                            (uint32_t)cmd->arg_i & valid, memory_order_relaxed);
      break;
    }
    case LE_CMD_SET_MONITOR_INPUT_FX: {
      const int32_t input = (cmd->arg_i >> 8) & 0xFF;
      const int32_t index = cmd->arg_i & 0xFF;
      if (input < 0 || input >= LE_MAX_INPUTS || index < 0 ||
          index >= LE_FX_MAX) {
        break;
      }
      le_monitor_input* m = &e->monitors[input];
      store_i32(&m->a_fx_type[index], (int32_t)cmd->arg_f);
      /* Reset the entry's DSP state so a freshly engaged effect starts clean. */
      m->fx.svf_ic1[index] = 0.0f;
      m->fx.svf_ic2[index] = 0.0f;
      m->fx.lfo[index] = 0.0f;
      m->fx.delay_pos[index] = 0;
      m->fx.fx_lp[index] = 0.0f;
      m->fx.grain_phase[index] = 0.0f;
      break;
    }
    case LE_CMD_SET_MONITOR_INPUT_FX_COUNT: {
      const int32_t input = (cmd->arg_i >> 8) & 0xFF;
      int32_t count = cmd->arg_i & 0xFF;
      if (input < 0 || input >= LE_MAX_INPUTS) break;
      if (count < 0) count = 0;
      if (count > LE_FX_MAX) count = LE_FX_MAX;
      store_i32(&e->monitors[input].a_fx_count, count);
      break;
    }
    case LE_CMD_COMMIT_SESSION: {
      const int32_t base = cmd->arg_i;
      if (base <= 0) break;
      /* Establish the master loop and start every imported track (EMPTY with a
       * loaded length) at its whole-loop multiple. The PCM and per-track length
       * were written by le_engine_import_track before this command was posted,
       * so they are visible here (the ring publishes them release/acquire). */
      le_loop_clock_set_length(&e->clock, base);
      e->loop_iteration = 0;
      store_i32(&e->a_master_len, base);
      for (int32_t t = 0; t < e->track_count; ++t) {
        le_track* tr = &e->tracks[t];
        if (load_i32(&tr->a_state) != LE_TRACK_EMPTY) continue;
        const int32_t len = load_i32(&tr->lanes[0].a_len);
        if (len <= 0) continue;
        int32_t k = len / base;
        if (k < 1) k = 1;
        store_i32(&tr->a_multiple, k);
        tr->start_iter = 0;
        store_i32(&tr->a_state, LE_TRACK_PLAYING);
      }
      break;
    }
    default:
      break;
  }
}

/* Resolves a captured latency measurement: cross-correlates the input-magnitude
 * envelope (lat_buf) with the emitted pulse — a length-M boxcar — via a sliding
 * sum, and publishes the peak lag as the round-trip record offset. Integrating
 * over the whole pulse locks onto the sustained echo and rejects the brief
 * crosstalk/noise a first-over-threshold test mis-locked onto. Audio-thread,
 * one-shot at end of capture; bounded (<= lat_buf_cap iterations). */
static void le_latency_resolve(le_engine* e, int sr) {
  const int32_t m = sr / LE_LATENCY_PULSE_DIV; /* pulse length in frames */
  const int32_t n = e->lat_buf_pos;            /* frames captured */
  if (e->lat_buf == NULL || n <= m) {
    store_i32(&e->a_latency_state, LE_LATENCY_TIMEOUT);
    return;
  }
  double window = 0.0;
  for (int32_t i = 0; i < m; ++i) window += e->lat_buf[i];
  double best = window;
  double total = window;
  int32_t best_lag = 0;
  int32_t count = 1;
  for (int32_t lag = 1; lag + m <= n; ++lag) {
    window += e->lat_buf[lag + m - 1] - e->lat_buf[lag - 1];
    total += window;
    ++count;
    if (window > best) {
      best = window;
      best_lag = lag;
    }
  }
  const double avg = total / (double)count;
  /* The echo's correlation peak must stand clearly above the baseline — a
   * level-independent test that works for weak loopback levels; the tiny
   * absolute floor rejects pure silence. */
  if (best < (double)LE_LATENCY_PEAK_RATIO * avg || best / (double)m < 1e-4) {
    store_i32(&e->a_latency_state, LE_LATENCY_TIMEOUT);
    return;
  }
  store_i32(&e->a_record_offset, best_lag);
  atomic_store_explicit(&e->a_latency_ms_bits,
                        f64_to_bits((double)best_lag * 1000.0 / (double)sr),
                        memory_order_relaxed);
  store_i32(&e->a_latency_state, LE_LATENCY_DONE);
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
  /* Loopback-labelled input channels are never recorded, monitored, or
   * metered (they carry our own output and would otherwise inflate the meter). */
  const uint32_t excluded =
      atomic_load_explicit(&e->a_excluded_input_mask, memory_order_relaxed);
  int active_in = 0;
  for (int c = 0; c < ch_in; ++c) {
    if (!(excluded & (1u << c))) ++active_in;
  }

  float in_sumsq = 0.0f;
  float in_peak = 0.0f;
  float out_sumsq = 0.0f;
  /* Per-lane metering accumulators (each track's snapshot mirrors lane 0). */
  float lane_sumsq[LE_MAX_TRACKS][LE_MAX_LANES] = {{0}};
  float lane_peak[LE_MAX_TRACKS][LE_MAX_LANES] = {{0}};

  /* Active lane count per track (control-thread plain int; clamped once). */
  int32_t lane_n[LE_MAX_TRACKS];
  for (int t = 0; t < tc; ++t) lane_n[t] = le_lanes_active(&e->tracks[t]);

  /* Per-lane effects chain, snapshotted once per buffer (control-thread writes
   * are applied at buffer granularity). has_fx gates the playback pass so lanes
   * with no effects skip the chain entirely. The chain is stageless — every
   * active entry colors playback in order. */
  int32_t fx_count[LE_MAX_TRACKS][LE_MAX_LANES];
  int32_t fx_type[LE_MAX_TRACKS][LE_MAX_LANES][LE_FX_MAX];
  float fx_params[LE_MAX_TRACKS][LE_MAX_LANES][LE_FX_MAX][LE_FX_PARAMS];
  int has_fx[LE_MAX_TRACKS][LE_MAX_LANES];
  for (int t = 0; t < tc; ++t) {
    for (int l = 0; l < lane_n[t]; ++l) {
      le_lane* ln = &e->tracks[t].lanes[l];
      has_fx[t][l] = 0;
      int32_t n = load_i32(&ln->a_fx_count);
      if (n < 0) n = 0;
      if (n > LE_FX_MAX) n = LE_FX_MAX;
      fx_count[t][l] = n;
      for (int s = 0; s < n; ++s) {
        const int32_t ty = load_i32(&ln->a_fx_type[s]);
        fx_type[t][l][s] = ty;
        if (ty != LE_FX_NONE) has_fx[t][l] = 1;
        for (int p = 0; p < LE_FX_PARAMS; ++p) {
          fx_params[t][l][s][p] = load_f32(&ln->a_fx_param[s][p]);
        }
      }
    }
  }

  /* Per-input live monitors, snapshotted the same way. mon_on/mon_out gate the
   * monitor pass per hardware input; the chain is stageless. */
  int mon_on[LE_MAX_INPUTS] = {0};
  uint32_t mon_out[LE_MAX_INPUTS];
  uint32_t mon_dry_out[LE_MAX_INPUTS];
  int32_t mon_fx_count[LE_MAX_INPUTS];
  int32_t mon_fx_type[LE_MAX_INPUTS][LE_FX_MAX];
  float mon_fx_params[LE_MAX_INPUTS][LE_FX_MAX][LE_FX_PARAMS];
  for (int c = 0; c < ch_in && c < LE_MAX_INPUTS; ++c) {
    le_monitor_input* m = &e->monitors[c];
    mon_on[c] = load_i32(&m->a_enabled) && !(excluded & (1u << c));
    mon_out[c] = atomic_load_explicit(&m->a_output_mask, memory_order_relaxed);
    mon_dry_out[c] =
        atomic_load_explicit(&m->a_dry_output_mask, memory_order_relaxed);
    int32_t n = load_i32(&m->a_fx_count);
    if (n < 0) n = 0;
    if (n > LE_FX_MAX) n = LE_FX_MAX;
    mon_fx_count[c] = n;
    for (int s = 0; s < n; ++s) {
      mon_fx_type[c][s] = load_i32(&m->a_fx_type[s]);
      for (int p = 0; p < LE_FX_PARAMS; ++p) {
        mon_fx_params[c][s][p] = load_f32(&m->a_fx_param[s][p]);
      }
    }
  }

  const int fx_cap = e->fx_delay_frames;

  for (uint32_t f = 0; f < frames; ++f) {
    float frame_mag = 0.0f; /* max |input| over real (non-loopback) channels */
    float loop_mag = 0.0f;  /* max |input| over loopback channels (latency tap) */
    for (int c = 0; c < ch_in; ++c) {
      const float s = in ? in[f * ch_in + c] : 0.0f;
      const float a = fabsf(s);
      if (excluded & (1u << c)) {
        /* Loopback channels carry our own output back; not recorded/monitored/
         * metered, but they are the round-trip path the latency harness times. */
        if (a > loop_mag) loop_mag = a;
        continue;
      }
      if (a > frame_mag) frame_mag = a;
      in_sumsq += s * s;
    }
    if (frame_mag > in_peak) in_peak = frame_mag;

    /* Sound-activated recording: a track armed for the input-level trigger
     * starts the moment the input crosses the threshold. Fired here — after the
     * input magnitude is known but before st[] is sampled below — so this very
     * frame is captured. */
    for (int qt = 0; qt < tc; ++qt) {
      if (e->tracks[qt].pending_record && e->tracks[qt].pending_trigger == 1 &&
          frame_mag > LE_AUTO_RECORD_THRESHOLD) {
        e->tracks[qt].pending_record = 0;
        e->tracks[qt].pending_trigger = 0;
        store_i32(&e->tracks[qt].a_pending, 0);
        handle_record(e, qt);
      }
    }

    /* The latency pulse returns on the loopback channels when the interface has
     * them (e.g. a Scarlett's "Loop 1/2"); otherwise (a physical cable, or a
     * routed loopback capture device) it returns on the normal inputs. */
    const float lat_mag = excluded != 0u ? loop_mag : frame_mag;

    /* Latency harness takes over the output entirely while measuring. It emits
     * a quiet ~10 ms pulse at the start of a fixed capture window, records the
     * input-magnitude envelope across that window, then cross-correlates it with
     * the pulse to find the round-trip by the correlation peak (le_latency_
     * resolve). The peak — integrated over the whole pulse — locks onto the real
     * echo and ignores the brief direct/crosstalk bleed that a first-over-
     * threshold test mis-reported (especially on low-latency JACK graphs). */
    if (e->lat_active) {
      float broadcast = 0.0f;
      if (e->lat_emit_remaining > 0) {
        /* A tone burst (not a DC level): AC-coupled interface inputs high-pass
         * a constant pulse down to edge transients, leaving nothing to
         * correlate. A 1 kHz burst returns as a sustained AC signal. */
        const int32_t emitted =
            (sr / LE_LATENCY_PULSE_DIV) - e->lat_emit_remaining;
        const float phase = 2.0f * 3.14159265f * LE_LATENCY_TONE_HZ *
                            (float)emitted / (float)sr;
        broadcast = LE_LATENCY_PULSE_AMP * sinf(phase);
        e->lat_emit_remaining--;
      }
      if (e->lat_buf != NULL && e->lat_buf_pos < e->lat_buf_cap) {
        e->lat_buf[e->lat_buf_pos++] = lat_mag;
      }
      /* Resolve on the same frame the window fills (not the next): the two
       * conditions overlap on the fill frame, so this is intentionally not an
       * `else`. */
      if (e->lat_buf == NULL || e->lat_buf_pos >= e->lat_buf_cap) {
        le_latency_resolve(e, sr);
        e->lat_active = 0;
      }
      for (int c = 0; c < ch_out; ++c) {
        out[f * ch_out + c] = broadcast;
        out_sumsq += broadcast * broadcast;
      }
      continue;
    }

    /* Snapshot per-lane playback state once per frame. The track state can flip
     * only between blocks; re-reading per frame is cheap and keeps undo's
     * control-thread a_live swap visible at frame granularity. */
    int32_t st[LE_MAX_TRACKS];
    float* buf[LE_MAX_TRACKS][LE_MAX_LANES];
    float vol[LE_MAX_TRACKS][LE_MAX_LANES];
    int mut[LE_MAX_TRACKS][LE_MAX_LANES];
    int32_t lane_in[LE_MAX_TRACKS][LE_MAX_LANES];
    uint32_t out_mask[LE_MAX_TRACKS][LE_MAX_LANES];
    for (int t = 0; t < tc; ++t) {
      st[t] = load_i32(&e->tracks[t].a_state);
      for (int l = 0; l < lane_n[t]; ++l) {
        le_lane* ln = &e->tracks[t].lanes[l];
        buf[t][l] = ln->pool[load_i32(&ln->a_live)];
        vol[t][l] = load_f32(&ln->a_vol_bits);
        mut[t][l] = load_i32(&ln->a_muted);
        lane_in[t][l] = load_i32(&ln->a_input_channel);
        out_mask[t][l] =
            atomic_load_explicit(&ln->a_output_mask, memory_order_relaxed);
      }
    }
    /* Latency compensation: captured input is recorded this many frames earlier
     * so it aligns with what the player heard. Monitoring stays live (it is no
     * longer folded into the loop buffer at the playhead). */
    const int32_t offset = load_i32(&e->a_record_offset);
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

    /* The looper mix is additive: clear this output frame, then sum every active
     * lane's mono contribution into the output channels its mask selects. */
    for (int c = 0; c < ch_out; ++c) out[f * ch_out + c] = 0.0f;

    for (int t = 0; t < tc; ++t) {
      for (int l = 0; l < lane_n[t]; ++l) {
        /* Clean single-input capture: a lane records exactly its assigned
         * hardware input — never an average of several — or silence when it has
         * no input, an out-of-range/loopback-excluded channel, or no allocated
         * buffer. Sibling lanes are never merged. */
        const int32_t ic = lane_in[t][l];
        float insample = 0.0f;
        if (in && ic >= 0 && ic < ch_in && !(excluded & (1u << ic))) {
          insample = in[f * ch_in + ic];
        }

        /* Real-time null-guard: a lane whose buffer is not yet allocated (the
         * lazy-alloc window, or a count/alloc mismatch) records and plays
         * nothing rather than dereferencing a NULL pool. */
        float* lbuf = buf[t][l];
        if (lbuf == NULL) continue;

        float loopsample = 0.0f;
        if (st[t] == LE_TRACK_RECORDING) {
          if (e->clock.length == 0) {
            /* defining track: no reference loop yet, so no compensation */
            if (e->tracks[t].record_pos < e->max_loop_frames) {
              lbuf[e->tracks[t].record_pos] = insample;
            }
          } else {
            /* new track: phase-locked shared write head (record_pos ==
             * segment*base + position), latency-compensated by dropping the
             * first `offset` frames so it aligns with what the player heard. */
            const int32_t w = e->tracks[t].record_pos - offset;
            if (w >= 0 && w < e->max_loop_frames) {
              lbuf[w] = insample;
            }
          }
        } else if (st[t] == LE_TRACK_OVERDUBBING) {
          /* Mix the existing loop (read before write); record the live input at
           * the compensated position in the current segment for the next pass. */
          loopsample = lbuf[seg_base[t] + pos];
          const int32_t w =
              seg_base[t] + comp_pos(pos, offset, e->clock.length);
          lbuf[w] += insample;
        } else if (st[t] == LE_TRACK_PLAYING) {
          loopsample = lbuf[seg_base[t] + pos];
        }

        /* The lane's mono output: its dry loop content at the lane's playback
         * volume while it sounds, silence otherwise, run through the lane's whole
         * (stageless) effects chain on its `fx` state. Effects run every frame
         * the lane has them (even on silence) so delay tails and LFO phase stay
         * continuous; the wet result is routed only while the lane is audible. */
        const int audible =
            (st[t] == LE_TRACK_PLAYING || st[t] == LE_TRACK_OVERDUBBING) &&
            !mut[t][l];
        float wet = audible ? loopsample * vol[t][l] : 0.0f;
        le_lane* ln = &e->tracks[t].lanes[l];
        if (has_fx[t][l]) {
          wet = fx_apply_chain(&ln->fx, sr, fx_cap, wet, fx_count[t][l],
                               fx_type[t][l], fx_params[t][l]);
        }
        if (audible) {
          for (int c = 0; c < ch_out; ++c) {
            if (out_mask[t][l] & (1u << c)) out[f * ch_out + c] += wet;
          }
        }

        const float la = fabsf(loopsample);
        if (la > lane_peak[t][l]) lane_peak[t][l] = la;
        if (la > frame_trk_peak[t]) frame_trk_peak[t] = la;
        lane_sumsq[t][l] += loopsample * loopsample;
      }
    }

    /* Per-input live monitoring: each enabled hardware input is run through its
     * own (stageless) effect chain and summed into the outputs its mask selects,
     * live and independent of every track. The monitored signal is never
     * recorded. Effects run every frame an input is enabled so delay tails / LFO
     * phase stay continuous. */
    if (in) {
      for (int c = 0; c < ch_in && c < LE_MAX_INPUTS; ++c) {
        if (!mon_on[c]) continue;
        const float clean = in[f * ch_in + c];
        float msample = clean;
        if (mon_fx_count[c] > 0) {
          msample = fx_apply_chain(&e->monitors[c].fx, sr, fx_cap, msample,
                                   mon_fx_count[c], mon_fx_type[c],
                                   mon_fx_params[c]);
        }
        /* Effected route to its outputs; the parallel dry send routes the clean
         * (pre-FX) sample to its own outputs — dry + wet at once. */
        for (int oc = 0; oc < ch_out; ++oc) {
          if (mon_out[c] & (1u << oc)) out[f * ch_out + oc] += msample;
          if (mon_dry_out[c] & (1u << oc)) out[f * ch_out + oc] += clean;
        }
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

    /* Advance the record heads, then the master transport. An auto-multiple
     * track grows freely and is rounded up only when stopped; a fixed-multiple
     * track auto-finalizes after exactly K base loops, continuing into overdub
     * or playback per rec/dub. All cap at the per-track buffer. */
    const int32_t fin_end = e->rec_dub ? LE_TRACK_OVERDUBBING : LE_TRACK_PLAYING;
    for (int t = 0; t < tc; ++t) {
      if (st[t] != LE_TRACK_RECORDING) continue;
      le_track* tr = &e->tracks[t];
      if (e->clock.length == 0) {
        tr->record_pos++;
        if (tr->record_pos >= e->max_loop_frames) {
          finalize_master(e, tr, LE_TRACK_PLAYING);
        }
      } else {
        tr->record_pos++;
        const int32_t eff = le_effective_multiple(e, t);
        const int32_t base = e->clock.length;
        if (eff >= 1 && tr->record_pos - tr->record_start >= eff * base) {
          finalize_new_track(e, tr, fin_end);
        } else if (tr->record_pos >= e->max_loop_frames) {
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
        if (le_loop_clock_tick(&e->clock)) {
          e->loop_iteration++;
          /* The loop just crossed its top (position == 0). Fire loop-top
           * (quantize) pending records here so a deferred start/finalize/overdub
           * lands exactly on the grid. Signal-triggered arms fire above, not
           * here. handle_record enforces one-capturer hand-off. */
          for (int qt = 0; qt < tc; ++qt) {
            if (e->tracks[qt].pending_record &&
                e->tracks[qt].pending_trigger == 0) {
              e->tracks[qt].pending_record = 0;
              store_i32(&e->tracks[qt].a_pending, 0);
              handle_record(e, qt);
            }
          }
        }
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

  /* Input RMS is normalised by the active (non-loopback) channel count only. */
  const uint32_t total_in = frames * (uint32_t)active_in;
  const uint32_t total_out = frames * (uint32_t)ch_out;
  store_f32(&e->a_in_rms_bits,
            total_in ? sqrtf(in_sumsq / (float)total_in) : 0.0f);
  store_f32(&e->a_in_peak_bits, in_peak);
  store_f32(&e->a_out_rms_bits,
            total_out ? sqrtf(out_sumsq / (float)total_out) : 0.0f);
  for (int t = 0; t < tc; ++t) {
    /* Lane buffers are mono: one loop sample accumulated per frame. The shared
     * write head publishes the same growing length onto every active lane. */
    const int recording =
        load_i32(&e->tracks[t].a_state) == LE_TRACK_RECORDING;
    const int32_t rp = e->tracks[t].record_pos;
    for (int l = 0; l < lane_n[t]; ++l) {
      le_lane* ln = &e->tracks[t].lanes[l];
      store_f32(&ln->a_rms_bits,
                frames ? sqrtf(lane_sumsq[t][l] / (float)frames) : 0.0f);
      store_f32(&ln->a_peak_bits, lane_peak[t][l]);
      if (recording) store_i32(&ln->a_len, rp > 0 ? rp : 0);
    }
  }
  store_i32(&e->a_master_pos, e->clock.position);
  atomic_fetch_add_explicit(&e->a_frames, (uint64_t)frames,
                            memory_order_relaxed);
}

/* The miniaudio data + notification callbacks, the device-config build, and the
 * device lifecycle (open/start/stop/close) now live behind the device-backend
 * seam in engine_miniaudio.c; this file keeps only le_engine_process (the
 * real-time core they pump) and the backend-agnostic lifecycle dispatch below. */

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
    ln->fx.svf_ic1[s] = 0.0f;
    ln->fx.svf_ic2[s] = 0.0f;
    ln->fx.lfo[s] = 0.0f;
    free(ln->fx.delay[s]);
    ln->fx.delay[s] = NULL;
    ln->fx.delay_pos[s] = 0;
    ln->fx.fx_lp[s] = 0.0f;
    ln->fx.grain_phase[s] = 0.0f;
  }
}

/* Resets a live monitor input to defaults (disabled, full stereo output, empty
 * chain), clearing its effect DSP state and releasing its delay lines. */
static void le_monitor_input_reset(le_monitor_input* m) {
  store_i32(&m->a_enabled, 0);
  atomic_store_explicit(&m->a_output_mask, 0x3u, memory_order_relaxed);
  atomic_store_explicit(&m->a_dry_output_mask, 0u, memory_order_relaxed);
  store_i32(&m->a_fx_count, 0);
  for (int s = 0; s < LE_FX_MAX; ++s) {
    store_i32(&m->a_fx_type[s], LE_FX_NONE);
    for (int p = 0; p < LE_FX_PARAMS; ++p) {
      store_f32(&m->a_fx_param[s][p], 0.0f);
    }
    m->fx.svf_ic1[s] = 0.0f;
    m->fx.svf_ic2[s] = 0.0f;
    m->fx.lfo[s] = 0.0f;
    free(m->fx.delay[s]);
    m->fx.delay[s] = NULL;
    m->fx.delay_pos[s] = 0;
    m->fx.fx_lp[s] = 0.0f;
    m->fx.grain_phase[s] = 0.0f;
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

  store_i32(&engine->a_sample_rate, sample_rate);
  store_i32(&engine->a_in_channels, input_channels);
  store_i32(&engine->a_out_channels, output_channels);
  /* Default to WASAPI; le_engine_start republishes the negotiated backend after
   * device open (always WASAPI in this build). */
  store_i32(&engine->a_active_backend, LE_BACKEND_WASAPI);
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

int le_label_is_loopback(const char* label) {
  /* Case-insensitive "loop" match. This covers both the generic "Loopback"
   * label and the Focusrite convention of naming the two loopback inputs
   * "Loop 1" / "Loop 2" (verified on a Scarlett 4i4). "loop" subsumes
   * "loopback", so one substring check handles both. */
  return contains_ci(label, "loop");
}

uint32_t le_excluded_mask_from_names(le_channel_name_fn get_name, void* ctx,
                                     int channel_count) {
  /* Pure bit-setting core shared by every platform's label probe: walk the
   * input channels, ask the caller's provider for each channel's name, and set
   * the bit for any name le_label_is_loopback matches. The OS-specific part is
   * only the *source* of the names (Core Audio on macOS, ASIO on Windows), so
   * this stays unit-testable with a fake provider and free of any OS calls.
   * Channels beyond LE_MAX_CHANNELS (the mask's width) are ignored. */
  if (get_name == NULL) return 0;
  uint32_t mask = 0;
  const int n =
      channel_count < LE_MAX_CHANNELS ? channel_count : LE_MAX_CHANNELS;
  for (int c = 0; c < n; ++c) {
    const char* name = get_name(ctx, c);
    if (name != NULL && le_label_is_loopback(name)) {
      mask |= (1u << c);
    }
  }
  return mask;
}

void le_find_loopback(ma_context* ctx, le_loopback_info* out,
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
  le_find_loopback(&ctx, out, NULL);
  ma_context_uninit(&ctx);
  return LE_OK;
}

/* ---- device enumeration & pinning ---- */

/* Serializes a miniaudio device id into a printable, round-trippable token.
 * The backend-specific encoding (char string vs WASAPI wchar string) lives
 * behind the platform seam so this portable core stays free of OS #ifs; see
 * le_platform_device_id_to_str (engine_platform.h). Enumeration and resolution
 * both route through here, so the token round-trips via strcmp on every OS. */
static void device_id_to_str(const ma_device_id* id, char* out, size_t cap) {
  le_platform_device_id_to_str(id, out, cap);
}

static void device_info_copy(le_device_info* dst, const ma_device_info* src) {
  /* Zero everything first so the WASAPI path never surfaces stack garbage for
   * fields it does not fill (channel counts, the ASIO-only buffer/rate sets). */
  memset(dst, 0, sizeof(*dst));
  device_id_to_str(&src->id, dst->id, sizeof(dst->id));
  strncpy(dst->name, src->name, sizeof(dst->name) - 1);
  dst->name[sizeof(dst->name) - 1] = '\0';
  dst->is_default = src->isDefault ? 1 : 0;
  /* WASAPI enumeration reports no per-device channel count / ASIO option sets
   * here; they stay 0 (unknown), filled only by the ASIO driver probe. */
}

/* Fills `out` (room for `max`) with the host's playback or capture devices and
 * writes the count into *count. Uses a transient context so it never disturbs a
 * running device. `capture` selects the direction. Externally linked (declared
 * in engine_private.h) so the Linux JACK pin hook can resolve friendly device
 * names through it; defined only here. */
int32_t enumerate_devices(le_device_info* out, int32_t max, int32_t* count,
                          int capture) {
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
int le_resolve_device_id(ma_context* ctx, int capture, const char* want,
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

/* ---- ASIO bridge math (pure; see engine_internal.h) ----------------------- *
 *
 * These run in the ASIO real-time callback but touch no engine state and no ASIO
 * headers, so they live here and are unit-tested directly. All integer formats
 * are read/written little-endian byte-by-byte so the conversion is correct
 * regardless of host endianness (the *LSB ASIO formats are always little-endian).
 */

/* Byte width of one sample in each native format. */
static int le_sample_bytes(le_sample_fmt fmt) {
  switch (fmt) {
    case LE_SMP_I16: return 2;
    case LE_SMP_I24: return 3;
    case LE_SMP_I32: return 4;
    case LE_SMP_F32: return 4;
  }
  return 4;
}

/* One little-endian native sample -> normalized f32 (integer formats map their
 * full range to [-1, 1)). */
static float le_native_to_f32(const uint8_t* p, le_sample_fmt fmt) {
  switch (fmt) {
    case LE_SMP_I16: {
      int16_t v = (int16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
      return (float)v / 32768.0f;
    }
    case LE_SMP_I24: {
      int32_t v = (int32_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                            ((uint32_t)p[2] << 16));
      if (v & 0x00800000) v |= (int32_t)0xFF000000; /* sign-extend 24 -> 32 */
      return (float)v / 8388608.0f;
    }
    case LE_SMP_I32: {
      int32_t v = (int32_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                            ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24));
      return (float)v / 2147483648.0f;
    }
    case LE_SMP_F32: {
      uint32_t bits = (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                      ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
      float f;
      memcpy(&f, &bits, sizeof(f));
      return f;
    }
  }
  return 0.0f;
}

/* Rounds + clamps to a signed integer range, then writes `bytes` little-endian. */
static void le_write_le_int(uint8_t* p, double scaled, double lo, double hi,
                            int bytes) {
  if (scaled > hi) scaled = hi;
  if (scaled < lo) scaled = lo;
  int64_t v = (int64_t)(scaled < 0 ? scaled - 0.5 : scaled + 0.5);
  for (int b = 0; b < bytes; ++b) p[b] = (uint8_t)((v >> (8 * b)) & 0xFF);
}

/* Normalized f32 -> one little-endian native sample (clamped to the format). */
static void le_f32_to_native(uint8_t* p, float f, le_sample_fmt fmt) {
  switch (fmt) {
    case LE_SMP_I16:
      le_write_le_int(p, (double)f * 32768.0, -32768.0, 32767.0, 2);
      break;
    case LE_SMP_I24:
      le_write_le_int(p, (double)f * 8388608.0, -8388608.0, 8388607.0, 3);
      break;
    case LE_SMP_I32:
      le_write_le_int(p, (double)f * 2147483648.0, -2147483648.0, 2147483647.0,
                      4);
      break;
    case LE_SMP_F32: {
      uint32_t bits;
      memcpy(&bits, &f, sizeof(bits));
      p[0] = (uint8_t)(bits & 0xFF);
      p[1] = (uint8_t)((bits >> 8) & 0xFF);
      p[2] = (uint8_t)((bits >> 16) & 0xFF);
      p[3] = (uint8_t)((bits >> 24) & 0xFF);
      break;
    }
  }
}

void le_deinterleave_in(float* out_interleaved, const void* native_block,
                        le_sample_fmt fmt, int chan, int channel_count,
                        int frames) {
  if (out_interleaved == NULL || native_block == NULL || channel_count <= 0 ||
      chan < 0 || chan >= channel_count) {
    return;
  }
  const int bytes = le_sample_bytes(fmt);
  const uint8_t* src = (const uint8_t*)native_block;
  for (int f = 0; f < frames; ++f) {
    out_interleaved[(size_t)f * channel_count + chan] =
        le_native_to_f32(src + (size_t)f * bytes, fmt);
  }
}

void le_interleave_out(void* native_block, const float* in_interleaved,
                       le_sample_fmt fmt, int chan, int channel_count,
                       int frames) {
  if (native_block == NULL || in_interleaved == NULL || channel_count <= 0 ||
      chan < 0 || chan >= channel_count) {
    return;
  }
  const int bytes = le_sample_bytes(fmt);
  uint8_t* dst = (uint8_t*)native_block;
  for (int f = 0; f < frames; ++f) {
    le_f32_to_native(dst + (size_t)f * bytes,
                     in_interleaved[(size_t)f * channel_count + chan], fmt);
  }
}

int32_t le_asio_pick_buffer(int32_t requested, int32_t min, int32_t max,
                            int32_t preferred, int32_t granularity) {
  /* Fixed-size driver: only `preferred` is selectable. */
  if (granularity == 0) return preferred;
  /* A request the driver can't honor (outside its window) -> preferred. */
  if (requested < min || requested > max) return preferred;

  if (granularity == -1) {
    /* Powers of two only: snap to the nearest power of two within [min,max]
     * (preferring the larger on a tie). */
    int32_t best = 0;
    int64_t best_dist = 0;
    for (int64_t p = 1; p <= max; p <<= 1) {
      if (p < min) continue;
      int64_t d = p > requested ? p - requested : requested - p;
      if (best == 0 || d < best_dist || (d == best_dist && p > best)) {
        best = (int32_t)p;
        best_dist = d;
      }
    }
    return best != 0 ? best : preferred;
  }

  /* granularity > 0: linear steps from `min`. Snap to the nearest valid step,
   * clamped to the largest step that does not exceed `max`. */
  int64_t steps = ((int64_t)requested - min + granularity / 2) / granularity;
  int64_t snapped = (int64_t)min + steps * granularity;
  int64_t last = (int64_t)min + (((int64_t)max - min) / granularity) * granularity;
  if (snapped > last) snapped = last;
  if (snapped < min) snapped = min;
  return (int32_t)snapped;
}

/* Selects the device backend for a requested le_audio_backend. The default build
 * ships only the miniaudio backend, so every choice resolves to it. In a
 * LOOPY_ENABLE_ASIO Windows build, LE_BACKEND_ASIO resolves to the ASIO backend;
 * the reference to le_asio_backend lives inside the guard, so the default build
 * never links any le_asio_* symbol. */
const le_device_backend* le_select_backend(int32_t backend) {
#if defined(_WIN32) && defined(LOOPY_ENABLE_ASIO)
  if (backend == LE_BACKEND_ASIO) return &le_asio_backend;
#endif
  (void)backend;
  return &le_miniaudio_backend;
}

#if !(defined(_WIN32) && defined(LOOPY_ENABLE_ASIO))
/* ASIO-disabled stub: no ASIO drivers exist, so enumeration is always empty. The
 * real probe lives in win_asio_device.cpp behind LOOPY_ENABLE_ASIO. Keeping the
 * FFI symbol defined in every build lets the Dart layer call it unconditionally
 * (it returns [] / count 0 off Windows or on the default build). */
int32_t le_enumerate_asio_drivers(le_device_info* out, int32_t max,
                                  int32_t* count) {
  if (out == NULL || count == NULL || max <= 0) return LE_ERR_INVALID;
  *count = 0;
  return LE_OK;
}
#endif

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
        free(ln->fx.delay[s]);
      }
    }
  }
  for (int c = 0; c < LE_MAX_INPUTS; ++c) {
    for (int s = 0; s < LE_FX_MAX; ++s) {
      free(engine->monitors[c].fx.delay[s]);
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

  /* Open the device through the selected backend (miniaudio in this build). The
   * backend builds the device config, resolves pins/loopback, opens the device
   * (shared mode), and reports the negotiated parameters back. */
  const le_device_backend* be = le_select_backend(config->backend);
  le_device_open_result info;
  int32_t open_result = be->open(engine, config, &info);
  /* ASIO fallback: a requested ASIO open that fails (build off, no/missing
   * driver, driver busy, init failure) retries once on miniaudio/WASAPI with the
   * same config (channel fields stay 0 = device default). info.active_backend
   * then reflects what actually opened, so the UI shows reality. It resets no
   * config fields, so it stays inline. */
  if (config->backend == LE_BACKEND_ASIO && open_result != LE_OK) {
    be = &le_miniaudio_backend;
    open_result = be->open(engine, config, &info);
  }
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
  out->redo_depth = load_i32(&tr->a_redo_depth);
  out->rms = load_f32(&l0->a_rms_bits);
  out->peak = load_f32(&l0->a_peak_bits);
  out->input_mask = le_lane_input_bits(l0);
  out->output_mask =
      atomic_load_explicit(&l0->a_output_mask, memory_order_relaxed);
  out->lane_count = le_lanes_active(tr);
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
  out->active_backend = load_i32(&engine->a_active_backend);
  out->track_count = engine->track_count;
  for (int t = 0; t < LE_MAX_TRACKS; ++t) {
    le_fill_track_snapshot(&engine->tracks[t], t < engine->track_count,
                           &out->tracks[t]);
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
    out->lane_count = 1;
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

/* Musical default parameters for a freshly engaged effect type (so picking an
 * effect sounds like something before the user tweaks it). */
static void le_fx_default_params(int32_t type, float out[LE_FX_PARAMS]) {
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
      break;
    case LE_FX_ECHO:
      out[0] = 0.45f; /* time */
      out[1] = 0.5f;  /* feedback */
      out[2] = 0.35f; /* wet mix */
      break;
    default:
      out[0] = out[1] = out[2] = 0.0f;
      break;
  }
}

/* Allocates the delay ring for a chain entry (control thread) when its type
 * needs one (LE_FX_DELAY, LE_FX_ECHO, or the LE_FX_OCTAVER grain ring), keeping
 * it for reuse once allocated, and seeds the type's musical defaults only when
 * the type actually changes (so a reorder doesn't wipe the user's tweaks).
 * Returns LE_OK, or LE_ERR_INVALID on allocation failure. */
static int32_t le_fx_prepare_entry(le_fx_state* fx, _Atomic int32_t* a_type,
                                   _Atomic uint32_t a_param[][LE_FX_PARAMS],
                                   int32_t index, int32_t type,
                                   int32_t delay_cap) {
  if ((type == LE_FX_DELAY || type == LE_FX_ECHO || type == LE_FX_OCTAVER) &&
      fx->delay[index] == NULL) {
    const int32_t cap = delay_cap > 0 ? delay_cap : 48000;
    float* line = (float*)calloc((size_t)cap, sizeof(float));
    if (line == NULL) return LE_ERR_INVALID;
    fx->delay[index] = line;
  }
  if (load_i32(a_type + index) != type) {
    float defaults[LE_FX_PARAMS];
    le_fx_default_params(type, defaults);
    for (int p = 0; p < LE_FX_PARAMS; ++p) {
      store_f32(&a_param[index][p], defaults[p]);
    }
  }
  return LE_OK;
}

int32_t le_engine_set_lane_fx(le_engine* engine, int32_t channel, int32_t lane,
                              int32_t index, int32_t type) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (lane < 0 || lane >= LE_MAX_LANES) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (type < LE_FX_NONE || type > LE_FX_ECHO) return LE_ERR_INVALID;
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
                                    int32_t enabled, int32_t output_mask) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  const int32_t iv = (input & 0xFF) | (enabled ? 0x100 : 0);
  return le_push(engine, LE_CMD_SET_MONITOR_INPUT, output_mask, (float)iv);
}

int32_t le_engine_set_monitor_input_dry(le_engine* engine, int32_t input,
                                        int32_t dry_output_mask) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  return le_push(engine, LE_CMD_SET_MONITOR_INPUT_DRY, dry_output_mask,
                 (float)input);
}

int32_t le_engine_set_monitor_input_fx(le_engine* engine, int32_t input,
                                       int32_t index, int32_t type) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (type < LE_FX_NONE || type > LE_FX_ECHO) return LE_ERR_INVALID;
  le_monitor_input* m = &engine->monitors[input];
  if (le_fx_prepare_entry(&m->fx, m->a_fx_type, m->a_fx_param, index, type,
                          engine->fx_delay_frames) != LE_OK) {
    return LE_ERR_INVALID;
  }
  return le_push(engine, LE_CMD_SET_MONITOR_INPUT_FX, (input << 8) | index,
                 (float)type);
}

int32_t le_engine_set_monitor_input_fx_count(le_engine* engine, int32_t input,
                                             int32_t count) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  if (count < 0) count = 0;
  if (count > LE_FX_MAX) count = LE_FX_MAX;
  return le_push(engine, LE_CMD_SET_MONITOR_INPUT_FX_COUNT,
                 (input << 8) | count, 0.0f);
}

int32_t le_engine_set_monitor_input_fx_param(le_engine* engine, int32_t input,
                                             int32_t index, int32_t param,
                                             float value) {
  if (engine == NULL) return LE_ERR_INVALID;
  if (input < 0 || input >= LE_MAX_INPUTS) return LE_ERR_INVALID;
  if (index < 0 || index >= LE_FX_MAX) return LE_ERR_INVALID;
  if (param < 0 || param >= LE_FX_PARAMS) return LE_ERR_INVALID;
  if (value < 0.0f) value = 0.0f;
  if (value > 1.0f) value = 1.0f;
  store_f32(&engine->monitors[input].a_fx_param[index][param], value);
  return LE_OK;
}

/* ---- session persistence ---- *
 * Lane buffers are mono (one sample per frame), so a stem is just the loop
 * samples; routing to channels is a playback concern, not stored. Export/import
 * operate on lane 0 — multi-lane stems are a later revision. */

int32_t le_engine_export_track(le_engine* engine, int32_t channel, float* out,
                               int32_t max_frames) {
  if (engine == NULL || out == NULL) return 0;
  if (channel < 0 || channel >= engine->track_count) return 0;
  if (max_frames <= 0) return 0;
  le_lane* ln = &engine->tracks[channel].lanes[0];
  int32_t n = load_i32(&ln->a_len);
  if (n > max_frames) n = max_frames;
  if (n <= 0) return 0;
  const int live = load_i32(&ln->a_live);
  if (ln->pool[live] == NULL) return 0;
  memcpy(out, ln->pool[live], (size_t)n * sizeof(float));
  return n;
}

int32_t le_engine_import_track(le_engine* engine, int32_t channel,
                               const float* pcm, int32_t frames) {
  if (engine == NULL || pcm == NULL) return LE_ERR_INVALID;
  if (!atomic_load_explicit(&engine->a_configured, memory_order_acquire)) {
    return LE_ERR_NOT_RUNNING;
  }
  if (channel < 0 || channel >= engine->track_count) return LE_ERR_INVALID;
  if (frames <= 0) return LE_ERR_INVALID;
  le_track* t = &engine->tracks[channel];
  /* Importing targets an empty track: its buffers are not read by the audio
   * thread, so the control thread can fill lane 0 directly. */
  if (load_i32(&t->a_state) != LE_TRACK_EMPTY) return LE_ERR_INVALID;
  /* Reject (rather than silently truncate) a stem that exceeds the buffer cap,
   * so a corrupted/foreign loop fails loudly instead of loading clipped. */
  if (frames > engine->max_loop_frames) return LE_ERR_INVALID;
  le_lane* ln = &t->lanes[0];
  const int live = load_i32(&ln->a_live);
  if (ln->pool[live] == NULL) return LE_ERR_INVALID;
  const size_t span = (size_t)frames;
  const size_t cap = (size_t)engine->max_loop_frames;
  memcpy(ln->pool[live], pcm, span * sizeof(float));
  if (span < cap) {
    memset(ln->pool[live] + span, 0, (cap - span) * sizeof(float));
  }
  store_i32(&ln->a_len, frames);
  t->start_iter = 0;
  return LE_OK;
}

int32_t le_engine_commit_session(le_engine* engine, int32_t base_frames) {
  return le_push(engine, LE_CMD_COMMIT_SESSION, base_frames, 0.0f);
}

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
