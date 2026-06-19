/*
 * engine_fx.h — the per-lane effects DSP island's cross-TU surface.
 *
 * The effects DSP lives in engine_fx.c (S1 split from engine.c): the built-in
 * effect kernels, the phase-vocoder / PSOLA octaver, the Freeverb reverb, and
 * the chain runner. This header exposes only what the rest of the engine needs:
 * the chain entry point (audio thread), the per-slot reset/free helpers (audio +
 * control thread), the active-octaver latency query (control thread), and the
 * one-time Hann-window init (control thread). The per-sample kernels (fx_drive,
 * fx_reverb, …) stay private to engine_fx.c.
 *
 * The phase-vocoder / PSOLA tuning constants live here too because the control
 * thread sizes the octaver's heap buffers (LE_PV_N / LE_PV_BINS) in
 * le_fx_prepare_entry — they are the single source of truth shared by the DSP
 * and its allocator.
 */
#ifndef LOOPY_ENGINE_FX_H
#define LOOPY_ENGINE_FX_H

#include <stdint.h>

#include "engine_private.h" /* le_fx_state, le_octaver_state, LE_FX_MAX/PARAMS */

#ifdef __cplusplus
extern "C" {
#endif

/* --- Phase-vocoder octaver (LE_FX_OCTAVER, mode p3 < 0.5) tuning ------------- */
#define LE_PV_N 1024             /* STFT window (power of two) */
#define LE_PV_HOP 256            /* 4x overlap (HOP = N/4: the clean-PV minimum) */
#define LE_PV_BINS (LE_PV_N / 2 + 1)
#define LE_PV_LIFTER (LE_PV_N / 24) /* ~42: cepstral envelope lifter cutoff */

/* --- PSOLA octaver (mode p3 >= 0.5) tuning ---------------------------------- */
#define LE_PSOLA_AHOP 256    /* re-run pitch detection every this many samples */
#define LE_PSOLA_WIN 1600    /* YIN analysis window (integration + max lag) */
#define LE_PSOLA_MAXLAG 800  /* longest lag searched (60 Hz at 48 kHz) */
#define LE_PSOLA_THRESH 0.15f /* YIN absolute threshold for the first dip */
#define LE_PSOLA_THMAX 300   /* grain half-width cap: 2*THMAX < LE_PV_N (fits OLA) */

/* Applies a lane/monitor chain to one stereo sample in place, in chain order.
 * Stageless: every active entry processes both channels on the lane's own `fx`
 * DSP state. [count] is the active length; [types]/[params] are the per-buffer
 * snapshot. Audio thread (le_engine_process) and the FX chain test. */
void fx_apply_chain(le_fx_state* fx, int sr, int cap, float* l, float* r,
                    int count, const int32_t* types,
                    const float params[LE_FX_MAX][LE_FX_PARAMS]);

/* Clears chain slot [slot]'s audio-thread DSP state (filter integrators, LFO
 * phase, delay heads, one-pole memory, octaver runtime, reverb lines) so a
 * freshly engaged effect starts clean. Does NOT allocate/free the delay ring or
 * octaver heap buffers (the control thread owns those). Runs on the audio thread
 * (SET_*_FX ring handlers) and the control thread (lane/monitor reset). */
void le_fx_entry_reset(le_fx_state* fx, int slot);

/* Frees a chain slot's octaver phase-vocoder heap buffers (both channels) and
 * nulls them. Control-thread only (lane/monitor reset, engine destroy). */
void le_fx_free_octaver(le_fx_state* fx, int slot);

/* Added latency (frames) of the active octaver in slot [o]; 0 for a non-octaver
 * slot's idle state. Folded into the published snapshot so the UI can warn about
 * monitoring lag. Control thread (le_max_fx_latency). */
int le_octaver_latency(const le_octaver_state* o);

/* Builds the shared octaver Hann window once (idempotent, guarded). Control
 * thread only, before an octaver slot can be processed; le_fx_prepare_entry
 * calls it when a slot becomes LE_FX_OCTAVER. */
void le_fx_ensure_hann(void);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_ENGINE_FX_H */
