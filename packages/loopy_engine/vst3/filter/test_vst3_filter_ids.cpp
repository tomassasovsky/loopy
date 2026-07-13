/*
 * test_vst3_filter_ids.cpp — GUID-drift regression test (umbrella D-GUID).
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
      0xED, 0xD2, 0x78, 0x69, 0xF5, 0xC0, 0x66, 0x7F,
      0x47, 0x9A, 0x33, 0x87, 0x81, 0xC8, 0x02, 0x62,
  };
  CHECK(std::memcmp(loopy_vst3_filter::kProcessorUID, expected, 16) == 0);
}

static void test_controller_uid_unchanged() {
  std::printf("test_controller_uid_unchanged\n");
  const unsigned char expected[16] = {
      0x05, 0xDE, 0x04, 0x85, 0x6B, 0x6E, 0xF5, 0x02,
      0xAE, 0x6D, 0x2C, 0x82, 0x7C, 0x66, 0x42, 0xE0,
  };
  CHECK(std::memcmp(loopy_vst3_filter::kControllerUID, expected, 16) == 0);
}

static void test_processor_and_controller_uid_distinct() {
  std::printf("test_processor_and_controller_uid_distinct\n");
  CHECK(std::memcmp(loopy_vst3_filter::kProcessorUID, loopy_vst3_filter::kControllerUID,
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
