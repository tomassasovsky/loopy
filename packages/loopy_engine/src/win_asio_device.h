/*
 * win_asio_device.h — opt-in Windows ASIO duplex device backend.
 *
 * Declares the le_device_backend the engine selects (le_select_backend) when
 * le_config.backend == LE_BACKEND_ASIO in a LOOPY_ENABLE_ASIO Windows build.
 * Unlike win_asio_labels (a brief label-only probe), this backend OWNS the
 * device lifecycle: it loads the ASIO driver, creates its buffers, runs its
 * real-time bufferSwitch callback, and feeds the unchanged le_engine_process at
 * the driver's full channel count. It plugs into the same seam the miniaudio
 * backend uses, so the SPSC ring, the atomic snapshot, and the looper/lane/FX
 * DSP are reused as-is.
 *
 * The symbol is referenced by le_select_backend only inside the
 * `#if defined(_WIN32) && defined(LOOPY_ENABLE_ASIO)` guard, so the default build
 * links no ASIO symbol (the Part 1 link-time guarantee holds).
 *
 * Licensing: the Steinberg ASIO SDK is GPLv3-or-proprietary and is NOT vendored
 * into this MIT repo. It is user-supplied via LOOPY_ASIO_SDK_DIR and .gitignored.
 *
 * Purely internal: NOT part of the FFI surface (loopy_engine_api.h) or ffigen.
 * See docs/WINDOWS_ASIO.md for the opt-in build and the MIT/GPLv3 SDK rationale.
 */
#ifndef LOOPY_WIN_ASIO_DEVICE_H
#define LOOPY_WIN_ASIO_DEVICE_H

#include "le_device_backend.h" /* le_device_backend */

#ifdef __cplusplus
extern "C" {
#endif

/* The ASIO duplex device backend. Defined in win_asio_device.cpp only when
 * LOOPY_ENABLE_ASIO is set; returned by le_select_backend for LE_BACKEND_ASIO. */
extern const le_device_backend le_asio_backend;

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_WIN_ASIO_DEVICE_H */
