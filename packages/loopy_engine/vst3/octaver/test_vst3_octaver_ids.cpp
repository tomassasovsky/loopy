/*
 * test_vst3_octaver_ids.cpp — GUID-drift regression test (umbrella D-GUID).
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
      INLINE_UID(0x3D522447, 0x83390B64, 0x15C6CB7A, 0x508CE993);
  CHECK(std::memcmp(loopy_vst3_octaver::kProcessorUID, expected, 16) == 0);
}

static void test_controller_uid_unchanged() {
  std::printf("test_controller_uid_unchanged\n");
  const ::Steinberg::TUID expected =
      INLINE_UID(0x89C9DB02, 0xE3C9041B, 0xF927EC11, 0x70880926);
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
