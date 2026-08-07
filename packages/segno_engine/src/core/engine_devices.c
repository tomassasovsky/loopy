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
#include "segno_engine_api.h"
#include "miniaudio.h"
#if defined(_WIN32) && defined(SEGNO_ENABLE_ASIO)
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

/* The channel count `id` can carry in `capture`'s direction, or 0 when the
 * device cannot answer.
 *
 * ma_context_get_devices returns the CHEAP list — id, name, default flag — and
 * nothing else; the counts live behind ma_context_get_device_info, one query
 * per device. They were never unobtainable here, only unasked-for.
 *
 * Takes the WIDEST advertised format rather than the first: a device that
 * advertises both a 2ch stereo and an 18ch multitrack format is an 18-in
 * interface, and reading nativeDataFormats[0] would call it a stereo one. */
static int32_t query_device_channels(ma_context* ctx, const ma_device_id* id,
                                     int capture) {
  ma_device_info info;
  const ma_device_type type = capture ? ma_device_type_capture
                                      : ma_device_type_playback;
  if (ma_context_get_device_info(ctx, type, id, &info) != MA_SUCCESS) return 0;
  ma_uint32 widest = 0;
  for (ma_uint32 i = 0; i < info.nativeDataFormatCount; ++i) {
    if (info.nativeDataFormats[i].channels > widest) {
      widest = info.nativeDataFormats[i].channels;
    }
  }
  return (int32_t)widest;
}

/* Channel counts memoised per (device id, direction), across enumerations.
 *
 * query_device_channels is the EXPENSIVE half of enumeration — on CoreAudio a
 * run of blocking HAL property reads, one call per device — and enumeration is
 * on a 1 Hz poll so the picker notices an interface being plugged in. Asking
 * once per device instead of once per second per device keeps that poll costing
 * what it cost before the counts existed: a box's channel count does not change
 * while it is plugged in, and an id that comes back is the same box.
 *
 * Control thread only, like everything else in this file (see the header
 * comment), so no lock. A full table is simply a miss, which costs exactly what
 * the uncached path always cost. */
#define LE_CHANNEL_CACHE_MAX 64

/* How many sightings an entry is trusted for before it is read again.
 *
 * A countdown ON THE ENTRY, deliberately, rather than one cursor walking the
 * table: the two enumeration passes each visit only their OWN direction's
 * entries, so a shared cursor spends half its steps parked on entries the
 * current pass never looks at — and because the passes strictly alternate, an
 * even entry count locks each index to one direction's parity and leaves every
 * entry whose direction disagrees with its index parity never re-read at all.
 * A per-entry countdown is decremented exactly when that entry is sighted, so
 * every entry refreshes on its own schedule whatever the table looks like.
 *
 * At the 1 Hz enumeration poll this is a re-read roughly every half minute per
 * device — enough to heal a macOS aggregate that gained a member (its UID does
 * not change) without putting the query back on the hot path. */
#define LE_CHANNEL_CACHE_TTL 32

typedef struct le_channel_cache_entry {
  char id[256];
  int capture;
  int32_t channels;
  /* Sightings still to go before this entry is re-read. */
  int trust;
} le_channel_cache_entry;

static le_channel_cache_entry g_channel_cache[LE_CHANNEL_CACHE_MAX];
static int g_channel_cache_count = 0;

static int32_t device_channels(ma_context* ctx, const ma_device_id* id,
                               const char* key, int capture) {
  for (int i = 0; i < g_channel_cache_count; ++i) {
    le_channel_cache_entry* hit = &g_channel_cache[i];
    if (hit->capture != capture || strcmp(hit->id, key) != 0) continue;
    if (--hit->trust > 0) return hit->channels;
    hit->trust = LE_CHANNEL_CACHE_TTL;
    const int32_t fresh = query_device_channels(ctx, id, capture);
    /* A failed re-read keeps what was already known: 0 means UNKNOWN, and a
     * transient failure must not blank a count the device has answered. */
    if (fresh > 0) hit->channels = fresh;
    return hit->channels;
  }
  const int32_t channels = query_device_channels(ctx, id, capture);
  /* Only a real answer is remembered — caching a failure would pin the device
   * at UNKNOWN for the rest of the process. */
  if (channels > 0 && g_channel_cache_count < LE_CHANNEL_CACHE_MAX) {
    const int index = g_channel_cache_count++;
    le_channel_cache_entry* entry = &g_channel_cache[index];
    strncpy(entry->id, key, sizeof(entry->id) - 1);
    entry->id[sizeof(entry->id) - 1] = '\0';
    entry->capture = capture;
    entry->channels = channels;
    /* Seeded from the insertion index so entries fall due on different
     * sightings rather than the whole table re-reading on one poll. */
    entry->trust = index % LE_CHANNEL_CACHE_TTL + 1;
  }
  return channels;
}

static void device_info_copy(le_device_info* dst, const ma_device_info* src,
                             ma_context* ctx, int capture) {
  /* Zero everything first so the miniaudio path never surfaces stack garbage for
   * fields it does not fill (the ASIO-only buffer/rate sets). */
  memset(dst, 0, sizeof(*dst));
  device_id_to_str(&src->id, dst->id, sizeof(dst->id));
  strncpy(dst->name, src->name, sizeof(dst->name) - 1);
  dst->name[sizeof(dst->name) - 1] = '\0';
  dst->is_default = src->isDefault ? 1 : 0;
  /* Only the direction being enumerated: a playback device reports what it can
   * PLAY and never the other way round, so the opposite field stays 0. A device
   * that cannot answer keeps 0 too, which still means UNKNOWN — the UI omits
   * the readout rather than printing a zero count. The serialized id is the
   * cache key, so it has to be written before this. */
  if (capture) {
    dst->input_channels = device_channels(ctx, &src->id, dst->id, 1);
  } else {
    dst->output_channels = device_channels(ctx, &src->id, dst->id, 0);
  }
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
    device_info_copy(&out[written++], &list[i], &ctx, capture);
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
 * SEGNO_ENABLE_ASIO Windows build, LE_BACKEND_ASIO resolves to the ASIO backend;
 * the reference to le_asio_backend lives inside the guard, so the default build
 * never links any le_asio_* symbol. */
const le_device_backend* le_select_backend(int32_t backend) {
#if defined(_WIN32) && defined(SEGNO_ENABLE_ASIO)
  if (backend == LE_BACKEND_ASIO) return &le_asio_backend;
#endif
  (void)backend;
  return &le_miniaudio_backend;
}

#if !(defined(_WIN32) && defined(SEGNO_ENABLE_ASIO))
/* ASIO-disabled stub: no ASIO drivers exist, so enumeration is always empty. The
 * real probe lives in win_asio_device.cpp behind SEGNO_ENABLE_ASIO. Keeping the
 * FFI symbol defined in every build lets the Dart layer call it unconditionally
 * (it returns [] / count 0 off Windows or on the default build). */
int32_t le_enumerate_asio_drivers(le_device_info* out, int32_t max,
                                  int32_t* count) {
  if (out == NULL || count == NULL || max <= 0) return LE_ERR_INVALID;
  *count = 0;
  return LE_OK;
}
#endif
