/*
 * tempo_grid.h — pure-value musical-grid math over {bpm, ts_num, ts_den,
 * sample_rate}.
 *
 * Pure value logic (no atomics, no allocation, no engine state): the audio
 * thread computes beat/bar/subdivision geometry from a stack copy of the
 * published tempo state, and the control thread / tests call the same
 * functions with plain values. Mirrors loop_clock.h in spirit: small,
 * self-contained, unit-testable in isolation.
 *
 * BEAT UNIT: the beat is the TIME-SIGNATURE DENOMINATOR NOTE (in 7/8 the grid
 * runs on eighth notes; BPM counts denominator notes per minute). The
 * denominator therefore cancels out of frames-per-beat-unit and frames-per-bar
 * and only enters the absolute note-value subdivisions (1/2 .. 1/16 note).
 * Sheeran Looper X semantics, per the plan's D1/D7 (index Architecture §1).
 */
#ifndef LOOPY_TEMPO_GRID_H
#define LOOPY_TEMPO_GRID_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Engine-wide tempo clamp (BPM). Deliberately a superset of the Sheeran's
 * 30–280: loopy keeps its historical 30–300 range (documented plan deviation). */
#define LE_GRID_TEMPO_MIN 30.0f
#define LE_GRID_TEMPO_MAX 300.0f

/* Musical quantization granularity (the value of the engine's a_quantize_div /
 * le_snapshot.quantize_div and of LE_CMD_SET_QUANTIZE_DIV's arg_i). OFF (0) is
 * the grid-off default — note this deliberately differs from the pre-2f0513a
 * stack, whose quantize defaulted to BAR. The note values are absolute (a 1/4
 * note is a quarter regardless of signature), which is why they need ts_den. */
typedef enum le_grid_div {
  LE_GRID_DIV_OFF = 0,
  LE_GRID_DIV_BAR = 1,
  LE_GRID_DIV_HALF = 2,      /* 1/2 note */
  LE_GRID_DIV_QUARTER = 3,   /* 1/4 note */
  LE_GRID_DIV_EIGHTH = 4,    /* 1/8 note */
  LE_GRID_DIV_SIXTEENTH = 5, /* 1/16 note */
} le_grid_div;

/* A tempo grid: everything needed to place beats/bars/subdivisions on a frame
 * timeline. Plain values — build one on the stack from published state. */
typedef struct le_tempo_grid {
  float bpm;           /* denominator-note beats per minute (> 0) */
  int32_t ts_num;      /* beats per bar (the numerator) */
  int32_t ts_den;      /* beat unit: 4 = quarter note, 8 = eighth note */
  int32_t sample_rate; /* frames per second (> 0) */
} le_tempo_grid;

/* Whether {num, den} is one of the 17 supported time signatures (per the
 * Sheeran manual §5.9.1): 2/4..7/4 and 5/8..15/8. Everything else (2/8, 8/4,
 * 16/8, 1/4, ...) is rejected. */
int le_grid_signature_valid(int32_t num, int32_t den);

/* Frames per beat unit (the denominator note): sample_rate * 60 / bpm.
 * Fractional by design — boundary placement must not accumulate truncation
 * drift. Returns 0.0 for a degenerate grid (bpm or sample_rate <= 0). */
double le_grid_frames_per_beat_unit(const le_tempo_grid* g);

/* Frames per bar: frames_per_beat_unit * ts_num. Returns 0.0 for a degenerate
 * grid (bpm, sample_rate, or ts_num <= 0). */
double le_grid_frames_per_bar(const le_tempo_grid* g);

/* The frame interval of one subdivision `div` (le_grid_div): the bar length
 * for BAR, or the absolute note value (frames_per_beat_unit * ts_den / N) for
 * the 1/N notes. Returns 0.0 for OFF, an unknown div, or a degenerate grid. */
double le_grid_div_frames(const le_tempo_grid* g, int32_t div);

/* The first grid boundary of subdivision `div` STRICTLY AFTER frame `pos`
 * (an action armed exactly on a boundary fires at the next one). Boundaries
 * are the nearest-frame renderings of the exact multiples k * interval —
 * computed from k each call, so repeated calls never accumulate drift.
 * Returns -1 for a degenerate grid, OFF, an unknown div, or pos >= 2^52
 * (past double integer precision the nearest-frame guarantee breaks).
 *
 * RECONCILIATION NOTE (for A3's quantize arming): these boundaries are
 * absolute, from the nominal BPM. Once a live loop exists the LOOP-LOCKED
 * grid (le_grid_beat_at over the actual length) is the truth, and the two
 * diverge whenever len != bars * frames_per_bar (a rounded bar count).
 * Quantize arming against a live loop must derive its boundaries from the
 * loop-locked grid — use this function only when no loop constrains the
 * grid (e.g. pre-first-loop count-in math). */
int64_t le_grid_next_boundary(const le_tempo_grid* g, int64_t pos, int32_t div);

/* Whole-bar count of a `loop_frames`-long loop on this grid, rounded to the
 * NEAREST bar, minimum 1 (D7: an existing grid rounds the bar COUNT — the
 * audio length is never altered). Returns 0 for a degenerate grid or length. */
int32_t le_grid_bars_for_loop(const le_tempo_grid* g, int32_t loop_frames);

/* Derives a tempo from a freshly recorded loop (D7, TempoSource.none only):
 * picks the BPM in [LE_GRID_TEMPO_MIN, LE_GRID_TEMPO_MAX] that gives the loop
 * a whole number of bars in the current signature, tie-break nearest 120; if
 * two candidates are equidistant from 120 the SLOWER one (fewer bars) wins.
 * A loop too short for even one bar at the max tempo clamps to the max with
 * one bar. Writes the chosen bar count to *out_bars. The beat unit is the
 * denominator note, so ts_den cancels out and is not a parameter. Returns
 * 0.0 (and *out_bars = 0) on degenerate input. */
float le_grid_derive_bpm(int32_t loop_frames, int32_t ts_num,
                         int32_t sample_rate, int32_t* out_bars);

/* The beat index (0-based) a loop of `len` frames divided into `total_beats`
 * beats is on at `pos`. Distributes any remainder evenly so the grid divides
 * the loop exactly even when len % total_beats != 0 (the recovered 2f0513a
 * beat_at). Returns 0 when len or total_beats <= 0. */
int32_t le_grid_beat_at(int32_t pos, int32_t len, int32_t total_beats);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_TEMPO_GRID_H */
