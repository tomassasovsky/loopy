/*
 * loopy_engine_api.h — the C ABI exposed to Dart via FFI.
 *
 * This is the single header consumed by ffigen. Everything here is POD or an
 * opaque handle; no C++; no callbacks into Dart. The audio callback that backs
 * this API performs no allocation, locking, or I/O (see engine.c).
 *
 * Scope: device lifecycle, duplex passthrough, level metering, a loopback
 * round-trip latency harness, the lock-free command ring, and a single-track
 * looper (record / master-loop length / overdub / loop playback / mix /
 * volume / mute / clear / one-level undo). Multi-track lands in a later phase.
 */
#ifndef LOOPY_ENGINE_API_H
#define LOOPY_ENGINE_API_H

#include <stdint.h>

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

/* Quantize-start mode: when a loop exists, a record/overdub press is held until
 * the next grid boundary of this resolution before the capture begins. */
typedef enum le_quantize_mode {
  LE_QUANTIZE_OFF = 0,  /* capture starts immediately */
  LE_QUANTIZE_BEAT = 1, /* arm until the next beat */
  LE_QUANTIZE_BAR = 2,  /* arm until the next bar (default) */
} le_quantize_mode;

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
  LE_CMD_SET_TEMPO = 9,      /* arg_f = bpm (clamped 30..300) */
  LE_CMD_SET_METRONOME = 10, /* arg_f = 0/1 */
  LE_CMD_SET_COUNT_IN = 11,  /* arg_f = 0/1 */
  LE_CMD_TAP_TEMPO = 12,
  LE_CMD_SET_RECORD_OFFSET = 13, /* arg_i = round-trip latency in frames */
  LE_CMD_SET_SYNC_TEMPO = 14,    /* arg_f = 0/1: snap tempo+grid to the loop */
  LE_CMD_SET_QUANTIZE = 15,      /* arg_i = le_quantize_mode */
} le_command_code;

/* Requested device configuration. Any field set to 0 uses the device default
 * (channels is additionally clamped to a maximum of 2). */
typedef struct le_config {
  int32_t sample_rate;
  int32_t buffer_frames;
  int32_t channels;
  int32_t passthrough;     /* 1 = copy captured input straight to the output */
  int32_t max_loop_frames; /* per-track buffer cap; 0 => default (8 min @ sr) */
  int32_t merge_to_mono;   /* 1 = average input channels and feed all outputs */
  int32_t use_loopback_capture; /* 1 = capture from a detected loopback device */
} le_config;

/* Maximum number of simultaneous looper tracks. */
#define LE_MAX_TRACKS 4

/* Number of points in the output visualization ring (le_engine_read_visual).
 * Each point is the peak |output| over one decimation window (~5 ms), so the
 * full ring is ~2.5 s of scrolling output waveform. */
#define LE_VIZ_POINTS 512

/* Per-track state published in le_snapshot.tracks. */
typedef struct le_track_snapshot {
  int32_t state;         /* le_track_state */
  float volume;          /* 0..1 */
  int32_t muted;         /* 0/1 */
  int32_t length_frames; /* frames captured (== multiple * master length) */
  int32_t multiple;      /* track length in whole base loops (>= 1) */
  int32_t undo_depth;    /* available undo steps (overdub layers) */
  int32_t redo_depth;    /* available redo steps */
  float rms;             /* 0..1 */
  float peak;            /* 0..1 */
} le_track_snapshot;

/* Lock-free snapshot of engine state, published by the audio thread and read by
 * Dart on a render-rate timer. Fields are individually atomic; readers may see
 * a one-frame-stale mix across fields, which is fine for metering/UI. */
typedef struct le_snapshot {
  int32_t running;            /* 0/1 */
  int32_t sample_rate;
  int32_t buffer_frames;
  int32_t channels;
  uint64_t frames_processed;  /* total frames seen by the callback */
  uint32_t xrun_count;        /* reserved; xrun detection lands later (0) */
  float input_rms;            /* 0..1 */
  float input_peak;           /* 0..1 */
  float output_rms;           /* 0..1 */
  int32_t latency_state;      /* le_latency_state */
  double measured_latency_ms; /* valid when latency_state == LE_LATENCY_DONE */

  /* Looper transport. */
  int32_t master_length_frames;   /* 0 until the first recording is finalized */
  int32_t master_position_frames; /* current loop playhead */

  /* Tempo / metronome. */
  float tempo_bpm;
  int32_t metronome_on;     /* 0/1 */
  int32_t count_in_enabled; /* 0/1 */
  int32_t counting_in;      /* 0/1: a count-in is currently in progress */
  int32_t current_beat;     /* 0..3 within the bar */
  /* Loop <-> tempo sync. When sync_loop_to_tempo is on, finalizing the defining
   * loop rounds it to a whole number of bars, snaps tempo_bpm to fit, and the
   * metronome divides the loop exactly. loop_bars is 0 until a loop is defined
   * (or when sync is off — the loop then keeps its free-form length). */
  int32_t loop_bars;          /* whole bars in the master loop; 0 if none */
  int32_t sync_loop_to_tempo; /* 0/1 (default 1) */
  /* Quantize-start. quantize_mode is the active resolution (le_quantize_mode);
   * armed_channel is the track waiting for the next grid boundary to begin
   * capturing, or -1 when nothing is armed. */
  int32_t quantize_mode;
  int32_t armed_channel;

  /* Record-offset latency compensation (frames). Recorded/overdubbed input is
   * written this many frames earlier in the loop so it aligns with what the
   * player heard. Auto-set by a latency measurement; manually overridable. */
  int32_t record_offset_frames;

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

/* Copies up to `max_points` decimated output-peak samples (a scrolling waveform
 * of the mixed output, oldest first, each in 0..1) into `out`; returns the
 * number written. Lock-free read of the audio thread's visualization ring. */
LE_EXPORT int32_t le_engine_read_visual(le_engine* engine, float* out,
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

/* ---- tempo / metronome ---- */
LE_EXPORT int32_t le_engine_set_tempo(le_engine* engine, float bpm);
LE_EXPORT int32_t le_engine_set_metronome(le_engine* engine, int32_t on);
LE_EXPORT int32_t le_engine_set_count_in(le_engine* engine, int32_t on);
/* Registers a tap; two taps set the tempo from their interval. */
LE_EXPORT int32_t le_engine_tap_tempo(le_engine* engine);
/* Enables/disables snapping the tempo and metronome grid to the loop. When on
 * (the default), finalizing the defining loop rounds it to whole bars, snaps
 * the displayed tempo, and drives the metronome from the loop position. */
LE_EXPORT int32_t le_engine_set_sync_tempo(le_engine* engine, int32_t on);
/* Sets the quantize-start resolution (le_quantize_mode). When not OFF and a loop
 * exists, a record/overdub press arms and the capture begins at the next grid
 * boundary; a second press on the armed track cancels the pending arm. */
LE_EXPORT int32_t le_engine_set_quantize(le_engine* engine, int32_t mode);

/* Sets the record-offset latency compensation in frames (clamped >= 0). */
LE_EXPORT int32_t le_engine_set_record_offset(le_engine* engine,
                                              int32_t frames);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_ENGINE_API_H */
