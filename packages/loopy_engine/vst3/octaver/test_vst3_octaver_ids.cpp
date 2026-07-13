/*
 * test_vst3_octaver_ids.cpp — GUID-drift regression test (umbrella D-GUID).
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
      0x3D, 0x52, 0x24, 0x47, 0x83, 0x39, 0x0B, 0x64,
      0x15, 0xC6, 0xCB, 0x7A, 0x50, 0x8C, 0xE9, 0x93,
  };
  CHECK(std::memcmp(loopy_vst3_octaver::kProcessorUID, expected, 16) == 0);
}

static void test_controller_uid_unchanged() {
  std::printf("test_controller_uid_unchanged\n");
  const unsigned char expected[16] = {
      0x89, 0xC9, 0xDB, 0x02, 0xE3, 0xC9, 0x04, 0x1B,
      0xF9, 0x27, 0xEC, 0x11, 0x70, 0x88, 0x09, 0x26,
  };
  CHECK(std::memcmp(loopy_vst3_octaver::kControllerUID, expected, 16) == 0);
}

static void test_processor_and_controller_uid_distinct() {
  std::printf("test_processor_and_controller_uid_distinct\n");
  CHECK(std::memcmp(loopy_vst3_octaver::kProcessorUID, loopy_vst3_octaver::kControllerUID,
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
