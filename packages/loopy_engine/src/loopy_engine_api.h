/*
 * loopy_engine_api.h — the C ABI exposed to Dart via FFI.
 *
 * This is the single header consumed by ffigen. Everything here is POD or an
 * opaque handle; no C++; no callbacks into Dart. The audio callback that backs
 * this API performs no allocation, locking, or I/O (see engine.c).
 *
 * Scope: device lifecycle, duplex passthrough, level metering, a loopback
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
  LE_LOOPBACK_WASAPI = 1,   /* Windows WASAPI output loopback (built-in) */
  LE_LOOPBACK_MONITOR = 2,  /* PulseAudio "Monitor of ..." source (Linux) */
  LE_LOOPBACK_VIRTUAL = 3,  /* named virtual driver (BlackHole, VB-Cable, ...) */
} le_loopback_kind;

/* Result of loopback detection. `device_name` is the capture device to open for
 * an auto-measurement (empty for WASAPI's built-in loopback, which the duplex
 * engine does not auto-route). */
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
   * Each hardware input has an independent live monitor route to the outputs
   * with its own effect chain; it is never recorded and is independent of all
   * track state. */
  LE_CMD_SET_MONITOR_INPUT = 30,    /* enable + route a hardware input's monitor.
                                     * arg_f = input | (enabled << 8),
                                     * arg_i = output bitmask. */
  LE_CMD_SET_MONITOR_INPUT_FX = 31, /* set a monitor input's chain entry type
                                     * (and reset its DSP state). arg_i =
                                     * (input << 8) | index, arg_f = le_fx_type. */
  LE_CMD_SET_MONITOR_INPUT_FX_COUNT = 32, /* set a monitor input's active chain
                                           * length. arg_i = (input<<8)|count. */
  LE_CMD_SET_MONITOR_INPUT_DRY = 33, /* route a monitor input's CLEAN (pre-FX)
                                      * signal to a second set of outputs.
                                      * arg_f = input, arg_i = dry bitmask. */
} le_command_code;

/* Per-lane / per-monitor-input effects: each lane (and each live monitor input)
 * carries an ordered chain of up to LE_FX_MAX entries, each with a type and
 * LE_FX_PARAMS normalized (0..1) parameters. The chain is non-destructive (the
 * recording is ALWAYS dry; effects color playback only) and every active entry
 * applies in chain order — there is no pre/post stage. The cap exists only so
 * the audio thread reads a fixed-size, allocation-free array — it is far beyond
 * musical need, not a CPU limit. */
#define LE_FX_MAX 8
#define LE_FX_PARAMS 3

/* Built-in effect types. Designed so a hosted VST3/CLAP plugin can later slot
 * in as just another type. Each type reads its entry's LE_FX_PARAMS normalized
 * values:
 *   DRIVE:   p0 = drive amount, p1 = output level
 *   FILTER:  p0 = cutoff, p1 = resonance        (resonant low-pass)
 *   DELAY:   p0 = time, p1 = feedback, p2 = wet mix
 *   TREMOLO: p0 = rate, p1 = depth
 *   OCTAVER: p0 = shift (0 = -2 oct, .5 = unison, 1 = +2 oct), p1 = tone,
 *            p2 = mix                                  (time-domain pitch shift)
 *   ECHO:    p0 = time, p1 = feedback, p2 = mix  (tape-style, damped repeats) */
typedef enum le_fx_type {
  LE_FX_NONE = 0,
  LE_FX_DRIVE = 1,
  LE_FX_FILTER = 2,
  LE_FX_DELAY = 3,
  LE_FX_TREMOLO = 4,
  LE_FX_OCTAVER = 5,
  LE_FX_ECHO = 6,
} le_fx_type;

/* Which device backend to open. The default (0) opens miniaudio's default
 * backend for the platform (WASAPI on Windows, Core Audio on macOS, the Linux
 * preference list). ASIO is opt-in and only available in a LOOPY_ENABLE_ASIO
 * build (the real backend lands in Part 2); the fields below are accepted and
 * ignored until then. */
typedef enum le_audio_backend {
  LE_BACKEND_WASAPI = 0, /* default: miniaudio's default backend (WASAPI/CoreAudio/ALSA) */
  LE_BACKEND_ASIO = 1,   /* opt-in Windows ASIO (Part 2; requires LOOPY_ENABLE_ASIO) */
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
  int32_t input_channels;  /* 0 = unknown (WASAPI); an ASIO probe fills it in Part 2 */
  int32_t output_channels; /* 0 = unknown */
} le_device_info;

/* Requested device configuration. Any channel field set to 0 uses the device
 * default; counts are clamped to LE_MAX_CHANNELS. */
typedef struct le_config {
  int32_t sample_rate;
  int32_t buffer_frames;
  int32_t passthrough;     /* 1 = copy captured input straight to the output */
  int32_t max_loop_frames; /* per-track buffer cap; 0 => default (8 min @ sr) */
  int32_t use_loopback_capture; /* 1 = capture from a detected loopback device */
  int32_t input_channels;  /* hardware capture channels (0 => device default) */
  int32_t output_channels; /* hardware playback channels (0 => device default) */
  /* Pin a specific device by id (an `id` from le_enumerate_*). An empty string
   * opens the system default (the unchanged behaviour). use_loopback_capture
   * overrides capture_device_id when a loopback device is detected. */
  char playback_device_id[256];
  char capture_device_id[256];
  /* 1 = request OS-exclusive device access (WASAPI exclusive mode on Windows:
   * bypasses the Windows mixer, native format, no resampling). Falls back to
   * shared automatically if the OS/hardware refuses exclusive. No effect on
   * backends without an exclusive concept; default 0 (shared, unchanged). */
  int32_t exclusive;
  /* le_audio_backend to open; 0 (LE_BACKEND_WASAPI) selects the default
   * miniaudio path. Accepted and ignored until the ASIO backend lands. */
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
  uint32_t xrun_count;        /* reserved; xrun detection lands later (0) */
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

  /* 1 = the device is actually open in OS-exclusive mode; 0 = shared (including
   * an exclusive request that fell back to shared). Lets the UI show the real
   * negotiated mode versus what was requested (le_config.exclusive). */
  int32_t exclusive_active;

  /* le_audio_backend actually running (negotiated). In Part 2, a requested-ASIO
   * open that fell back to WASAPI reports WASAPI here. Always WASAPI today. */
  int32_t active_backend;

  /* Tracks. */
  int32_t track_count; /* number of usable tracks (<= LE_MAX_TRACKS) */
  le_track_snapshot tracks[LE_MAX_TRACKS];
} le_snapshot;

/* Opaque engine handle. */
typedef struct le_engine le_engine;

/* Returns the miniaudio + engine version string (never NULL). */
LE_EXPORT const char* le_version(void);

/* Detects a cable-free loopback capture path (PulseAudio monitor / virtual
 * driver / WASAPI) by enumerating capture devices. Fills *out and returns LE_OK,
 * or LE_ERR_INVALID for a null argument / enumeration failure. */
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
 * enumerates while stopped or running on WASAPI. Returns LE_OK, or LE_ERR_INVALID
 * for a null argument / non-positive `max`. */
LE_EXPORT int32_t le_enumerate_asio_drivers(le_device_info* out, int32_t max,
                                            int32_t* count);

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
 * always ends in playback/stopped. */
LE_EXPORT int32_t le_engine_set_rec_dub(le_engine* engine, int32_t enabled);

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
 * Each hardware input has an independent live monitor route: when enabled, its
 * live signal is summed (through its own effect chain) into the output channels
 * its output mask selects. It is NEVER recorded and is independent of all track
 * state (record/play/overdub), so an input can be monitored whether or not any
 * track is using it. This replaces the old global monitor-FX bus and the
 * monitor-follows-a-track model. */

/* Enables or disables live monitoring of hardware input [input] and routes it
 * to the output channels set in [output_mask] (bit c => output channel c). Bits
 * beyond the output range are ignored; a loopback-excluded input is never
 * monitored. */
LE_EXPORT int32_t le_engine_set_monitor_input(le_engine* engine, int32_t input,
                                              int32_t enabled,
                                              int32_t output_mask);

/* Routes monitor input [input]'s CLEAN (pre-effects) signal to the output
 * channels set in [dry_output_mask], independent of its effected route (see
 * le_engine_set_monitor_input). This is a parallel dry send: the clean input
 * goes to these outputs while the effected signal goes to its own outputs, so
 * an input can be heard dry and wet at once on different outputs. `0` disables
 * the dry send (the default). The dry signal is never recorded. */
LE_EXPORT int32_t le_engine_set_monitor_input_dry(le_engine* engine,
                                                  int32_t input,
                                                  int32_t dry_output_mask);

/* Sets chain entry [index] (0..LE_FX_MAX-1) on monitor input [input] to [type].
 * Changing the type resets that entry's DSP state; LE_FX_DELAY lazily allocates
 * the entry's delay line (on this calling thread) and seeds the type's default
 * parameters. Use le_engine_set_monitor_input_fx_count to make entries active. */
LE_EXPORT int32_t le_engine_set_monitor_input_fx(le_engine* engine,
                                                 int32_t input, int32_t index,
                                                 int32_t type);

/* Sets monitor input [input]'s active chain length to [count] (0..LE_FX_MAX):
 * only entries [0, count) are processed, in order. */
LE_EXPORT int32_t le_engine_set_monitor_input_fx_count(le_engine* engine,
                                                       int32_t input,
                                                       int32_t count);

/* Sets parameter [param] (0..LE_FX_PARAMS-1) of monitor input [input]'s chain
 * entry [index] to [value] (clamped to 0..1). Its meaning depends on the
 * entry's le_fx_type. */
LE_EXPORT int32_t le_engine_set_monitor_input_fx_param(le_engine* engine,
                                                       int32_t input,
                                                       int32_t index,
                                                       int32_t param,
                                                       float value);

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

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_ENGINE_API_H */
