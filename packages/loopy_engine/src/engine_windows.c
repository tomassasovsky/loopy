/*
 * engine_windows.c — Windows implementation of the engine platform seam
 * (engine_platform.h).
 *
 * All hooks are no-ops today: the WASAPI/DirectSound path miniaudio selects by
 * default needs no per-OS lifecycle work, and there is no Windows channel-label
 * source, so le_platform_excluded_input_mask excludes nothing. The whole file is
 * wrapped in `#if defined(_WIN32)` so it compiles to a near-empty object on
 * macOS/Linux — a dummy typedef in the `#else` keeps the translation unit
 * non-empty (an entirely #if'd-out TU is UB in ISO C and warns under
 * -Wempty-translation-unit / -pedantic).
 *
 * TODO: opt-in ASIO lands here (low-latency pro-audio path). See the
 * Windows/Linux native brainstorm + plan
 * (docs/brainstorm/2026-06-11-windows-linux-native-brainstorm-doc.md) — this is
 * the landing spot so the portable engine.c stays free of Windows #if churn.
 */
#if defined(_WIN32)

#include <stdint.h>

#include "engine_platform.h"  /* the seam; le_engine / le_config via engine_private.h */

void le_platform_backends(const ma_backend** out_list, ma_uint32* out_count) {
  /* miniaudio's default backend priority (WASAPI, then DirectSound, …) until
   * ASIO opt-in lands. */
  *out_list = NULL;
  *out_count = 0;
}

void le_platform_before_context_init(const le_config* config) { (void)config; }

void le_platform_after_device_start(le_engine* engine, const le_config* config) {
  (void)engine;
  (void)config;
}

void le_platform_on_engine_teardown(void) {}

uint32_t le_platform_excluded_input_mask(const char* uid, int channel_count) {
  (void)uid;
  (void)channel_count;
  return 0;
}

#else
typedef int loopy_engine_windows_tu_unused; /* keep the TU non-empty off Windows */
#endif
