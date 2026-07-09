/*
 * test_vst3_tremolo_ids.cpp — GUID-drift regression test (umbrella D-GUID).
 *
 * Independently hardcodes the same 16 bytes ids.h declares, transcribed
 * separately rather than reused from ids.h's own macros — the point is to
 * catch an accidental edit to ids.h itself, so this test must not share the
 * literal it is checking against. Byte order matches INLINE_UID's own
 * splitting of each 32-bit word (MSB first), independent of COM_COMPATIBLE.
 *
 * Wired into run_native_tests.sh (macOS-only section, alongside the other
 * plugin-hosting tests already built there).
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
  const unsigned char expected[16] = {
      0x2D, 0x8D, 0x41, 0x87, 0x3B, 0xDF, 0x80, 0x21,
      0x0F, 0xE2, 0x47, 0x0F, 0xA5, 0xD3, 0x9A, 0xA0,
  };
  CHECK(std::memcmp(loopy_vst3_tremolo::kProcessorUID, expected, 16) == 0);
}

static void test_controller_uid_unchanged() {
  std::printf("test_controller_uid_unchanged\n");
  const unsigned char expected[16] = {
      0x41, 0x9C, 0xC1, 0xE4, 0x65, 0x7A, 0x31, 0x71,
      0x7E, 0x31, 0xB5, 0xC5, 0x1B, 0x05, 0x6A, 0x8E,
  };
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
