/*
 * test_plugin_scan.cpp — native unit test for the plugin scan ABI + thread.
 *
 * macOS-only (LOOPY_ENABLE_PLUGINS): built and run by run_native_tests.sh after
 * the engine + MIDI suites. It does NOT depend on any real installed plugin —
 * it points CLAP_PATH at a temp directory holding a deliberately-broken .clap
 * and asserts the per-candidate guard (D-SCAN): the scan completes, the broken
 * candidate surfaces as a failed entry (empty id), and nothing aborts or hangs.
 *
 * Expects "ALL PASSED".
 */
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <string>

#include "loopy_engine_api.h"
#include "plugin_host.h"

static int g_failures = 0;

#define CHECK(cond)                                                       \
  do {                                                                    \
    if (!(cond)) {                                                        \
      printf("  FAIL: %s (line %d)\n", #cond, __LINE__);                  \
      g_failures++;                                                       \
    }                                                                     \
  } while (0)

// A non-null sentinel: the scan ABI validates engine != null but never
// dereferences it (scan state is an engine-independent singleton).
static le_engine* kEngine = reinterpret_cast<le_engine*>(0x1);

static void test_parse_version(void) {
  printf("test_parse_version\n");
  CHECK(loopy::parseVersion("1.2.3") == ((1u << 16) | (2u << 8) | 3u));
  CHECK(loopy::parseVersion("1.0.0.512") == (1u << 16));  // 4th field ignored
  CHECK(loopy::parseVersion("2") == (2u << 16));
  CHECK(loopy::parseVersion("1.4") == ((1u << 16) | (4u << 8)));
  CHECK(loopy::parseVersion("1.0-beta") == (1u << 16));  // stops at non-numeric
  CHECK(loopy::parseVersion("") == 0u);
  CHECK(loopy::parseVersion("abc") == 0u);
  CHECK(loopy::parseVersion("300.0.0") == ((255u << 16)));  // clamps to a byte
}

static void test_null_guards(void) {
  printf("test_null_guards\n");
  CHECK(le_plugin_scan_begin(nullptr, 0) == LE_ERR_INVALID);
  CHECK(le_plugin_scan_poll(nullptr, nullptr, nullptr, nullptr, nullptr) ==
        LE_ERR_INVALID);
  le_plugin_desc d;
  CHECK(le_plugin_scan_get(nullptr, 0, &d) == LE_ERR_INVALID);
  CHECK(le_plugin_scan_cancel(nullptr) == LE_ERR_INVALID);
}

// Drives a full scan to completion (bounded poll) and returns the final counts.
static void run_scan(int* done, int* found, int* scanned, int* total) {
  CHECK(le_plugin_scan_begin(kEngine, 0) == LE_OK);
  *done = 0;
  for (int i = 0; i < 400 && !*done; i++) {
    le_plugin_scan_poll(kEngine, done, found, scanned, total);
    struct timespec ts;
    ts.tv_sec = 0;
    ts.tv_nsec = 25 * 1000 * 1000;  // 25 ms
    nanosleep(&ts, nullptr);
  }
}

static void test_broken_candidate_yields_failed_entry(void) {
  printf("test_broken_candidate_yields_failed_entry\n");
  // A temp CLAP dir with one broken bundle (a .clap with no clap_entry symbol).
  std::system("rm -rf /tmp/loopy_scan_fixture && "
              "mkdir -p /tmp/loopy_scan_fixture/broken.clap && "
              "echo garbage > /tmp/loopy_scan_fixture/broken.clap/x.txt");
  setenv("CLAP_PATH", "/tmp/loopy_scan_fixture", 1);

  int done = 0, found = 0, scanned = 0, total = 0;
  run_scan(&done, &found, &scanned, &total);

  CHECK(done == 1);          // completed, did not hang
  CHECK(found >= 1);         // at least the broken fixture surfaced
  CHECK(scanned >= 1);

  // The broken fixture must appear as a failed entry: empty id, our filename.
  bool sawFailed = false;
  for (int i = 0; i < found; i++) {
    le_plugin_desc d;
    if (le_plugin_scan_get(kEngine, i, &d) != LE_OK) continue;
    if (d.id[0] == '\0' && std::string(d.name) == "broken.clap") {
      sawFailed = true;
      CHECK(d.format == LE_PLUGIN_CLAP);
    }
  }
  CHECK(sawFailed);

  unsetenv("CLAP_PATH");
  std::system("rm -rf /tmp/loopy_scan_fixture");
}

static void test_cancel_is_idempotent(void) {
  printf("test_cancel_is_idempotent\n");
  // Cancel with no scan running is a safe no-op; calling twice must not crash.
  CHECK(le_plugin_scan_cancel(kEngine) == LE_OK);
  CHECK(le_plugin_scan_cancel(kEngine) == LE_OK);
  // A fresh scan still works after cancellation.
  int done = 0, found = 0, scanned = 0, total = 0;
  run_scan(&done, &found, &scanned, &total);
  CHECK(done == 1);
  le_plugin_scan_cancel(kEngine);
}

int main(void) {
  test_parse_version();
  test_null_guards();
  test_broken_candidate_yields_failed_entry();
  test_cancel_is_idempotent();
  if (g_failures == 0) {
    printf("ALL PASSED\n");
    return 0;
  }
  printf("%d FAILURE(S)\n", g_failures);
  return 1;
}
