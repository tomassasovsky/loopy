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
 * relying on it arriving transitively via lockfree_ring.h. <string.h> backs the
 * memcpy-based float<->bits helpers below. */
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

#include "audio_ring.h"        /* le_audio_ring (performance-recording taps) */
#include "layer_staging_ring.h" /* le_layer_staging_ring (retired-layer persistence) */
#include "le_device_backend.h" /* le_device_backend (the device-backend seam) */
#include "lockfree_ring.h"     /* le_command, le_ring */
#include "loop_clock.h"        /* le_loop_clock */
#include "loopy_engine_api.h"  /* le_engine typedef, le_config, le_device_info,
                                * LE_MAX_CHANNELS / LE_MAX_TRACKS / LE_MAX_INPUTS
                                * / LE_MAX_LANES / LE_FX_MAX / LE_FX_PARAMS /
                                * LE_VIZ_POINTS */
#include "miniaudio.h"         /* ma_device, ma_context, ma_device_id */
#include "perf_log_ring.h"     /* le_perf_log_ring (performance event log) */

#ifdef __cplusplus
extern "C" {
#endif

#define LE_RING_CAPACITY 256u

/* Performance event log (part 3): 4096 slots absorbs a command storm (a
 * scripted/automated burst of >= 2000 audibility-affecting changes) within one
 * 250ms drain interval without dropping an entry; the control-side ring is
 * far smaller since it only ever sees human-paced UI edits. Both power of
 * two, matching every other ring in this engine. */
#define LE_PERF_LOG_RING_CAPACITY 4096u
#define LE_PERF_LOG_CTRL_RING_CAPACITY 512u

/* Per-track buffer pool size: one live buffer plus up to LE_POOL_SLOTS-1 undo/
 * redo layers (one per overdub pass). Buffers are allocated lazily, so memory
 * grows only as deep as the user actually overdubs; past the cap the oldest
 * undo layer is evicted and its slot recycled. Only the slot POINTER tables are
 * sized by this (2 KB per lane), not audio. */
#define LE_POOL_SLOTS 256

/* Retired-layer staging (part 5, D-LAYER): this ring is engine-wide, shared
 * by every track, so it must cover the worst case across ALL of them, not
 * just one — LE_MAX_TRACKS * LE_POOL_SLOTS, i.e. every slot on every track
 * retiring before the drain thread's next ~250ms cycle, still fits without
 * dropping a layer. (One usable slot is reserved to distinguish full from
 * empty, per the ring's own invariant.) Already a power of two, as the ring
 * requires — entries are small (a few pointers + ints), so the larger table
 * costs ~200 KB, cheap for a one-time static allocation. */
#define LE_LAYER_STAGING_RING_CAPACITY (LE_MAX_TRACKS * (unsigned)LE_POOL_SLOTS)

/* Undo-layer buffers are sized to the track's ACTUAL loop length rounded up to
 * this quantum (frames), not to max_loop_frames — a 2 s loop's undo layer
 * costs ~2 s of floats, not the 30 s (or 8 min) cap. The quantum keeps slot
 * reuse across small length changes allocation-free. The LIVE buffer of a
 * recording track is the exception: a fresh capture can grow to the cap, so
 * every path that starts a recording first regrows the live slot to
 * max_loop_frames (see le_lane_ensure_slot). */
#define LE_LAYER_QUANTUM 48000

/* SAMPLES of live->shadow copy per track per le_engine_process call while a
 * partially backed-up overdub layer drains after punch-out. The per-track
 * budget is divided by the track's active lane count (the copy runs per
 * lane), so one draining track costs <= 128 KB of memcpy per callback
 * regardless of lanes; even all 8 tracks draining at once stay ~1 MB/block
 * (~0.1-0.5 ms — bounded on the Pi appliance target). A 30 s mono loop
 * completes in ~44 callbacks (~0.5 s at typical buffer sizes). */
#define LE_DRAIN_CHUNK 32768

/* Minimum performance-recording capture ring size, in seconds of audio at the
 * device rate (le_perf_arm sizes the master + per-monitor rings from this). */
#define LE_PERF_CAPTURE_SECONDS 2

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
 * samples (shared by DELAY, ECHO, and the OCTAVER's input FIFO); fx_lp is a
 * generic one-pole low-pass memory (ECHO feedback damping, OCTAVER tone). The
 * OCTAVER's phase-vocoder working set lives in the `oct` sub-state (its heap
 * buffers are control-thread allocated alongside the delay ring). A slot is only
 * ever one type at a time, so these reuse freely. Each lane and each live
 * monitor lane owns one of these, running its own non-destructive chain. */
/* Reverb (LE_FX_REVERB) is a Schroeder/Freeverb network: a bank of parallel
 * damped comb filters summed into a chain of series allpass diffusers. It runs
 * LE_REV_BANKS of those in parallel — a left and a right whose delay lines are
 * offset by the Freeverb "stereo spread" so their tails decorrelate, turning a
 * mono input into a wide stereo tail. All the lines are packed into the slot's
 * single `delay` ring at fixed offsets; rev_comb_pos / rev_ap_pos are the
 * per-line write heads (left bank first, then right) and rev_comb_lp the
 * per-comb damping (one-pole low-pass) memory. */
#define LE_REV_COMBS 8
#define LE_REV_APS 4
#define LE_REV_BANKS 2

/* The OCTAVER's phase-vocoder (and, in part 4, PSOLA) working set for one chain
 * slot on one channel. The three pointers are heap buffers the control thread
 * allocates when the slot becomes OCTAVER (sized by the LE_PV_* constants in
 * engine.c) and frees on retype/reset/destroy; everything else is plain scalar
 * state the audio thread owns. The PSOLA fields are defined now but unused until
 * part 4, so that PR needs no struct/ABI change. */
typedef struct le_octaver_state {
  float* out;        /* synthesis overlap-add accumulator, length LE_PV_N */
  float* last_phase; /* previous analysis phase per bin, length LE_PV_BINS */
  float* sum_phase;  /* accumulated synthesis phase per bin, length LE_PV_BINS */
  int32_t hop_count; /* samples emitted in the current hop block */
  int32_t out_pos;   /* reserved read/write phase (PSOLA, part 4) */
  /* PSOLA (part 4; zero-initialized and unused here). */
  float period;
  float voiced;
  int32_t in_epoch;
  int32_t out_epoch;
  /* Shared: per-sample param smoothing + mode-switch gain-dip (D1/D2/H3). */
  float sm_shift;
  float sm_tone;
  float sm_mix;
  int32_t cur_mode; /* 0 = phase vocoder, 1 = PSOLA */
  float xfade;      /* equal-power gain-dip envelope during a mode switch (1 = steady) */
} le_octaver_state;

/* Per-slot DSP state is carried per channel ([slot][chan], chan 0 = left,
 * 1 = right) so the whole chain runs in full stereo: a slot colours its left and
 * right independently. A mono source seeds l == r, so a symmetric chain produces
 * l == r and is audibly unchanged. The delay-ringed effects (DELAY / ECHO /
 * OCTAVER) own a ring per channel (delay[slot][0] and [1]); the REVERB packs its
 * two stereo banks into the single ring delay[slot][0] (delay[slot][1] stays
 * NULL), reading both banks from xl / xr — see fx_reverb. The rev_* arrays
 * already hold both banks (LE_REV_BANKS == 2) and stay per-slot. */
typedef struct le_fx_state {
  float svf_ic1[LE_FX_MAX][2];
  float svf_ic2[LE_FX_MAX][2];
  float lfo[LE_FX_MAX][2];
  float* delay[LE_FX_MAX][2];
  int32_t delay_pos[LE_FX_MAX][2];
  float fx_lp[LE_FX_MAX][2];
  le_octaver_state oct[LE_FX_MAX][2];
  int32_t rev_comb_pos[LE_FX_MAX][LE_REV_COMBS * LE_REV_BANKS];
  float rev_comb_lp[LE_FX_MAX][LE_REV_COMBS * LE_REV_BANKS];
  int32_t rev_ap_pos[LE_FX_MAX][LE_REV_APS * LE_REV_BANKS];
  /* For an LE_FX_PLUGIN slot: the hosted-plugin slot handle the audio thread
   * forwards to, or NULL. The control thread publishes/retracts it
   * (engine_plugin.c); the audio thread only loads it (fx_plugin_process). A
   * NULL or not-ready slot renders dry passthrough — no plugin is ever created
   * or freed on the audio thread (D-LIFE). */
  _Atomic(le_plugin_slot*) plugin[LE_FX_MAX];
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

  float* pool[LE_POOL_SLOTS]; /* lazily allocated loop buffers */
  int32_t pool_cap[LE_POOL_SLOTS]; /* allocated frames per slot (0 = none).
                                    * Undo layers are quantized to the track's
                                    * length; only a recording live slot needs
                                    * the full max_loop_frames. */
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

/* One hardware input's live monitor (engine-level, one slot per input).
 *
 * When a_enabled, the input's live sample runs through ONE non-destructive effect
 * chain (stageless, on its own `fx` state) at a_vol_bits, routed to the output
 * channels a_output_mask selects unless a_muted. An empty chain (a_fx_count == 0)
 * is the clean (dry) path — there is no special-case dry concept. The monitored
 * signal is NEVER recorded and is independent of all track state, so an input can
 * be monitored whether or not any track records or plays it. Input-level enable
 * gates the whole input (and honours loopback exclusion + the latency-measurement
 * suppress/restore). This single chain is what le_engine_record deep-copies onto a
 * recording lane (snapshot-on-record). */
typedef struct le_monitor_input {
  _Atomic int32_t a_enabled;      /* 0/1 live monitoring on for this input */
  _Atomic uint32_t a_output_mask; /* output channels the monitor plays to */
  _Atomic uint32_t a_vol_bits;    /* monitor gain (float bits, 0..1) */
  _Atomic int32_t a_muted;        /* 0/1 monitor mute */
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
   * (the same slot index names the snapshot in every lane). Layers arrive on the
   * undo stack via LE_EVT_LAYER_RETIRED events the audio thread emits at each
   * completed overdub pass (see the dub_* capture state below). */
  int32_t undo_stack[LE_POOL_SLOTS];
  int undo_count;
  int32_t redo_stack[LE_POOL_SLOTS];
  int redo_count;

  /* ---- per-pass layer capture (audio-thread-local unless noted) ----
   *
   * While the track overdubs, each in-place write first saves the pre-value
   * into the armed shadow slot (`dub_slot`, same index on every lane —
   * lockstep). The write trajectory visits each of the track's len positions
   * exactly once per len frames, so dub_count == dub_len means the shadow holds
   * a complete pre-pass image: it is retired to the control thread (which
   * pushes it onto the undo stack) and the pre-posted spare takes over — one
   * undo layer per pass. A punch-out mid-pass drains the uncovered remainder
   * live->shadow in bounded chunks (live is stable then), then retires. */
  int32_t dub_slot;  /* armed shadow pool slot (-1 = none) */
  int32_t dub_spare; /* next shadow, pre-posted by control (-1 = none) */
  int32_t dub_count; /* frames backed up into dub_slot this pass; -1 = armed
                      * but unstarted (the first write latches the start point,
                      * so no entry path needs position math). Reaching dub_len
                      * freezes the complete image until it can be retired. */
  int32_t dub_phase; /* frames written since the last pass boundary; wraps at
                      * dub_len — the rotation point (hand off + arm spare) */
  int32_t dub_len;   /* pass length (track len), latched at session start */
  int32_t dub_offset; /* record offset latched for the whole dub session, so a
                       * mid-dub offset change cannot tear the trajectory */
  int32_t dub_start_vpos; /* trajectory point (base-loop position + segment) */
  int32_t dub_start_vseg; /* of the pass's first backed-up write */
  int32_t dub_vpos; /* drain cursor: the NEXT position to complete, walking */
  int32_t dub_vseg; /* the remaining trajectory from start + count */
  int32_t dub_draining;       /* post-punch-out bulk completion in progress */
  int32_t dub_retire_slot;    /* retired slot awaiting evt-ring space (-1 none) */
  uint32_t dub_gen_audio; /* audio-side mirror of dub_generation: both sides
                           * bump exactly once per applied CLEAR, so they agree
                           * without sharing a variable */
  /* 1 from OVERDUBBING entry until every captured layer has been retired
   * (through tail + drain). Audio stores it; control reads it (acquire after
   * draining the event ring) to queue undo instead of swapping a_live while
   * the audio thread still writes/reads the live buffers. The retire event is
   * pushed BEFORE this clears, so a control thread that drained the ring and
   * still sees 0 knows the undo stack is complete. */
  _Atomic int32_t a_layer_in_flight;

  /* ---- control-thread-owned undo bookkeeping ---- */
  int32_t outstanding_slots[4]; /* shadow slots posted, not yet retired */
  int outstanding_count;
  int queued_undo;   /* undo taps deferred until the in-flight layer retires */
  int32_t empty_len; /* len to restore on redo-from-empty (0 = none) */
  /* Posted-but-unapplied state-flip accounting. UNDO_TO_EMPTY /
   * REDO_FROM_EMPTY / CLEAR change a_state on the audio thread; until they
   * apply, control-side decisions (a record press racing a redo would memset
   * the very buffer redo just made live) must see the POSTED target, not the
   * stale a_state. The audio thread bumps a_state_acks once per applied
   * command; while state_cmds_posted > a_state_acks the effective state is
   * pending_target. Deterministic (ring FIFO), no observation races. */
  int state_cmds_posted;   /* control: state-flip commands pushed */
  int32_t pending_target;  /* control: the last posted command's end state */
  _Atomic int32_t a_state_acks; /* audio: state-flip commands applied */
  uint32_t dub_generation; /* bumped on clear; audio mirrors it in handle_clear
                            * and tags retire events, so a stale event from
                            * before a clear is dropped, never re-pushed */

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
  float od_gain; /* audio-thread-local overdub punch envelope (0..1). Ramps up on
                  * punch-in and down on punch-out so the layered input enters and
                  * leaves the loop buffer without a step discontinuity (a click)
                  * at the punch points / loop seam. Drives the fade-out tail that
                  * keeps writing for a few ms after the track is back in PLAYING. */

  /* Deferred crossfade-finalize of the defining master (audio-thread-local). On
   * the finalize press the master keeps RECORDING `xfade_capture` more frames —
   * the continuation of the performance just past the loop point — into
   * [xfade_len, xfade_len + F). When the count hits 0 that overlap is
   * equal-power crossfaded into the loop head so the wrap (xfade_len-1 -> 0) is
   * click-free, and the loop is finalized at exactly xfade_len (length, and so
   * tempo/quantize, are preserved). 0 == not deferring (immediate finalize). */
  int32_t xfade_capture;
  int32_t xfade_len;
  int32_t xfade_end_state;
} le_track;

/* Performance-recording capture state (le_perf_arm / le_perf_disarm,
 * loopy_engine_api.h). Rings are allocated CONTROL-side at arm and freed
 * CONTROL-side only after the quiescent handshake in le_perf_disarm; the audio
 * thread only ever pushes into an already-published ring — the same
 * control-allocates/publish discipline as le_lane.fx.delay and the hosted-
 * plugin slot pointers. `armed` is the audio-thread-LOCAL mirror of the
 * published a_perf_armed atomic (like le_track.dub_slot mirrors
 * a_layer_in_flight): cheaper to test per frame than an atomic load, and the
 * only field of this struct the audio thread itself ever writes. */
typedef struct le_perf_capture {
  le_audio_ring master_ring;
  int32_t master_channels;  /* 1 (mono) or 2 (stereo) — the ring's frame width */
  int32_t master_out_ch[2]; /* captured output channel(s); [1] == -1 if mono */

  /* One stereo ring per hardware input, valid iff its bit is set in
   * input_mask (frozen at arm: inputs enabled later are not retroactively
   * captured). */
  le_audio_ring monitor_ring[LE_MAX_INPUTS];
  uint32_t input_mask;

  int armed;

  /* The sample-accurate event log (part 3): every audibility-affecting
   * command the audio thread applies, plus a handful of transport facts
   * (record start/end, loop length locked, layer retired), tagged with the
   * capture frame it occurred at and pushed here for perf_drain.c to append
   * to events.log. Audio-thread-producer, so it lives alongside the taps
   * above rather than being control-allocated at arm like the audio rings —
   * a fixed-size field the same way evt_ring is (see le_engine below), just
   * re-initialised (head/tail reset) on every arm so a session never sees a
   * stale entry from a previous one. See docs/design/performance-event-log-
   * format.md for the audited command table and on-disk format. */
  le_perf_log_ring log_ring;
  le_perf_log_entry log_storage[LE_PERF_LOG_RING_CAPACITY];

  /* A second, control-thread-producer instance for the direct-atomic setters
   * that bypass the command ring entirely (FX/monitor params, the limiter,
   * overdub feedback, and the common in-track undo/redo swap) — splitting by
   * producer thread keeps both rings single-producer/single-consumer with no
   * new synchronization, at the cost of the drain thread appending two
   * streams to events.log that are monotonic per-stream but not globally
   * merged (see the format doc). Sized far smaller than log_ring: these are
   * human-paced UI edits, not per-buffer audio-thread traffic. */
  le_perf_log_ring log_ctrl_ring;
  le_perf_log_entry log_ctrl_storage[LE_PERF_LOG_CTRL_RING_CAPACITY];

  /* Retired-layer persistence (part 5, D-LAYER): every completed overdub
   * pass's PCM, copied into a fresh heap buffer the moment it retires —
   * before pool eviction, a track clear, or redo-invalidation can reclaim
   * its slot and let a later write destroy it. Control-thread-producer
   * (le_stage_retired_layer, engine_commands.c), drained by perf_drain.c
   * into numbered layer files + sidecar manifest entries. Re-initialised on
   * every arm, same as the two rings above. */
  le_layer_staging_ring layer_staging_ring;
  le_staged_layer layer_staging_storage[LE_LAYER_STAGING_RING_CAPACITY];

  /* The capture-to-disk drain thread (perf_drain.h), spawned by le_perf_arm
   * right after the ring set above is published and joined by le_perf_disarm
   * before the rings are freed. Opaque here (perf_drain.c owns the
   * definition) — control-thread lifecycle only; engine_process.c never
   * touches it. NULL when not armed. */
  struct le_perf_drain* drain;

  /* The offline render worker (perf_render.h, part 7) — independent of the
   * arm/disarm/drain lifecycle above: a render reads only a finalized
   * capture directory from disk, never live engine state, so it can run
   * whether or not this engine is currently armed. Opaque here (perf_render.c
   * owns the definition). NULL when no render is active. */
  struct le_perf_render* render;
} le_perf_capture;

struct le_engine {
  /* The device backend driving the lifecycle (le_select_backend's choice),
   * remembered so le_engine_stop / le_engine_destroy release the device through
   * the same seam that opened it. NULL until the first device open; set once the
   * device is open (so "running implies backend set") and retained across
   * stop/start cycles. close() is idempotent, so a stale value never harms. */
  const le_device_backend* backend;

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
  /* le_audio_backend actually running, published in the snapshot. Set to
   * LE_BACKEND_MINIAUDIO in the configure/reset path and republished at device
   * open from the backend's negotiated le_device_open_result.active_backend
   * (ASIO on Windows, miniaudio on macOS/Linux). */
  _Atomic int32_t a_active_backend;
  /* Input channels whose Core Audio label marks them as loopback; never
   * recorded, monitored, or routable. Computed once at device open. */
  _Atomic uint32_t a_excluded_input_mask;
  /* Structural output gate: bit c set => output channel c is ENABLED (a routing
   * target). A cleared bit removes the output from the mix fan-out while leaving
   * every lane/monitor mask untouched. Written by the control thread
   * (LE_CMD_SET_OUTPUT_ENABLED), read once per process() on the audio thread and
   * published in the snapshot. All bits set on a fresh configure (default-on). */
  _Atomic uint32_t a_output_enabled_mask;
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

  /* Global master output gain (float bits, 0..1), applied post-mix to the final
   * output. Written by the control thread (LE_CMD_SET_MASTER_GAIN), read once
   * per process() on the audio thread. Unity (1.0) by default / on configure. */
  _Atomic uint32_t a_master_gain_bits;

  /* Master peak limiter, applied post-gain to the additive mix so the summed
   * output (many tracks + overdub layers + monitoring) cannot hard-clip in the
   * driver. Feed-forward, no lookahead: instant attack (clamp this frame to the
   * ceiling) + smooth release. OFF by default so the deterministic native tests
   * see the raw mix; the app enables it. ceiling is float bits in (0,1]. */
  _Atomic int32_t a_limiter_enabled;
  _Atomic uint32_t a_limiter_ceiling_bits;
  float lim_gain; /* audio-thread-local smoothed gain reduction (1 = no cut) */

  /* Overdub feedback: the existing loop content at the write head is scaled by
   * this before the new input is layered in, so stacked overdubs can't grow
   * without bound. Unity (1.0) by default == the classic additive overdub (and
   * what the native tests assert); < 1.0 decays older layers. Float bits. */
  _Atomic uint32_t a_overdub_fb_bits;

  /* Performance-recording capture: published status atomics (le_snapshot's
   * whole surface for this slice) plus the RT-owned ring set/config in `perf`
   * (le_perf_capture above). */
  _Atomic int32_t a_perf_armed;
  _Atomic uint64_t a_perf_frames;
  _Atomic uint32_t a_perf_overruns;
  /* Perf-log ring drops (part 3), tracked separately from a_perf_overruns
   * (the PCM-ring overrun count from part 1) — a dropped log entry and a
   * dropped audio sample are different failure modes worth telling apart in
   * a native test. Not surfaced via le_snapshot: no Dart consumer needs this
   * yet (native tests read the atomic directly); add it there if a later
   * part does. */
  _Atomic uint32_t a_perf_log_overruns;
  _Atomic uint32_t a_perf_log_ctrl_overruns;
  /* Retired-layer staging drops (part 5) — the staging ring rejected a
   * layer (LE_LAYER_STAGING_RING_CAPACITY exceeded), so its PCM was freed
   * unpersisted instead of queued for the drain thread. Same rationale as
   * the two atomics above: not surfaced via le_snapshot yet. */
  _Atomic uint32_t a_perf_layer_overruns;
  le_perf_capture perf;

  /* Tracks. */
  le_track tracks[LE_MAX_TRACKS];
  int32_t track_count;

  /* Command ring + pre-allocated backing storage. */
  le_ring ring;
  le_command ring_storage[LE_RING_CAPACITY];

  /* Event ring: the reverse direction (audio thread = producer, control thread
   * = consumer), carrying LE_EVT_LAYER_RETIRED — the pool slot of a completed
   * overdub-pass snapshot for the control thread to push onto that track's undo
   * stack. Same SPSC ring type; the roles are simply swapped. Drained at the
   * top of le_engine_get_snapshot (the UI poll) and of the transport calls. */
  le_ring evt_ring;
  le_command evt_storage[LE_RING_CAPACITY];

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
   * at the next loop top. Arming creates no undo layer (layers are captured
   * per pass on the audio thread), so cancelling is a plain disarm. */
  int quantize; /* global default */
  /* Per-track quantize override: -1 inherit the global default, 0 force off,
   * 1 force on. The effective value drives le_engine_record's arm decision. */
  int track_quantize[LE_MAX_TRACKS];
  int armed[LE_MAX_TRACKS];
  /* What each arm is waiting for: 0 = loop top (quantize), 1 = input level
   * (auto-record). Lets toggling one feature cancel only its own arms. */
  int armed_trigger[LE_MAX_TRACKS];

  /* Loop length. The global default (0 auto-rounds up to whole base loops on
   * stop; K >= 1 fixes K base loops) applies to tracks that inherit. A track's
   * target_multiple is 0 to inherit the global default, or K >= 1 to fix it.
   * Control-thread-owned. */
  int default_multiple;
  int target_multiple[LE_MAX_TRACKS];

  /* When `rec_dub` is set, finalizing a recording with a record (second) press
   * continues into overdub instead of playback (the second-press "rec/dub"
   * mode). A stop still ends in playback/stopped. Independently of this flag, a
   * track recorded over an existing master that auto-finishes (reaches its loop
   * length with no press) always continues into overdub, so layering stays live
   * rather than auto-stopping to playback the moment the loop completes.
   * Control-thread default, read on the audio thread via the finalize
   * end-state. */
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

  /* Explicit context + resolved device ids, used when capturing from a detected
   * loopback device (use_loopback_capture) or when a device is pinned by id.
   * Owned and managed by the miniaudio backend (engine_miniaudio.c). */
  ma_context context;
  int context_initialised;
  ma_device_id capture_id;
  ma_device_id playback_id;
  /* 1 when capture_id holds a resolved (pinned/loopback) capture device, so the
   * portable core can compute the loopback-excluded input mask from that device
   * UID after open. */
  int capture_id_set;
};

/* Fills `out` (room for `max`) with the host's playback or capture devices and
 * writes the count into *count. Uses a transient context so it never disturbs a
 * running device. `capture` selects the direction. Defined in engine.c;
 * declared here because the Linux JACK pin hook resolves friendly device names
 * through it (le_jack_device_name). */
int32_t enumerate_devices(le_device_info* out, int32_t max, int32_t* count,
                          int capture);

/* Device-resolution helpers defined in the portable core (engine.c) and shared
 * with the miniaudio backend (engine_miniaudio.c), which resolves pinned /
 * loopback device ids at device open. le_find_loopback also backs the FFI
 * le_detect_loopback. Both operate on an already-open ma_context. */
void le_find_loopback(ma_context* ctx, le_loopback_info* out,
                      ma_device_id* out_id);
int le_resolve_device_id(ma_context* ctx, int capture, const char* want,
                         ma_device_id* out_id);

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

/* float/double <-> atomic-bits helpers. The published metering/gain fields are
 * stored as _Atomic uint32_t/uint64_t bit patterns; these reinterpret without a
 * strict-aliasing violation. `static inline` here (like load_i32/store_i32) so
 * every engine TU shares one copy with no external symbol. */
static inline uint32_t f32_to_bits(float v) {
  uint32_t b;
  memcpy(&b, &v, sizeof(b));
  return b;
}
static inline float bits_to_f32(uint32_t b) {
  float v;
  memcpy(&v, &b, sizeof(v));
  return v;
}
static inline uint64_t f64_to_bits(double v) {
  uint64_t b;
  memcpy(&b, &v, sizeof(b));
  return b;
}
static inline double bits_to_f64(uint64_t b) {
  double v;
  memcpy(&v, &b, sizeof(v));
  return v;
}
static inline void store_f32(_Atomic uint32_t* slot, float v) {
  atomic_store_explicit(slot, f32_to_bits(v), memory_order_relaxed);
}
static inline float load_f32(_Atomic uint32_t* slot) {
  return bits_to_f32(atomic_load_explicit(slot, memory_order_relaxed));
}

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_ENGINE_PRIVATE_H */
