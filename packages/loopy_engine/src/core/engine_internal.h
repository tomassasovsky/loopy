/*
 * engine_internal.h — non-public engine entry points for deterministic tests.
 *
 * These let native tests drive the looper DSP with synthetic buffers, without
 * opening an audio device. Not part of the FFI surface (excluded from ffigen).
 */
#ifndef LOOPY_ENGINE_INTERNAL_H
#define LOOPY_ENGINE_INTERNAL_H

#include <stdint.h>

#include "le_device_backend.h"  /* le_device_backend (le_select_backend return) */
#include "loopy_engine_api.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Selects the device backend for a requested le_audio_backend (le_config.backend).
 * In this build the only implementation is the miniaudio backend, so every input
 * returns it; the opt-in ASIO branch lands in Part 2. The default build never
 * references an ASIO symbol. Not part of the FFI surface. */
const le_device_backend* le_select_backend(int32_t backend);

/* Publishes the "device present + running" lifecycle flags after a backend's
 * start() succeeds (release stores, mirroring the miniaudio backend). Exists so a
 * device backend implemented in a C++ TU (the opt-in ASIO backend) can mark the
 * engine started without including the _Atomic struct definition in
 * engine_private.h, keeping all atomic access in C. Not part of the FFI surface. */
void le_engine_mark_started(le_engine* engine);

/* Increments the published xrun (dropout) tally by one. Called from a device
 * backend's overload notification — e.g. the ASIO driver's kAsioOverload message
 * — so the snapshot's xrun_count reflects real device starvation. A C helper for
 * the same reason as le_engine_mark_started (C++ backend TUs avoid the _Atomic
 * field). Relaxed atomic; safe off any thread. Not part of the FFI surface. */
void le_engine_note_xrun(le_engine* engine);

/* Publishes "device lost" (a_device_present = 0, a_running untouched) so the
 * control layer drives reconnection. Mirrors the miniaudio device-notification
 * callback; called by the ASIO reset-request / sample-rate-change handlers so a
 * driver reconfigured out from under us recovers via stop -> start rather than
 * going silent. Relaxed atomic; safe off the driver's message thread. Not part
 * of the FFI surface. */
void le_engine_mark_device_lost(le_engine* engine);

/* Allocates the track buffers and sets engine parameters WITHOUT opening a
 * device. Used by le_engine_start and by tests. `input_channels` /
 * `output_channels` are each clamped to LE_MAX_CHANNELS and `max_loop_frames` to
 * a positive value. Returns LE_OK or LE_ERR_INVALID. */
int32_t le_engine_configure(le_engine* engine, int32_t sample_rate,
                            int32_t input_channels, int32_t output_channels,
                            int32_t max_loop_frames);

/* Processes one interleaved block: drains commands, advances the loop, records/
 * overdubs/mixes, and publishes metering. This is exactly what the miniaudio
 * data callback invokes, exposed so tests can call it directly. */
void le_engine_process(le_engine* engine, float* output, const float* input,
                       uint32_t frames);

/* Runs the master-bus per-frame step (master gain -> feed-forward limiter ->
 * output metering) on out[f*ch_out .. +ch_out) in isolation, with explicit gain /
 * limiter params, so the limiter dynamics can be unit-tested without a full block.
 * Reads/updates engine->lim_gain. Not part of the FFI surface. */
void le_engine_master_bus_frame_for_test(le_engine* engine, float* out,
                                         uint32_t f, int ch_out,
                                         float master_gain, int limiter_on,
                                         float limiter_ceiling, float lim_release,
                                         float* out_sumsq, float* frame_out_peak);

/* Classifies a capture device by name into a loopback kind (name heuristic
 * only; backend built-in loopback detection is context-level). Pure and
 * unit-testable. */
le_loopback_kind le_classify_capture_device(const char* name);

/* Whether a Core Audio channel label marks a loopback channel (case-insensitive
 * substring "loopback"). Pure and unit-testable; a NULL/blank label is not a
 * loopback. */
int le_label_is_loopback(const char* label);

/* YIN pitch detector for the PSOLA octaver (mode >= 0.5). Runs the cumulative-
 * mean-normalized difference function over `n` contiguous samples of `x` at `sr`
 * Hz, searching the vocal band (~60-1000 Hz), and returns a sub-sample period
 * estimate (parabolic-interpolated, in samples) in *out_period and a voicing
 * confidence in [0,1] (1 = perfectly periodic) in *out_voiced. Returns 1 when the
 * frame reads as confidently voiced, else 0 (silence or aperiodic). Pure (no
 * engine state) and unit-tested directly so the octave-error guard is verifiable
 * independently of the lossy grain synthesis. Defined in engine.c. */
int le_psola_detect(const float* x, int n, int sr, float* out_period,
                    float* out_voiced);

/* ---- ASIO bridge math (pure, platform-agnostic; defined in engine.c) ---- *
 *
 * ASIO hands the device callback non-interleaved, per-channel blocks in the
 * driver's native sample format, whereas le_engine_process works on one
 * interleaved f32 buffer. These two helpers absorb both differences and are the
 * riskiest part of the ASIO backend, so they live in the portable core (no ASIO
 * headers) and are unit-tested off-thread without any hardware. */

/* Native sample format of one ASIO channel block, mirroring the ASIOSampleType
 * values the backend actually handles (all little-endian). */
typedef enum le_sample_fmt {
  LE_SMP_I16, /* ASIOSTInt16LSB   — 16-bit signed PCM */
  LE_SMP_I24, /* ASIOSTInt24LSB   — packed 24-bit signed PCM (3 bytes/sample) */
  LE_SMP_I32, /* ASIOSTInt32LSB   — 32-bit signed PCM */
  LE_SMP_F32, /* ASIOSTFloat32LSB — 32-bit float */
} le_sample_fmt;

/* Scatters one ASIO input channel's native block into the interleaved f32 buffer
 * le_engine_process reads: for each frame f, converts native_block[f] (format
 * `fmt`) to f32 and writes it to out_interleaved[f * channel_count + chan]. The
 * block holds `frames` samples; the source stride is the format's byte width. */
void le_deinterleave_in(float* out_interleaved, const void* native_block,
                        le_sample_fmt fmt, int chan, int channel_count,
                        int frames);

/* Gathers channel `chan` out of the interleaved f32 buffer le_engine_process
 * produced (in_interleaved[f * channel_count + chan]) and writes it, converted
 * to `fmt` (clamped to the format's range), into one ASIO output channel's
 * native block. The inverse of le_deinterleave_in for f32 (exact round-trip). */
void le_interleave_out(void* native_block, const float* in_interleaved,
                       le_sample_fmt fmt, int chan, int channel_count,
                       int frames);

/* Snaps a requested buffer size to a size the ASIO driver actually allows, given
 * its (min, max, preferred, granularity) from ASIOGetBufferSize. granularity:
 *   -1 => powers of two only (snap to the nearest power of two in [min,max]);
 *    0 => the driver offers only `preferred` (always returned);
 *   >0 => linear steps from `min` (snap to the nearest min + k*granularity).
 * A request outside [min,max] (un-honorable) falls back to `preferred`. Pure and
 * unit-tested; used once at open so the device never fails over a chip choice. */
int32_t le_asio_pick_buffer(int32_t requested, int32_t min, int32_t max,
                            int32_t preferred, int32_t granularity);

/* Per-channel name provider: returns input channel [channel]'s label (or NULL
 * if unavailable). `ctx` is caller state (e.g. an ASIO driver handle or, in
 * tests, a fixed name table). */
typedef const char* (*le_channel_name_fn)(void* ctx, int channel);

/* Builds the excluded-input-channel bitmask from a name provider: bit c is set
 * when get_name(ctx, c) matches le_label_is_loopback. The platform-agnostic
 * core of every label probe (only the name *source* is OS-specific), so it is
 * pure and unit-testable with a fake provider. Channels >= LE_MAX_CHANNELS and
 * a NULL provider yield no bits. Not part of the FFI surface. */
uint32_t le_excluded_mask_from_names(le_channel_name_fn get_name, void* ctx,
                                     int channel_count);

/* Overrides the excluded-input-channel mask without opening a device, so the
 * capture-average / monitoring / SET_INPUT_MASK exclusion paths can be tested
 * deterministically. Not part of the FFI surface. */
void le_engine_set_excluded_input_mask_for_test(le_engine* engine,
                                                uint32_t mask);

/* Begins a round-trip latency measurement without a device (configured-gated,
 * like the looper commands), so the harness's loopback-channel detection can be
 * tested deterministically. Not part of the FFI surface. */
int32_t le_engine_begin_latency_for_test(le_engine* engine);

/* Whether lane [lane] of track [channel] has its live loop buffer allocated.
 * Lets a test assert lazy lane allocation (idle lanes stay unallocated). Returns
 * 0 for out-of-range indices. Not part of the FFI surface. */
int le_engine_lane_buffer_allocated_for_test(le_engine* engine, int32_t channel,
                                             int32_t lane);

/* Allocated frames of lane [lane]'s pool slot [slot] (slot < 0 selects the
 * lane's live slot; 0 = unallocated; -1 = out of range). Lets tests assert the
 * undo-layer quantized sizing and the full-cap live-buffer invariant. Not part
 * of the FFI surface. */
int32_t le_engine_lane_slot_cap_for_test(le_engine* engine, int32_t channel,
                                         int32_t lane, int32_t slot);

/* Forces track [channel]'s active lane count to [count] WITHOUT allocating the
 * new lanes' buffers, so a test can drive the audio thread into the window where
 * lane_count claims more lanes than are allocated and assert the real-time
 * null-guard keeps it silent (never dereferences a NULL pool). Not part of the
 * FFI surface. */
void le_engine_set_lane_count_unsafe_for_test(le_engine* engine,
                                              int32_t channel, int32_t count);

/* Drives track [channel] lane [lane]'s effect chain once with an explicit stereo
 * pair (*l, *r), writing the processed pair back in place. The device paths seed
 * the chain l == r from a mono source, so this is the only way a test can feed a
 * decorrelated (l != r) input — e.g. an impulse on one channel only — to prove
 * each delay-ringed slot keeps independent left/right ring state. Reads the
 * lane's published chain config (type/params/count); the caller must have drained
 * any pending SET_*_FX commands so the entries' DSP state is reset. Not part of
 * the FFI surface. */
void le_engine_lane_fx_chain_for_test(le_engine* engine, int32_t channel,
                                      int32_t lane, float* l, float* r);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_ENGINE_INTERNAL_H */
