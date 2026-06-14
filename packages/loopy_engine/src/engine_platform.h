/*
 * engine_platform.h — lifecycle hooks the portable core (engine.c) calls at
 * well-defined points; implemented once per OS in engine_<os>.c. Most are no-ops
 * on most platforms — this is a seam for per-OS *capabilities* (CoreAudio
 * channel labels on macOS; JACK port-pinning + PipeWire quantum forcing on
 * Linux; opt-in ASIO on Windows later), not a generic backend vtable.
 *
 * Purely internal: NOT part of the FFI surface (loopy_engine_api.h), the Dart
 * loader, or ffigen.
 */
#ifndef LOOPY_ENGINE_PLATFORM_H
#define LOOPY_ENGINE_PLATFORM_H

#include <stddef.h>
#include <stdint.h>

#include "engine_private.h"  /* struct le_engine; le_config re-exported via its
                              * own loopy_engine_api.h include */
#include "miniaudio.h"       /* ma_backend, ma_uint32, ma_device_id */

#ifdef __cplusplus
extern "C" {
#endif

/* Backend preference list passed to ma_context_init. Linux returns
 * {jack, pulseaudio, alsa}; macOS/Windows return (NULL, 0) = miniaudio default. */
void le_platform_backends(const ma_backend** out_list, ma_uint32* out_count);

/* Called immediately before ma_context_init. Linux sets PIPEWIRE_QUANTUM and
 * forces the graph quantum via pw-metadata. No-op elsewhere. */
void le_platform_before_context_init(const le_config* config);

/* Called immediately after ma_device_start. Linux pins the JACK ports to the
 * selected device and clamps the published channel count. No-op elsewhere. */
void le_platform_after_device_start(le_engine* engine, const le_config* config);

/* Called from le_engine_stop and le_engine_destroy. Linux restores PipeWire's
 * dynamic quantum (force-quantum 0). No-op elsewhere. */
void le_platform_on_engine_teardown(void);

/* Excluded-input-channel mask from per-channel labels. macOS reads CoreAudio
 * labels; Windows (ASIO) and Linux return 0 for now. */
uint32_t le_platform_excluded_input_mask(const char* uid, int channel_count);

/* Serializes a miniaudio device id into a printable, round-trippable token used
 * to match a user-selected device back to its native id. On the string-id
 * backends (CoreAudio, ALSA, PulseAudio, …) the union's active member is a
 * NUL-terminated char string, so a plain copy is exact. On Windows the device id
 * is a wchar_t string and must be converted to UTF-8 — reading it as a narrow
 * char* stops at the first UTF-16 NUL byte and collapses every id to its first
 * character. Writes at most `cap` bytes including the NUL. */
void le_platform_device_id_to_str(const ma_device_id* id, char* out, size_t cap);

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_ENGINE_PLATFORM_H */
