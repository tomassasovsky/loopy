/*
 * test_vst3_reverb_ids.cpp — GUID-drift regression test (umbrella D-GUID).
 *
 * Independently hardcodes the same 16 bytes ids.h declares, transcribed
 * separately rather than reused from ids.h's own macros — the point is to
 * catch an accidental edit to ids.h itself, so this test must not share the
 * literal it is checking against. Byte order matches INLINE_UID's own
 * splitting of each 32-bit word (MSB first), independent of COM_COMPATIBLE.
 *
 * Wired into run_native_tests.sh (macOS-only section, alongside the Delay
 * plugin's equivalent test).
 */
#include <cstdio>
#include <cstring>

#include "ids.h"

int g_failures = 0;
#define CHECK(cond)                                       \
  do {                                                     \
    if (!(cond)) {                                         \
      std::printf("  FAIL: %s (line %d)\n", #cond, __LINE__); \
      g_failures++;                                        \
    }                                                       \
  } while (0)

static void test_processor_uid_unchanged() {
  std::printf("test_processor_uid_unchanged\n");
  const unsigned char expected[16] = {
      0xC9, 0xC6, 0x5F, 0xCD, 0xD0, 0x77, 0x4D, 0x83,
      0x8C, 0x10, 0xB8, 0x45, 0x99, 0xFD, 0x94, 0xC4,
  };
  CHECK(std::memcmp(loopy_vst3_reverb::kProcessorUID, expected, 16) == 0);
}

static void test_controller_uid_unchanged() {
  std::printf("test_controller_uid_unchanged\n");
  const unsigned char expected[16] = {
      0xC7, 0x0B, 0x8B, 0x61, 0xAF, 0x21, 0x49, 0x27,
      0x83, 0x01, 0xB7, 0x08, 0xB2, 0x36, 0xF1, 0xF7,
  };
  CHECK(std::memcmp(loopy_vst3_reverb::kControllerUID, expected, 16) == 0);
}

static void test_processor_and_controller_uid_distinct() {
  std::printf("test_processor_and_controller_uid_distinct\n");
  CHECK(std::memcmp(loopy_vst3_reverb::kProcessorUID, loopy_vst3_reverb::kControllerUID,
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
