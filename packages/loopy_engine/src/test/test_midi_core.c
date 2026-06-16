/*
 * test_midi_core.c - native unit tests for the portable MIDI core (midi.c).
 *
 * Covers the pieces with the strictest correctness requirements and which are
 * fully testable without MIDI hardware: the pure parser, the SPSC ring
 * (filtering, FIFO order, wrap-around, full), the drain -> callback delivery
 * path, and the close-nulls-the-callback dispose ordering that guards against a
 * use-after-free into freed Dart state.
 *
 * The three per-OS backend TUs are listed in the build below; the two that don't
 * match the host compile to near-empty objects, so le_midi_select_backend
 * resolves at link time exactly as in the shipped library.
 *
 * Build & run (Windows, MinGW gcc — the WinMM backend links winmm):
 *   gcc -std=c11 -I src -I src/miniaudio \
 *     src/test/test_midi_core.c src/midi.c \
 *     src/midi_backend_linux.c src/midi_backend_apple.c \
 *     src/midi_backend_windows.c \
 *     -lwinmm -o loopy_midi_tests.exe
 *   ./loopy_midi_tests.exe
 *
 * Build & run (Linux — the ALSA backend links asound):
 *   clang -std=c11 -I src -I src/miniaudio \
 *     src/test/test_midi_core.c src/midi.c \
 *     src/midi_backend_linux.c src/midi_backend_apple.c \
 *     src/midi_backend_windows.c \
 *     -lasound -lpthread -o /tmp/loopy_midi_tests && /tmp/loopy_midi_tests
 *
 * Build & run (macOS — links CoreMIDI):
 *   clang -std=c11 -I src -I src/miniaudio \
 *     src/test/test_midi_core.c src/midi.c \
 *     src/midi_backend_linux.c src/midi_backend_apple.c \
 *     src/midi_backend_windows.c \
 *     -framework CoreMIDI -framework CoreFoundation \
 *     -o /tmp/loopy_midi_tests && /tmp/loopy_midi_tests
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "le_midi_backend.h"
#include "le_midi_internal.h"
#include "loopy_engine_api.h"

static int g_failures = 0;

#define CHECK(cond)                                      \
  do {                                                   \
    if (!(cond)) {                                       \
      printf("  FAIL: %s (line %d)\n", #cond, __LINE__); \
      g_failures++;                                      \
    }                                                    \
  } while (0)

/* ---- callback capture (the cb is a plain C function pointer) -------------- */

#define CAP_MAX 512
typedef struct {
  uint8_t status, data1, data2;
  uint64_t ts_us;
} cap_msg;
static int g_cap_count;
static cap_msg g_cap[CAP_MAX];

static void cap_reset(void) { g_cap_count = 0; }

static void cap_cb(uint8_t status, uint8_t data1, uint8_t data2,
                   uint64_t ts_us) {
  if (g_cap_count < CAP_MAX) {
    g_cap[g_cap_count].status = status;
    g_cap[g_cap_count].data1 = data1;
    g_cap[g_cap_count].data2 = data2;
    g_cap[g_cap_count].ts_us = ts_us;
  }
  g_cap_count++;
}

/* ---- parser -------------------------------------------------------------- */

static void test_parse_control_change(void) {
  printf("test_parse_control_change\n");
  le_midi_parsed p;
  CHECK(le_midi_parse(0xB0, 80, 127, &p) == LE_MIDI_CC);
  CHECK(p.kind == LE_MIDI_CC);
  CHECK(p.channel == 0);
  CHECK(p.number == 80);
  CHECK(p.value == 127);
  /* channel rides in the low nibble */
  CHECK(le_midi_parse(0xB5, 83, 0, &p) == LE_MIDI_CC);
  CHECK(p.channel == 5);
  CHECK(p.number == 83);
  CHECK(p.value == 0);
}

static void test_parse_note_on_and_off(void) {
  printf("test_parse_note_on_and_off\n");
  le_midi_parsed p;
  CHECK(le_midi_parse(0x90, 60, 100, &p) == LE_MIDI_NOTE_ON);
  CHECK(p.number == 60 && p.value == 100);
  /* Note On with velocity 0 is a Note Off (running-status convention). */
  CHECK(le_midi_parse(0x90, 60, 0, &p) == LE_MIDI_NOTE_OFF);
  CHECK(p.value == 0);
  /* Explicit Note Off. */
  CHECK(le_midi_parse(0x83, 64, 40, &p) == LE_MIDI_NOTE_OFF);
  CHECK(p.channel == 3 && p.number == 64 && p.value == 40);
}

static void test_parse_ignores_non_note_cc(void) {
  printf("test_parse_ignores_non_note_cc\n");
  CHECK(le_midi_parse(0xA0, 60, 10, NULL) == LE_MIDI_IGNORE); /* aftertouch */
  CHECK(le_midi_parse(0xC0, 5, 0, NULL) == LE_MIDI_IGNORE);   /* program */
  CHECK(le_midi_parse(0xD0, 64, 0, NULL) == LE_MIDI_IGNORE);  /* chan press */
  CHECK(le_midi_parse(0xE0, 0, 64, NULL) == LE_MIDI_IGNORE);  /* pitch bend */
  CHECK(le_midi_parse(0xF0, 0, 0, NULL) == LE_MIDI_IGNORE);   /* SysEx start */
  CHECK(le_midi_parse(0xF8, 0, 0, NULL) == LE_MIDI_IGNORE);   /* clock */
  CHECK(le_midi_parse(0xFE, 0, 0, NULL) == LE_MIDI_IGNORE);   /* active sens */
  /* A data byte (high bit clear) is never a status. */
  CHECK(le_midi_parse(0x40, 0, 0, NULL) == LE_MIDI_IGNORE);
  /* NULL out pointer is allowed. */
  CHECK(le_midi_parse(0xB0, 1, 2, NULL) == LE_MIDI_CC);
}

/* ---- ring push filtering ------------------------------------------------- */

static void test_ring_push_filters_non_note_cc(void) {
  printf("test_ring_push_filters_non_note_cc\n");
  le_midi* m = le_midi_create();
  CHECK(m != NULL);
  CHECK(le_midi_push_for_test(m, 0xB0, 80, 127, 1) == 1); /* CC kept */
  CHECK(le_midi_push_for_test(m, 0x90, 60, 100, 2) == 1); /* Note On kept */
  CHECK(le_midi_push_for_test(m, 0x80, 60, 0, 3) == 1);   /* Note Off kept */
  CHECK(le_midi_push_for_test(m, 0xF0, 0, 0, 4) == 0);    /* SysEx dropped */
  CHECK(le_midi_push_for_test(m, 0xF8, 0, 0, 5) == 0);    /* clock dropped */
  CHECK(le_midi_push_for_test(m, 0xE0, 0, 64, 6) == 0);   /* pitch dropped */
  le_midi_destroy(m);
}

/* ---- drain delivery + FIFO ----------------------------------------------- */

static void test_drain_delivers_in_fifo_order(void) {
  printf("test_drain_delivers_in_fifo_order\n");
  cap_reset();
  le_midi* m = le_midi_create();
  le_midi_set_cb_for_test(m, cap_cb);
  CHECK(le_midi_push_for_test(m, 0xB0, 80, 10, 111) == 1);
  CHECK(le_midi_push_for_test(m, 0xB0, 81, 20, 222) == 1);
  CHECK(le_midi_push_for_test(m, 0x90, 64, 30, 333) == 1);
  le_midi_drain(m);
  CHECK(g_cap_count == 3);
  CHECK(g_cap[0].status == 0xB0 && g_cap[0].data1 == 80 && g_cap[0].data2 == 10);
  CHECK(g_cap[0].ts_us == 111);
  CHECK(g_cap[1].data1 == 81 && g_cap[1].ts_us == 222);
  CHECK(g_cap[2].status == 0x90 && g_cap[2].data1 == 64 && g_cap[2].ts_us == 333);
  /* A second drain with nothing queued delivers nothing. */
  le_midi_drain(m);
  CHECK(g_cap_count == 3);
  le_midi_destroy(m);
}

static void test_ring_wraps_around(void) {
  printf("test_ring_wraps_around\n");
  cap_reset();
  le_midi* m = le_midi_create();
  le_midi_set_cb_for_test(m, cap_cb);
  /* Push/drain many more than the ring capacity in small batches so the head/
   * tail indices wrap past the buffer size while staying correct. */
  int expected = 0;
  for (int batch = 0; batch < 50; ++batch) {
    for (int i = 0; i < 10; ++i) {
      CHECK(le_midi_push_for_test(m, 0xB0, (uint8_t)(i & 0x7F),
                                  (uint8_t)(batch & 0x7F), (uint64_t)expected) ==
            1);
      expected++;
    }
    le_midi_drain(m);
  }
  CHECK(g_cap_count == expected);
  CHECK(g_cap[expected - 1].ts_us == (uint64_t)(expected - 1));
  le_midi_destroy(m);
}

static void test_ring_full_drops_newest(void) {
  printf("test_ring_full_drops_newest\n");
  le_midi* m = le_midi_create();
  /* Without draining, the ring accepts CAP-1 messages then rejects the rest. */
  int accepted = 0;
  for (int i = 0; i < 1000; ++i) {
    if (le_midi_push_for_test(m, 0xB0, (uint8_t)(i & 0x7F), 1, (uint64_t)i)) {
      accepted++;
    }
  }
  CHECK(accepted == 127); /* LE_MIDI_RING_CAP (128) - 1 usable slot */
  /* Everything accepted drains back out in order. */
  cap_reset();
  le_midi_set_cb_for_test(m, cap_cb);
  le_midi_drain(m);
  CHECK(g_cap_count == accepted);
  CHECK(g_cap[0].ts_us == 0);
  CHECK(g_cap[accepted - 1].ts_us == (uint64_t)(accepted - 1));
  le_midi_destroy(m);
}

/* ---- dispose ordering ---------------------------------------------------- */

static void test_close_nulls_callback_before_teardown(void) {
  printf("test_close_nulls_callback_before_teardown\n");
  cap_reset();
  le_midi* m = le_midi_create();
  le_midi_set_cb_for_test(m, cap_cb);
  CHECK(le_midi_push_for_test(m, 0xB0, 80, 127, 1) == 1);
  /* close() must null the callback; a drain afterwards delivers nothing, so a
   * message queued before close can never reach freed Dart state. */
  CHECK(le_midi_close(m) == LE_OK);
  le_midi_drain(m);
  CHECK(g_cap_count == 0);
  /* close is idempotent. */
  CHECK(le_midi_close(m) == LE_OK);
  le_midi_destroy(m);
}

/* ---- lifecycle / FFI guards ---------------------------------------------- */

static void test_create_destroy_and_null_safety(void) {
  printf("test_create_destroy_and_null_safety\n");
  le_midi* m = le_midi_create();
  CHECK(m != NULL);
  le_midi_destroy(m);
  le_midi_destroy(NULL);              /* safe */
  CHECK(le_midi_close(NULL) == LE_ERR_INVALID);
  CHECK(le_midi_open(NULL, "x", cap_cb) == LE_ERR_INVALID);
}

static void test_open_rejects_null_callback(void) {
  printf("test_open_rejects_null_callback\n");
  le_midi* m = le_midi_create();
  CHECK(le_midi_open(m, "nonexistent", NULL) == LE_ERR_INVALID);
  /* A non-existent device id fails as a device error, not a crash. */
  CHECK(le_midi_open(m, "no-such-device-xyz", cap_cb) == LE_ERR_DEVICE);
  le_midi_destroy(m);
}

static void test_enumerate_arg_validation(void) {
  printf("test_enumerate_arg_validation\n");
  le_midi_info infos[8];
  int32_t count = -1;
  CHECK(le_midi_enumerate(NULL, 8, &count) == LE_ERR_INVALID);
  CHECK(le_midi_enumerate(infos, 8, NULL) == LE_ERR_INVALID);
  CHECK(le_midi_enumerate(infos, 0, &count) == LE_ERR_INVALID);
  /* Valid call returns LE_OK and a non-negative count (0 with no devices). */
  count = -1;
  CHECK(le_midi_enumerate(infos, 8, &count) == LE_OK);
  CHECK(count >= 0 && count <= 8);
}

/* ---- MIDI output seam ---------------------------------------------------- *
 *
 * The output path has no ring and no callback, so the host-testable surface is
 * the FFI contract: argument validation, the not-open guard, idempotent close,
 * and create/destroy null safety. The actual byte delivery needs a real OS port
 * (covered by the manual per-OS smoke pass), so these never assert on a send to
 * an open device. */

static void test_midi_out_create_destroy_and_null_safety(void) {
  printf("test_midi_out_create_destroy_and_null_safety\n");
  le_midi_out* m = le_midi_out_create();
  CHECK(m != NULL);
  le_midi_out_destroy(m);
  le_midi_out_destroy(NULL);                    /* safe */
  CHECK(le_midi_out_close(NULL) == LE_ERR_INVALID);
  CHECK(le_midi_out_open(NULL, "x") == LE_ERR_INVALID);
  const uint8_t b[] = {0xB0, 80, 127};
  CHECK(le_midi_out_send(NULL, b, 3) == LE_ERR_INVALID);
}

static void test_midi_out_enumerate_arg_validation(void) {
  printf("test_midi_out_enumerate_arg_validation\n");
  le_midi_info infos[8];
  int32_t count = -1;
  CHECK(le_midi_out_enumerate(NULL, 8, &count) == LE_ERR_INVALID);
  CHECK(le_midi_out_enumerate(infos, 8, NULL) == LE_ERR_INVALID);
  CHECK(le_midi_out_enumerate(infos, 0, &count) == LE_ERR_INVALID);
  /* Valid call returns LE_OK and a non-negative, clamped count. */
  count = -1;
  CHECK(le_midi_out_enumerate(infos, 8, &count) == LE_OK);
  CHECK(count >= 0 && count <= 8);
}

static void test_midi_out_send_and_open_guards(void) {
  printf("test_midi_out_send_and_open_guards\n");
  le_midi_out* m = le_midi_out_create();
  CHECK(m != NULL);
  const uint8_t msg[] = {0xB0, 80, 127};
  /* Nothing open yet: send is a device error, not a crash. */
  CHECK(le_midi_out_send(m, msg, 3) == LE_ERR_DEVICE);
  /* Bad send arguments are rejected before the open check. */
  CHECK(le_midi_out_send(m, NULL, 3) == LE_ERR_INVALID);
  CHECK(le_midi_out_send(m, msg, 0) == LE_ERR_INVALID);
  /* A non-existent destination id fails as a device error. */
  CHECK(le_midi_out_open(m, "no-such-output-xyz") == LE_ERR_DEVICE);
  /* close is idempotent even when nothing was ever opened. */
  CHECK(le_midi_out_close(m) == LE_OK);
  CHECK(le_midi_out_close(m) == LE_OK);
  le_midi_out_destroy(m);
}

int main(void) {
  test_parse_control_change();
  test_parse_note_on_and_off();
  test_parse_ignores_non_note_cc();
  test_ring_push_filters_non_note_cc();
  test_drain_delivers_in_fifo_order();
  test_ring_wraps_around();
  test_ring_full_drops_newest();
  test_close_nulls_callback_before_teardown();
  test_create_destroy_and_null_safety();
  test_open_rejects_null_callback();
  test_enumerate_arg_validation();
  test_midi_out_create_destroy_and_null_safety();
  test_midi_out_enumerate_arg_validation();
  test_midi_out_send_and_open_guards();

  if (g_failures == 0) {
    printf("ALL PASSED\n");
    return 0;
  }
  printf("%d CHECK(S) FAILED\n", g_failures);
  return 1;
}
