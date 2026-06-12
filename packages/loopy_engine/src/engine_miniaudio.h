/*
 * engine_miniaudio.h — the miniaudio device backend (le_device_backend.h).
 *
 * Exposes the single device backend this build ships: it owns the miniaudio
 * device lifecycle (context init, pin/loopback resolution, the WASAPI
 * exclusive-mode fallback, ma_device_init/start/uninit, and the data /
 * notification callbacks) behind the le_device_backend vtable. The portable
 * core (engine.c) drives it through le_select_backend and never touches
 * ma_device_* directly.
 *
 * Purely internal: NOT part of the FFI surface (loopy_engine_api.h) or ffigen.
 */
#ifndef LOOPY_ENGINE_MINIAUDIO_H
#define LOOPY_ENGINE_MINIAUDIO_H

#include "le_device_backend.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The miniaudio device backend. Returned by le_select_backend for every backend
 * choice in this build (no ASIO backend exists yet). */
extern const le_device_backend le_miniaudio_backend;

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_ENGINE_MINIAUDIO_H */
