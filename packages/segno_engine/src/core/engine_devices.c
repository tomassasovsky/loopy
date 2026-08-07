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
static int32_t device_channels(ma_context* ctx, const ma_device_id* id,
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

/* ---- channel-count cache ----
 *
 * device_channels is ~0.4-1.3 ms PER DEVICE (measured: macOS, Core Audio, see
 * src/test/bench/bench_devices.c), because ma_context_get_device_info is a
 * round trip to the audio daemon rather than a read of the list already in
 * hand. The picker re-enumerates on a 1 Hz timer, synchronously over FFI on
 * the UI isolate, in both directions — so uncached that is ~8 ms of blocked UI
 * every second on a 9-device host, against ~1.5 ms for the rest of the tick.
 * Nine devices is a laptop; a real rig has more, and the cost is linear in the
 * count.
 *
 * A device's channel count is a property OF THE DEVICE, not of the moment, so
 * the second query for the same id answers what the first one did. This caches
 * it by serialized id and direction. The id set is what actually changes across
 * ticks, and ma_context_get_devices already hands us that for free — so the
 * per-id lookup IS the hot-plug diff: a device that appears misses and is
 * queried once, a device that vanishes is swept. Steady state on an unchanging
 * rig costs zero queries.
 *
 * STALENESS: a device that changes its channel count WITHOUT changing its id
 * keeps the old count until it disappears from the list once. That is an
 * aggregate device being reconfigured, or an interface re-moded in its control
 * panel — rare, and the cost of being wrong is a readout, not a routing. The
 * count is re-taken on the next unplug/replug.
 *
 * THREAD OWNERSHIP: control thread, like everything else in this file. The
 * table is plain static state with no locking because enumeration has exactly
 * one caller thread; it is never touched from the audio thread. */
#define LE_CHANNEL_CACHE_CAP 64

typedef struct le_channel_cache_entry {
  char id[256];
  int capture;      /* the direction this count was taken in */
  int32_t channels; /* 0 = the device could not answer; cached as such */
  int seen;         /* mark bit for the sweep at the end of an enumeration */
} le_channel_cache_entry;

static le_channel_cache_entry g_channel_cache[LE_CHANNEL_CACHE_CAP];
static int32_t g_channel_cache_count;

/* Clears the mark bit on every entry for `capture`'s direction, so the walk can
 * set it on the ids it still sees and the sweep can drop the rest. Entries for
 * the OTHER direction are untouched: a playback enumeration is no evidence
 * about which capture devices still exist. */
static void channel_cache_begin(int capture) {
  for (int32_t i = 0; i < g_channel_cache_count; ++i) {
    if (g_channel_cache[i].capture == capture) g_channel_cache[i].seen = 0;
  }
}

/* Drops every unmarked entry for `capture`'s direction — the devices that were
 * cached but no longer enumerate, i.e. unplugged. Compacts in place so the
 * table cannot fill up with the ghosts of a session's worth of hot-plugs. */
static void channel_cache_end(int capture) {
  int32_t kept = 0;
  for (int32_t i = 0; i < g_channel_cache_count; ++i) {
    if (g_channel_cache[i].capture == capture && !g_channel_cache[i].seen) {
      continue;
    }
    if (kept != i) g_channel_cache[kept] = g_channel_cache[i];
    ++kept;
  }
  g_channel_cache_count = kept;
}

/* The cached count for (`id`, `capture`), querying and caching it on a miss.
 * A full table degrades to querying every time rather than evicting — the cap
 * is well past any real host's device count, so this is a safety valve and not
 * a path anything is expected to take. */
static int32_t device_channels_cached(ma_context* ctx, const ma_device_id* raw,
                                      const char* id, int capture) {
  for (int32_t i = 0; i < g_channel_cache_count; ++i) {
    le_channel_cache_entry* e = &g_channel_cache[i];
    if (e->capture == capture && strcmp(e->id, id) == 0) {
      e->seen = 1;
      return e->channels;
    }
  }
  const int32_t channels = device_channels(ctx, raw, capture);
  if (g_channel_cache_count < LE_CHANNEL_CACHE_CAP) {
    le_channel_cache_entry* e = &g_channel_cache[g_channel_cache_count++];
    strncpy(e->id, id, sizeof(e->id) - 1);
    e->id[sizeof(e->id) - 1] = '\0';
    e->capture = capture;
    e->channels = channels;
    e->seen = 1;
  }
  return channels;
}

/* Drops every cached count. Exposed for the unit tests, which need a known
 * empty table to assert the miss-then-hit behaviour; nothing in the shipping
 * paths calls it, because the mark-and-sweep keeps the table honest on its
 * own. Declared in engine_internal.h. */
void le_channel_cache_reset(void) { g_channel_cache_count = 0; }

/* The number of entries currently cached — tests only, same rationale. */
int32_t le_channel_cache_size(void) { return g_channel_cache_count; }

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
   * the readout rather than printing a zero count. */
  if (capture) {
    dst->input_channels =
        device_channels_cached(ctx, &src->id, dst->id, /*capture=*/1);
  } else {
    dst->output_channels =
        device_channels_cached(ctx, &src->id, dst->id, /*capture=*/0);
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
  /* Mark-and-sweep around the walk: every id still present gets its mark set by
   * device_channels_cached, and the sweep drops what kept none — the devices
   * that went away. See the channel-count cache notes above. */
  channel_cache_begin(capture);
  for (ma_uint32 i = 0; i < n && written < max; ++i) {
    device_info_copy(&out[written++], &list[i], &ctx, capture);
  }
  /* Only sweep when the whole list was walked. A list truncated by `max` leaves
   * the devices past the cap unmarked though they still exist, and sweeping
   * then would evict them every call — turning the tail of an over-cap host
   * into a permanent cache miss instead of merely an unlisted device. */
  if (written == (int32_t)n) channel_cache_end(capture);
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
