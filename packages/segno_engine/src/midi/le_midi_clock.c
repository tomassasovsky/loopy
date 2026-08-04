/*
 * le_midi_clock.c — see le_midi_clock.h.
 *
 * Pure value logic: every function is total over its arguments, safe on any
 * thread including the audio callback (no allocation, no atomics, no I/O).
 */
#include "le_midi_clock.h"

#include <stddef.h> /* NULL */

#include "tempo_grid.h" /* le_tempo_grid, le_grid_div_frames, LE_GRID_DIV_QUARTER */

void le_midi_clock_reset(le_midi_clock_gen* g) {
  if (g == NULL) return;
  g->active_prev = 0;
  g->active_frames = 0;
}

int32_t le_midi_clock_advance(le_midi_clock_gen* g, int32_t frames, float bpm,
                              int32_t ts_num, int32_t ts_den,
                              int32_t sample_rate, int transport_active,
                              int gate_open, uint8_t* out, int32_t out_cap) {
  if (g == NULL || out == NULL || out_cap <= 0 || frames < 0) return 0;

  int32_t n = 0;
  const int active_now = gate_open && transport_active;

  if (active_now && !g->active_prev) {
    /* idle -> active edge (which also covers the gate opening onto an
     * already-running transport, since a gated-closed generator is held at
     * active_prev == 0 below): the loop downbeat. Anchor a fresh tick epoch
     * so the first tick lands exactly one PPQN interval after THIS Start,
     * never inheriting frames counted before it. */
    g->active_frames = 0;
    if (n < out_cap) out[n++] = LE_MIDI_CLOCK_START;
  } else if (!active_now && g->active_prev) {
    if (n < out_cap) out[n++] = LE_MIDI_CLOCK_STOP;
  }

  if (active_now) {
    const le_tempo_grid grid = {bpm, ts_num, ts_den, sample_rate};
    const double frames_per_quarter =
        le_grid_div_frames(&grid, LE_GRID_DIV_QUARTER);
    if (frames_per_quarter > 0.0) {
      const double frames_per_tick =
          frames_per_quarter / (double)LE_MIDI_CLOCK_PPQN;
      const uint64_t before = g->active_frames;
      const uint64_t after = before + (uint64_t)frames;
      /* Boundary count re-derived from the ABSOLUTE epoch each call (never a
       * decremented remainder) — the same drift-free, double-count-proof
       * shape as le_grid_next_boundary's "computed from k, never by
       * stepping": ticks_before always equals the previous call's
       * ticks_after exactly, so no boundary is ever reported twice and none
       * is ever skipped across a block edge. */
      const int64_t ticks_before =
          (int64_t)((double)before / frames_per_tick);
      const int64_t ticks_after = (int64_t)((double)after / frames_per_tick);
      const int64_t new_ticks = ticks_after - ticks_before;
      for (int64_t i = 0; i < new_ticks && n < out_cap; ++i) {
        out[n++] = LE_MIDI_CLOCK_TICK;
      }
    }
    g->active_frames += (uint64_t)frames;
  } else {
    g->active_frames = 0;
  }

  g->active_prev = active_now;
  return n;
}
