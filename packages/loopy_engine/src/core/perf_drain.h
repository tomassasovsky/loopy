/*
 * perf_drain.h — the performance-recording capture-to-disk subsystem (part 2
 * of the DAW-export stack).
 *
 * A dedicated background thread — spawned by le_perf_arm, joined by
 * le_perf_disarm — that drains part 1's capture rings (audio_ring.h) into raw
 * float PCM temp files plus a `performance.json` sidecar, flushing every
 * ~250 ms. WAV headers are written only at finalize (a later part): a crash
 * mid-capture leaves salvageable raw PCM + a parseable sidecar, never a
 * truncated WAV (umbrella D-FMT).
 *
 * Lifecycle sibling of the plugin scan thread (host/plugin_scan.cpp), but
 * this one is plain C (no SDK dependency) so it lives in core/ alongside the
 * rest of the engine. Thread ownership: engine_commands.c's le_perf_arm/
 * disarm are the only callers; this module never touches the audio thread or
 * the command ring (a background thread pushing commands would be a second
 * producer on the control thread's SPSC ring — never done here).
 */
#ifndef LOOPY_PERF_DRAIN_H
#define LOOPY_PERF_DRAIN_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct le_engine le_engine; /* opaque; full definition in engine_private.h */

/* Opaque drain-thread handle, one per armed capture session. */
typedef struct le_perf_drain le_perf_drain;

/* Why a capture session ended, recorded in the sidecar's `stopped_early`
 * field (absent on a normal disarm — only le_perf_arm/disarm's own bookkeeping
 * needs `finalized`, still false in this slice either way). */
typedef enum le_perf_stop_reason {
  LE_PERF_STOP_DISARM = 0,         /* a normal, caller-requested disarm */
  LE_PERF_STOP_DEVICE_CHANGED = 1, /* engine reconfigure while armed */
} le_perf_stop_reason;

/* Starts the drain thread for `engine`'s just-armed perf capture: creates
 * `capture_dir` if it does not already exist, opens the master + per-monitor
 * PCM files, and begins the drain-flush-sleep loop. `capture_dir` is copied
 * (the caller's buffer need not outlive the call). Returns the handle, or
 * NULL on failure (directory could not be created, or the thread could not be
 * spawned) — the caller must not proceed to arm without a working drain
 * thread. Call once per capture session, after the ring set is published
 * (i.e. after LE_CMD_PERF_ARM is pushed) so the rings the drain thread reads
 * are already valid. */
le_perf_drain* le_perf_drain_start(le_engine* engine, const char* capture_dir);

/* Signals the drain thread to run one final drain-and-flush pass and stop,
 * then joins it and frees `drain`. `reason` is recorded in the final sidecar
 * flush's `stopped_early` field UNLESS the thread already self-stopped for
 * its own reason (a disk-full write failure) — that reason always wins, since
 * the thread reached it first. Safe to call on a thread that already
 * self-stopped early — the join simply reaps it. `drain` must not be used
 * again afterward. No-op on NULL. */
void le_perf_drain_stop(le_perf_drain* drain, le_perf_stop_reason reason);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_PERF_DRAIN_H */
