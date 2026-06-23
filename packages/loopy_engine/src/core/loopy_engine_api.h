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
  LE_CMD_SET_VOLUME = 7,/* arg_f = 0..1 */
  LE_CMD_SET_MUTE = 8,  /* arg_f = 0 (unmute) or 1 (mute) */
  LE_CMD_SET_RECORD_OFFSET = 13, /* arg_i = round-trip latency in frames */
  LE_CMD_SET_INPUT_MASK = 14,    /* route a track's record sources (arg_f =
                                  * track, arg_i = input bitmask) */
  LE_CMD_SET_OUTPUT_MASK = 15,   /* route a track's playback destinations
                                  * (arg_f = track, arg_i = output bitmask) */
  LE_CMD_ARM = 16,    /* arg_i = track: arm a quantized record (fire at loop top) */
  LE_CMD_DISARM = 17, /* arg_i = track: cancel a pending quantized record */
  LE_CMD_SET_LANE_FX = 20, /* set a lane chain entry's type (and reset its DSP
                            * state). arg_i = (channel << 16) | (lane << 8) |
                            * index, arg_f = le_fx_type. */
  LE_CMD_SET_LANE_FX_COUNT = 21, /* set a lane's active chain length.
                                  * arg_i = (channel << 16) | (lane << 8) |
                                  * count. */
  LE_CMD_COMMIT_SESSION = 23,    /* arg_i = base loop length in frames: publish
                                  * the master loop and start imported tracks */
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
                                * arg_f = 0..1. */
  LE_CMD_SET_LANE_MUTE = 29,   /* lane mute.
                                * arg_i = channel*LE_MAX_LANES + lane,
                                * arg_f = 0/1. */
  /* ---- per-input live monitor (one slot per hardware input) ----
   * Each hardware input has a SINGLE live-monitor chain: input-level enable gates
   * the whole input, then the input's live signal runs through its own effect
   * chain / routing / volume / mute. An empty chain is the clean (dry) path. Never
   * recorded, independent of all track state. The chain you monitor live is the
   * chain that is snapshot-copied onto a track lane when you record into it. The
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
                                         * arg_i = input, arg_f = 0..1. */
  LE_CMD_SET_MONITOR_INPUT_MUTE = 35,   /* input monitor mute.
                                         * arg_i = input, arg_f = 0/1. */
  LE_CMD_SET_MASTER_GAIN = 36, /* global post-mix output gain. arg_f = 0..1. */
  LE_CMD_SET_OUTPUT_ENABLED = 37, /* structural output gate (preserves routes).
                                   * arg_i = output index, arg_f = enabled (0/1).
                                   * A disabled output is skipped in the mix
                                   * fan-out regardless of any lane/monitor mask
                                   * pointing at it; masks are untouched. */
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
  float volume;          /* 0..1 */
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
  float volume;          /* lane 0 volume, 0..1 */
  int32_t muted;         /* lane 0 mute, 0/1 */
  int32_t length_frames; /* frames captured (== multiple * master length) */
  int32_t multiple;      /* track length in whole base loops (>= 1) */
  int32_t undo_depth;    /* available undo steps (overdub layers) */
  int32_t redo_depth;    /* available redo steps */
  float rms;             /* lane 0 RMS, 0..1 */
  float peak;            /* lane 0 peak, 0..1 */
  uint32_t input_mask;   /* lane 0 input as a bitmask (1 << input_channel, or 0
                          * when lane 0 records no input) */
  uint32_t output_mask;  /* lane 0 output mask */
  int32_t lane_count;    /* number of active lanes (1..LE_MAX_LANES) */
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

  /* Tracks. */
  int32_t track_count; /* number of usable tracks (<= LE_MAX_TRACKS) */
  le_track_snapshot tracks[LE_MAX_TRACKS];
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
LE_EXPORT int32_t le_engine_undo(le_engine* engine, int32_t channel);
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

/* Sets lane [lane] of track [channel]'s playback gain, clamped to 0..1. */
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
 * 0..1). The default is 1.0 (unity). */
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

/* Loads `frames` mono frames of PCM into track `channel`'s buffer and records
 * the length. The track must be EMPTY (LE_ERR_INVALID otherwise); the unfilled
 * tail is zeroed. The track starts playing on le_engine_commit_session. Returns
 * LE_OK or an le_result error. */
LE_EXPORT int32_t le_engine_import_track(le_engine* engine, int32_t channel,
                                         const float* pcm, int32_t frames);

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
