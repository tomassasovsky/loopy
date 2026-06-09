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

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_ENGINE_INTERNAL_H */
