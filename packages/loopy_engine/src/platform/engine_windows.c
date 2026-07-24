/*
 * engine_windows.c — Windows implementation of the engine platform seam
 * (engine_platform.h).
 *
 * The lifecycle hooks (backends/before-init/after-start/teardown) are no-ops:
 * the default backend miniaudio selects on Windows needs no per-OS work.
 * Two hooks do real Windows work:
 *   - le_platform_device_id_to_str converts the wchar device id to UTF-8
 *     (a narrow read collapses every id to its first character).
 *   - le_platform_excluded_input_mask excludes nothing by default; with the
 *     opt-in LOOPY_ENABLE_ASIO build it dispatches to the ASIO channel-label
 *     probe (win_asio_labels.cpp; see docs/WINDOWS_ASIO.md).
 *
 * The whole file is wrapped in `#if defined(_WIN32)` so it compiles to a
 * near-empty object on macOS/Linux — a dummy typedef in the `#else` keeps the
 * translation unit non-empty (an entirely #if'd-out TU is UB in ISO C and warns
 * under -Wempty-translation-unit / -pedantic). Keeping this here lets the
 * portable engine.c stay free of Windows #if churn.
 */
#if defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>  /* WideCharToMultiByte for wchar device ids */

#include <stdint.h>

#include "engine_platform.h"  /* the seam; le_engine / le_config via engine_private.h */

#if defined(LOOPY_ENABLE_ASIO)
#include "win_asio_labels.h"  /* le_win_asio_excluded_mask (opt-in ASIO probe) */
#endif

void le_platform_backends(const ma_backend** out_list, ma_uint32* out_count) {
  /* Use miniaudio's default backend priority for the platform. */
  *out_list = NULL;
  *out_count = 0;
}

int le_platform_enumerate_devices(le_device_info* out, int32_t max,
                                  int32_t* count, int capture) {
  /* Defer to miniaudio's WASAPI enumeration (already the right list). */
  (void)out;
  (void)max;
  (void)count;
  (void)capture;
  return 0;
}

void le_platform_before_context_init(const le_config* config) { (void)config; }

void le_platform_after_device_start(le_engine* engine, const le_config* config) {
  (void)engine;
  (void)config;
}

void le_platform_after_device_open(le_engine* engine) { (void)engine; }

void le_platform_on_engine_teardown(void) {}

uint32_t le_platform_excluded_input_mask(const char* uid, int channel_count) {
#if defined(LOOPY_ENABLE_ASIO)
  /* Opt-in: read per-channel labels via ASIO (win_asio_labels.cpp). Degrades to
   * 0 internally on any failure, so the contract is identical to the default. */
  return le_win_asio_excluded_mask(uid, channel_count);
#else
  /* Default Windows build: no per-channel label source (the OS device API
   * cannot return channel name strings), so exclude nothing — same as Linux. */
  (void)uid;
  (void)channel_count;
  return 0;
#endif
}

void le_platform_device_id_to_str(const ma_device_id* id, char* out,
                                  size_t cap) {
  /* miniaudio's Windows backend reports each device id as a wchar_t endpoint
   * string. Convert it to UTF-8 so ids stay unique and
   * round-trippable; reading the union as a narrow char* (as the other
   * backends' string ids allow) would stop at the first UTF-16 NUL byte and
   * collapse every id to its first character (e.g. "{"), making every device
   * indistinguishable. */
  if (cap == 0) return;
  const int written = WideCharToMultiByte(CP_UTF8, 0, (const wchar_t*)id, -1,
                                          out, (int)cap, NULL, NULL);
  if (written <= 0) out[0] = '\0'; /* unmappable / buffer too small: empty id */
  out[cap - 1] = '\0';
}

#else
typedef int loopy_engine_windows_tu_unused; /* keep the TU non-empty off Windows */
#endif
