/*
 * engine_internal.h — non-public engine entry points for deterministic tests.
 *
 * These let native tests drive the looper DSP with synthetic buffers, without
 * opening an audio device. Not part of the FFI surface (excluded from ffigen).
 */
#ifndef LOOPY_ENGINE_INTERNAL_H
#define LOOPY_ENGINE_INTERNAL_H

#include <stdint.h>

#include "loopy_engine_api.h"

#ifdef __cplusplus
extern "C" {
#endif

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

/* Classifies a capture device by name into a loopback kind (name heuristic
 * only; WASAPI detection is context-level). Pure and unit-testable. */
le_loopback_kind le_classify_capture_device(const char* name);

/* Whether a Core Audio channel label marks a loopback channel (case-insensitive
 * substring "loopback"). Pure and unit-testable; a NULL/blank label is not a
 * loopback. */
int le_label_is_loopback(const char* label);

/* Outcome of the share-mode fallback decision (see le_decide_share_fallback). */
typedef enum {
  LE_SHARE_DONE_EXCLUSIVE, /* exclusive requested and the first init succeeded */
  LE_SHARE_RETRY_SHARED,   /* exclusive requested but failed: retry in shared */
  LE_SHARE_DONE_SHARED,    /* exclusive not requested: shared as-is */
} le_share_decision;

/* Pure share-mode fallback decision, factored out so the retry logic is testable
 * without opening a device. Given whether exclusive access was requested and
 * whether the first (exclusive) device init succeeded, decides what to do.
 * Not part of the FFI surface. */
le_share_decision le_decide_share_fallback(int requested_exclusive,
                                           int first_init_ok);

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

/* Forces track [channel]'s active lane count to [count] WITHOUT allocating the
 * new lanes' buffers, so a test can drive the audio thread into the window where
 * lane_count claims more lanes than are allocated and assert the real-time
 * null-guard keeps it silent (never dereferences a NULL pool). Not part of the
 * FFI surface. */
void le_engine_set_lane_count_unsafe_for_test(le_engine* engine,
                                              int32_t channel, int32_t count);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_ENGINE_INTERNAL_H */
