/*
 * perf_render.h — the offline performance-recording renderer (part 7 of the
 * DAW-export stack): dry replay only, reconstructing full-length per-track
 * stems from a FINALIZED capture directory (part 6). Wet stems + the golden
 * master-parity gate are part 8.
 *
 * Reads exclusively from the capture directory — `performance.json`
 * (sample rate, channel layout, arm/disarm snapshots, retired-layer
 * manifest), `events.log` (docs/design/performance-event-log-format.md),
 * `loops/track<t>-lane0.wav` (settled lane exports, part 6), and
 * `layer-<channel>-<frame>-<slot>.pcm` (retired overdub layers, part 5) —
 * never the live engine. This is what lets a render run concurrently with
 * live looping and makes a crash-salvage render free (umbrella D-RENDER).
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

/* Starts an offline render of the finalized capture at `capture_dir`:
 * spawns a worker thread that loads the capture's sidecar/log/layers/lane
 * WAVs, reconstructs each non-empty track's full-length dry stem, and writes
 * `stems/dry/track<channel>.wav` under `capture_dir`. `capture_dir` is
 * copied (the caller's buffer need not outlive the call).
 *
 * Returns LE_ERR_INVALID for a null engine/capture_dir or an empty
 * capture_dir, LE_ERR_ALREADY_RUNNING if a render is already active on this
 * engine, or LE_OK once the worker thread is launched (poll for
 * completion/failure — this call never blocks on the render itself). */
int32_t le_perf_render_begin(le_engine* engine, const char* capture_dir);

/* Reads the current render's progress. Safe to call repeatedly (e.g. on a
 * timer) whether or not a render is active — when none is active, `*done`
 * reads 1, `*progress_pct` reads 100, `*track_count` reads 0 (indices
 * accepted by `le_perf_render_track_status` are cleared with it). Any output
 * pointer may be NULL to skip that field. Returns LE_OK, or LE_ERR_INVALID
 * for a null engine. */
int32_t le_perf_render_poll(le_engine* engine, int32_t* done,
                            int32_t* progress_pct, int32_t* track_count);

/* Reads render result `index`'s (0..track_count-1, from the most recent
 * `le_perf_render_poll`) track channel and outcome — valid once `*done`
 * (partial success: SOME tracks may already show a result while `done` is
 * still 0, since each track's stem is written progressively). Returns LE_OK,
 * or LE_ERR_INVALID for a null engine / out-of-range index / null out
 * pointers. */
int32_t le_perf_render_track_status(le_engine* engine, int32_t index,
                                    int32_t* channel, int32_t* succeeded);

/* Cancels an in-progress render and joins the worker thread — safe to call
 * when no render is active (a no-op). Cancellation is checked once per
 * per-track work chunk (never mid-stem), so this returns only once the
 * worker has actually stopped, and leaves no partial stem file behind for
 * whichever track was in flight at the moment of cancellation. Returns
 * LE_OK, or LE_ERR_INVALID for a null engine. */
int32_t le_perf_render_cancel(le_engine* engine);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_PERF_RENDER_H */
