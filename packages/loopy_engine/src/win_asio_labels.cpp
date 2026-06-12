/*
 * win_asio_labels.cpp — opt-in Windows ASIO per-channel label probe.
 *
 * Built ONLY when LOOPY_ENABLE_ASIO is set (see packages/loopy_engine/src/
 * CMakeLists.txt + docs/WINDOWS_ASIO.md). Reads per-input-channel names from the
 * ASIO driver and reuses the engine's portable le_excluded_mask_from_names /
 * le_label_is_loopback to build the same excluded-input bitmask macOS produces
 * from Core Audio labels.
 *
 * Scope and guarantees:
 *   - Label probe ONLY. Capture/playback never touch ASIO — they stay on
 *     miniaudio/WASAPI. This file opens the ASIO driver briefly, reads names,
 *     and closes it.
 *   - Degrades to 0 (exclude nothing) on ANY failure or ambiguity. The feature
 *     being unavailable is correct behaviour; the engine never errors because a
 *     label could not be read.
 *   - Prefer no-match over wrong-match: a mask that excludes the WRONG channels
 *     is worse than the no-op default, so any uncertainty returns 0.
 *
 * Licensing: the Steinberg ASIO SDK is GPLv3-or-proprietary and is NOT vendored
 * into this MIT repo. It is user-supplied via LOOPY_ASIO_SDK_DIR and .gitignored.
 *
 * The ASIO↔WASAPI device-matching heuristic below is deliberately conservative
 * pending the PR2 hardware spike (does the interface expose a name that reliably
 * maps a WASAPI uid to one ASIO driver?). Until that is answered on real
 * hardware, multi-driver rigs fall through to 0 rather than risk a wrong match.
 */
#if defined(_WIN32) && defined(LOOPY_ENABLE_ASIO)

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <ctype.h>
#include <string.h>

// User-supplied Steinberg ASIO SDK (LOOPY_ASIO_SDK_DIR on the include path).
#include "asio.h"
#include "asiodrivers.h"
#include "asiosys.h"

extern "C" {
#include "engine_internal.h"  // le_excluded_mask_from_names, le_channel_name_fn
#include "loopy_engine_api.h"  // LE_MAX_CHANNELS
#include "win_asio_labels.h"   // le_win_asio_excluded_mask prototype
}

// asiodrivers.h declares loadAsioDriver() and the asioDrivers global; both are
// defined in the SDK host sources (asiodrivers.cpp) the CMake adds when ON.

namespace {

constexpr int kMaxAsioDrivers = 32;
constexpr int kAsioNameLen = 32;  // ASIOChannelInfo.name is char[32].

// Collected input-channel names, indexed by channel, fed to the portable mask
// builder so the OS-facing ASIO calls stay out of the unit-tested core.
struct AsioInputNames {
  char names[LE_MAX_CHANNELS][kAsioNameLen];
  int count;
};

const char* asio_name_provider(void* ctx, int channel) {
  const AsioInputNames* n = static_cast<const AsioInputNames*>(ctx);
  if (channel < 0 || channel >= n->count) return nullptr;
  return n->names[channel];
}

bool contains_ci_ascii(const char* haystack, const char* needle) {
  if (haystack == nullptr || needle == nullptr || needle[0] == '\0') {
    return false;
  }
  const size_t hlen = strlen(haystack);
  const size_t nlen = strlen(needle);
  if (nlen > hlen) return false;
  for (size_t i = 0; i + nlen <= hlen; ++i) {
    size_t j = 0;
    for (; j < nlen; ++j) {
      const int a = tolower((unsigned char)haystack[i + j]);
      const int b = tolower((unsigned char)needle[j]);
      if (a != b) break;
    }
    if (j == nlen) return true;
  }
  return false;
}

// Chooses the ASIO driver index for `uid`, or -1 if none / ambiguous.
//
// A single installed driver is unambiguous and used directly. With several
// drivers we look for exactly one whose name relates to the WASAPI `uid`; any
// other count (zero or 2+ matches) returns -1 so the caller degrades to no-op.
// The WASAPI uid is an opaque endpoint string, so this match is best-effort and
// the precise rule is the spike's open question — bias is toward no-match.
int choose_driver(char* const* names, long driver_count, const char* uid) {
  if (driver_count <= 0) return -1;
  if (driver_count == 1) return 0;
  int match = -1;
  for (long i = 0; i < driver_count; ++i) {
    if (contains_ci_ascii(uid, names[i]) || contains_ci_ascii(names[i], uid)) {
      if (match != -1) return -1;  // ambiguous: 2+ candidates
      match = static_cast<int>(i);
    }
  }
  return match;
}

}  // namespace

extern "C" uint32_t le_win_asio_excluded_mask(const char* uid,
                                              int channel_count) {
  if (uid == nullptr || channel_count <= 0) return 0;

  // Enumerate installed ASIO drivers.
  char name_storage[kMaxAsioDrivers][kAsioNameLen];
  char* name_ptrs[kMaxAsioDrivers];
  for (int i = 0; i < kMaxAsioDrivers; ++i) name_ptrs[i] = name_storage[i];
  AsioDrivers drivers;
  const long driver_count = drivers.getDriverNames(name_ptrs, kMaxAsioDrivers);

  const int chosen = choose_driver(name_ptrs, driver_count, uid);
  if (chosen < 0) return 0;  // no driver / ambiguous match → exclude nothing.

  if (!loadAsioDriver(name_ptrs[chosen])) return 0;

  ASIODriverInfo info;
  memset(&info, 0, sizeof(info));
  info.asioVersion = 2;
  info.sysRef = GetDesktopWindow();  // ASIO wants an HWND; a probe needs no UI.
  if (ASIOInit(&info) != ASE_OK) {
    ASIOExit();
    return 0;
  }

  long input_channels = 0;
  long output_channels = 0;
  if (ASIOGetChannels(&input_channels, &output_channels) != ASE_OK) {
    ASIOExit();
    return 0;
  }

  // Read input-channel names up to the mask width and the caller's count.
  AsioInputNames collected;
  collected.count = 0;
  int probe = channel_count;
  if (probe > input_channels) probe = static_cast<int>(input_channels);
  if (probe > LE_MAX_CHANNELS) probe = LE_MAX_CHANNELS;
  for (int c = 0; c < probe; ++c) {
    ASIOChannelInfo ci;
    memset(&ci, 0, sizeof(ci));
    ci.channel = c;
    ci.isInput = ASIOTrue;
    if (ASIOGetChannelInfo(&ci) == ASE_OK) {
      strncpy(collected.names[c], ci.name, kAsioNameLen - 1);
      collected.names[c][kAsioNameLen - 1] = '\0';
    } else {
      collected.names[c][0] = '\0';
    }
    collected.count++;
  }

  ASIOExit();  // Release the driver before returning to the miniaudio path.

  return le_excluded_mask_from_names(asio_name_provider, &collected,
                                     collected.count);
}

#else
typedef int loopy_win_asio_labels_tu_unused; /* keep the TU non-empty when off */
#endif
