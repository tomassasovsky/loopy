/*
 * engine_devices.c — device discovery, loopback detection, id resolution, and
 * backend selection (S1 split from engine.c).
 *
 * THREAD OWNERSHIP: control thread. Everything here runs on transient ma_context
 * objects (enumeration / loopback detection) or is a pure selector — none of it
 * touches a running device or the audio thread. le_find_loopback / enumerate_devices
 * / le_resolve_device_id are also called by the miniaudio backend and the per-OS
 * seams (declared in engine_private.h); le_classify_capture_device /
 * le_label_is_loopback / le_excluded_mask_from_names / le_select_backend are the
 * unit-tested pure cores (declared in engine_internal.h). Behaviour unchanged.
 */
#include <ctype.h>
#include <stdint.h>
#include <string.h>

#include "engine_internal.h"  /* le_classify_capture_device, le_select_backend, ... */
#include "engine_miniaudio.h" /* le_miniaudio_backend */
#include "engine_platform.h"  /* le_platform_device_id_to_str */
#include "engine_private.h"   /* le_engine, enumerate_devices/le_find_loopback decls */
#include "loopy_engine_api.h"
#include "miniaudio.h"
#if defined(_WIN32) && defined(LOOPY_ENABLE_ASIO)
#include "win_asio_device.h" /* le_asio_backend (selected by le_select_backend) */
#endif

/* ---- loopback detection ---- */

static int contains_ci(const char* haystack, const char* needle) {
  if (haystack == NULL || needle == NULL) return 0;
  const size_t nlen = strlen(needle);
  if (nlen == 0) return 1;
  for (const char* h = haystack; *h != '\0'; ++h) {
    size_t i = 0;
    while (i < nlen && h[i] != '\0' &&
           tolower((unsigned char)h[i]) == tolower((unsigned char)needle[i])) {
      ++i;
    }
    if (i == nlen) return 1;
  }
  return 0;
}

le_loopback_kind le_classify_capture_device(const char* name) {
  if (name == NULL) return LE_LOOPBACK_NONE;
  if (contains_ci(name, "monitor of")) return LE_LOOPBACK_MONITOR;
  static const char* const virtual_names[] = {
      "blackhole", "soundflower", "loopback audio", "loopback",
      "vb-audio",  "vb-cable",    "cable output",   "voicemeeter",
  };
  for (size_t i = 0; i < sizeof(virtual_names) / sizeof(virtual_names[0]); ++i) {
    if (contains_ci(name, virtual_names[i])) return LE_LOOPBACK_VIRTUAL;
  }
  return LE_LOOPBACK_NONE;
}

int le_label_is_loopback(const char* label) {
  /* Case-insensitive "loop" match. This covers both the generic "Loopback"
   * label and the Focusrite convention of naming the two loopback inputs
   * "Loop 1" / "Loop 2" (verified on a Scarlett 4i4). "loop" subsumes
   * "loopback", so one substring check handles both. */
  return contains_ci(label, "loop");
}

uint32_t le_excluded_mask_from_names(le_channel_name_fn get_name, void* ctx,
                                     int channel_count) {
  /* Pure bit-setting core shared by every platform's label probe: walk the
   * input channels, ask the caller's provider for each channel's name, and set
   * the bit for any name le_label_is_loopback matches. The OS-specific part is
   * only the *source* of the names (Core Audio on macOS, ASIO on Windows), so
   * this stays unit-testable with a fake provider and free of any OS calls.
   * Channels beyond LE_MAX_CHANNELS (the mask's width) are ignored. */
  if (get_name == NULL) return 0;
  uint32_t mask = 0;
  const int n =
      channel_count < LE_MAX_CHANNELS ? channel_count : LE_MAX_CHANNELS;
  for (int c = 0; c < n; ++c) {
    const char* name = get_name(ctx, c);
    if (name != NULL && le_label_is_loopback(name)) {
      mask |= (1u << c);
    }
  }
  return mask;
}

void le_find_loopback(ma_context* ctx, le_loopback_info* out,
                      ma_device_id* out_id) {
  out->available = 0;
  out->kind = LE_LOOPBACK_NONE;
  out->device_name[0] = '\0';

  ma_device_info* playback = NULL;
  ma_uint32 playback_count = 0;
  ma_device_info* capture = NULL;
  ma_uint32 capture_count = 0;
  if (ma_context_get_devices(ctx, &playback, &playback_count, &capture,
                             &capture_count) != MA_SUCCESS) {
    return;
  }

  for (ma_uint32 i = 0; i < capture_count; ++i) {
    const le_loopback_kind kind = le_classify_capture_device(capture[i].name);
    if (kind != LE_LOOPBACK_NONE) {
      out->available = 1;
      out->kind = kind;
      strncpy(out->device_name, capture[i].name, sizeof(out->device_name) - 1);
      out->device_name[sizeof(out->device_name) - 1] = '\0';
      if (out_id != NULL) *out_id = capture[i].id;
      return;
    }
  }

  if (ma_context_is_loopback_supported(ctx)) {
    out->available = 1;
    out->kind = LE_LOOPBACK_BACKEND;
  }
}

int32_t le_detect_loopback(le_loopback_info* out) {
  if (out == NULL) return LE_ERR_INVALID;
  ma_context ctx;
  if (ma_context_init(NULL, 0, NULL, &ctx) != MA_SUCCESS) {
    out->available = 0;
    out->kind = LE_LOOPBACK_NONE;
    out->device_name[0] = '\0';
    return LE_ERR_INVALID;
  }
  le_find_loopback(&ctx, out, NULL);
  ma_context_uninit(&ctx);
  return LE_OK;
}

/* ---- device enumeration & pinning ---- */

/* Serializes a miniaudio device id into a printable, round-trippable token.
 * The backend-specific encoding (char string vs Windows wchar string) lives
 * behind the platform seam so this portable core stays free of OS #ifs; see
 * le_platform_device_id_to_str (engine_platform.h). Enumeration and resolution
 * both route through here, so the token round-trips via strcmp on every OS. */
static void device_id_to_str(const ma_device_id* id, char* out, size_t cap) {
  le_platform_device_id_to_str(id, out, cap);
}

static void device_info_copy(le_device_info* dst, const ma_device_info* src) {
  /* Zero everything first so the miniaudio path never surfaces stack garbage for
   * fields it does not fill (channel counts, the ASIO-only buffer/rate sets). */
  memset(dst, 0, sizeof(*dst));
  device_id_to_str(&src->id, dst->id, sizeof(dst->id));
  strncpy(dst->name, src->name, sizeof(dst->name) - 1);
  dst->name[sizeof(dst->name) - 1] = '\0';
  dst->is_default = src->isDefault ? 1 : 0;
  /* miniaudio enumeration reports no per-device channel count / ASIO option sets
   * here; they stay 0 (unknown), filled only by the ASIO driver probe. */
}

/* Fills `out` (room for `max`) with the host's playback or capture devices and
 * writes the count into *count. Uses a transient context so it never disturbs a
 * running device. `capture` selects the direction. Externally linked (declared
 * in engine_private.h) so the Linux JACK pin hook can resolve friendly device
 * names through it; defined only here. */
int32_t enumerate_devices(le_device_info* out, int32_t max, int32_t* count,
                          int capture) {
  if (out == NULL || count == NULL || max <= 0) return LE_ERR_INVALID;
  *count = 0;
  /* Prefer the platform-native list when the OS has a better source than
   * miniaudio's default backend. On Linux that is JACK: playback runs on the
   * JACK backend, so enumerating via ALSA (miniaudio's default) both surfaces
   * plugin clutter and hands back ids that never match a JACK port prefix, so a
   * selection cannot route. When this handles it, the ids pin correctly. */
  if (le_platform_enumerate_devices(out, max, count, capture)) return LE_OK;
  ma_context ctx;
  if (ma_context_init(NULL, 0, NULL, &ctx) != MA_SUCCESS) return LE_ERR_INVALID;
  ma_device_info* playback = NULL;
  ma_uint32 playback_count = 0;
  ma_device_info* cap = NULL;
  ma_uint32 cap_count = 0;
  if (ma_context_get_devices(&ctx, &playback, &playback_count, &cap,
                             &cap_count) != MA_SUCCESS) {
    ma_context_uninit(&ctx);
    return LE_ERR_INVALID;
  }
  ma_device_info* list = capture ? cap : playback;
  ma_uint32 n = capture ? cap_count : playback_count;
  int32_t written = 0;
  for (ma_uint32 i = 0; i < n && written < max; ++i) {
    device_info_copy(&out[written++], &list[i]);
  }
  *count = written;
  ma_context_uninit(&ctx);
  return LE_OK;
}

int32_t le_enumerate_playback_devices(le_device_info* out, int32_t max,
                                      int32_t* count) {
  return enumerate_devices(out, max, count, /*capture=*/0);
}

int32_t le_enumerate_capture_devices(le_device_info* out, int32_t max,
                                     int32_t* count) {
  return enumerate_devices(out, max, count, /*capture=*/1);
}

/* Looks up the device whose serialized id equals `want` in the already-open
 * `ctx` and copies its native id into *out_id. Returns 1 on a match (out_id set)
 * or 0 if `want` is empty / unmatched / enumeration failed. */
int le_resolve_device_id(ma_context* ctx, int capture, const char* want,
                         ma_device_id* out_id) {
  if (want == NULL || want[0] == '\0') return 0;
  ma_device_info* playback = NULL;
  ma_uint32 playback_count = 0;
  ma_device_info* cap = NULL;
  ma_uint32 cap_count = 0;
  if (ma_context_get_devices(ctx, &playback, &playback_count, &cap,
                             &cap_count) != MA_SUCCESS) {
    return 0;
  }
  ma_device_info* list = capture ? cap : playback;
  ma_uint32 n = capture ? cap_count : playback_count;
  char buf[256];
  for (ma_uint32 i = 0; i < n; ++i) {
    device_id_to_str(&list[i].id, buf, sizeof(buf));
    if (strcmp(buf, want) == 0) {
      *out_id = list[i].id;
      return 1;
    }
  }
  return 0;
}

/* ---- device backend selection ---- */

/* Selects the device backend for a requested le_audio_backend. The default build
 * ships only the miniaudio backend, so every choice resolves to it. In a
 * LOOPY_ENABLE_ASIO Windows build, LE_BACKEND_ASIO resolves to the ASIO backend;
 * the reference to le_asio_backend lives inside the guard, so the default build
 * never links any le_asio_* symbol. */
const le_device_backend* le_select_backend(int32_t backend) {
#if defined(_WIN32) && defined(LOOPY_ENABLE_ASIO)
  if (backend == LE_BACKEND_ASIO) return &le_asio_backend;
#endif
  (void)backend;
  return &le_miniaudio_backend;
}

#if !(defined(_WIN32) && defined(LOOPY_ENABLE_ASIO))
/* ASIO-disabled stub: no ASIO drivers exist, so enumeration is always empty. The
 * real probe lives in win_asio_device.cpp behind LOOPY_ENABLE_ASIO. Keeping the
 * FFI symbol defined in every build lets the Dart layer call it unconditionally
 * (it returns [] / count 0 off Windows or on the default build). */
int32_t le_enumerate_asio_drivers(le_device_info* out, int32_t max,
                                  int32_t* count) {
  if (out == NULL || count == NULL || max <= 0) return LE_ERR_INVALID;
  *count = 0;
  return LE_OK;
}
#endif
