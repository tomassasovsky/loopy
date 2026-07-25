/*
 * le_midi_clock.h — pure-value 24-PPQN MIDI clock SEND emitter (Phase C, D15).
 *
 * Mirrors tempo_grid.h in spirit: no engine state, no atomics, no allocation —
 * a small generator struct plus one advance function, so the audio thread and
 * a plain unit test drive the exact same logic. The engine wires this to real
 * grid/transport state each block (engine_process.c, at the end of
 * le_engine_process) and forwards the emitted bytes onward through the
 * existing `le_midi_out_send` transport (loopy_engine_api.h) — this module
 * only decides WHAT to send and WHEN, never touches OS MIDI I/O itself.
 *
 * PPQN is fixed by the MIDI spec at 24 pulses per QUARTER note, regardless of
 * the session's actual beat unit: tempo_grid's BPM counts DENOMINATOR-note
 * beats (a 7/8 session's "beat" is an eighth note), so the tick interval is
 * derived from the absolute quarter-note value (le_grid_div_frames(...,
 * LE_GRID_DIV_QUARTER)), never from frames-per-beat-unit directly.
 *
 * Manual-verified gating (docs/plan/2026-07-22-song-mode-spec.md, "MIDI
 * clock" section): the Sheeran manual describes send as active "while
 * recording, overdubbing, and playing your loops in Multi, Sync and Band
 * modes" — i.e. only while the transport is actually running, NOT free-
 * running through complete idle. This reverses the tempo-aware-looper-modes
 * index plan's initial DAW-sync-modeled guess (ticks free-running while
 * stopped); the corrected behavior below is what a C1 self-review found
 * against that manual excerpt. 0xF8 ticks are therefore emitted ONLY while
 * `transport_active`; Start/Stop bracket exactly that region.
 */
#ifndef LOOPY_ENGINE_MIDI_CLOCK_H
#define LOOPY_ENGINE_MIDI_CLOCK_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* MIDI System Real-Time status bytes this emitter sends. Standard values —
 * distinct from the pedal's own vendored reuse of 0xFA as a loop-top pulse to
 * FIRMWARE (pedal_repository's PedalCodec.loopTopPulse): that is a different
 * destination/protocol entirely, this module addresses a generic external
 * clock-sync destination with the bytes' real MIDI meaning. */
#define LE_MIDI_CLOCK_TICK 0xF8  /* Timing Clock: one per PPQN pulse */
#define LE_MIDI_CLOCK_START 0xFA /* Start: transport begins at position 0 */
#define LE_MIDI_CLOCK_STOP 0xFC  /* Stop: transport halts */

/* Pulses per quarter note, fixed by the MIDI spec. */
#define LE_MIDI_CLOCK_PPQN 24

/* A clock generator's running state. Zero-initialized (or le_midi_clock_reset)
 * is the idle state: no Start emitted yet, tick epoch unanchored. */
typedef struct le_midi_clock_gen {
  int active_prev;        /* gated transport-active state as of the last call,
                           * for Start/Stop edge detection */
  uint64_t active_frames; /* frames elapsed since the current active run's
                           * Start (held at 0 while idle) — the absolute basis
                           * every tick boundary this run is recomputed from
                           * each call (never accumulated as a remainder), so
                           * repeated calls can never drift OR double-count a
                           * boundary already reported, mirroring tempo_grid.c's
                           * le_grid_next_boundary "computed from k, never by
                           * stepping" philosophy. */
} le_midi_clock_gen;

/* Resets `g` to its idle, pre-Start state: no Start/Stop pending, tick epoch
 * cleared. Call once when a generator is created and again at every fresh
 * session (le_engine_configure) — a stale active/frame count carried over
 * from a previous session would misplace the next Start or emit a spurious
 * Stop. Safe with a NULL `g` (no-op). */
void le_midi_clock_reset(le_midi_clock_gen* g);

/* Advances `g` by `frames` on the grid {bpm, ts_num, ts_den, sample_rate},
 * appending emitted bytes (LE_MIDI_CLOCK_TICK / _START / _STOP) to `out`
 * (capacity `out_cap`) and returning the count written — clamped to `out_cap`
 * if a pathological input would exceed it (never happens at any block size /
 * tempo this engine actually runs: even at the slowest supported tempo
 * (30 BPM) one quarter note is multiple seconds of audio, vastly longer than
 * one audio block).
 *
 * `ts_num` is accepted only so every grid consumer in this codebase builds
 * its le_tempo_grid the same four-field way; the tick math itself is
 * quarter-note-relative and does not depend on the bar length.
 *
 * `transport_active`: whether the engine's transport is actually running
 * this block (any track RECORDING/OVERDUBBING/PLAYING) — the same predicate
 * `le_transport_held` (engine_process.c) negates for the master clock's own
 * idle/advance decision, so the clock and the transport can never disagree
 * about what "running" means.
 *
 * `gate_open`: whether clock output should be audible at all right now
 * (clock_mode == SEND AND looper_mode in {MULTI, SYNC, BAND} — Song and Free
 * stay silent regardless of clock_mode, per the manual). When false, NOTHING
 * is emitted (not even a wrong-moment Start/Stop) and the generator is held
 * at its idle state — so re-opening the gate later against an
 * already-running transport is treated as a FRESH Start (clock output
 * "begins" the moment it turns on, matching a DAW's expectation when a user
 * flips a sync toggle mid-performance), and closing the gate mid-run never
 * leaves a phantom Stop waiting to fire the moment it reopens.
 *
 * D15: Start fires on the first call where gate_open && transport_active —
 * the loop downbeat. During a count-in `transport_active` is false (no track
 * has entered RECORDING yet — count-in only ever runs on an otherwise-idle
 * transport, D9), so Start can never land at count-in start; it fires
 * exactly once the count-in commits and the defining recording actually
 * begins. Stop fires on the first call afterwards where `transport_active`
 * drops back to 0 (or the gate closes). */
int32_t le_midi_clock_advance(le_midi_clock_gen* g, int32_t frames, float bpm,
                              int32_t ts_num, int32_t ts_den,
                              int32_t sample_rate, int transport_active,
                              int gate_open, uint8_t* out, int32_t out_cap);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_ENGINE_MIDI_CLOCK_H */
