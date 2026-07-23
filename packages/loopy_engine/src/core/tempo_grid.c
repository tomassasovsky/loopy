/*
 * tempo_grid.c — pure-value musical-grid math (see tempo_grid.h).
 *
 * No engine state, no atomics, no allocation: every function is a total
 * function of its arguments, safe on any thread including the audio callback.
 */
#include "tempo_grid.h"

#include <math.h>
#include <stddef.h> /* NULL */

int le_grid_signature_valid(int32_t num, int32_t den) {
  /* The 17 Sheeran signatures (§5.9.1): x/4 for 2..7, x/8 for 5..15. */
  if (den == 4) return num >= 2 && num <= 7;
  if (den == 8) return num >= 5 && num <= 15;
  return 0;
}

double le_grid_frames_per_beat_unit(const le_tempo_grid* g) {
  /* Positive-form guard: !(x > 0) also rejects NaN, so a non-finite bpm can
   * never produce a NaN interval downstream (a NaN interval would make
   * le_grid_next_boundary spin forever — llround(NaN) is 0 here). */
  if (g == NULL || !(g->bpm > 0.0f) || g->sample_rate <= 0) return 0.0;
  return (double)g->sample_rate * 60.0 / (double)g->bpm;
}

double le_grid_frames_per_bar(const le_tempo_grid* g) {
  if (g == NULL || g->ts_num <= 0) return 0.0;
  return le_grid_frames_per_beat_unit(g) * (double)g->ts_num;
}

double le_grid_div_frames(const le_tempo_grid* g, int32_t div) {
  if (g == NULL) return 0.0;
  const double fpb = le_grid_frames_per_beat_unit(g);
  if (!(fpb > 0.0) || g->ts_den <= 0) return 0.0;
  switch (div) {
    case LE_GRID_DIV_BAR:
      return le_grid_frames_per_bar(g);
    /* Absolute note values: a whole note is ts_den beat units, so a 1/N note
     * is fpb * ts_den / N regardless of the signature's numerator. */
    case LE_GRID_DIV_HALF:
      return fpb * (double)g->ts_den / 2.0;
    case LE_GRID_DIV_QUARTER:
      return fpb * (double)g->ts_den / 4.0;
    case LE_GRID_DIV_EIGHTH:
      return fpb * (double)g->ts_den / 8.0;
    case LE_GRID_DIV_SIXTEENTH:
      return fpb * (double)g->ts_den / 16.0;
    default:
      return 0.0; /* OFF or unknown */
  }
}

int64_t le_grid_next_boundary(const le_tempo_grid* g, int64_t pos,
                              int32_t div) {
  const double interval = le_grid_div_frames(g, div);
  if (!(interval > 0.0) || pos < 0) return -1;
  /* Past 2^52 frames a double no longer holds integer positions exactly, so
   * the nearest-frame guarantee (and llround itself, past 2^63) breaks down.
   * 2^52 frames is ~3,000 years at 48 kHz — refuse rather than mis-round. */
  if (pos >= ((int64_t)1 << 52)) return -1;
  /* First multiple of `interval` strictly after `pos`, rendered to the nearest
   * frame FROM ITS INDEX k (never by stepping), so no drift accumulates. The
   * llround guard below covers the k where rounding lands exactly on pos. */
  int64_t k = (int64_t)floor((double)pos / interval) + 1;
  int64_t boundary = (int64_t)llround((double)k * interval);
  while (boundary <= pos) {
    ++k;
    boundary = (int64_t)llround((double)k * interval);
  }
  return boundary;
}

int32_t le_grid_bars_for_loop(const le_tempo_grid* g, int32_t loop_frames) {
  const double fpbar = le_grid_frames_per_bar(g);
  if (!(fpbar > 0.0) || loop_frames <= 0) return 0;
  int32_t bars = (int32_t)llround((double)loop_frames / fpbar);
  if (bars < 1) bars = 1;
  return bars;
}

float le_grid_derive_bpm(int32_t loop_frames, int32_t ts_num,
                         int32_t sample_rate, int32_t* out_bars) {
  if (out_bars != NULL) *out_bars = 0;
  if (loop_frames <= 0 || ts_num <= 0 || sample_rate <= 0 || out_bars == NULL) {
    return 0.0f;
  }
  /* A loop of `b` whole bars holds b * ts_num beat units, so
   * bpm(b) = 60 * sample_rate * b * ts_num / loop_frames — strictly
   * increasing in b. The b nearest 120 is therefore the integer neighborhood
   * of 120/per_bar, clamped into the whole-bar window
   * [ceil(MIN/per_bar), floor(MAX/per_bar)] — O(1), no walk (the previous
   * walk's int32 index overflowed before the >MAX break for extreme-but-valid
   * arguments). Ties choose the SLOWER tempo (fewer bars). */
  const double per_bar = 60.0 * (double)sample_rate * (double)ts_num /
                         (double)loop_frames; /* bpm(1) */
  if (!(per_bar > 0.0)) return 0.0f;
  int64_t bmin = (int64_t)ceil((double)LE_GRID_TEMPO_MIN / per_bar - 1e-9);
  if (bmin < 1) bmin = 1;
  const int64_t bmax =
      (int64_t)floor((double)LE_GRID_TEMPO_MAX / per_bar + 1e-9);
  if (bmax < bmin) {
    /* No whole-bar tempo fits the window. bpm(b) grows by a factor <= 2 per
     * step while the window spans 10x, so the only way here is a loop shorter
     * than one bar at the max tempo: clamp to the ceiling, one bar. */
    *out_bars = 1;
    return LE_GRID_TEMPO_MAX;
  }
  const int64_t b0 = llround(120.0 / per_bar);
  int64_t best = 0;
  double best_d = 0.0;
  for (int64_t k = b0 - 1; k <= b0 + 1; ++k) {
    int64_t b = k;
    if (b < bmin) b = bmin;
    if (b > bmax) b = bmax;
    const double d = fabs(per_bar * (double)b - 120.0);
    if (best == 0 || d < best_d || (d == best_d && b < best)) {
      best = b;
      best_d = d;
    }
  }
  if (best > INT32_MAX) { /* bar count would overflow int32: stay grid-free */
    *out_bars = 0;
    return 0.0f;
  }
  *out_bars = (int32_t)best;
  return (float)(per_bar * (double)best);
}

int32_t le_grid_beat_at(int32_t pos, int32_t len, int32_t total_beats) {
  if (len <= 0 || total_beats <= 0) return 0;
  return (int32_t)(((int64_t)pos * (int64_t)total_beats) / (int64_t)len);
}

float le_grid_bpm_for_length(int32_t loop_frames, int32_t bars,
                             int32_t ts_num, int32_t sample_rate) {
  if (loop_frames <= 0 || bars <= 0 || ts_num <= 0 || sample_rate <= 0) {
    return 0.0f;
  }
  /* frames_per_bar = sample_rate * 60 * ts_num / bpm (le_grid_frames_per_bar,
   * with frames_per_bar == loop_frames / bars) inverted for bpm. */
  const double bpm = 60.0 * (double)sample_rate * (double)ts_num *
                     (double)bars / (double)loop_frames;
  if (!(bpm > 0.0)) return 0.0f;
  if (bpm < (double)LE_GRID_TEMPO_MIN) return LE_GRID_TEMPO_MIN;
  if (bpm > (double)LE_GRID_TEMPO_MAX) return LE_GRID_TEMPO_MAX;
  return (float)bpm;
}

/* ---- loop-locked subdivision grid (A3) — see the header block comment ---- */

int le_grid_loop_subdiv_ratio(int32_t total_beats, int32_t ts_num,
                              int32_t ts_den, int32_t div, int64_t* out_num,
                              int64_t* out_den) {
  if (out_num == NULL || out_den == NULL) return 0;
  *out_num = 0;
  *out_den = 1;
  if (total_beats <= 0 || ts_num <= 0 || ts_den <= 0) return 0;
  switch (div) {
    case LE_GRID_DIV_BAR:
      /* total_beats is bars * ts_num by construction, so this is a whole
       * number — but the rational form costs nothing and never assumes it. */
      *out_num = (int64_t)total_beats;
      *out_den = (int64_t)ts_num;
      return 1;
    /* Absolute note values: one beat is the 1/ts_den note, so a 1/N note is
     * ts_den / N beats and the loop holds total_beats * N / ts_den of them —
     * fractional whenever the note value does not divide the signature (a 3/4
     * bar holds 1.5 half notes), which is exactly why this is a rational. */
    case LE_GRID_DIV_HALF:
      *out_num = (int64_t)total_beats * 2;
      *out_den = (int64_t)ts_den;
      return 1;
    case LE_GRID_DIV_QUARTER:
      *out_num = (int64_t)total_beats * 4;
      *out_den = (int64_t)ts_den;
      return 1;
    case LE_GRID_DIV_EIGHTH:
      *out_num = (int64_t)total_beats * 8;
      *out_den = (int64_t)ts_den;
      return 1;
    case LE_GRID_DIV_SIXTEENTH:
      *out_num = (int64_t)total_beats * 16;
      *out_den = (int64_t)ts_den;
      return 1;
    default:
      return 0; /* OFF or unknown */
  }
}

int32_t le_grid_loop_subdiv_at(int32_t pos, int32_t len, int64_t sub_num,
                               int64_t sub_den) {
  if (pos < 0 || len <= 0 || sub_num <= 0 || sub_den <= 0) return 0;
  return (int32_t)(((int64_t)pos * sub_num) / ((int64_t)len * sub_den));
}

int32_t le_grid_loop_subdiv_start(int32_t idx, int32_t len, int64_t sub_num,
                                  int64_t sub_den) {
  if (idx <= 0 || len <= 0 || sub_num <= 0 || sub_den <= 0) return 0;
  int64_t p = ((int64_t)idx * (int64_t)len * sub_den + sub_num - 1) / sub_num;
  if (p > (int64_t)len) p = (int64_t)len;
  return (int32_t)p;
}

int32_t le_grid_loop_next_subdiv(int32_t pos, int32_t len, int64_t sub_num,
                                 int64_t sub_den) {
  if (pos < 0 || pos >= len || len <= 0 || sub_num <= 0 || sub_den <= 0) {
    return -1; /* pos must lie inside the loop for "strictly after" to hold */
  }
  const int32_t idx = le_grid_loop_subdiv_at(pos, len, sub_num, sub_den);
  const int32_t p = le_grid_loop_subdiv_start(idx + 1, len, sub_num, sub_den);
  /* Past the loop's last boundary the next one is the wrap itself. start()
   * already clamps to len; the max() below only guards degenerate sub-frame
   * subdivisions where start(idx + 1) could land at or before pos. */
  return p > pos ? p : len;
}
