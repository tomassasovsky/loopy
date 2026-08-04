/*
 * engine_cache.h — the Loop-stage wet cache's cross-TU seam (FX v3 part 2).
 *
 * The cache's control/worker machinery (scheduler, job queue, the single
 * render worker [B6], memory accounting + LRU eviction) lives in
 * engine_cache.c behind the opaque `struct le_fx_cache` pointer on le_engine.
 * This header exposes only the three lifecycle/tick hooks the rest of the
 * engine calls; everything the AUDIO thread needs (le_lane.a_wet,
 * le_track.a_audio_rev, le_wet_entry) is in engine_private.h — the audio
 * thread never calls into this TU.
 *
 * NOT the FFI surface (the log/test-only telemetry accessors are declared in
 * segno_engine_api.h and defined in engine_cache.c) and NOT the test surface —
 * the private contract between the engine's own TUs.
 */
#ifndef SEGNO_ENGINE_CACHE_H
#define SEGNO_ENGINE_CACHE_H

#include "engine_private.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Settle debounce [B2][B3]: no render is scheduled until the lane's cache key
 * has been unchanged for this long. Continuously-moving state (param sweeps,
 * volume moves — D-VOL) folds into the key, so it resets this window on every
 * change. Measured in PROCESSED FRAMES (a_frames scaled by the sample rate),
 * not wall time, so the device-free native tests are deterministic — and it
 * lives here (not TU-private in engine_cache.c) so those tests derive their
 * pump counts from this one definition. */
#define LE_CACHE_SETTLE_MS 250

/* Allocates the cache state and starts the render worker (control thread; the
 * tail of le_engine_configure, after the pools exist). A thread-start failure
 * leaves engine->cache NULL — caching silently disabled, every lane live. */
void le_cache_init(le_engine* engine);

/* Joins the worker and frees every cache allocation — entries, in-flight job
 * buffers, the state struct (control thread). MUST run before any pool or
 * wet-buffer free [R2]: called from le_engine_stop, the top of
 * le_engine_configure, and le_engine_destroy, in each case after the device
 * (and so the audio thread) is stopped, which is why the frees here need no
 * quiescent handshake. Idempotent; safe when never initialized. */
void le_cache_shutdown(le_engine* engine);

/* One control-thread scheduler pass: collects finished renders (publishing
 * only those whose key still matches [B5]), re-evaluates every lane's key
 * against the settle debounce [B2][B3], enqueues copy-at-enqueue render jobs
 * [R2], and enforces the memory cap via LRU eviction. Called from
 * le_engine_drain_events, i.e. on the UI's snapshot-poll cadence. */
void le_cache_tick(le_engine* engine);

#ifdef __cplusplus
}
#endif

#endif /* SEGNO_ENGINE_CACHE_H */
