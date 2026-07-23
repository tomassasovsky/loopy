/*
 * test_midi_core.c - native unit tests for the portable MIDI core (midi.c).
 *
 * Covers the pieces with the strictest correctness requirements and which are
 * fully testable without MIDI hardware: the pure parser, the SPSC ring
 * (filtering, FIFO order, wrap-around, full), the drain -> callback delivery
 * path, and the close-nulls-the-callback dispose ordering that guards against a
 * use-after-free into freed Dart state.
 *
 * The MIDI sources live under src/midi/ (midi.c plus the three per-OS backend
 * TUs, all compiled — the two that don't match the host compile to near-empty
 * objects, so le_midi_select_backend resolves at link time as in the shipped
 * library).
 *
 * Build & run: use the helper, which picks the right per-OS toolchain flags and
 * source/include paths and runs both native suites:
 *   bash src/test/run_native_tests.sh
 * It expects "ALL PASSED".
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "le_midi_backend.h"
#include "le_midi_clock.h" /* le_midi_clock_advance (C1, D15) */
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

/* ---- MIDI clock send (C1, D15) -------------------------------------------
 *
 * Pure logic tests for le_midi_clock_advance -- no engine, no OS MIDI, fully
 * deterministic (mirrors how tempo_grid.c's pure math is unit-tested in
 * test_engine_core.c). Engine-level wiring (the looper-mode gate, the
 * real count-in path, the published atomics) is covered separately in
 * test_engine_core.c.
 */

/* Counts bytes of `value` in out[0..n). */
static int count_byte(const uint8_t* out, int32_t n, uint8_t value) {
  int c = 0;
  for (int32_t i = 0; i < n; ++i) {
    if (out[i] == value) c++;
  }
  return c;
}

static void test_clock_silent_when_gate_closed(void) {
  printf("test_clock_silent_when_gate_closed\n");
  le_midi_clock_gen g;
  le_midi_clock_reset(&g);
  uint8_t out[32];
  /* Transport active but the gate is closed (clock_mode off, or Song/Free
   * mode) for many blocks in a row: nothing is ever emitted, not even a
   * Start for the already-active transport. */
  for (int i = 0; i < 200; ++i) {
    const int32_t n = le_midi_clock_advance(&g, 512, 120.0f, 4, 4, 48000,
                                            /*transport_active=*/1,
                                            /*gate_open=*/0, out, 32);
    CHECK(n == 0);
  }
}

static void test_clock_silent_when_transport_idle(void) {
  printf("test_clock_silent_when_transport_idle\n");
  le_midi_clock_gen g;
  le_midi_clock_reset(&g);
  uint8_t out[32];
  /* Gate open but the transport never becomes active (idle looper, or
   * mid count-in): nothing is emitted. The manual-verified correction (see
   * le_midi_clock.h) is exactly this -- no free-run while idle. */
  for (int i = 0; i < 200; ++i) {
    const int32_t n = le_midi_clock_advance(&g, 512, 120.0f, 4, 4, 48000,
                                            /*transport_active=*/0,
                                            /*gate_open=*/1, out, 32);
    CHECK(n == 0);
  }
}

static void test_clock_start_fires_once_on_activation(void) {
  printf("test_clock_start_fires_once_on_activation\n");
  le_midi_clock_gen g;
  le_midi_clock_reset(&g);
  uint8_t out[32];

  /* Idle for a few blocks: nothing (in particular, no premature Start --
   * this stands in for "Start never lands at count-in start", which the
   * engine level test proves with a real count-in; here transport_active=0
   * IS the count-in's transport state). */
  for (int i = 0; i < 5; ++i) {
    CHECK(le_midi_clock_advance(&g, 512, 120.0f, 4, 4, 48000, 0, 1, out, 32) ==
          0);
  }

  /* Downbeat: transport becomes active. Exactly one Start, as the first
   * byte. */
  int32_t n = le_midi_clock_advance(&g, 512, 120.0f, 4, 4, 48000, 1, 1, out,
                                    32);
  CHECK(n >= 1);
  CHECK(out[0] == LE_MIDI_CLOCK_START);
  CHECK(count_byte(out, n, LE_MIDI_CLOCK_START) == 1);

  /* Staying active never re-fires Start. */
  for (int i = 0; i < 50; ++i) {
    n = le_midi_clock_advance(&g, 512, 120.0f, 4, 4, 48000, 1, 1, out, 32);
    CHECK(count_byte(out, n, LE_MIDI_CLOCK_START) == 0);
  }
}

static void test_clock_stop_fires_once_on_deactivation(void) {
  printf("test_clock_stop_fires_once_on_deactivation\n");
  le_midi_clock_gen g;
  le_midi_clock_reset(&g);
  uint8_t out[32];

  le_midi_clock_advance(&g, 512, 120.0f, 4, 4, 48000, 1, 1, out, 32); /* Start */
  for (int i = 0; i < 10; ++i) {
    le_midi_clock_advance(&g, 512, 120.0f, 4, 4, 48000, 1, 1, out, 32);
  }

  int32_t n = le_midi_clock_advance(&g, 512, 120.0f, 4, 4, 48000, 0, 1, out,
                                    32);
  CHECK(n == 1);
  CHECK(out[0] == LE_MIDI_CLOCK_STOP);

  /* Staying idle never re-fires Stop, and emits no ticks. */
  for (int i = 0; i < 50; ++i) {
    n = le_midi_clock_advance(&g, 512, 120.0f, 4, 4, 48000, 0, 1, out, 32);
    CHECK(n == 0);
  }
}

static void test_clock_gate_close_mid_run_stops_then_reopen_is_fresh_start(
    void) {
  printf("test_clock_gate_close_mid_run_stops_then_reopen_is_fresh_start\n");
  le_midi_clock_gen g;
  le_midi_clock_reset(&g);
  uint8_t out[32];

  int32_t n =
      le_midi_clock_advance(&g, 100, 120.0f, 4, 4, 48000, 1, 1, out, 32);
  CHECK(n >= 1 && out[0] == LE_MIDI_CLOCK_START);

  /* The gate closes while the transport is still running (e.g. the user
   * flips clock_mode to off, or switches into Song/Free) -- a Stop fires
   * immediately, not deferred until the gate reopens. */
  n = le_midi_clock_advance(&g, 100, 120.0f, 4, 4, 48000, 1, 0, out, 32);
  CHECK(n == 1 && out[0] == LE_MIDI_CLOCK_STOP);

  /* Gated closed: silence regardless of the (still-active) transport. */
  for (int i = 0; i < 20; ++i) {
    CHECK(le_midi_clock_advance(&g, 100, 120.0f, 4, 4, 48000, 1, 0, out, 32) ==
          0);
  }

  /* Reopening against an already-running transport is a FRESH Start -- no
   * phantom Stop was left waiting, and the tick epoch restarts at 0 (proven
   * by the next tick landing a full interval later, not immediately). */
  n = le_midi_clock_advance(&g, 100, 120.0f, 4, 4, 48000, 1, 1, out, 32);
  CHECK(n == 1 && out[0] == LE_MIDI_CLOCK_START);
}

/* frames_per_tick at 120 BPM, 4/4, sr 48000: frames_per_beat = 24000,
 * frames_per_quarter == frames_per_beat (ts_den 4), /24 = 1000. Round numbers
 * make the exact-count assertions below unambiguous. */
#define TICK_BPM 120.0f
#define TICK_SR 48000
#define TICK_FRAMES_PER_TICK 1000

static void test_clock_ppqn_between_two_starts(void) {
  printf("test_clock_ppqn_between_two_starts\n");
  /* Exactly 24*beats ticks between a Start and the Stop/next-Start boundary:
   * run the transport active for precisely `beats` quarter notes' worth of
   * frames, then deactivate. */
  const int beats = 4;
  le_midi_clock_gen g;
  le_midi_clock_reset(&g);
  uint8_t out[8192];

  int32_t n = le_midi_clock_advance(&g, 1, TICK_BPM, 4, 4, TICK_SR, 1, 1, out,
                                    8192);
  CHECK(n == 1 && out[0] == LE_MIDI_CLOCK_START);
  int ticks = 0;

  /* Run comfortably past the 96th tick's boundary (beats*PPQN = 96 ticks,
   * at frame 96*1000 = 96000) but well short of the 97th (at 97000), so the
   * count is unambiguous regardless of exactly which block a boundary falls
   * in. `remaining` accounts for the 1 frame the Start call above already
   * consumed. */
  const int32_t target_active_frames =
      beats * TICK_FRAMES_PER_TICK * LE_MIDI_CLOCK_PPQN + 500;
  int32_t remaining = target_active_frames - 1;
  while (remaining > 0) {
    const int32_t chunk = remaining > 37 ? 37 : remaining; /* odd block size
                                                             * on purpose: see
                                                             * the no-double-
                                                             * count test
                                                             * below for why */
    n = le_midi_clock_advance(&g, chunk, TICK_BPM, 4, 4, TICK_SR, 1, 1, out,
                              8192);
    ticks += count_byte(out, n, LE_MIDI_CLOCK_TICK);
    CHECK(count_byte(out, n, LE_MIDI_CLOCK_START) == 0);
    CHECK(count_byte(out, n, LE_MIDI_CLOCK_STOP) == 0);
    remaining -= chunk;
  }

  /* Exactly 24*beats ticks fired in the active run, no more (the 97th
   * boundary was never reached) and no fewer. */
  CHECK(ticks == beats * LE_MIDI_CLOCK_PPQN);

  n = le_midi_clock_advance(&g, 100, TICK_BPM, 4, 4, TICK_SR, 0, 1, out, 8192);
  CHECK(n == 1 && out[0] == LE_MIDI_CLOCK_STOP);
}

static void test_clock_no_double_count_across_block_boundary(void) {
  printf("test_clock_no_double_count_across_block_boundary\n");
  /* Drives many blocks of a size that does NOT evenly divide
   * TICK_FRAMES_PER_TICK (37 has no common factor with 1000), so ticks land
   * mid-block as often as not -- the classic off-by-one/double-count
   * scenario. The final total must exactly match the ideal floor-division
   * count: any drift or double count would show up as a mismatch here. */
  le_midi_clock_gen g;
  le_midi_clock_reset(&g);
  uint8_t out[64];

  le_midi_clock_advance(&g, 1, TICK_BPM, 4, 4, TICK_SR, 1, 1, out, 64); /* Start */
  uint64_t total_frames = 1;
  int64_t ticks = 0;
  const int32_t block = 37;
  const int blocks = 5000; /* 185000 frames ~ 185 ticks */
  for (int i = 0; i < blocks; ++i) {
    const int32_t n =
        le_midi_clock_advance(&g, block, TICK_BPM, 4, 4, TICK_SR, 1, 1, out,
                              64);
    ticks += count_byte(out, n, LE_MIDI_CLOCK_TICK);
    total_frames += (uint64_t)block;
  }
  const int64_t expected = (int64_t)(total_frames / TICK_FRAMES_PER_TICK);
  CHECK(ticks == expected);
}

static void test_clock_tick_spacing_jitter_bound(void) {
  printf("test_clock_tick_spacing_jitter_bound\n");
  /* Reconstructs the frame position of every emitted tick (from the running
   * total of frames processed) and checks consecutive ticks never land more
   * than one block's worth of frames away from the ideal spacing -- the
   * jitter bound a block-granular (not per-sample) emitter can promise. */
  le_midi_clock_gen g;
  le_midi_clock_reset(&g);
  uint8_t out[64];
  const int32_t block = 23; /* another size that doesn't divide 1000 evenly */

  le_midi_clock_advance(&g, 1, TICK_BPM, 4, 4, TICK_SR, 1, 1, out, 64);
  uint64_t frame = 1;
  int64_t last_tick_frame = -1;
  int max_abs_jitter = 0;
  for (int i = 0; i < 3000; ++i) {
    const int32_t n =
        le_midi_clock_advance(&g, block, TICK_BPM, 4, 4, TICK_SR, 1, 1, out,
                              64);
    for (int32_t b = 0; b < n; ++b) {
      if (out[b] != LE_MIDI_CLOCK_TICK) continue;
      /* This tick was detected somewhere within [frame, frame+block) --
       * frame+block (the call's END position) is the tightest available
       * upper bound without per-sample instrumentation. */
      const int64_t detected_at = (int64_t)frame + block;
      if (last_tick_frame >= 0) {
        const int64_t spacing = detected_at - last_tick_frame;
        const int jitter = (int)(spacing - TICK_FRAMES_PER_TICK);
        const int abs_jitter = jitter < 0 ? -jitter : jitter;
        if (abs_jitter > max_abs_jitter) max_abs_jitter = abs_jitter;
      }
      last_tick_frame = detected_at;
    }
    frame += (uint64_t)block;
  }
  CHECK(last_tick_frame > 0); /* sanity: ticks actually fired */
  /* Detection latency is bounded by one block, so spacing between two
   * DETECTED ticks is within one block of the true interval either way. */
  CHECK(max_abs_jitter <= block);
}

static void test_clock_beat_unit_is_quarter_note_absolute(void) {
  printf("test_clock_beat_unit_is_quarter_note_absolute\n");
  /* D15/PPQN: ticks are 24-per-QUARTER-note regardless of the session's beat
   * unit (tempo_grid's BPM counts denominator-note beats). At the SAME BPM,
   * an 8-beat-unit signature's quarter note is twice as long as a
   * 4-beat-unit signature's -- so it takes half as many ticks to cover the
   * same wall-clock span. */
  le_midi_clock_gen g4, g8;
  le_midi_clock_reset(&g4);
  le_midi_clock_reset(&g8);
  uint8_t out[64];

  le_midi_clock_advance(&g4, 1, 120.0f, 4, 4, 48000, 1, 1, out, 64);
  le_midi_clock_advance(&g8, 1, 120.0f, 4, 8, 48000, 1, 1, out, 64);

  const int32_t span = 48000; /* 1 second */
  int ticks4 = 0, ticks8 = 0;
  int32_t n = le_midi_clock_advance(&g4, span - 1, 120.0f, 4, 4, 48000, 1, 1,
                                    out, 64);
  ticks4 = count_byte(out, n, LE_MIDI_CLOCK_TICK);
  n = le_midi_clock_advance(&g8, span - 1, 120.0f, 4, 8, 48000, 1, 1, out, 64);
  ticks8 = count_byte(out, n, LE_MIDI_CLOCK_TICK);

  CHECK(ticks4 == 2 * ticks8);
}

static void test_clock_null_and_degenerate_args_are_safe(void) {
  printf("test_clock_null_and_degenerate_args_are_safe\n");
  uint8_t out[8];
  le_midi_clock_gen g;
  le_midi_clock_reset(&g);
  le_midi_clock_reset(NULL); /* safe */
  CHECK(le_midi_clock_advance(NULL, 64, 120.0f, 4, 4, 48000, 1, 1, out, 8) ==
        0);
  CHECK(le_midi_clock_advance(&g, 64, 120.0f, 4, 4, 48000, 1, 1, NULL, 8) ==
        0);
  CHECK(le_midi_clock_advance(&g, 64, 120.0f, 4, 4, 48000, 1, 1, out, 0) == 0);
  CHECK(le_midi_clock_advance(&g, -1, 120.0f, 4, 4, 48000, 1, 1, out, 8) == 0);
  /* No tempo set (bpm 0, the grid-off default): Start/Stop still fire on
   * transport edges, but no ticks (a degenerate grid yields 0 frames-per-
   * quarter, per tempo_grid.c). */
  le_midi_clock_reset(&g);
  int32_t n = le_midi_clock_advance(&g, 64, 0.0f, 4, 4, 48000, 1, 1, out, 8);
  CHECK(n == 1 && out[0] == LE_MIDI_CLOCK_START);
  n = le_midi_clock_advance(&g, 64, 0.0f, 4, 4, 48000, 1, 1, out, 8);
  CHECK(n == 0);
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

  test_clock_silent_when_gate_closed();
  test_clock_silent_when_transport_idle();
  test_clock_start_fires_once_on_activation();
  test_clock_stop_fires_once_on_deactivation();
  test_clock_gate_close_mid_run_stops_then_reopen_is_fresh_start();
  test_clock_ppqn_between_two_starts();
  test_clock_no_double_count_across_block_boundary();
  test_clock_tick_spacing_jitter_bound();
  test_clock_beat_unit_is_quarter_note_absolute();
  test_clock_null_and_degenerate_args_are_safe();

  if (g_failures == 0) {
    printf("ALL PASSED\n");
    return 0;
  }
  printf("%d CHECK(S) FAILED\n", g_failures);
  return 1;
}
