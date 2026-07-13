/*
 * test_vst3_tremolo_ids.cpp — GUID-drift regression test (umbrella D-GUID).
 *
 * Independently transcribes the same four 32-bit identity words ids.h declares
 * (a separate copy, NOT reused from ids.h's macros) and rebuilds the expected
 * TUID through the SDK's own INLINE_UID — so an accidental edit to ids.h's
 * literals is still caught, while the byte comparison stays correct on every OS:
 * INLINE_UID applies the COM_COMPATIBLE byte order on Windows and the plain
 * MSB-first order on macOS/Linux, exactly as kProcessorUID/kControllerUID are
 * built. (A raw hardcoded 16-byte array only matches one platform's order.)
 */
#include <cstdio>
#include <cstring>

#include "ids.h"

int g_failures = 0;
#define CHECK(cond)                                      \
  do {                                                    \
    if (!(cond)) {                                        \
      std::printf("  FAIL: %s (line %d)\n", #cond, __LINE__); \
      g_failures++;                                       \
    }                                                     \
  } while (0)

static void test_processor_uid_unchanged() {
  std::printf("test_processor_uid_unchanged\n");
  const ::Steinberg::TUID expected =
      INLINE_UID(0x2D8D4187, 0x3BDF8021, 0x0FE2470F, 0xA5D39AA0);
  CHECK(std::memcmp(loopy_vst3_tremolo::kProcessorUID, expected, 16) == 0);
}

static void test_controller_uid_unchanged() {
  std::printf("test_controller_uid_unchanged\n");
  const ::Steinberg::TUID expected =
      INLINE_UID(0x419CC1E4, 0x657A3171, 0x7E31B5C5, 0x1B056A8E);
  CHECK(std::memcmp(loopy_vst3_tremolo::kControllerUID, expected, 16) == 0);
}

static void test_processor_and_controller_uid_distinct() {
  std::printf("test_processor_and_controller_uid_distinct\n");
  CHECK(std::memcmp(loopy_vst3_tremolo::kProcessorUID, loopy_vst3_tremolo::kControllerUID,
                     16) != 0);
}

int main() {
  test_processor_uid_unchanged();
  test_controller_uid_unchanged();
  test_processor_and_controller_uid_distinct();
  if (g_failures == 0) {
    std::printf("ALL PASSED\n");
    return 0;
  }
  std::printf("%d FAILURE(S)\n", g_failures);
  return 1;
}
