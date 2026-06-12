/*
 * engine_private.h — cross-TU engine internals shared by the portable core
 * (engine.c) and the per-OS translation units (engine_linux.c / engine_apple.c /
 * engine_windows.c).
 *
 * This is the full `struct le_engine` definition plus the handful of helpers a
 * per-OS seam body needs to reach into engine state (the JACK pin hook touches
 * engine->context.backend, engine->device.jack.*, engine->in/out_channels, and
 * publishes engine->a_in/out_channels). It is NOT the FFI surface
 * (loopy_engine_api.h) and NOT the test surface (engine_internal.h) — it is the
 * private contract between the engine's own translation units.
 *
 * Must be self-contained and idempotent: other TUs include it, so it cannot rely
 * on any .c's include order.
 */
#ifndef LOOPY_ENGINE_PRIVATE_H
#define LOOPY_ENGINE_PRIVATE_H

/* The struct holds atomic_* fields; pull in <stdatomic.h> explicitly rather than
 * relying on it arriving transitively via lockfree_ring.h. */
#include <stdatomic.h>
#include <stdint.h>

#include "lockfree_ring.h"     /* le_command, le_ring */
#include "loop_clock.h"        /* le_loop_clock */
#include "loopy_engine_api.h"  /* le_engine typedef, le_config, le_device_info,
                                * LE_MAX_CHANNELS / LE_MAX_TRACKS / LE_MAX_INPUTS
                                * / LE_MAX_LANES / LE_FX_MAX / LE_FX_PARAMS /
                                * LE_VIZ_POINTS */
#include "miniaudio.h"         /* ma_device, ma_context, ma_device_id */

#ifdef __cplusplus
extern "C" {
#endif

#define LE_RING_CAPACITY 256u

/* Per-track buffer pool size: one live buffer plus up to LE_UNDO_SLOTS-1 undo/
 * redo snapshots. Buffers are allocated lazily, so memory grows only as deep as
 * the user actually overdubs. */
#define LE_UNDO_SLOTS 8

/* One looper track.
 *
 * The audio thread only reads pool[a_live] (and writes into it while recording/
 * overdubbing). All undo/redo bookkeeping — the pool, the stacks, and a_live
 * (whose sole writer is the control thread) — lives on the control thread, so
 * undo/redo never races the audio callback. */
/* Audio-thread-owned DSP state for one effects chain (LE_FX_MAX entries), reset
 * per entry when its type changes. svf_* are the state-variable filter
 * integrators; lfo is an LFO phase (0..1, TREMOLO depth / ECHO wow); delay is a
 * lazily allocated ring
 * (the control thread allocates before posting the command) of fx_delay_frames
 * samples (shared by DELAY, ECHO, and the OCTAVER's grain ring); fx_lp is a
 * generic one-pole low-pass memory (ECHO feedback damping, OCTAVER tone);
 * grain_phase is the OCTAVER pitch-shifter's read phase within a grain. A slot
 * is only ever one type at a time, so these reuse freely. Each lane and each
 * live monitor input owns one of these, running its own non-destructive chain. */
typedef struct le_fx_state {
  float svf_ic1[LE_FX_MAX];
  float svf_ic2[LE_FX_MAX];
  float lfo[LE_FX_MAX];
  float* delay[LE_FX_MAX];
  int32_t delay_pos[LE_FX_MAX];
  float fx_lp[LE_FX_MAX];
  float grain_phase[LE_FX_MAX];
} le_fx_state;

/* One recordable input lane — the fundamental unit of captured audio.
 *
 * A lane records exactly one hardware input (a_input_channel, -1 = none) into
 * its own clean mono buffer (pool[a_live]); sibling lanes are NEVER merged.
 * Lanes own only their audio content + per-lane routing/volume/mute + their
 * effects DSP state. The owning track (le_track) drives the shared write head,
 * the one undo span (lanes use the same slot indices in lockstep), and a_live
 * (whose sole writer is the control thread), so undo/redo never races the audio
 * callback.
 *
 * The effects fields are the per-lane record-route chain: a single
 * non-destructive chain run on playback. The recording stays dry. */
typedef struct le_lane {
  _Atomic int32_t a_input_channel; /* hardware input recorded (-1 = none) */
  _Atomic uint32_t a_output_mask;  /* bitmask of output channels to play to */
  _Atomic uint32_t a_vol_bits;     /* per-lane volume (float bits, 0..1) */
  _Atomic int32_t a_muted;         /* per-lane mute */

  float* pool[LE_UNDO_SLOTS]; /* lazily allocated loop buffers */
  _Atomic int32_t a_live;     /* pool index the audio thread plays/records */
  _Atomic int32_t a_len;      /* recorded length (== the track's length) */
  _Atomic uint32_t a_rms_bits;
  _Atomic uint32_t a_peak_bits;

  /* Per-lane effects chain. Published config (control writes, audio reads once
   * per buffer): an ordered array of LE_FX_MAX entries, of which a_fx_count are
   * active, each with a type and LE_FX_PARAMS normalized parameters. The chain
   * is stageless — every active entry colors playback in order — and runs on
   * the lane's own `fx` DSP state. */
  _Atomic int32_t a_fx_count;
  _Atomic int32_t a_fx_type[LE_FX_MAX];
  _Atomic uint32_t a_fx_param[LE_FX_MAX][LE_FX_PARAMS]; /* float bits, 0..1 */
  le_fx_state fx;
} le_lane;

/* One hardware input's live monitor route (engine-level, one slot per input).
 *
 * When a_enabled, the input's live sample is run through this route's own
 * effect chain and summed into the output channels a_output_mask selects. The
 * monitored signal is NEVER recorded and is independent of all track state, so
 * an input can be monitored whether or not any track records or plays it. This
 * replaces the old global monitor-FX bus and monitor-follows-a-track model. */
typedef struct le_monitor_input {
  _Atomic int32_t a_enabled;      /* 0/1 live monitoring on for this input */
  _Atomic uint32_t a_output_mask; /* output channels the effected route plays to */
  _Atomic uint32_t a_dry_output_mask; /* outputs the CLEAN (pre-FX) signal goes
                                       * to — a parallel dry send (0 = off) */
  _Atomic int32_t a_fx_count;
  _Atomic int32_t a_fx_type[LE_FX_MAX];
  _Atomic uint32_t a_fx_param[LE_FX_MAX][LE_FX_PARAMS]; /* float bits, 0..1 */
  le_fx_state fx;
} le_monitor_input;

/* One looper track: a multi-lane container that owns the transport, the shared
 * latency-compensated write head, and one undo span across all its lanes.
 *
 * Recording is track-addressed and fans out to every active lane (each captures
 * its own input clean); playback sums all active lanes. The undo span uses the
 * SAME pool slot indices across every lane in lockstep, so the track owns the
 * stacks and the lanes own only the buffers. */
typedef struct le_track {
  le_lane lanes[LE_MAX_LANES];
  int32_t lane_count; /* active lanes (1..LE_MAX_LANES); control-thread plain
                       * int, like track_count — not an atomic, not a ring
                       * command (set before the first record into a new lane). */

  /* Control-thread-owned undo/redo stacks of pool indices, shared by all lanes
   * (the same slot index names the snapshot in every lane). */
  int32_t undo_stack[LE_UNDO_SLOTS];
  int undo_count;
  int32_t redo_stack[LE_UNDO_SLOTS];
  int redo_count;

  _Atomic int32_t a_state;
  _Atomic int32_t a_undo_depth; /* published undo_count */
  _Atomic int32_t a_redo_depth; /* published redo_count */
  _Atomic int32_t a_multiple;   /* track length in whole base loops (>= 1) */
  _Atomic int32_t a_pending; /* published arm state (1 = waiting for the loop top
                              * to fire a quantized record action); read by the
                              * control thread to reconcile arm vs. fired. */
  int32_t pending_record; /* audio-thread-local: a deferred record is armed. */
  int32_t pending_trigger; /* what fires the pending record: 0 = next base-loop
                            * top (quantize), 1 = input level threshold
                            * (sound-activated auto-record). */
  int32_t record_pos; /* audio-thread-local shared write head, driving every
                       * active lane. Defining track: linear frame count. New
                       * track over a master: the absolute phase (segment*base +
                       * position), seeded at press so writes stay phase-locked
                       * to the master loop. */
  uint64_t start_iter; /* loop_iteration when this track's recording began */
  int32_t record_start; /* record_pos when this capture began, so a fixed-length
                         * track can auto-finalize after exactly K base loops. */
} le_track;

struct le_engine {
  ma_device device;
  int device_initialised;

  /* Snapshot, published as independent atomics. */
  _Atomic int32_t a_running;
  /* 1 while the device is present, 0 once a device-lost/rerouted/stopped
   * notification fires. Written only by the RT-adjacent notification callback
   * (store-only, no work) and the lifecycle calls; read into the snapshot.
   * The callback stores `relaxed` (it carries no other state and must not block
   * the audio thread); the lifecycle store and the snapshot load use
   * release/acquire to match the `a_running` publication they sit beside. The
   * flag is a single independent value, so plain visibility is all that's
   * required either way. */
  _Atomic int32_t a_device_present;
  _Atomic int32_t a_configured;
  _Atomic int32_t a_sample_rate;
  _Atomic int32_t a_buffer_frames;
  _Atomic int32_t a_in_channels;    /* negotiated hardware capture channels */
  _Atomic int32_t a_out_channels;   /* negotiated hardware playback channels */
  /* 1 when the device opened in OS-exclusive mode, 0 for shared (incl. an
   * exclusive request that fell back). Set once at device open in
   * le_engine_start; published in the snapshot. */
  _Atomic int32_t a_exclusive_active;
  /* Input channels whose Core Audio label marks them as loopback; never
   * recorded, monitored, or routable. Computed once at device open. */
  _Atomic uint32_t a_excluded_input_mask;
  _Atomic uint64_t a_frames;
  _Atomic uint32_t a_xruns;
  _Atomic uint32_t a_in_rms_bits;
  _Atomic uint32_t a_in_peak_bits;
  _Atomic uint32_t a_out_rms_bits;
  /* Loop-indexed visualization (float bits): one peak per loop bucket, spanning
   * exactly one master loop and refreshed as the playhead sweeps. a_loop_viz is
   * the mixed output; a_track_viz is each track's own contribution. */
  _Atomic uint32_t a_loop_viz[LE_VIZ_POINTS];
  _Atomic uint32_t a_track_viz[LE_MAX_TRACKS][LE_VIZ_POINTS];
  _Atomic int32_t a_latency_state;
  _Atomic uint64_t a_latency_ms_bits;

  /* Per-input live monitors: one independent route per hardware input. Each
   * sounds iff its a_enabled is set (a loopback measurement clears them all to
   * break the cable feedback loop; a fresh start restores defaults). */
  le_monitor_input monitors[LE_MAX_INPUTS];

  /* Looper transport (master). */
  _Atomic int32_t a_master_len;
  _Atomic int32_t a_master_pos;

  _Atomic int32_t a_record_offset; /* latency compensation in frames */

  /* Tracks. */
  le_track tracks[LE_MAX_TRACKS];
  int32_t track_count;

  /* Command ring + pre-allocated backing storage. */
  le_ring ring;
  le_command ring_storage[LE_RING_CAPACITY];

  /* Configuration. */
  int sample_rate;
  int in_channels;  /* hardware capture channels */
  int out_channels; /* hardware playback channels */
  int32_t max_loop_frames;
  int32_t fx_delay_frames; /* per-slot delay-line capacity (1 s @ sample rate) */

  /* Audio-thread-local transport. */
  le_loop_clock clock;
  uint64_t loop_iteration; /* free-running count of base-loop wraps */

  /* Quantized recording (control-thread-owned). When `quantize` is set, a record
   * press over an existing master arms `armed[ch]` (and does the one-time prep
   * an immediate record would) instead of acting now; the audio thread fires it
   * at the next loop top. `arm_snapshotted[ch]` records whether the arm pushed a
   * pre-overdub undo layer, so a cancel can reverse it. */
  int quantize; /* global default */
  /* Per-track quantize override: -1 inherit the global default, 0 force off,
   * 1 force on. The effective value drives le_engine_record's arm decision. */
  int track_quantize[LE_MAX_TRACKS];
  int armed[LE_MAX_TRACKS];
  int arm_snapshotted[LE_MAX_TRACKS];
  /* What each arm is waiting for: 0 = loop top (quantize), 1 = input level
   * (auto-record). Lets toggling one feature cancel only its own arms. */
  int armed_trigger[LE_MAX_TRACKS];

  /* Loop length. The global default (0 auto-rounds up to whole base loops on
   * stop; K >= 1 fixes K base loops) applies to tracks that inherit. A track's
   * target_multiple is 0 to inherit the global default, or K >= 1 to fix it.
   * Control-thread-owned. */
  int default_multiple;
  int target_multiple[LE_MAX_TRACKS];

  /* When `rec_dub` is set, finalizing a recording with a record press continues
   * into overdub instead of playback (the second-press "rec/dub" mode). A stop
   * still ends in playback/stopped. Control-thread default, read on the audio
   * thread via the finalize end-state. */
  int rec_dub;

  /* When `auto_record` is set, a record press on an empty track arms a
   * signal-triggered start: the audio thread begins recording the first frame
   * the input level crosses LE_AUTO_RECORD_THRESHOLD. Reuses the arm/pending
   * machinery with a per-track trigger type (see le_track.pending_trigger). */
  int auto_record;

  /* Loop-viz bucketing (audio-thread-local): peaks accumulate within the
   * current loop bucket and publish when the playhead crosses into the next. */
  int32_t loop_viz_bucket;
  float loop_viz_accum;
  float track_viz_accum[LE_MAX_TRACKS];

  /* Latency harness (audio-thread-local + published state). The measurement
   * captures the input-magnitude envelope into lat_buf for a fixed window after
   * emitting the pulse, then cross-correlates it with the pulse to find the
   * round-trip by its peak (robust to crosstalk/noise). */
  int lat_active;
  int32_t lat_emit_remaining;
  float* lat_buf;      /* envelope capture (control-thread allocated) */
  int32_t lat_buf_cap; /* capacity in frames */
  int32_t lat_buf_pos; /* write head during a measurement */

  char device_name[256];
  int passthrough; /* input monitoring */

  /* Explicit context + resolved device ids, used when capturing from a detected
   * loopback device (use_loopback_capture) or when a device is pinned by id. */
  ma_context context;
  int context_initialised;
  ma_device_id capture_id;
  ma_device_id playback_id;
};

/* Fills `out` (room for `max`) with the host's playback or capture devices and
 * writes the count into *count. Uses a transient context so it never disturbs a
 * running device. `capture` selects the direction. Defined in engine.c;
 * declared here because the Linux JACK pin hook resolves friendly device names
 * through it (le_jack_device_name). */
int32_t enumerate_devices(le_device_info* out, int32_t max, int32_t* count,
                          int capture);

/* Relaxed atomic accessors for the published int32 snapshot fields. `static
 * inline` so every TU that touches engine state (the core and the per-OS seam
 * bodies) gets its own copy with no external symbol — no double-definition
 * risk. */
static inline int32_t load_i32(_Atomic int32_t* slot) {
  return atomic_load_explicit(slot, memory_order_relaxed);
}
static inline void store_i32(_Atomic int32_t* slot, int32_t v) {
  atomic_store_explicit(slot, v, memory_order_relaxed);
}

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_ENGINE_PRIVATE_H */
