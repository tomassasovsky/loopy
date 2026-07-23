/*
 * loopy_engine_api.h — the C ABI exposed to Dart via FFI.
 *
 * This is the single header consumed by ffigen. Everything here is POD or an
 * opaque handle; no C++; no callbacks into Dart. The audio callback that backs
 * this API performs no allocation, locking, or I/O (see engine.c).
 *
 * Scope: device lifecycle, per-input live monitoring, level metering, a loopback
 * round-trip latency harness, the lock-free command ring, and a multi-track,
 * multi-lane looper. Each track owns up to LE_MAX_LANES lanes; a lane records
 * one hardware input into its own clean mono buffer (never merged with sibling
 * lanes) with per-lane routing / volume / mute / effects, while the track owns
 * the shared transport (record / master-loop length / overdub / loop playback /
 * loop multiples / clear) and one undo span across all its lanes.
 */
#ifndef LOOPY_ENGINE_API_H
#define LOOPY_ENGINE_API_H

#include <stdint.h>

/* Maximum number of hardware input/output channels the engine opens and routes.
 * Per-track buffers are mono; tracks record from one input channel and play to
 * any subset of the output channels (see le_track_snapshot.output_mask). */
#define LE_MAX_CHANNELS 32

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define LE_EXPORT __declspec(dllexport)
#else
#define LE_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

/* Result codes returned by lifecycle calls. */
typedef enum le_result {
  LE_OK = 0,
  LE_ERR_INVALID = -1,       /* null handle or bad argument */
  LE_ERR_ALREADY_RUNNING = -2,
  LE_ERR_NOT_RUNNING = -3,
  LE_ERR_DEVICE = -4,        /* miniaudio failed to init/start the device */
  LE_ERR_UNSUPPORTED = -5,   /* a plugin's bus topology is not a stereo (or
                              * mono-adaptable) effect — instrument / multi-bus /
                              * sidechain / wrong channel count (D-BUS) */
  LE_ERR_CAPACITY = -6,      /* a requested allocation would exceed engine
                              * capacity (A6, D17): N bars of the current
                              * signature at the slowest possible tempo (30
                              * BPM) would not fit in max_loop_frames */
} le_result;

/* Latency-harness phase, mirrored in le_snapshot.latency_state. */
typedef enum le_latency_state {
  LE_LATENCY_IDLE = 0,
  LE_LATENCY_MEASURING = 1, /* impulse emitted, waiting for it to return */
  LE_LATENCY_DONE = 2,      /* measured_latency_ms is valid */
  LE_LATENCY_TIMEOUT = 3,   /* no loopback detected within the window */
} le_latency_state;

/* Per-track state machine, mirrored in le_snapshot.track_state. */
typedef enum le_track_state {
  LE_TRACK_EMPTY = 0,
  LE_TRACK_RECORDING = 1,    /* capturing the first pass (defines the loop) */
  LE_TRACK_OVERDUBBING = 2,  /* summing input into the existing loop */
  LE_TRACK_PLAYING = 3,
  LE_TRACK_STOPPED = 4,      /* buffer retained, playback halted */
} le_track_state;

/* Where the current tempo came from, mirrored in le_snapshot.tempo_source
 * (D7 precedence). MANUAL and TAPPED are last-writer-wins; DERIVED is set only
 * when a defining loop finalizes with sync on and the source was NONE (a set
 * tempo is never re-derived); EXTERNAL is reserved for the Phase E MIDI-clock
 * follower and unused here. A DERIVED tempo survives clearing the loop that
 * produced it (the "dead tempo" lesson): only an explicit reset returns the
 * source to NONE. */
typedef enum le_tempo_source {
  LE_TEMPO_SOURCE_NONE = 0,     /* no tempo set; tempo_bpm reads 0 */
  LE_TEMPO_SOURCE_MANUAL = 1,   /* LE_CMD_SET_TEMPO */
  LE_TEMPO_SOURCE_TAPPED = 2,   /* LE_CMD_TAP_TEMPO */
  LE_TEMPO_SOURCE_DERIVED = 3,  /* derived from a defining loop (D7) */
  LE_TEMPO_SOURCE_EXTERNAL = 4, /* reserved: MIDI clock receive (Phase E) */
} le_tempo_source;

/* Click (metronome) audibility mode, mirrored in le_snapshot.click_mode — a
 * 4-value mode per the Sheeran manual §5.9.1, replacing the old boolean
 * metronome (D5). It gates WHEN the click voice sounds; WHERE it sounds is the
 * click output mask (le_engine_set_click_output — default no outputs).
 * Count-in clicks are audible in every mode except OFF while counting. */
typedef enum le_click_mode {
  LE_CLICK_OFF = 0,       /* never audible (count-ins still run, silently) */
  LE_CLICK_REC = 1,       /* while any track records or overdubs */
  LE_CLICK_REC_FIRST = 2, /* only during the DEFINING first-layer recording
                           * (incl. its count-in) */
  LE_CLICK_PLAY_REC = 3,  /* whenever the transport plays or records */
} le_click_mode;

/* The five architectural looper modes (B2a, D4/D10), mirrored in
 * le_snapshot.looper_mode. MULTI is today's behavior — independent per-track
 * loops, the whole engine as it exists before this series — and stays the
 * default. Sync/Song/Band/Free semantics (primary-track sync + divisions,
 * section sequencing, quantized section tracks, per-track independent
 * clocks) are NOT implemented yet: this part is only the field plus D4's
 * content-lock gate (le_looper_mode_locked, engine_process.c) that guards
 * switching it. Later B-series parts (B2b onward) give the non-MULTI values
 * their behavior; setting one here today just changes what is published,
 * with the engine's audio path staying exactly the MULTI behavior
 * regardless of the published value. This is a DIFFERENT axis from
 * InteractionMode (Dart-only: record/mute, what a track press does) — the
 * two never coexist under the same name (D10) and must not be confused. */
typedef enum le_looper_mode {
  LE_LOOPER_MODE_MULTI = 0, /* default: independent per-track loops (today's
                             * behavior, unchanged by this part) */
  LE_LOOPER_MODE_SYNC = 1,  /* primary-track sync + multiples/divisions (B3) */
  LE_LOOPER_MODE_SONG = 2,  /* section sequencing (B4) */
  LE_LOOPER_MODE_BAND = 3,  /* primary + independently-quantized sections
                             * (B3) */
  LE_LOOPER_MODE_FREE = 4,  /* independent per-track clocks (B2b) */
} le_looper_mode;

/* Maximum count-in length in measures (le_engine_set_count_in). */
#define LE_COUNT_IN_MAX_BARS 64

/* Maximum track length preset in bars (A6, D17;
 * le_engine_set_track_length_preset). 0 is AUTO, not a bar count. */
#define LE_LENGTH_PRESET_MAX_BARS 64

/* Classification of a cable-free loopback path used to auto-measure latency.
 * All of these capture the *digital* round-trip (output → OS mixer → capture);
 * they exclude DAC/ADC converter latency, so they under-report the true analog
 * round-trip. A physical loopback cable remains the only true analog measure. */
typedef enum le_loopback_kind {
  LE_LOOPBACK_NONE = 0,
  LE_LOOPBACK_BACKEND = 1,   /* device backend's built-in output loopback */
  LE_LOOPBACK_MONITOR = 2,  /* PulseAudio "Monitor of ..." source (Linux) */
  LE_LOOPBACK_VIRTUAL = 3,  /* named virtual driver (BlackHole, VB-Cable, ...) */
} le_loopback_kind;

/* Result of loopback detection. `device_name` is the capture device to open for
 * an auto-measurement (empty for the backend's built-in loopback, which the
 * duplex engine does not auto-route). */
typedef struct le_loopback_info {
  int32_t available; /* 0/1 */
  int32_t kind;      /* le_loopback_kind */
  char device_name[256];
} le_loopback_info;

/* Command codes posted into the engine's SPSC ring. */
typedef enum le_command_code {
  LE_CMD_NONE = 0,
  LE_CMD_MEASURE_LATENCY = 1,
  LE_CMD_RECORD = 2,    /* record / finalize-loop / toggle overdub */
  LE_CMD_STOP = 3,      /* halt playback (retain buffer) */
  LE_CMD_PLAY = 4,      /* resume playback */
  LE_CMD_CLEAR = 5,     /* erase the track, back to empty */
  LE_CMD_UNDO = 6,      /* remove the last overdub layer */
  LE_CMD_SET_VOLUME = 7,/* arg_f = 0..LE_MAX_GAIN */
  LE_CMD_SET_MUTE = 8,  /* arg_f = 0 (unmute) or 1 (mute) */
  /* ---- tempo grid (D6/D7). SET_TEMPO / SET_TIME_SIGNATURE / TAP_TEMPO are
   * REJECTED (no-op) while the tempo is locked: any track has content AND a
   * grid exists (loop_bars > 0 or tempo_source != none). Only clearing every
   * track releases the lock. */
  LE_CMD_SET_TEMPO = 9,  /* arg_f = bpm, clamped to 30..300; sets
                          * tempo_source = manual (last writer wins) */
  LE_CMD_SET_TIME_SIGNATURE = 10, /* arg_i = numerator, arg_f = denominator
                                   * (4 or 8); validated to the 17 supported
                                   * signatures (le_grid_signature_valid,
                                   * tempo_grid.h) — others are dropped */
  LE_CMD_TAP_TEMPO = 11, /* two taps set the tempo from their interval; sets
                          * tempo_source = tapped (last writer wins) */
  LE_CMD_SET_SYNC_TEMPO = 12, /* arg_f = 0/1: whether finalizing a defining
                               * loop establishes the loop<->grid relationship
                               * (bar count / tempo derivation — see
                               * le_engine_set_sync_tempo) */
  LE_CMD_SET_RECORD_OFFSET = 13, /* arg_i = round-trip latency in frames */
  LE_CMD_SET_INPUT_MASK = 14,    /* route a track's record sources (arg_f =
                                  * track, arg_i = input bitmask) */
  LE_CMD_SET_OUTPUT_MASK = 15,   /* route a track's playback destinations
                                  * (arg_f = track, arg_i = output bitmask) */
  LE_CMD_ARM = 16,    /* arg_i = track: arm a quantized record (fire at loop top) */
  LE_CMD_DISARM = 17, /* arg_i = track: cancel a pending quantized record */
  LE_CMD_SET_QUANTIZE_DIV = 18, /* arg_i = le_grid_div (tempo_grid.h): 0 off /
                                 * 1 bar / 2..5 = 1/2..1/16 note. State only in
                                 * this part — the musical arm machinery that
                                 * consumes it lands in A3. Default off. */
  /* ---- click + count-in (A2, D5/D9). The click is its own routable source:
   * it sums into the channels of its output mask AFTER the master bus and the
   * performance tap, so it bypasses master gain / limiter / metering and is
   * excluded from performance capture and export by construction. None of
   * these commands is therefore perf-logged. */
  LE_CMD_SET_CLICK_MODE = 19, /* arg_i = le_click_mode (0..3). Default off. */
  LE_CMD_SET_LANE_FX = 20, /* set a lane chain entry's type (and reset its DSP
                            * state). arg_i = (channel << 16) | (lane << 8) |
                            * index, arg_f = le_fx_type. */
  LE_CMD_SET_LANE_FX_COUNT = 21, /* set a lane's active chain length.
                                  * arg_i = (channel << 16) | (lane << 8) |
                                  * count. */
  LE_CMD_SET_CLICK_OUTPUT = 22,  /* click output routing. trackmask arm:
                                  * channel unused, mask = output bitmask
                                  * (default 0 = no outputs). */
  LE_CMD_COMMIT_SESSION = 23,    /* arg_i = base loop length in frames: publish
                                  * the master loop and start imported tracks */
  LE_CMD_SET_CLICK_VOLUME = 24,  /* arg_f = 0..LE_MAX_GAIN (the click's ONLY
                                  * gain stage — master gain never applies). */
  LE_CMD_SET_COUNT_IN = 25,      /* arg_i = count-in length in measures
                                  * (0 = off, up to LE_COUNT_IN_MAX_BARS).
                                  * 0 also cancels an in-progress count-in. */
  /* ---- multi-lane recording (a track owns an array of lanes) ----
   * Each lane records one hardware input into its own clean mono buffer; all
   * lanes of a track share one transport and one undo span. The lane *count* is
   * a control-thread plain int (le_engine_set_lane_count), not a ring command;
   * these RT-concurrent lane edits go through the ring. arg packing differs per
   * command so a 32-bit mask / a negative channel / a float volume each
   * round-trips exactly (see the lane setters). */
  LE_CMD_SET_LANE_INPUT = 26,  /* lane records this input channel (-1 = none).
                                * arg_f = channel*LE_MAX_LANES + lane,
                                * arg_i = input channel (or -1). */
  LE_CMD_SET_LANE_OUTPUT = 27, /* lane playback destinations.
                                * arg_f = channel*LE_MAX_LANES + lane,
                                * arg_i = output bitmask. */
  LE_CMD_SET_LANE_VOLUME = 28, /* lane playback gain.
                                * arg_i = channel*LE_MAX_LANES + lane,
                                * arg_f = 0..LE_MAX_GAIN. */
  LE_CMD_SET_LANE_MUTE = 29,   /* lane mute.
                                * arg_i = channel*LE_MAX_LANES + lane,
                                * arg_f = 0/1. */
  /* ---- per-input live monitor (one slot per hardware input) ----
   * Each hardware input has a SINGLE live-monitor chain: input-level enable gates
   * the whole input, then the input's live signal runs through its own effect
   * chain / routing / volume / mute. An empty chain is the clean (dry) path. Never
   * recorded, independent of all track state. The chain you monitor live is the
   * chain that is snapshot-copied onto a track lane when you record into it (a
   * clean monitor chain leaves the lane's own staged chain untouched). The
   * monitor commands are keyed by input only (no per-lane index): the FX commands
   * carry (input, index, type) in the typed `fx` arm (lane unused), the count in
   * `fxcount` (lane unused); output rides the `trackmask` arm (channel = input);
   * volume/mute use the generic { arg_i = input, arg_f = value } arm. */
  LE_CMD_SET_MONITOR_INPUT = 30, /* enable/disable a hardware input's monitor.
                                  * arg_i = input, arg_f = enabled (0/1). */
  LE_CMD_SET_MONITOR_INPUT_FX = 31, /* set the input's chain entry type (and reset
                                     * its DSP state). fx arm: channel = input,
                                     * index, type (lane unused). */
  LE_CMD_SET_MONITOR_INPUT_FX_COUNT = 32, /* set the input's active chain length.
                                           * fxcount arm: channel = input, count
                                           * (lane unused). */
  LE_CMD_SET_MONITOR_INPUT_OUTPUT = 33, /* input monitor playback destinations.
                                         * trackmask arm: channel = input, mask. */
  LE_CMD_SET_MONITOR_INPUT_VOLUME = 34, /* input monitor gain.
                                         * arg_i = input, arg_f = 0..LE_MAX_GAIN. */
  LE_CMD_SET_MONITOR_INPUT_MUTE = 35,   /* input monitor mute.
                                         * arg_i = input, arg_f = 0/1. */
  LE_CMD_SET_MASTER_GAIN = 36, /* global post-mix output gain. arg_f = 0..1. */
  LE_CMD_SET_OUTPUT_ENABLED = 37, /* structural output gate (preserves routes).
                                   * arg_i = output index, arg_f = enabled (0/1).
                                   * A disabled output is skipped in the mix
                                   * fan-out regardless of any lane/monitor mask
                                   * pointing at it; masks are untouched. */
  LE_CMD_DUB_SHADOW = 38, /* supply a shadow pool slot for per-pass overdub
                           * layer capture. lanei arm: channel, value = slot
                           * (lane unused). Lane buffers are allocated by the
                           * control thread before the push. */
  LE_CMD_UNDO_TO_EMPTY = 39,   /* undo past the base layer: track to EMPTY,
                                * len 0, master grid kept. arg_i = track. */
  LE_CMD_REDO_FROM_EMPTY = 40, /* reinstate an undone-to-empty track. lanei
                                * arm: channel, value = restored length. The
                                * control thread already swapped a_live. */
  LE_CMD_RESTORE_CLEAR = 43,   /* undo of an undoable clear: reinstate a cleared
                                * track. `restore` arm. Distinct from REDO_FROM_
                                * EMPTY because it restores the pre-clear STATE
                                * (which may be STOPPED) and re-establishes the
                                * master grid a whole-rig clear reset — REDO_
                                * FROM_EMPTY only ever reads the clock. The
                                * control thread already swapped a_live. */

  /* ---- performance-recording capture (arm/disarm the RT taps) ----
   * Zero-payload commands: the control thread allocates the capture rings and
   * writes the frozen config (master.perf_master_out_ch / .perf_input_mask,
   * struct le_engine.perf, engine_private.h) directly into engine state BEFORE
   * pushing the command, then the ring's release/acquire ordering makes that
   * state visible to the audio thread once it pops — the same
   * control-allocates/publish pattern as le_post_dub_shadows and the FX delay
   * lines, so no payload is needed. */
  LE_CMD_PERF_ARM = 41,    /* begin publishing to the perf capture rings */
  LE_CMD_PERF_DISARM = 42, /* stop; control frees the rings after a quiescent
                            * handshake once the audio thread acks this */

  /* ---- track length presets (A6, D17) ----
   * A per-track DEFINING-recording length preset, orthogonal to the existing
   * fixed-multiple machinery (le_effective_multiple / target_multiple,
   * engine_private.h): the multiple mechanism fixes a NON-defining track's
   * length in whole BASE loops once a master already exists; this preset
   * governs the DEFINING (first/master) recording itself — before any base
   * loop length exists — and drives whether tempo, bar count, or both are
   * derived from it (see le_arm_length_preset_target / finalize_master,
   * engine_process.c). Values 0 (AUTO) or 1..LE_LENGTH_PRESET_MAX_BARS
   * (fixed N bars) round-trip identically; anything else is clamped by the
   * audio thread on apply, matching every other per-track setter. Inert on
   * an already-recorded track until it is re-recorded. */
  LE_CMD_SET_LENGTH_PRESET = 44, /* arg_i = channel, arg_f = bars (0 = AUTO,
                                  * 1..LE_LENGTH_PRESET_MAX_BARS = fixed). */

  /* ---- looper mode (B2a, D4) ----
   * The five-mode axis (le_looper_mode). LOCKED (silently rejected, no-op)
   * whenever ANY track has content (state != EMPTY) — le_looper_mode_locked,
   * engine_process.c. Simpler than the D6 tempo lock: content alone, no grid
   * or count-in check. Only clearing every track releases the lock. Mode
   * semantics beyond the field itself land in B2b onward; this part accepts
   * any of the 5 values unconditionally once unlocked. Not perf-logged (a
   * mode switch changes no audible output in this part). */
  LE_CMD_SET_LOOPER_MODE = 45, /* arg_i = le_looper_mode (0..4) */

  /* ---- primary track / Sync + Band (B3, D16/D18) ----
   * Designates track [arg_i] the "crowned" primary track for Sync/Band's
   * multiple-or-division sync (a_primary_track). Accepted in ANY mode (the
   * crown is a persistent per-session designation per D18 — it simply has no
   * effect outside Sync/Band); rejected only for an out-of-range channel.
   * There is no "un-crown": D18's no-auto-reassignment rule means the only
   * way to change it is another CROWN_PRIMARY. See le_sync_quantize_active
   * (engine_private.h) for how this gates Sync/Band's finalize behavior. */
  LE_CMD_CROWN_PRIMARY = 46, /* arg_i = channel */

  /* Event codes (audio thread -> control thread, on the engine's evt_ring —
   * the reverse SPSC direction; numbered apart from the commands for clarity). */
  LE_EVT_LAYER_RETIRED = 100, /* a completed overdub-pass snapshot. evt arm:
                               * channel, slot, generation. */
} le_command_code;

/* Per-lane / per-monitor-input effects: each lane (and each live monitor input)
 * carries an ordered chain of up to LE_FX_MAX entries, each with a type and
 * LE_FX_PARAMS normalized (0..1) parameters. The chain is non-destructive (the
 * recording is ALWAYS dry; effects color playback only) and every active entry
 * applies in chain order — there is no pre/post stage. The cap exists only so
 * the audio thread reads a fixed-size, allocation-free array — it is far beyond
 * musical need, not a CPU limit. */
#define LE_FX_MAX 8
#define LE_FX_PARAMS 4

/* Built-in effect types. Designed so a hosted VST3/CLAP plugin can later slot
 * in as just another type. Each type reads its entry's LE_FX_PARAMS normalized
 * values:
 *   DRIVE:   p0 = drive amount, p1 = output level
 *   FILTER:  p0 = cutoff, p1 = resonance        (resonant low-pass)
 *   DELAY:   p0 = time, p1 = feedback, p2 = wet mix
 *   TREMOLO: p0 = rate, p1 = depth
 *   OCTAVER: p0 = shift (0 = -2 oct, .5 = unison, 1 = +2 oct), p1 = tone,
 *            p2 = mix, p3 = mode (< .5 = phase vocoder, >= .5 = PSOLA; stored
 *            but inert until the formant-preserving rewrite reads it)
 * Every other type leaves its unused trailing params (including p3) at 0; no
 * non-octaver effect reads p3.
 *   ECHO:    p0 = time, p1 = feedback, p2 = mix  (tape-style, damped repeats)
 *   REVERB:  p0 = size, p1 = damping, p2 = mix   (Schroeder room tail; a mono
 *            input yields a decorrelated stereo tail spread across the first two
 *            output channels of the lane/monitor mask) */
typedef enum le_fx_type {
  LE_FX_NONE = 0,
  LE_FX_DRIVE = 1,
  LE_FX_FILTER = 2,
  LE_FX_DELAY = 3,
  LE_FX_TREMOLO = 4,
  LE_FX_OCTAVER = 5,
  LE_FX_ECHO = 6,
  LE_FX_REVERB = 7,
  /* A hosted VST3/CLAP plugin. Unlike the built-ins this row carries no fixed
   * params and no DSP state in le_fx_state — its `process` forwards to a plugin
   * host owned by an le_plugin_slot, loaded on the control thread (see
   * le_engine_set_lane_plugin). An LE_FX_PLUGIN entry whose slot is not yet
   * published (or is being torn down) renders dry passthrough. */
  LE_FX_PLUGIN = 8,
} le_fx_type;

/* Which device backend to open. The default (0) opens miniaudio's default
 * backend for the platform (Core Audio on macOS, the Linux preference list).
 * On Windows the engine forces ASIO, which is only available in a
 * LOOPY_ENABLE_ASIO build. */
typedef enum le_audio_backend {
  LE_BACKEND_MINIAUDIO = 0, /* default: miniaudio's default platform backend */
  LE_BACKEND_ASIO = 1,   /* Windows ASIO (requires LOOPY_ENABLE_ASIO) */
} le_audio_backend;

/* A hardware audio device discovered by enumeration (le_enumerate_*).
 *
 * `id` is an opaque, backend-specific token suitable for pinning a device via
 * le_config.playback_device_id / capture_device_id. On every string-id backend
 * (CoreAudio, ALSA, PulseAudio, sndio) it is the device's native id string; it
 * round-trips byte-for-byte back into le_config. `name` is the human-readable
 * label; `is_default` marks the system default for that direction. */
typedef struct le_device_info {
  char id[256];
  char name[256];
  int32_t is_default;      /* 0/1 */
  int32_t input_channels;  /* 0 = unknown (miniaudio); an ASIO probe fills it */
  int32_t output_channels; /* 0 = unknown */
  /* ASIO-only: the driver's selectable buffer sizes and supported sample rates,
   * probed by le_enumerate_asio_drivers so the UI can offer the driver's real
   * options instead of a generic list. Count 0 for non-ASIO devices (the UI
   * then keeps its default lists). Sizes/rates are ascending; the buffer set
   * always includes the driver's preferred size. */
  int32_t asio_buffer_sizes[8];
  int32_t asio_buffer_count;
  int32_t asio_sample_rates[8];
  int32_t asio_sample_rate_count;
} le_device_info;

/* Requested device configuration. Any channel field set to 0 uses the device
 * default; counts are clamped to LE_MAX_CHANNELS. */
typedef struct le_config {
  int32_t sample_rate;
  int32_t buffer_frames;
  int32_t max_loop_frames; /* per-track buffer cap; 0 => default (8 min @ sr) */
  int32_t use_loopback_capture; /* 1 = capture from a detected loopback device */
  int32_t input_channels;  /* hardware capture channels (0 => device default) */
  int32_t output_channels; /* hardware playback channels (0 => device default) */
  /* Pin a specific device by id (an `id` from le_enumerate_*). An empty string
   * opens the system default (the unchanged behaviour). use_loopback_capture
   * overrides capture_device_id when a loopback device is detected. */
  char playback_device_id[256];
  char capture_device_id[256];
  /* le_audio_backend to open; 0 (LE_BACKEND_MINIAUDIO) selects the default
   * miniaudio path, LE_BACKEND_ASIO the Windows ASIO backend. Honored at start
   * via le_select_backend (a LOOPY_ENABLE_ASIO Windows build); elsewhere every
   * value resolves to miniaudio. */
  int32_t backend;
  /* Selected ASIO driver name (used by the ASIO backend in Part 2). Empty and
   * ignored on the default path. */
  char asio_driver[256];
} le_config;

/* Maximum number of simultaneous looper tracks (two banks of four). */
#define LE_MAX_TRACKS 8

/* Maximum hardware input channels a single track can fan out across lanes, and
 * therefore the maximum number of lanes per track: one lane per input. A lane
 * is the fundamental recordable unit — one clean mono buffer fed by one input —
 * and a track owns up to this many, all sharing one transport and undo span.
 * Lane buffers are allocated lazily (only recorded/counted lanes), so the
 * worst-case LE_MAX_TRACKS * LE_MAX_LANES does not inflate idle memory.
 *
 * This also bounds the per-input live-monitor array (le_engine_set_monitor_input
 * and friends), so live monitoring covers input channels [0, LE_MAX_INPUTS). On
 * an interface with more than LE_MAX_INPUTS inputs, a higher-numbered channel
 * can still be RECORDED into a lane (le_engine_set_lane_input accepts any
 * in-range channel) but cannot be monitored; raise LE_MAX_INPUTS if that ceiling
 * is ever a problem. */
#define LE_MAX_INPUTS 8
#define LE_MAX_LANES LE_MAX_INPUTS

/* Ceiling for a per-lane / per-monitor channel volume. 2.0 is +6.02 dB, so the
 * UI can boost a quiet take/input up to +6 dB rather than only attenuate from
 * unity (1.0 = 0 dB). The output limiter downstream still guards the bus. */
#define LE_MAX_GAIN 2.0f

/* Number of points in the loop visualization buffer (le_engine_read_visual):
 * one peak per loop position, spanning exactly one master loop. */
#define LE_VIZ_POINTS 512

/* Per-lane state published via le_engine_get_lane: one recordable input lane of
 * a track. A lane records exactly one hardware input (input_channel, -1 = none)
 * into its own clean mono buffer and plays back to the outputs in output_mask,
 * scaled by volume and gated by muted. length_frames is the lane's recorded
 * length (all lanes of a track share the same length via the one transport). */
typedef struct le_lane_snapshot {
  int32_t input_channel; /* hardware input this lane records (-1 = none) */
  uint32_t output_mask;  /* bitmask of output channels this lane plays to */
  float volume;          /* 0..LE_MAX_GAIN */
  int32_t muted;         /* 0/1 */
  int32_t length_frames; /* frames captured into this lane's buffer */
  float rms;             /* 0..1 */
  float peak;            /* 0..1 */
} le_lane_snapshot;

/* Per-track state published in le_snapshot.tracks.
 *
 * A track is a multi-lane container: it owns the transport (state, multiple,
 * undo/redo depth) and up to lane_count lanes. The volume/muted/length/
 * input_mask/output_mask/rms/peak fields mirror lane 0 for backward
 * compatibility (a track always has at least one lane); per-lane state is read
 * with le_engine_get_lane. */
typedef struct le_track_snapshot {
  int32_t state;         /* le_track_state */
  float volume;          /* lane 0 volume, 0..LE_MAX_GAIN */
  int32_t muted;         /* lane 0 mute, 0/1 */
  int32_t length_frames; /* frames captured (== multiple * master length) */
  int32_t multiple;      /* track length in whole base loops (>= 1) */
  int32_t undo_depth;    /* available undo steps (overdub layers). A track
                          * cleared via le_engine_clear_undoable reads 0 here
                          * even though its erased take's layers are still held:
                          * they are not peelable until the restore point above
                          * them is undone. See clear_restore. */
  int32_t clear_restore; /* 1 when the next le_engine_undo restores a cleared
                          * take rather than peeling a layer — i.e. "undo would
                          * do something" on a track whose undo_depth is 0. */
  int32_t redo_depth;    /* available redo steps */
  float rms;             /* lane 0 RMS, 0..1 */
  float peak;            /* lane 0 peak, 0..1 */
  uint32_t input_mask;   /* lane 0 input as a bitmask (1 << input_channel, or 0
                          * when lane 0 records no input) */
  uint32_t output_mask;  /* lane 0 output mask */
  int32_t lane_count;    /* number of active lanes (1..LE_MAX_LANES) */
  int32_t layer_in_flight; /* 0/1: an overdub undo layer is still being
                            * captured/drained (punch tail window). Session
                            * capture waits this out before exporting. */
  int32_t pending;         /* 0/1: a quantized/signal arm is waiting to fire */
  /* Trailing (A6, D17): the DEFINING-recording length preset — 0 = AUTO,
   * 1..LE_LENGTH_PRESET_MAX_BARS = fixed N bars. Inert on a track that
   * already has content; applies to the next defining recording only. See
   * le_engine_set_track_length_preset. */
  int32_t length_preset_bars;
  /* Trailing (B3, D16): 0 = this track's length is an ordinary multiple of
   * the base loop (see `multiple` above — the common case in every mode,
   * including Sync/Band multiples). 2 or 4 = this track is a SYNC DIVISION:
   * it plays a repeating 1/2 or 1/4 slice of the primary track's length,
   * phase-locked to the primary's loop top (`multiple` reads 1, inertly, for
   * a division track). Only ever nonzero in Sync/Band mode on a non-primary
   * track. See le_sync_quantize_active (engine_private.h) for how it's set. */
  int32_t sync_divisor;
} le_track_snapshot;

/* Lock-free snapshot of engine state, published by the audio thread and read by
 * Dart on a render-rate timer. Fields are individually atomic; readers may see
 * a one-frame-stale mix across fields, which is fine for metering/UI. */
typedef struct le_snapshot {
  int32_t running;            /* 0/1: device is open and the callback is live */
  /* 0/1: the pinned (or default) device is currently present. DISTINCT from
   * `running`: a device can be lost (device_present == 0) while the engine
   * object still "runs" until it is restarted. Set from the RT-adjacent device
   * notification callback; the Dart layer derives a higher-level isConnected
   * from it and drives any reconnection (no reconnection happens in native). */
  int32_t device_present;
  int32_t sample_rate;
  int32_t buffer_frames;
  int32_t input_channels;     /* negotiated hardware capture channels */
  int32_t output_channels;    /* negotiated hardware playback channels */
  /* Bitmask of input channels excluded from recording/monitoring/routing
   * because their hardware (Core Audio) label matches "loopback". Such channels
   * are skipped in the capture average and in monitoring, and are stripped from
   * any track input mask. Always 0 off macOS / when no label matches. */
  uint32_t excluded_input_mask;
  uint64_t frames_processed;  /* total frames seen by the callback */
  /* Device dropouts (xruns) since the device started, as reported by the backend.
   * The Windows ASIO backend tallies the driver's kAsioOverload notifications;
   * the miniaudio backends (macOS / Linux) expose no portable per-callback xrun
   * signal, so this stays 0 there. Monotonic; cleared on each fresh start. */
  uint32_t xrun_count;
  float input_rms;            /* 0..1 */
  float input_peak;           /* 0..1 */
  float output_rms;           /* 0..1 */
  int32_t latency_state;      /* le_latency_state */
  double measured_latency_ms; /* valid when latency_state == LE_LATENCY_DONE */

  /* Looper transport (free mode: the first finalized recording sets the one
   * master loop length; everything else plays/overdubs against it). */
  int32_t master_length_frames;   /* 0 until the first recording is finalized */
  int32_t master_position_frames; /* current loop playhead */

  /* Record-offset latency compensation (frames). Recorded/overdubbed input is
   * written this many frames earlier in the loop so it aligns with what the
   * player heard. Auto-set by a latency measurement; manually overridable. */
  int32_t record_offset_frames;

  /* Added latency (frames) of the highest-latency effect active in any audible
   * or monitored lane chain — the MAXIMUM across active effects, so it stays
   * forward-compatible as effects accrue. Today the formant-preserving octaver
   * is the only contributor (~LE_PV_N frames; both PV and PSOLA modes report the
   * same value); every other effect adds 0, so this reads 0 whenever no octaver
   * is engaged. The Dart layer divides by sample_rate to show milliseconds and
   * warn a performer monitoring through the octaver. PURELY informational: this
   * does NOT feed record_offset_frames or any compensation — it only surfaces
   * the lag so the UI can suggest the lower-latency choice. */
  int32_t fx_added_latency_frames;

  /* Global master output gain (0..1) applied post-mix to the final output, after
   * every track/lane/monitor lane has summed in. 1.0 (unity) by default and on
   * every fresh configure. Set via le_engine_set_master_gain. */
  float master_gain;

  /* le_audio_backend actually running (negotiated). On Windows this is always
   * ASIO; on macOS/Linux it is the miniaudio backend. */
  int32_t active_backend;

  /* Structural output gate, one bit per hardware output channel (bit c => output
   * c is ENABLED). A disabled output is removed as a mix target — skipped in the
   * fan-out regardless of any lane/monitor mask pointing at it — while its stored
   * route masks are preserved (turning it back on restores them). Default: all
   * enabled (every bit in [0, output_channels) set) on a fresh configure, so the
   * absence of any gate is "all outputs on". Outputs beyond the device channel
   * count are reported enabled but never sounded. Set via
   * le_engine_set_output_enabled. */
  uint32_t output_enabled_mask;

  /* Performance-recording capture (le_perf_arm / le_perf_disarm). No separate
   * status ABI — these three atomics are the whole surface for this slice
   * (part 2 adds file-drain progress alongside them). */
  int32_t perf_armed;      /* 0/1: the RT taps are live */
  uint64_t perf_frames;    /* frames processed since the most recent arm */
  uint32_t perf_overruns;  /* dropped capture frames (ring full) since arm */

  /* Tracks. */
  int32_t track_count; /* number of usable tracks (<= LE_MAX_TRACKS) */
  le_track_snapshot tracks[LE_MAX_TRACKS];

  /* ---- tempo grid (trailing on purpose: every pre-existing field keeps its
   * offset, so a reader built against the old layout still reads correctly).
   * All default to grid-off values; with no tempo ever set and quantize off,
   * the engine's behavior is identical to the tempo-free build. */
  float tempo_bpm;      /* denominator-note beats per minute; 0 = unset */
  int32_t ts_num;       /* time-signature numerator (default 4) */
  int32_t ts_den;       /* time-signature denominator, 4 or 8 (default 4) */
  int32_t sync_tempo;   /* 0/1: loop<->grid sync on finalize (default 1) */
  int32_t quantize_div; /* le_grid_div granularity (default 0 = off) */
  int32_t tempo_source; /* le_tempo_source (default 0 = none) */
  /* Whole bars in the master loop, or 0 when no grid relationship exists
   * (sync off, no loop, or the loop predates any grid). The loop's AUDIO
   * length is never altered by the grid — bars is a derived count. */
  int32_t loop_bars;
  int32_t current_beat; /* 0..ts_num-1 within the bar: loop-driven, or driven
                         * by the count-in / free-running click; 0 idle */

  /* ---- click + count-in (A2; trailing for the same offset-stability reason
   * as the tempo block above). All default to click-off values: mode off,
   * mask 0 (unrouted), volume 1, count-in 0 bars — the untouched engine is
   * bit-identical to the click-free build. */
  int32_t click_mode;   /* le_click_mode (default 0 = off) */
  uint32_t click_mask;  /* click output bitmask (default 0 = no outputs) */
  float click_volume;   /* 0..LE_MAX_GAIN (default 1); the click's only gain */
  int32_t count_in_bars; /* count-in length in measures; 0 = off (default) */
  int32_t counting_in;   /* 0/1: a count-in is currently running */
  /* Beat countdown while counting in: the number of count-in beats still to
   * come, INCLUSIVE of the one currently sounding (a one-bar 4/4 count-in
   * reads 4, 3, 2, 1, then 0 as the recording starts). 0 when idle. */
  int32_t count_in_beats_left;

  /* ---- looper mode (B2a, D4; trailing for the same offset-stability reason
   * as the tempo/click blocks above). Default MULTI (0) — an untouched
   * engine's mode reads MULTI, today's behavior. See le_looper_mode's doc for
   * the content-lock gate and what each value means. */
  int32_t looper_mode; /* le_looper_mode (default 0 = MULTI) */

  /* ---- primary track (B3, D18; trailing for the same offset-stability
   * reason as the blocks above). -1 = none (default). Persists through the
   * primary track being cleared/undone-to-empty; only an explicit re-crown
   * (le_engine_crown_primary) changes it — see LE_CMD_CROWN_PRIMARY's doc.
   * Meaningful only in Sync/Band mode (see le_sync_quantize_active); a
   * nonzero value in any other mode is inert. */
  int32_t primary_track;
} le_snapshot;

/* ============================ Plugin hosting ==============================
 * Discovery of installed VST3 / CLAP audio-effect plugins. This first slice is
 * SCAN ONLY: no plugin is loaded into the audio graph, no audio thread is
 * touched. The whole surface runs on the control thread and an engine-owned
 * dedicated scan thread (see le_plugin_scan_begin) — never the audio callback.
 *
 * The hosting backends are compiled only in a LOOPY_ENABLE_PLUGINS build (macOS
 * today); other builds link a stub that reports "no plugins" so the symbols
 * always resolve over FFI. */

/* The plugin format a descriptor was discovered in. */
typedef enum le_plugin_format {
  LE_PLUGIN_VST3 = 0,
  LE_PLUGIN_CLAP = 1,
} le_plugin_format;

/* One discovered plugin class. Fixed-size POD so it round-trips over FFI like
 * le_device_info. A *failed* candidate (a file that could not be loaded or
 * described) is reported as an entry with an EMPTY `id` and `name`/`path` set to
 * the offending file, so a single broken plugin surfaces in the list instead of
 * aborting the scan (umbrella D-SCAN). The Dart layer treats `id == ""` as the
 * unavailable/failed marker. */
typedef struct le_plugin_desc {
  char id[256];    /* VST3 TUID as 32 hex chars / CLAP descriptor id — stable
                    * identity. Empty for a failed-to-scan entry. */
  char name[128];
  char vendor[128];
  char path[1024]; /* the .vst3 bundle / .clap file the class lives in */
  int32_t format;  /* le_plugin_format */
  uint32_t version; /* packed major<<16 | minor<<8 | patch, parsed from the
                     * plugin's version string (0 if unknown) */
} le_plugin_desc;

/* Opaque engine handle. */
typedef struct le_engine le_engine;

/* Returns the miniaudio + engine version string (never NULL). */
LE_EXPORT const char* le_version(void);

/* Detects a cable-free loopback capture path (PulseAudio monitor / virtual
 * driver / backend built-in loopback) by enumerating capture devices. Fills
 * *out and returns LE_OK, or LE_ERR_INVALID for a null argument / enumeration
 * failure. */
LE_EXPORT int32_t le_detect_loopback(le_loopback_info* out);

/* Enumerates the host's playback (output) devices into `out`, a caller-allocated
 * array with room for `max` entries, and writes the number filled into *count
 * (clamped to `max`). Returns LE_OK, or LE_ERR_INVALID for a null argument,
 * non-positive `max`, or an enumeration failure. Uses a transient ma_context, so
 * it is safe to call while an engine is already started. */
LE_EXPORT int32_t le_enumerate_playback_devices(le_device_info* out, int32_t max,
                                                int32_t* count);

/* Like le_enumerate_playback_devices but for capture (input) devices. */
LE_EXPORT int32_t le_enumerate_capture_devices(le_device_info* out, int32_t max,
                                               int32_t* count);

/* Enumerates the installed ASIO drivers into `out` (room for `max`), writing the
 * count into *count. Each entry is one duplex driver: `id` and `name` are the
 * driver name and `input_channels`/`output_channels` are probed from the driver
 * (so the picker can show "18 in / 20 out" before opening). A driver that fails
 * to probe is omitted; the call degrades to *count = 0 rather than erroring.
 *
 * Only the LOOPY_ENABLE_ASIO Windows build enumerates real drivers; every other
 * build is a stub returning *count = 0, LE_OK. RE-ENTRANCY: the ASIO host SDK
 * loads a single process-global driver, so this MUST NOT be called while an ASIO
 * device is open (it would tear down the live stream) — the Dart layer only
 * enumerates while stopped or running on the miniaudio backend. Returns LE_OK,
 * or LE_ERR_INVALID for a null argument / non-positive `max`. */
LE_EXPORT int32_t le_enumerate_asio_drivers(le_device_info* out, int32_t max,
                                            int32_t* count);

/* ---- Plugin scanning (control thread; runs on a dedicated scan thread) ----
 *
 * le_plugin_scan_begin spawns ONE dedicated OS scan thread (the engine has no
 * thread pool) that walks the standard VST3 / CLAP install locations and loads
 * each candidate under a per-candidate guard, so one broken plugin yields a
 * "failed" entry rather than aborting the scan (D-SCAN). Dart polls
 * le_plugin_scan_poll on a timer and reads finished entries with
 * le_plugin_scan_get. The scan thread never touches the audio callback, so a
 * scan is safe while the engine is running.
 *
 * Only one scan runs at a time. `rescan != 0` is a hint to ignore any native
 * caching (none in this slice — caching lives in the Dart catalog). */

/* Starts an async scan. Returns LE_OK once the scan thread is launched, or
 * LE_ERR_INVALID for a null engine, LE_ERR_ALREADY_RUNNING if a scan is already
 * in progress. */
LE_EXPORT int32_t le_plugin_scan_begin(le_engine* engine, int32_t rescan);

/* Polls scan progress. Any out-pointer may be NULL. *done is 0 while scanning,
 * 1 once the scan thread has finished (or was cancelled). *found is the number
 * of entries currently retrievable via le_plugin_scan_get (grows as the scan
 * proceeds and includes failed entries). *scanned / *total are candidate files
 * processed / discovered. Returns LE_OK, or LE_ERR_INVALID for a null engine. */
LE_EXPORT int32_t le_plugin_scan_poll(le_engine* engine, int32_t* done,
                                      int32_t* found, int32_t* scanned,
                                      int32_t* total);

/* Copies the descriptor at `index` (0-based, < the last polled *found) into
 * *out. Returns LE_OK, or LE_ERR_INVALID for a null argument / out-of-range
 * index. Safe to call during or after a scan. */
LE_EXPORT int32_t le_plugin_scan_get(le_engine* engine, int32_t index,
                                     le_plugin_desc* out);

/* Requests cancellation and joins the scan thread (blocks briefly until the
 * in-flight candidate finishes). Idempotent; safe when no scan is running.
 * Returns LE_OK, or LE_ERR_INVALID for a null engine. */
LE_EXPORT int32_t le_plugin_scan_cancel(le_engine* engine);

/* ---- Plugin slot lifecycle (control thread; D-LIFE) ----
 *
 * An opaque handle to a plugin loaded into one lane / monitor FX chain slot.
 * Valid from a successful le_engine_set_*_plugin until that slot is cleared or
 * the engine is destroyed. The heavy work — instancing, activation, buffer
 * allocation — runs on the CONTROL thread; the audio thread only ever reads an
 * atomically-published "ready" flag and forwards samples. No plugin is ever
 * created, destroyed, or dylib-loaded on the audio callback. */
typedef struct le_plugin_slot le_plugin_slot;

/* Loads the plugin identified by `plugin_id` (a scanned le_plugin_desc.id) into
 * FX chain slot `index` of a lane (channel, lane) or a monitor input. The load
 * + activate happen here on the control thread, BYPASSED, then the slot is
 * atomically published so the audio thread begins forwarding to it; until ready
 * the slot renders dry passthrough (no click). On success the chain entry's type
 * becomes LE_FX_PLUGIN and *out_slot receives the handle. The entry is activated
 * in the chain the same way as a built-in, via le_engine_set_lane_fx_count /
 * le_engine_set_monitor_input_fx_count. Returns LE_OK, LE_ERR_INVALID for a bad
 * argument / unknown plugin_id, or LE_ERR_DEVICE on a plugin load/activate
 * failure. (out_slot may be NULL if the caller does not need the handle.) */
LE_EXPORT int32_t le_engine_set_lane_plugin(le_engine* engine, int32_t channel,
                                            int32_t lane, int32_t index,
                                            const char* plugin_id,
                                            le_plugin_slot** out_slot);
LE_EXPORT int32_t le_engine_set_monitor_plugin(le_engine* engine, int32_t input,
                                               int32_t index,
                                               const char* plugin_id,
                                               le_plugin_slot** out_slot);

/* Clears a plugin slot: the audio thread is signalled to stop forwarding to it,
 * and the host is destroyed on the control thread only AFTER a published-
 * quiescent handshake (so there is never a use-after-free or an audio-thread
 * free). The chain entry returns to LE_FX_NONE. Idempotent on an empty slot.
 * Returns LE_OK or LE_ERR_INVALID. */
LE_EXPORT int32_t le_engine_clear_lane_plugin(le_engine* engine, int32_t channel,
                                              int32_t lane, int32_t index);
LE_EXPORT int32_t le_engine_clear_monitor_plugin(le_engine* engine,
                                                 int32_t input, int32_t index);

/* ---- Plugin parameters (control thread; D-PARAM) ----
 *
 * A plugin's parameters are a VARIABLE-LENGTH list sourced live from the plugin
 * — separate from the built-in fixed 4-float LE_FX_PARAMS surface, which is left
 * untouched. Values are PLAIN (not normalized): VST3's normalized params are
 * converted via normalizedParamToPlain; CLAP params are already plain. */

/* Bit flags for le_plugin_param_info.flags. */
typedef enum le_plugin_param_flags {
  LE_PARAM_AUTOMATABLE = 1 << 0,
  LE_PARAM_READONLY = 1 << 1,
  LE_PARAM_BYPASS = 1 << 2,
  LE_PARAM_HIDDEN = 1 << 3,
  LE_PARAM_STEPPED = 1 << 4,
} le_plugin_param_flags;

/* One plugin parameter's metadata. Fixed-size POD for FFI, like le_plugin_desc. */
typedef struct le_plugin_param_info {
  uint32_t id;        /* stable param id (VST3 ParamID / CLAP clap_id) */
  char name[128];
  char unit[32];
  double min;
  double max;
  double def;         /* default plain value */
  int32_t step_count; /* 0 = continuous; >0 = discrete steps */
  uint32_t flags;     /* le_plugin_param_flags bitmask */
} le_plugin_param_info;

/* The number of parameters the plugin in `slot` exposes. Returns LE_OK, or
 * LE_ERR_INVALID for a null argument. */
LE_EXPORT int32_t le_plugin_param_count(le_plugin_slot* slot, int32_t* count);

/* Copies the metadata of the parameter at `index` (0-based, < count) into *out.
 * Returns LE_OK, or LE_ERR_INVALID for a null argument / out-of-range index. */
LE_EXPORT int32_t le_plugin_param_info_at(le_plugin_slot* slot, int32_t index,
                                          le_plugin_param_info* out);

/* Reads the current plain value of parameter `id` into *plain. Returns LE_OK,
 * or LE_ERR_INVALID for a null argument. */
LE_EXPORT int32_t le_plugin_param_get(le_plugin_slot* slot, uint32_t id,
                                      double* plain);

/* Sets parameter `id` to the plain `value`. THREAD-SAFE: enqueues onto the
 * slot's lock-free SPSC ring, drained into the SDK's own event mechanism
 * (VST3 IParameterChanges / CLAP clap_input_events) at the top of the next
 * process() — never a direct store from the audio thread (D-PARAM). Returns
 * LE_OK, or LE_ERR_INVALID for a null slot. */
LE_EXPORT int32_t le_plugin_param_set(le_plugin_slot* slot, uint32_t id,
                                      double value);

/* Formats parameter `id`'s plain `value` to the plugin's own display string
 * (e.g. "-6.0 dB", "Lowpass"), copied NUL-terminated into out[out_size]. Lets
 * the UI label discrete params and read out continuous ones in real units.
 * CONTROL THREAD. Returns LE_OK, LE_ERR_INVALID for a null argument, or
 * LE_ERR_UNSUPPORTED when the plugin offers no text for it. */
LE_EXPORT int32_t le_plugin_param_value_text(le_plugin_slot* slot, uint32_t id,
                                             double value, char* out,
                                             int32_t out_size);

/* ---- Native editor window (MAIN THREAD; macOS only) ---- */

/* Opens the plugin's own native editor in a HOST-OWNED top-level OS window
 * (D-WIN) — not embedded in the Flutter tree. Idempotent: a second call while
 * the editor is already open is a no-op success. Returns LE_OK, LE_ERR_INVALID
 * for a null slot, or LE_ERR_UNSUPPORTED when the plugin has no editor / the
 * platform view type is unsupported (or on a non-macOS build). */
LE_EXPORT int32_t le_plugin_editor_open(le_plugin_slot* slot);

/* Force-closes the editor window and detaches the plugin view (D-WIN teardown).
 * Idempotent: closing an already-closed editor is a no-op success. Returns
 * LE_OK, or LE_ERR_INVALID for a null slot. */
LE_EXPORT int32_t le_plugin_editor_close(le_plugin_slot* slot);

/* Writes 1 into *open if the editor window is currently open, else 0. Returns
 * LE_OK, or LE_ERR_INVALID for a null argument. */
LE_EXPORT int32_t le_plugin_editor_is_open(le_plugin_slot* slot, int32_t* open);

/* ---- Opaque plugin state, for session persistence (MAIN THREAD; D-P1) ---- */

/* Writes the byte size of the plugin's current opaque state into *bytes.
 * Returns LE_OK, LE_ERR_INVALID for a null argument, or LE_ERR_UNSUPPORTED when
 * the plugin exposes no state (then *bytes is 0). */
LE_EXPORT int32_t le_plugin_state_size(le_plugin_slot* slot, int32_t* bytes);

/* Captures the plugin's opaque state into `buf` (capacity `cap`), writing the
 * full byte size into *written. If `cap` is smaller than *written (or `buf` is
 * NULL), nothing is copied — the caller should retry with a buffer of at least
 * *written bytes. Returns LE_OK, LE_ERR_INVALID for a null slot/`written`, or
 * LE_ERR_UNSUPPORTED when the plugin has no state. */
LE_EXPORT int32_t le_plugin_state_get(le_plugin_slot* slot, uint8_t* buf,
                                      int32_t cap, int32_t* written);

/* Restores the plugin from an opaque state blob previously captured with
 * le_plugin_state_get. Returns LE_OK, LE_ERR_INVALID for a null slot (or null
 * `buf` with `bytes` > 0), or LE_ERR_UNSUPPORTED when the plugin rejects it. */
LE_EXPORT int32_t le_plugin_state_set(le_plugin_slot* slot, const uint8_t* buf,
                                      int32_t bytes);

/* Allocates an engine. Returns NULL on allocation failure. */
LE_EXPORT le_engine* le_engine_create(void);

/* Stops (if running) and frees the engine. Safe to call with NULL. */
LE_EXPORT void le_engine_destroy(le_engine* engine);

/* Opens the default duplex device with `config` and starts the audio callback.
 * Allocates the track buffers before the device starts. Returns LE_OK or an
 * le_result error. */
LE_EXPORT int32_t le_engine_start(le_engine* engine, const le_config* config);

/* Stops and closes the device. Returns LE_OK or an le_result error. */
LE_EXPORT int32_t le_engine_stop(le_engine* engine);

/* ---- device-free test pump ----
 *
 * The two calls a test harness needs to drive the engine deterministically
 * with NO audio device: configure the tracks/buffers, then pump blocks through
 * the same block processor the real device callback runs. Exactly how the
 * native test suite (src/test/test_engine_core.c) exercises the engine; the
 * Dart sequence fuzzer uses these through the generated bindings. NOT part of
 * the app's runtime surface — the app always goes through le_engine_start. */

/* Allocates/resets the track buffers and marks the engine configured, without
 * opening a device. `max_loop_frames <= 0` selects the default (30 s). */
LE_EXPORT int32_t le_engine_configure(le_engine* engine, int32_t sample_rate,
                                      int32_t input_channels,
                                      int32_t output_channels,
                                      int32_t max_loop_frames);

/* Processes one block exactly like the device callback: drains the command
 * ring, records/mixes `frames` frames from `input` (interleaved f32, may be
 * NULL for silence) into `output`, advances the transport, publishes
 * metering/undo events. frames == 0 still drains rings and advances the
 * per-block maintenance (the test suites' `drain` idiom). */
LE_EXPORT void le_engine_process(le_engine* engine, float* output,
                                 const float* input, uint32_t frames);

/* Copies the current state snapshot into *out. No-op if either pointer is NULL.
 */
LE_EXPORT void le_engine_get_snapshot(le_engine* engine, le_snapshot* out);

/* Copies track `channel`'s snapshot into *out. Out-of-range channels yield an
 * empty track. No-op if either pointer is NULL. */
LE_EXPORT void le_engine_get_track(le_engine* engine, int32_t channel,
                                   le_track_snapshot* out);

/* Copies up to `max_points` of the loop waveform — peaks of the mixed output
 * indexed by position across exactly one master loop (bucket 0 = loop start),
 * each in 0..1 — into `out`; returns the number written. Pair with the
 * snapshot's master_position/master_length for the playhead. Lock-free read of
 * the audio thread's loop-visualization buffer; empty until a loop exists. */
LE_EXPORT int32_t le_engine_read_visual(le_engine* engine, float* out,
                                        int32_t max_points);

/* Like le_engine_read_visual but for a single track's own contribution
 * (channel 0..track_count-1), for per-track waveform thumbnails. */
LE_EXPORT int32_t le_engine_read_track_visual(le_engine* engine,
                                              int32_t channel, float* out,
                                              int32_t max_points);

/* Name of the active duplex/playback device, or "" if not running. The returned
 * pointer is owned by the engine and valid until the next start/stop. */
LE_EXPORT const char* le_engine_device_name(le_engine* engine);

/* Posts a command into the engine's SPSC ring (drained by the audio thread).
 * Returns LE_OK, LE_ERR_NOT_RUNNING, or LE_ERR_INVALID (ring full / bad args).
 */
LE_EXPORT int32_t le_engine_post_command(le_engine* engine, int32_t code,
                                         int32_t arg_i, float arg_f);

/* Convenience: triggers a single loopback latency measurement. Requires an
 * output->input loopback path. */
LE_EXPORT int32_t le_engine_measure_latency(le_engine* engine);

/* ---- looper control (per channel) ---- *
 * These post ring commands targeting track `channel` (0..track_count-1).
 * le_engine_record additionally takes the one-level undo snapshot on the calling
 * thread when it begins an overdub (the track is read-only on the audio thread
 * at that moment), so the audio callback only performs an O(1) buffer swap to
 * undo — never a copy. */
LE_EXPORT int32_t le_engine_record(le_engine* engine, int32_t channel);
LE_EXPORT int32_t le_engine_stop_track(le_engine* engine, int32_t channel);
LE_EXPORT int32_t le_engine_play(le_engine* engine, int32_t channel);
LE_EXPORT int32_t le_engine_clear(le_engine* engine, int32_t channel);
/* Clear that leaves a restore point: identical to le_engine_clear, except the
 * track's history survives with a LE_HIST_CLEAR entry pushed on top, so the next
 * le_engine_undo puts the take back — content, length, multiple, state, mutes,
 * and the master grid if this clear reset it — with the erased take's overdub
 * layers still peelable beneath it. le_engine_redo then re-clears.
 *
 * Use this for a USER clear. le_engine_clear stays the destructive one, and must
 * remain so for its two non-user callers: session load, and the internal clear
 * le_engine_record posts to redefine the grid when recording onto an otherwise-
 * empty looper (which would otherwise leave a bogus restore point on every take).
 *
 * The restore point is dropped — and this decays to a plain clear — when the
 * track has nothing to restore (already empty / zero length), when a fresh
 * recording on this track overwrites the live slot it names, or when the pool
 * runs out of room for it. `undo` is never a promise, only an offer. */
LE_EXPORT int32_t le_engine_clear_undoable(le_engine* engine, int32_t channel);
LE_EXPORT int32_t le_engine_undo(le_engine* engine, int32_t channel);
/* Whether the NEXT le_engine_undo on `channel` would restore a cleared take
 * (1) rather than peel an overdub layer or empty the track (0). Also 0 for an
 * invalid channel or a stopped engine.
 *
 * For a host that has to put back state the engine does not own — the take's FX
 * chains, say. Ask BEFORE undoing: afterwards the answer describes the next tap,
 * not the one just made. Deriving it from a snapshot instead would race — the
 * snapshot publishes a_state, which does not flip until the audio thread applies
 * the restore, whereas this reads the control thread's own history stack and is
 * exact the moment it returns. */
LE_EXPORT int32_t le_engine_undo_restores_clear(le_engine* engine,
                                                int32_t channel);
LE_EXPORT int32_t le_engine_redo(le_engine* engine, int32_t channel);
LE_EXPORT int32_t le_engine_set_track_volume(le_engine* engine, int32_t channel,
                                             float volume);
LE_EXPORT int32_t le_engine_set_track_mute(le_engine* engine, int32_t channel,
                                           int32_t muted);

/* Routes track `channel`'s record sources to the input channels set in `mask`
 * (a bitmask; bit c => hardware input channel c). Selected inputs are averaged
 * into the track's mono buffer. Bits beyond the negotiated input-channel range
 * are ignored. */
LE_EXPORT int32_t le_engine_set_input_mask(le_engine* engine, int32_t channel,
                                           int32_t mask);

/* Routes track `channel`'s playback to the output channels set in `mask` (a
 * bitmask; bit c => hardware output channel c). Bits beyond the negotiated
 * output-channel range are ignored. */
LE_EXPORT int32_t le_engine_set_output_mask(le_engine* engine, int32_t channel,
                                            int32_t mask);

/* ---- multi-lane recording ---- *
 * A track owns up to LE_MAX_LANES lanes; each records one hardware input into
 * its own clean mono buffer (never merged with sibling lanes) and plays back
 * through its own routing/volume/mute. All lanes of a track share one
 * transport (record/stop/play/clear/undo are track-addressed and fan out to
 * every active lane) and one undo span. The track-addressed setters above
 * (volume/mute/input/output mask) operate on lane 0 for backward
 * compatibility. */

/* Sets track [channel]'s active lane count to [count] (clamped 1..LE_MAX_LANES)
 * on the calling (control) thread, lazily allocating the loop buffers for any
 * newly added lanes before the audio thread can read them. New lanes default to
 * recording input channel == their lane index, full stereo output, unity
 * volume, unmuted. Shrinking the count leaves the dropped lanes' buffers
 * allocated for reuse but stops playing/recording them. */
LE_EXPORT int32_t le_engine_set_lane_count(le_engine* engine, int32_t channel,
                                           int32_t count);

/* Routes lane [lane] of track [channel] to record from hardware input
 * [input_channel] (-1 = record nothing). Bits beyond the negotiated input range
 * or loopback-excluded channels record silence. */
LE_EXPORT int32_t le_engine_set_lane_input(le_engine* engine, int32_t channel,
                                           int32_t lane, int32_t input_channel);

/* Routes lane [lane] of track [channel]'s playback to the output channels set
 * in [mask] (bit c => output channel c). Bits beyond the output range are
 * ignored. */
LE_EXPORT int32_t le_engine_set_lane_output(le_engine* engine, int32_t channel,
                                            int32_t lane, int32_t mask);

/* Sets lane [lane] of track [channel]'s playback gain, clamped to
 * 0..LE_MAX_GAIN (2.0, +6.02 dB headroom above unity). */
LE_EXPORT int32_t le_engine_set_lane_volume(le_engine* engine, int32_t channel,
                                            int32_t lane, float volume);

/* Mutes or unmutes lane [lane] of track [channel]. */
LE_EXPORT int32_t le_engine_set_lane_mute(le_engine* engine, int32_t channel,
                                          int32_t lane, int32_t muted);

/* Copies lane [lane] of track [channel]'s snapshot into *out. Out-of-range
 * channels/lanes yield an empty lane. No-op if either pointer is NULL. */
LE_EXPORT void le_engine_get_lane(le_engine* engine, int32_t channel,
                                  int32_t lane, le_lane_snapshot* out);

/* Sets the record-offset latency compensation in frames (clamped >= 0). */
LE_EXPORT int32_t le_engine_set_record_offset(le_engine* engine,
                                              int32_t frames);

/* Enables or disables quantized recording. When enabled, a record/overdub press
 * over an existing master loop is deferred to the next base-loop top, so
 * captures start and finalize aligned to the loop grid; a second press before
 * the boundary cancels the pending action. The defining recording (no master
 * yet) always acts immediately. Disabling cancels any pending arms. */
LE_EXPORT int32_t le_engine_set_quantize(le_engine* engine, int32_t enabled);

/* Sets track [channel]'s quantize override: a negative [mode] inherits the
 * global default (le_engine_set_quantize), 0 forces quantize off for the track,
 * and a positive value forces it on. */
LE_EXPORT int32_t le_engine_set_track_quantize(le_engine* engine,
                                               int32_t channel, int32_t mode);

/* ---- tempo grid ----
 * Grid state + locks (A1) and the click + count-in built on them (A2); the
 * musical (subdivision) arm machinery lands in a later part. With every
 * default in place (no tempo ever set, quantize_div off, click mode off,
 * count-in 0) the engine behaves exactly like the tempo-free build.
 *
 * Tempo LOCK (D6): while any track has content AND a grid exists
 * (loop_bars > 0 or tempo_source != none), set_tempo / set_time_signature /
 * tap_tempo are accepted but IGNORED by the audio thread (the published state
 * is unchanged). Clearing every track releases the lock; the tempo VALUE and
 * its source survive the clear (a derived tempo outlives its source loop). */

/* Sets the tempo in denominator-note beats per minute, clamped to 30..300.
 * Sets tempo_source = manual; ignored while the tempo is locked. */
LE_EXPORT int32_t le_engine_set_tempo(le_engine* engine, float bpm);

/* Sets the time signature. Only the 17 Sheeran signatures are valid — x/4 for
 * num 2..7 and x/8 for num 5..15 — anything else returns LE_ERR_INVALID
 * without posting. Ignored while the tempo is locked. */
LE_EXPORT int32_t le_engine_set_time_signature(le_engine* engine, int32_t num,
                                               int32_t den);

/* Registers a tap; two taps set the tempo from their interval (intervals
 * outside the 30..300 BPM window are ignored, so a stale first tap never
 * yields an absurd tempo). Sets tempo_source = tapped on success; taps are
 * ignored entirely while the tempo is locked. */
LE_EXPORT int32_t le_engine_tap_tempo(le_engine* engine);

/* Enables/disables loop<->grid sync (default ON). When on, finalizing the
 * DEFINING loop establishes the grid relationship: with a tempo already set
 * (manual/tapped/derived) the loop's whole-bar count is rounded to the
 * existing grid and the tempo is untouched; with no tempo set (source none)
 * a tempo is derived from the loop per D7 (whole bars in the current
 * signature, BPM in 30..300, nearest 120) and tempo_source becomes derived.
 * The loop's AUDIO length is never altered either way. When off, the loop
 * stays free-form (loop_bars 0, tempo untouched) — the tempo-free behavior. */
LE_EXPORT int32_t le_engine_set_sync_tempo(le_engine* engine, int32_t on);

/* Sets the musical quantization granularity (le_grid_div, tempo_grid.h):
 * 0 = off (default), 1 = bar, 2..5 = 1/2..1/16 note. Values outside 0..5
 * return LE_ERR_INVALID. State only in this part (published in the snapshot;
 * consumed by the musical arm machinery in a later part). */
LE_EXPORT int32_t le_engine_set_quantize_div(le_engine* engine, int32_t div);

/* ---- looper mode (B2a, decision D4) ----
 * The five architectural looper modes (le_looper_mode). Mode is a
 * session-level choice, LOCKED while any track has content (state != EMPTY):
 * a switch attempted then is silently rejected (no-op) — a simpler predicate
 * than the D6 tempo lock (content alone, no grid or count-in check; see
 * le_looper_mode_locked, engine_process.c). Only clearing every track
 * releases the lock. Mode switching is NOT a pedal action (D4) and has no UI
 * in this part (that lands in B5c). Semantics beyond the field itself
 * (Sync/Song/Band/Free behavior) land in B2b onward — this part accepts any
 * of the 5 values unconditionally once unlocked, with the engine's audio path
 * staying today's MULTI behavior regardless of the published value. Persists
 * across configure() exactly like tempo_source: seeded once in
 * le_engine_create, never reset by configure (same 2f0513a persistence
 * pattern) — and untouched by clear-all, since no engine-side "revert to
 * Multi" event is specified anywhere in the plan; the mode simply stays at
 * whatever it was last explicitly set to. */

/* Sets the looper mode (le_looper_mode, 0..4). Values outside the enum
 * return LE_ERR_INVALID without posting. Ignored (no-op) while the mode is
 * locked (see the class doc) — the audio thread silently drops it. */
LE_EXPORT int32_t le_engine_set_looper_mode(le_engine* engine, int32_t mode);

/* ---- primary track / Sync (B3, decisions D16/D18; Band's independently
 * start/stoppable section tracks are a follow-on part, B3b) ----
 * One primary track; every other track's DEFINING recording is
 * auto-quantized (D16) to the nearest of {1/4, 1/2, 1, 2, 4} times the
 * primary's established length — a multiple (1/2/4) plays like today's
 * fixed-multiple tracks; a division (1/4, 1/2) plays a repeating slice of
 * ITS OWN (shorter) buffer, phase-locked to the primary's loop top. Inert
 * until a primary is crowned AND that primary already has an established
 * (single-base-loop) length; until then Sync's non-primary tracks record
 * exactly like Multi (D16 fallback). The gate (le_sync_quantize_active,
 * engine_private.h) already also recognizes BAND mode — Band shares this
 * SAME primary/multiple-division machinery per D16 — but Band's
 * ADDITIONAL independently start/stoppable section tracks have no engine
 * surface yet in this part. */

/* Crowns [channel] the primary track (D18). Rejects only an out-of-range
 * channel; accepted in every looper mode (the crown persists regardless of
 * mode, per D18) though it is inert outside Sync/Band. No "un-crown" call
 * exists — re-crowning a different channel is the only way to change it. */
LE_EXPORT int32_t le_engine_crown_primary(le_engine* engine, int32_t channel);

/* ---- click + count-in (A2, decisions D5/D9) ----
 * The click is a synthesized voice (sine 1000 Hz on beats / 1500 Hz on the
 * bar downbeat, 30 ms linear decay) with its OWN output routing and volume,
 * summed into its masked output channels after the master bus and the
 * performance tap. Consequences, all by design: the click bypasses master
 * gain, the limiter, and output metering (its own volume is its only gain
 * stage — it must stay audible and constant regardless of master moves), and
 * it never appears in performance captures, bounces, or exports. It defaults
 * to NO outputs: nothing sounds until a mask is assigned. */

/* Sets the click audibility mode (le_click_mode, 0..3). Values outside the
 * enum return LE_ERR_INVALID. Default off. */
LE_EXPORT int32_t le_engine_set_click_mode(le_engine* engine, int32_t mode);

/* Routes the click to the output channels set in [mask] (bit c => hardware
 * output channel c; bits beyond the negotiated range are ignored). Default 0:
 * the click sounds on no outputs until explicitly routed. */
LE_EXPORT int32_t le_engine_set_click_output(le_engine* engine, int32_t mask);

/* Sets the click volume, clamped to 0..LE_MAX_GAIN (default 1.0). This is the
 * click's only gain stage — master gain and the limiter never touch it. */
LE_EXPORT int32_t le_engine_set_click_volume(le_engine* engine, float volume);

/* Sets the count-in length in measures (0 = off .. LE_COUNT_IN_MAX_BARS;
 * values outside return LE_ERR_INVALID). Default 0 = off on the wire — the
 * manual's 1-bar default is applied by the app layer when the user enables
 * counting in. With count-in on and a tempo set, a record press on an idle,
 * empty looper (the DEFINING recording) first clicks [bars] measures — the
 * counting state is published via counting_in / count_in_beats_left — and
 * recording then starts exactly on the downbeat. A record press during the
 * count-in cancels it (back to idle); so does a stop press, and so does
 * setting this to 0. With no tempo set there is nothing to click against and
 * recording starts immediately. Once anything is recorded, record presses
 * behave exactly as without count-in (quantize governs — D9). Mutually
 * exclusive with sound-activated recording: enabling count-in disables
 * auto-record (and cancels its threshold arms), and enabling auto-record
 * clears the count-in — count-in wins when both are somehow set at once. */
LE_EXPORT int32_t le_engine_set_count_in(le_engine* engine, int32_t bars);

/* Fixes track [channel]'s loop length to [multiple] whole base loops (>= 1), or
 * 0 to inherit the global default (le_engine_set_default_multiple). Applies to
 * the next recording; existing content is unchanged. */
LE_EXPORT int32_t le_engine_set_track_multiple(le_engine* engine,
                                               int32_t channel,
                                               int32_t multiple);

/* Sets the global default loop length used by tracks that inherit (target 0):
 * [multiple] whole base loops (>= 1), or 0 to auto-round-up on stop. */
LE_EXPORT int32_t le_engine_set_default_multiple(le_engine* engine,
                                                 int32_t multiple);

/* ---- track length presets (A6, D17) ----
 * A per-track preset governing the DEFINING (first/master) recording only —
 * orthogonal to le_engine_set_track_multiple above, which fixes a
 * NON-defining track's length once a master already exists. Implements the
 * Sheeran manual's preset x click-mode matrix (song-mode-spec.md §1):
 *   - AUTO (0) + click off: tempo AND bar count are both derived from the
 *     recording (unchanged A1 sync_grid_to_loop path).
 *   - AUTO (0) + click on: bar count only is derived; an already-set tempo is
 *     never re-derived. With NO tempo set, this falls back to deriving both
 *     (the same as click off) — there is nothing else to preserve.
 *   - N bars + click off: the recording proceeds as an ordinary manual take;
 *     on finalize, tempo is derived from recorded-length / N — UNCONDITIONALLY,
 *     even over an existing manual/tapped tempo (the manual's explicit rule for
 *     this preset; distinct from AUTO's D7 "never re-derive" precedence).
 *   - N bars + click on: REQUIRES a tempo already set (source != none) at the
 *     moment recording begins, so frames-per-bar is computable — the defining
 *     recording then auto-finalizes into overdub at exactly N bars' worth of
 *     frames. An early record press before N bars disarms the preset (closes
 *     normally, like AUTO, per D17's general early-press rule). With NO tempo
 *     set at record start, auto-finalize cannot be armed (there is no way to
 *     know how many frames N bars is) — this degrades to the N-bars + click-off
 *     behavior: an ordinary manual take, tempo derived from length / N on
 *     finalize (documented A6 judgment call).
 * In every case the loop's AUDIO length is never altered — only tempo/bars are
 * set to describe it. Requires loop<->grid sync on (le_engine_set_sync_tempo);
 * with sync off the preset is dormant (matches a plain grid-off recording).
 * Preset changes on an already-recorded track are inert until the track is
 * cleared and re-recorded (stored, not retroactively applied). */

/* Sets track [channel]'s length preset: 0 = AUTO, or 1..
 * LE_LENGTH_PRESET_MAX_BARS to fix the defining recording to N bars (see the
 * matrix above). Returns LE_ERR_INVALID for a bad channel/bars, or
 * LE_ERR_CAPACITY when N bars of the CURRENT time signature at the slowest
 * possible tempo (30 BPM) would exceed the engine's max_loop_frames — checked
 * here, before recording starts, so a doomed preset is rejected outright
 * rather than silently failing mid-take. This is a best-effort check against
 * the signature live NOW: nothing locks the signature/tempo between setting
 * the preset and actually recording (no track has content yet, so D6's lock
 * does not apply), so a change in between can still make an N-bars+click-on
 * take's auto-finalize target unreachable. That case is re-guarded with the
 * ACTUAL live grid when recording starts (engine_process.c's
 * le_arm_length_preset_target) — an unreachable target is never armed, so
 * the take degrades cleanly to the click-off derive-from-length path at
 * finalize instead of silently stalling. */
LE_EXPORT int32_t le_engine_set_track_length_preset(le_engine* engine,
                                                     int32_t channel,
                                                     int32_t bars);

/* Sets the second-press "rec/dub" mode: when enabled, finalizing a recording
 * with a record press continues into overdub instead of playback. A stop press
 * always ends in playback/stopped. Independent of this setting, a track recorded
 * over an existing master that auto-finishes (reaches its loop length with no
 * press) always continues into overdub, so layering stays live rather than
 * auto-stopping to playback the moment the loop completes. */
LE_EXPORT int32_t le_engine_set_rec_dub(le_engine* engine, int32_t enabled);

/* Sets the global master output gain (clamped to 0..1), applied post-mix to the
 * final output after all tracks/lanes/monitors have summed in. Unity (1.0) by
 * default and after every fresh configure; published in le_snapshot.master_gain.
 */
LE_EXPORT int32_t le_engine_set_master_gain(le_engine* engine, float gain);

/* Enables/disables the master peak limiter and sets its ceiling (clamped to
 * (0,1], default 0.99). The limiter is applied post master-gain so the summed
 * output of all tracks, overdub layers, and monitoring cannot exceed the ceiling
 * and hard-clip in the driver; below the ceiling it is bit-transparent. OFF by
 * default and after every fresh configure (the host app turns it on). */
LE_EXPORT int32_t le_engine_set_limiter(le_engine* engine, int32_t enabled,
                                        float ceiling);

/* Sets the overdub feedback coefficient (clamped to [0,1], default 1.0). While a
 * track is overdubbing, its existing content at the write head is scaled by this
 * before the new layer is summed in: 1.0 is the classic additive overdub (older
 * layers persist forever and can build toward clipping); below 1.0 decays older
 * layers each pass so the loop self-limits. Applies only during overdub passes,
 * never plain playback. */
LE_EXPORT int32_t le_engine_set_overdub_feedback(le_engine* engine,
                                                 float feedback);

/* Enables sound-activated recording: a record press on an empty track waits and
 * begins capturing the first frame the input level crosses the threshold. A
 * second press before then cancels. Disabling cancels tracks still waiting. */
LE_EXPORT int32_t le_engine_set_auto_record(le_engine* engine, int32_t enabled);

/* Sets chain entry [index] (0..LE_FX_MAX-1) on lane [lane] of track [channel] to
 * [type]. Changing the type resets that entry's DSP state; LE_FX_DELAY lazily
 * allocates the entry's delay line (on this calling thread) and seeds the type's
 * default parameters. The chain is non-destructive and stageless — every active
 * entry colors playback in order. This sets the entry's value only; use
 * le_engine_set_lane_fx_count to make entries active. */
LE_EXPORT int32_t le_engine_set_lane_fx(le_engine* engine, int32_t channel,
                                        int32_t lane, int32_t index,
                                        int32_t type);

/* Sets the active chain length on lane [lane] of track [channel] to [count]
 * (0..LE_FX_MAX): only entries [0, count) are processed, in order. */
LE_EXPORT int32_t le_engine_set_lane_fx_count(le_engine* engine, int32_t channel,
                                              int32_t lane, int32_t count);

/* Sets parameter [param] (0..LE_FX_PARAMS-1) of chain entry [index] on lane
 * [lane] of track [channel] to [value] (clamped to 0..1). The parameter's
 * meaning depends on the entry's le_fx_type. */
LE_EXPORT int32_t le_engine_set_lane_fx_param(le_engine* engine, int32_t channel,
                                              int32_t lane, int32_t index,
                                              int32_t param, float value);

/* ---- per-input live monitor ---- *
 * Each hardware input has a SINGLE live-monitor chain: input-level enable gates
 * the whole input, then the live signal runs through one effect chain / routing /
 * volume / mute. An empty chain is the clean (dry) path. The monitored signal is
 * NEVER recorded and is independent of all track state (record/play/overdub), so
 * an input can be monitored whether or not any track is using it. The chain you
 * monitor live is the chain that is snapshot-copied onto a track lane the moment
 * you record into that input (le_engine_record), so a take sounds like what you
 * heard; the copy is a deep copy taken on the control thread (never recorded into
 * the buffer — playback re-applies it), so later input-chain edits do not alter
 * earlier takes. */

/* Enables or disables live monitoring of hardware input [input]. When enabled,
 * the input routes per its own output mask; a loopback-excluded input is never
 * monitored regardless of [enabled]. */
LE_EXPORT int32_t le_engine_set_monitor_input(le_engine* engine, int32_t input,
                                              int32_t enabled);

/* Routes hardware input [input]'s monitor chain to the output channels set in
 * [mask] (bit c => output channel c). Bits beyond the output range are ignored. */
LE_EXPORT int32_t le_engine_set_monitor_input_output(le_engine* engine,
                                                     int32_t input, int32_t mask);

/* Sets hardware input [input]'s monitor output gain to [volume] (clamped to
 * 0..LE_MAX_GAIN, i.e. 2.0/+6.02 dB headroom above unity). The default is 1.0
 * (unity). */
LE_EXPORT int32_t le_engine_set_monitor_input_volume(le_engine* engine,
                                                     int32_t input, float volume);

/* Mutes or unmutes hardware input [input]'s monitor. */
LE_EXPORT int32_t le_engine_set_monitor_input_mute(le_engine* engine,
                                                   int32_t input, int32_t muted);

/* Sets chain entry [index] (0..LE_FX_MAX-1) on hardware input [input]'s monitor
 * chain to [type]. Changing the type resets that entry's DSP state; LE_FX_DELAY
 * lazily allocates the entry's delay line (on this calling thread) and seeds the
 * type's default parameters. Use le_engine_set_monitor_input_fx_count to make
 * entries active. */
LE_EXPORT int32_t le_engine_set_monitor_input_fx(le_engine* engine, int32_t input,
                                                 int32_t index, int32_t type);

/* Sets hardware input [input]'s monitor active chain length to [count]
 * (0..LE_FX_MAX): only entries [0, count) are processed, in order. */
LE_EXPORT int32_t le_engine_set_monitor_input_fx_count(le_engine* engine,
                                                       int32_t input,
                                                       int32_t count);

/* Sets parameter [param] (0..LE_FX_PARAMS-1) of hardware input [input]'s monitor
 * chain entry [index] to [value] (clamped to 0..1). Its meaning depends on the
 * entry's le_fx_type. */
LE_EXPORT int32_t le_engine_set_monitor_input_fx_param(le_engine* engine,
                                                       int32_t input,
                                                       int32_t index,
                                                       int32_t param, float value);

/* ---- structural output gate ---- *
 * Turns hardware output [output] on/off as a routing target. A disabled output is
 * skipped in the mix fan-out regardless of any lane/monitor mask pointing at it,
 * while the stored masks are left untouched (re-enabling restores them). This is
 * distinct from a level mute: it changes the routing graph, not a gain. RT-safe
 * (applies mid-record without artifacts). A gate state for an output beyond the
 * device's channel count is stored but never affects audio. All outputs are
 * enabled by default and on every fresh configure. */
LE_EXPORT int32_t le_engine_set_output_enabled(le_engine* engine, int32_t output,
                                               int32_t enabled);

/* ---- performance recording (RT capture taps + capture-to-disk; parts 1-2 of
 * the DAW-export stack) ---- *
 * While armed, the audio thread copies two kinds of streams into pre-published
 * lock-free rings: the post-limiter master output (stereo from the first
 * enabled output pair; mono when the device has only one), and each hardware
 * input actively monitored AT ARM (post-monitor-FX, pre-route; frozen for the
 * whole arm session — an input enabled later is not retroactively captured).
 * Rings are allocated control-side at arm (>= 2 s of audio at the device rate)
 * and published to the audio thread with LE_CMD_PERF_ARM; on overflow the
 * audio thread drops the frame and increments the overrun atomic — it never
 * blocks or allocates. Status (armed / frames / overruns) is exposed only via
 * le_snapshot; there is no separate query call.
 *
 * A dedicated background drain thread (perf_drain.h; spawned by le_perf_arm,
 * joined by le_perf_disarm) empties those rings into raw PCM temp files plus a
 * `performance.json` sidecar under the capture directory, flushed every
 * ~250 ms. WAV headers are written only at finalize (a later part): a crash
 * mid-capture leaves salvageable raw PCM + a parseable sidecar, never a
 * truncated WAV. */

/* Arms performance-recording capture: allocates the master + per-monitor
 * rings, freezes the captured input set from whichever inputs are currently
 * monitored, publishes them to the audio thread, and starts the drain thread
 * writing into `capture_dir` (created if it does not already exist).
 * Idempotent (a second call while already armed is a no-op success — the
 * armed session's original `capture_dir` keeps draining; the repeat call's
 * `capture_dir` argument is still required to be non-null/non-empty but is
 * otherwise unused). Returns LE_OK, LE_ERR_NOT_RUNNING (not configured),
 * LE_ERR_INVALID (null/empty `capture_dir`, no output enabled to capture, or
 * ring allocation failure), or LE_ERR_DEVICE (the drain thread could not be
 * started — e.g. the directory could not be created — or a previous disarm's
 * quiescent wait bailed out and left a stale drain session still live). */
LE_EXPORT int32_t le_perf_arm(le_engine* engine, const char* capture_dir);

/* Disarms performance-recording capture: tells the audio thread to stop
 * writing, waits for a published-quiescent handshake to confirm it has (so
 * there is never a use-after-free or an audio-thread free) — mirroring the
 * plugin-slot teardown handshake — then stops and joins the drain thread
 * (which runs one final drain-and-flush pass) before freeing the rings.
 * Idempotent (a second call while already disarmed is a no-op success).
 * Returns LE_OK, or LE_ERR_DEVICE if the callback could not be confirmed
 * quiescent (a stalled device; the rings and drain thread are left
 * retracted-but-running and are reclaimed by a later retry or at
 * le_engine_destroy). */
LE_EXPORT int32_t le_perf_disarm(le_engine* engine);

/* ---- offline performance renderer (parts 7-8 of the DAW-export stack) ----
 * Reconstructs, from a FINALIZED capture directory (part 6's
 * `performance.json` + `events.log` + `loops/` + retired-layer PCM), on a
 * dedicated worker thread: full-length per-track dry stems (part 7,
 * `stems/dry/track<channel>.wav`), per-track wet (FX-applied) stems and a
 * reconstructed master bus (part 8, `stems/wet/track<channel>.wav` +
 * `stems/wet/master.wav`: track sum + master gain + limiter — this
 * feature's golden-parity guardrail against the live-captured master).
 * Reads exclusively from disk — no live-engine dependency — so a render can
 * run concurrently with live looping, and a crash-salvage render is free. */

/* Starts an offline render of the finalized capture at `capture_dir`: spawns
 * a worker thread that writes `stems/dry/track<channel>.wav` +
 * `stems/wet/track<channel>.wav` under `capture_dir` for every non-empty
 * track, then `stems/wet/master.wav` once every channel has been processed,
 * with poll-based progress. Returns LE_OK once the worker thread is
 * launched (this call never blocks on the render itself), LE_ERR_INVALID
 * for a null engine/capture_dir or an empty capture_dir, or
 * LE_ERR_ALREADY_RUNNING if a render is already active on this engine. */
LE_EXPORT int32_t le_perf_render_begin(le_engine* engine,
                                       const char* capture_dir);

/* Reads the current render's progress: `*done` (0 while rendering, 1 once
 * finished), `*progress_pct` (0..100, monotonic), `*track_count` (how many
 * entries `le_perf_render_track_status` can currently read — grows
 * progressively as each track's stem completes, not only once `*done`).
 * Safe to call whether or not a render is active — with none active,
 * `*done` reads 1, `*progress_pct` reads 100, `*track_count` reads 0. Any
 * output pointer may be NULL to skip that field. Returns LE_OK, or
 * LE_ERR_INVALID for a null engine. */
LE_EXPORT int32_t le_perf_render_poll(le_engine* engine, int32_t* done,
                                     int32_t* progress_pct,
                                     int32_t* track_count);

/* Reads render result `index`'s (0..track_count-1, from the most recent
 * le_perf_render_poll) track channel and outcome (`*succeeded`: 1 if its
 * stem was written, 0 on a per-stem failure — the umbrella's "partial
 * success" posture: one failed stem does not abort the others). `*succeeded`
 * reflects BOTH the dry and wet stem for that channel — either one failing
 * marks the track failed, since a wet stem with no matching dry source is
 * not a usable partial result. Returns LE_OK, or LE_ERR_INVALID for a null
 * engine / out-of-range index. */
LE_EXPORT int32_t le_perf_render_track_status(le_engine* engine,
                                              int32_t index, int32_t* channel,
                                              int32_t* succeeded);

/* Cancels an in-progress render and joins the worker thread; a no-op when no
 * render is active. Cancellation is checked once per per-track work chunk
 * (never mid-stem), so this only returns once the worker has actually
 * stopped, leaving no partial stem file for whichever track was in flight.
 * Returns LE_OK, or LE_ERR_INVALID for a null engine. */
LE_EXPORT int32_t le_perf_render_cancel(le_engine* engine);

/* ---- effect-chain fingerprints (control thread; FX divergence detection) ---- *
 * An order-sensitive 64-bit hash of a lane's / monitor's PUBLISHED effect chain:
 * for each of the a_fx_count active entries, its type, plus (for a built-in) its
 * LE_FX_PARAMS float parameter bits — a plugin entry contributes its type only
 * (its params live in the plugin host, not a_fx_param). The empty chain hashes
 * to the FNV-1a offset basis. This is DETECTION only, not a chain readback: the
 * Dart repository owns the chain and computes the identical hash over its cache,
 * so a debug assert / the sequence fuzzer can catch a cache-vs-engine divergence
 * without the engine ever narrating the chain back. Scanned on the control thread
 * off the published a_fx_* atomics (the race-free seam, like le_max_fx_latency);
 * the audio thread never reads it. Out-of-range args return 0. */
LE_EXPORT uint64_t le_engine_lane_fx_fingerprint(le_engine* engine,
                                                 int32_t channel, int32_t lane);
LE_EXPORT uint64_t le_engine_monitor_fx_fingerprint(le_engine* engine,
                                                    int32_t input);

/* ---- session persistence ---- *
 * Save: read each track's loop PCM with le_engine_export_track. Load: clear the
 * engine (so every track is EMPTY), le_engine_import_track each stem, then
 * le_engine_commit_session to establish the master and start playback. Per-track
 * buffers are mono (one sample per frame). */

/* Copies up to `max_frames` frames of track `channel`'s mono loop into `out`;
 * returns the number of frames written (the track length, clamped to
 * `max_frames`), or 0 on a bad argument / empty track. Reads the live buffer —
 * call when the track is not capturing. */
LE_EXPORT int32_t le_engine_export_track(le_engine* engine, int32_t channel,
                                         float* out, int32_t max_frames);

/* Copies up to `max_frames` frames of track `channel`'s lane `lane` mono loop
 * into `out`; returns the number of frames written (the lane's length,
 * clamped to `max_frames`), 0 for a valid-but-empty lane, or LE_ERR_INVALID
 * for an out-of-range channel/lane or a non-positive `max_frames`. On a
 * successful (valid-argument) call this is byte-identical to
 * le_engine_export_track (which is equivalent to lane 0 and untouched by
 * this addition) — call when the track is not capturing. The two functions
 * intentionally diverge on invalid-argument return codes: this one
 * distinguishes LE_ERR_INVALID from 0 because it has a `lane` argument to
 * validate separately; le_engine_export_track has no such argument and
 * returns 0 uniformly for any bad input. */
LE_EXPORT int32_t le_engine_export_track_lane(le_engine* engine,
                                              int32_t channel, int32_t lane,
                                              float* out, int32_t max_frames);

/* Loads `frames` mono frames of PCM into track `channel`'s buffer and records
 * the length. The track must be EMPTY (LE_ERR_INVALID otherwise); the unfilled
 * tail is zeroed. The track starts playing on le_engine_commit_session. Returns
 * LE_OK or an le_result error. Equivalent to le_engine_import_track_lane with
 * lane == 0. */
LE_EXPORT int32_t le_engine_import_track(le_engine* engine, int32_t channel,
                                         const float* pcm, int32_t frames);

/* Loads `frames` mono frames of PCM into track `channel`'s lane `lane`, the
 * multi-lane restore counterpart of le_engine_export_track_lane. The track must
 * be EMPTY (LE_ERR_INVALID otherwise); the unfilled tail is zeroed. Importing a
 * lane >= the current active count grows lane_count to activate it for playback
 * (the new lane takes its standard record route, input == lane index). Lane 0 is
 * the primary import and resets the track's redo/empty accounting; additional
 * lanes only fill their own buffer (they share the track's one undo span). Call
 * lane 0 first, then each further lane, then le_engine_commit_session. Returns
 * LE_OK or an le_result error. */
LE_EXPORT int32_t le_engine_import_track_lane(le_engine* engine, int32_t channel,
                                              int32_t lane, const float* pcm,
                                              int32_t frames);

/* ---- overdub-layer (undo/redo) persistence ---- *
 * A track's full history is the ordered set of pool buffers per lane:
 * undo_stack[0..undo_depth) (oldest first) then the live buffer then the redo
 * stack. le_engine_export_layer reads them by a linear `ordinal`, and
 * le_engine_import_layer + le_engine_finalize_layers rebuild them. The stacks
 * are track-owned and shared across lanes in lockstep, so every lane carries
 * the same layer count at the same ordinals. */

/* Copies up to `max_frames` frames of track `channel`'s lane `lane` layer at
 * `ordinal` into `out`. Ordinals run oldest→newest: `[0, undo_depth)` are the
 * undo snapshots, `undo_depth` is the live buffer, and the next `redo_depth`
 * are the redo snapshots. Returns the frames written (the loop length, clamped
 * to `max_frames`), 0 for an empty layer, or LE_ERR_INVALID for an out-of-range
 * channel/lane/ordinal or non-positive `max_frames`. Control thread; call when
 * the track is not capturing. */
LE_EXPORT int32_t le_engine_export_layer(le_engine* engine, int32_t channel,
                                         int32_t lane, int32_t ordinal,
                                         float* out, int32_t max_frames);

/* Loads `frames` mono frames into track `channel`'s lane `lane` at layer
 * `ordinal` (which becomes the pool slot index), staging a reconstruction into
 * an EMPTY track. Call once per (lane, ordinal) — ordinals contiguous from 0 —
 * then le_engine_finalize_layers, then le_engine_commit_session. Importing a
 * lane >= the active count activates it. Returns LE_OK, or LE_ERR_INVALID for a
 * non-EMPTY track, an `ordinal` past the pool cap, or an oversized `frames`. */
LE_EXPORT int32_t le_engine_import_layer(le_engine* engine, int32_t channel,
                                         int32_t lane, int32_t ordinal,
                                         const float* pcm, int32_t frames);

/* Publishes a track reconstructed by le_engine_import_layer: rebuilds the
 * undo/redo stacks (slot index == ordinal), points a_live at the live buffer
 * (slot `undo_count`), and republishes the undo/redo depths — every active lane
 * in lockstep. `undo_count + 1 + redo_count` layers must already be staged on
 * every active lane at the same loop length. Returns LE_OK, or LE_ERR_INVALID
 * for a non-EMPTY track, a layer count past LE_POOL_SLOTS, or a torn/partial
 * reconstruction (a missing slot or mismatched lane length). */
LE_EXPORT int32_t le_engine_finalize_layers(le_engine* engine, int32_t channel,
                                            int32_t undo_count,
                                            int32_t redo_count);

/* Establishes the master loop at `base_frames` and starts every imported track
 * (EMPTY with a loaded length) playing at its whole-loop multiple
 * (length / base_frames). Posts a command; returns LE_OK or an le_result error.
 */
LE_EXPORT int32_t le_engine_commit_session(le_engine* engine,
                                           int32_t base_frames);

/* ---- native USB MIDI input (foot-pedal control) ---- *
 *
 * A self-contained capture seam, independent of the audio engine lifecycle: it
 * enumerates the host's MIDI *input* ports, opens one, and pushes raw Note/CC
 * messages to a registered callback for the Dart controller pipeline to map
 * (CC 80-83 -> record/stop/undo/clear by default). Captured natively on all
 * three desktop OSes (CoreMIDI / ALSA sequencer / WinMM) so the footswitch ->
 * action latency stays tight and consistent.
 *
 * SysEx / real-time / aftertouch / pitch-bend / program-change are dropped at
 * the native layer, so the callback only ever sees Note On/Off and Control
 * Change. The OS MIDI callback does no allocation, locking, or blocking I/O on
 * its hot path (it parses + pushes to a lock-free SPSC ring); a drain step
 * invokes the callback off that thread. Entirely separate from the audio
 * command ring -- never a second producer on it. */

/* A MIDI input port discovered by le_midi_enumerate.
 *
 * `id` is a per-OS stable token for re-selecting the same device across replug:
 * the CoreMIDI kMIDIPropertyUniqueID (macOS), or the port name (ALSA, WinMM).
 * `name` is the human-readable label. `is_default` marks a system-preferred
 * input where the OS exposes one (always 0 on ALSA/WinMM, which have none). */
typedef struct le_midi_info {
  char id[256];
  char name[256];
  int32_t is_default; /* 0/1 */
} le_midi_info;

/* Raw MIDI input callback: one Note On/Off or Control Change message.
 * `status` carries the message type in its high nibble and the channel in its
 * low nibble; `data1`/`data2` are the two data bytes (CC number/value or note/
 * velocity). `ts_us` is a per-OS monotonic capture timestamp in microseconds,
 * carried for future quantization (unused by the default control path).
 *
 * Invoked off the OS MIDI thread via the drain step. With Dart's
 * NativeCallable.listener the delivery is marshalled onto the isolate event
 * loop, so the registered function may run any Dart code. */
typedef void (*le_midi_event_cb)(uint8_t status, uint8_t data1, uint8_t data2,
                                 uint64_t ts_us);

/* Opaque MIDI capture handle (one open input port at a time). */
typedef struct le_midi le_midi;

/* Allocates a MIDI capture handle bound to the compiled-in per-OS backend.
 * Returns NULL on allocation failure or when no backend is available for the
 * platform. */
LE_EXPORT le_midi* le_midi_create(void);

/* Closes any open port and frees the handle. Safe to call with NULL. */
LE_EXPORT void le_midi_destroy(le_midi* m);

/* Enumerates the host's MIDI input ports into `out` (room for `max` entries),
 * writing the number filled into *count (clamped to `max`). Returns LE_OK, or
 * LE_ERR_INVALID for a null argument / non-positive `max`. Degrades to
 * *count = 0, LE_OK when the platform has no backend or no ports. Uses a
 * transient OS handle, so it is safe to call while a port is open. */
LE_EXPORT int32_t le_midi_enumerate(le_midi_info* out, int32_t max,
                                    int32_t* count);

/* Opens the input port whose `id` matches an `id` from le_midi_enumerate and
 * begins capture, delivering messages to `cb`. Re-opening switches the device
 * (the previous port is closed first), so this is idempotent for re-selection.
 * Returns LE_OK, LE_ERR_INVALID (null handle / cb), LE_ERR_DEVICE (port not
 * found or could not be opened, e.g. in use). */
LE_EXPORT int32_t le_midi_open(le_midi* m, const char* id,
                               le_midi_event_cb cb);

/* Stops capture and closes the open port. Idempotent (a no-op when nothing is
 * open). After it returns the callback registered by le_midi_open is guaranteed
 * not to be invoked again. Returns LE_OK or LE_ERR_INVALID (null handle). */
LE_EXPORT int32_t le_midi_close(le_midi* m);

/* ---- native USB MIDI output (foot-pedal LED feedback) ---- *
 *
 * The send side of the same transport, kept as a fully independent handle from
 * the input capture (le_midi above): a pedal binds one input source AND one
 * output destination of the same physical device, but the two are separate OS
 * ports with separate ids. This seam enumerates the host's MIDI *output* ports,
 * opens one, and sends raw MIDI bytes to it — short channel-voice / real-time
 * messages and System Exclusive alike. It has no callback, no ring, and no
 * worker thread: le_midi_out_send synchronously hands the bytes to the OS.
 *
 * loopy uses it to push the pedal's LED state frames (checksummed 7-bit SysEx)
 * and the loop-top real-time pulse. The bytes are sent verbatim; framing,
 * 7-bit packing, and checksums are the Dart/firmware contract, not this layer's
 * concern. Reuses le_midi_info for enumeration (id/name/is_default). */

/* Opaque MIDI output handle (one open output port at a time). */
typedef struct le_midi_out le_midi_out;

/* Allocates a MIDI output handle bound to the compiled-in per-OS backend.
 * Returns NULL on allocation failure or when no backend is available for the
 * platform. */
LE_EXPORT le_midi_out* le_midi_out_create(void);

/* Closes any open port and frees the handle. Safe to call with NULL. */
LE_EXPORT void le_midi_out_destroy(le_midi_out* m);

/* Enumerates the host's MIDI output ports into `out` (room for `max` entries),
 * writing the number filled into *count (clamped to `max`). Returns LE_OK, or
 * LE_ERR_INVALID for a null argument / non-positive `max`. Degrades to
 * *count = 0, LE_OK when the platform has no backend or no ports. The `id`s
 * mirror the input seam's scheme (CoreMIDI unique id / ALSA client name / WinMM
 * device name) but address *destinations*, so an output id is not interchangeable
 * with an input id even for the same physical device. */
LE_EXPORT int32_t le_midi_out_enumerate(le_midi_info* out, int32_t max,
                                        int32_t* count);

/* Opens the output port whose `id` matches an `id` from le_midi_out_enumerate.
 * Re-opening switches the device (the previous port is closed first), so this is
 * idempotent for re-selection. Returns LE_OK, LE_ERR_INVALID (null handle),
 * LE_ERR_DEVICE (port not found or could not be opened). */
LE_EXPORT int32_t le_midi_out_open(le_midi_out* m, const char* id);

/* Closes the open output port. Idempotent (a no-op when nothing is open).
 * Returns LE_OK or LE_ERR_INVALID (null handle). */
LE_EXPORT int32_t le_midi_out_close(le_midi_out* m);

/* Sends `len` raw MIDI bytes to the open port. `data` may be a short
 * channel-voice or System real-time message (1-3 bytes) or a complete System
 * Exclusive message (`0xF0` … `0xF7`); the backend routes long vs short
 * appropriately. The call is synchronous — the bytes are owned only for its
 * duration. Returns LE_OK, LE_ERR_INVALID (null handle / data, non-positive
 * len), or LE_ERR_DEVICE (no port open or the OS rejected the send). */
LE_EXPORT int32_t le_midi_out_send(le_midi_out* m, const uint8_t* data,
                                   int32_t len);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_ENGINE_API_H */
