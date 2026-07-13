/*
 * test_vst3_drive_ids.cpp — GUID-drift regression test (umbrella D-GUID).
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
      0x4B, 0x97, 0xC4, 0xB2, 0xDF, 0x15, 0x0F, 0xA1,
      0xAD, 0xF3, 0x9F, 0x6E, 0x82, 0xE9, 0x7A, 0x25,
  };
  CHECK(std::memcmp(loopy_vst3_drive::kProcessorUID, expected, 16) == 0);
}

static void test_controller_uid_unchanged() {
  std::printf("test_controller_uid_unchanged\n");
  const unsigned char expected[16] = {
      0xF5, 0x2D, 0x09, 0x54, 0x50, 0xC5, 0x94, 0xA7,
      0x4D, 0x48, 0x65, 0x98, 0x3B, 0xA4, 0x7E, 0xF2,
  };
  CHECK(std::memcmp(loopy_vst3_drive::kControllerUID, expected, 16) == 0);
}

static void test_processor_and_controller_uid_distinct() {
  std::printf("test_processor_and_controller_uid_distinct\n");
  CHECK(std::memcmp(loopy_vst3_drive::kProcessorUID, loopy_vst3_drive::kControllerUID,
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
