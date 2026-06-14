/*
 * win_asio_labels.h — opt-in Windows ASIO per-channel label probe.
 *
 * Declares the one entry point the Windows platform seam (engine_windows.c)
 * calls when the engine is built with LOOPY_ENABLE_ASIO. Capture/playback stay
 * on miniaudio; ASIO is used *only* to read channel names so the engine
 * can exclude "Loopback"-labelled inputs the same way macOS does via Core Audio.
 *
 * Purely internal: NOT part of the FFI surface (loopy_engine_api.h) or ffigen.
 * See docs/WINDOWS_ASIO.md for the build and the vendored-SDK rationale.
 */
#ifndef LOOPY_WIN_ASIO_LABELS_H
#define LOOPY_WIN_ASIO_LABELS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Excluded-input-channel mask read from ASIO per-channel names for the device
 * identified by `uid` (the miniaudio device id from enumeration). Bit c
 * is set when input channel c's ASIO name matches le_label_is_loopback.
 *
 * Returns 0 — exclude nothing — on ANY failure or ambiguity (no ASIO driver,
 * driver load/init fails, or the uid cannot be matched to exactly one
 * ASIO driver). Rule: prefer no-match over wrong-match — a false-positive mask
 * (excluding the wrong channels) is worse than the no-op default.
 *
 * Defined only when LOOPY_ENABLE_ASIO is set (win_asio_labels.cpp); the seam in
 * engine_windows.c calls it under the same guard. */
uint32_t le_win_asio_excluded_mask(const char* uid, int channel_count);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_WIN_ASIO_LABELS_H */
