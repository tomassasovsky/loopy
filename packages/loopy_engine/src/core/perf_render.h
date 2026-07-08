/*
 * perf_render.h — the offline performance-recording renderer (parts 7-8 of
 * the DAW-export stack): reconstructs, from a FINALIZED capture directory
 * (part 6), full-length per-track dry stems (`stems/dry/track<channel>.wav`,
 * part 7), per-track wet stems with the logged FX chain applied
 * (`stems/wet/track<channel>.wav`, part 8), and a reconstructed master bus
 * (`stems/wet/master.wav`, part 8: track sum + master gain + limiter) that
 * is this feature's golden-parity guardrail against the live-captured
 * master.
 *
 * Reads exclusively from the capture directory — `performance.json`
 * (sample rate, channel layout, arm/disarm snapshots including the master
 * gain/limiter and per-lane FX chain state, retired-layer manifest),
 * `events.log` (docs/design/performance-event-log-format.md), `loops/
 * track<t>-lane0.wav` (settled lane exports, part 6), and `layer-<channel>-
 * <frame>-<slot>.pcm` (retired overdub layers, part 5) — never the live
 * engine. This is what lets a render run concurrently with live looping and
 * makes a crash-salvage render free (umbrella D-RENDER).
 *
 * Lifecycle sibling of `perf_drain.c` (a dedicated background thread, plain
 * C, no SDK dependency) and of the plugin-scan thread's begin/poll/cancel
 * shape (`host/plugin_scan.cpp`) — mirrored here as scalar out-params rather
 * than a struct pointer, matching `le_plugin_scan_poll`/`_get`'s own
 * convention, so the Dart FFI surface stays consistent across both features.
 *
 * ONE render at a time, per engine (matches D-RENDER's "no render queue" —
 * arm is refused while rendering, a policy enforced by the Dart-side
 * repository, not by this module, since this module has no live-engine
 * dependency to check against).
 */
#ifndef LOOPY_PERF_RENDER_H
#define LOOPY_PERF_RENDER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct le_engine le_engine; /* opaque; full definition in engine_private.h */

/* Opaque render-session handle, one per active render. Owned by
 * `engine->perf.render` (engine_private.h), the same per-engine ownership
 * model as `engine->perf.drain`. */
typedef struct le_perf_render le_perf_render;

/* le_perf_render_begin/poll/track_status/cancel are the public API for this
 * module (declared with LE_EXPORT in loopy_engine_api.h, the single source
 * of truth for the FFI surface — redeclaring them here without LE_EXPORT
 * causes an MSVC linkage-mismatch error, C2375, in any TU that includes both
 * headers). Callers of this module should include loopy_engine_api.h. */

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_PERF_RENDER_H */
