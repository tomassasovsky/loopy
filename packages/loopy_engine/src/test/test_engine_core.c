/*
 * test_engine_core.c — native unit tests for the real-time-critical core.
 *
 * Covers the lock-free SPSC command ring (wrap-around, full/empty, FIFO order)
 * and the engine lifecycle paths that do not require an audio device. These are
 * the pieces with the strictest correctness/real-time requirements.
 *
 * Build & run (macOS):
 *   clang -std=c11 -I src -I src/miniaudio \
 *     src/test/test_engine_core.c src/engine.c src/lockfree_ring.c \
 *     src/loop_clock.c src/miniaudio_impl.c \
 *     -framework CoreAudio -framework AudioToolbox -framework AudioUnit \
 *     -framework CoreFoundation -lpthread -lm -o /tmp/loopy_core_tests
 *   /tmp/loopy_core_tests
 */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "engine_internal.h"
#include "lockfree_ring.h"
#include "loop_clock.h"
#include "loopy_engine_api.h"

static int g_failures = 0;

#define CHECK(cond)                                                       \
  do {                                                                    \
    if (!(cond)) {                                                        \
      printf("  FAIL: %s (line %d)\n", #cond, __LINE__);                  \
      g_failures++;                                                       \
    }                                                                     \
  } while (0)

static void test_ring_init_rejects_bad_capacity(void) {
  printf("test_ring_init_rejects_bad_capacity\n");
  le_command storage[8];
  le_ring ring;
  CHECK(le_ring_init(&ring, storage, 8) == 1);   /* power of two */
  CHECK(le_ring_init(&ring, storage, 6) == 0);   /* not power of two */
  CHECK(le_ring_init(&ring, storage, 1) == 0);   /* too small */
  CHECK(le_ring_init(&ring, storage, 0) == 0);   /* zero */
  CHECK(le_ring_init(NULL, storage, 8) == 0);    /* null ring */
  CHECK(le_ring_init(&ring, NULL, 8) == 0);      /* null buffer */
}

static void test_ring_push_pop_fifo(void) {
  printf("test_ring_push_pop_fifo\n");
  le_command storage[8];
  le_ring ring;
  le_ring_init(&ring, storage, 8);

  le_command out;
  CHECK(le_ring_pop(&ring, &out) == 0); /* empty */

  for (int i = 0; i < 5; ++i) {
    le_command cmd = {i, i * 10, (float)i};
    CHECK(le_ring_push(&ring, cmd) == 1);
  }
  for (int i = 0; i < 5; ++i) {
    CHECK(le_ring_pop(&ring, &out) == 1);
    CHECK(out.code == i);
    CHECK(out.arg_i == i * 10);
  }
  CHECK(le_ring_pop(&ring, &out) == 0); /* drained */
}

static void test_ring_reports_full(void) {
  printf("test_ring_reports_full\n");
  le_command storage[4]; /* usable slots == capacity - 1 == 3 */
  le_ring ring;
  le_ring_init(&ring, storage, 4);

  le_command cmd = {1, 0, 0.0f};
  CHECK(le_ring_push(&ring, cmd) == 1);
  CHECK(le_ring_push(&ring, cmd) == 1);
  CHECK(le_ring_push(&ring, cmd) == 1);
  CHECK(le_ring_push(&ring, cmd) == 0); /* full at capacity-1 */

  le_command out;
  CHECK(le_ring_pop(&ring, &out) == 1);
  CHECK(le_ring_push(&ring, cmd) == 1); /* room again after a pop */
}

static void test_ring_wraps_around(void) {
  printf("test_ring_wraps_around\n");
  le_command storage[4];
  le_ring ring;
  le_ring_init(&ring, storage, 4);

  /* Many push/pop cycles force head/tail to wrap past the buffer length. */
  le_command out;
  for (int i = 0; i < 100; ++i) {
    le_command cmd = {i, 0, 0.0f};
    CHECK(le_ring_push(&ring, cmd) == 1);
    CHECK(le_ring_pop(&ring, &out) == 1);
    CHECK(out.code == i);
  }
}

static void test_engine_lifecycle_without_device(void) {
  printf("test_engine_lifecycle_without_device\n");
  le_engine* engine = le_engine_create();
  CHECK(engine != NULL);

  /* Stopping or commanding before start must not touch a device. */
  CHECK(le_engine_stop(engine) == LE_ERR_NOT_RUNNING);
  CHECK(le_engine_measure_latency(engine) == LE_ERR_NOT_RUNNING);
  CHECK(le_engine_post_command(engine, LE_CMD_MEASURE_LATENCY, 0, 0.0f) ==
        LE_ERR_NOT_RUNNING);
  CHECK(strcmp(le_engine_device_name(engine), "") == 0);

  le_snapshot snap;
  le_engine_get_snapshot(engine, &snap);
  CHECK(snap.running == 0);
  CHECK(snap.device_present == 0); /* no device opened yet */
  CHECK(snap.frames_processed == 0);
  CHECK(snap.latency_state == LE_LATENCY_IDLE);

  le_engine_destroy(engine);
}

static void test_null_safety(void) {
  printf("test_null_safety\n");
  CHECK(le_engine_stop(NULL) == LE_ERR_INVALID);
  CHECK(le_engine_measure_latency(NULL) == LE_ERR_INVALID);
  le_engine_destroy(NULL);             /* must not crash */
  le_engine_get_snapshot(NULL, NULL);  /* must not crash */
  CHECK(le_version() != NULL);
}

/* ---- loop_clock ---- */

static void test_loop_clock(void) {
  printf("test_loop_clock\n");
  le_loop_clock clock;
  le_loop_clock_reset(&clock);
  CHECK(clock.length == 0);
  CHECK(le_loop_clock_tick(&clock) == 0); /* unset never ticks */

  le_loop_clock_set_length(&clock, 3);
  CHECK(clock.position == 0);
  CHECK(le_loop_clock_tick(&clock) == 0); /* -> 1 */
  CHECK(clock.position == 1);
  CHECK(le_loop_clock_tick(&clock) == 0); /* -> 2 */
  CHECK(le_loop_clock_tick(&clock) == 1); /* wrap -> 0 */
  CHECK(clock.position == 0);

  le_loop_clock_set_length(&clock, -5); /* invalid resets */
  CHECK(clock.length == 0);
}

/* ---- looper DSP (mono, device-free via le_engine_configure/process) ---- */

#define LOOP_N 4

/* Processes `frames` mono frames of constant `value`, capturing output. */
static void process_const(le_engine* e, float value, int frames, float* out) {
  float in[64];
  for (int i = 0; i < frames; ++i) in[i] = value;
  le_engine_process(e, out, in, (uint32_t)frames);
}

static le_engine* make_configured_engine(void) {
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 1000); /* mono in, mono out */
  return e;
}

static void drain(le_engine* e) {
  float out[8];
  process_const(e, 0.0f, 0, out); /* frames=0 just drains the ring */
}

static void test_looper_record_then_play(void) {
  printf("test_looper_record_then_play\n");
  le_engine* e = make_configured_engine();
  float out[64];

  CHECK(le_engine_record(e, 0) == LE_OK); /* EMPTY -> RECORDING */
  process_const(e, 1.0f, LOOP_N, out); /* capture 1.0 x N */

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING);
  CHECK(s.tracks[0].length_frames == LOOP_N);

  CHECK(le_engine_record(e, 0) == LE_OK); /* finalize -> PLAYING */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.master_length_frames == LOOP_N);

  /* Playback reproduces the recorded loop (no input monitoring configured). */
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.0f) < 1e-6f);

  le_engine_destroy(e);
}

static void test_looper_overdub_and_undo(void) {
  printf("test_looper_overdub_and_undo\n");
  le_engine* e = make_configured_engine();
  float out[64];

  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0); /* finalize -> PLAYING, loop == 1.0 */
  drain(e);

  /* Overdub one loop of +0.5. The live input is not folded into the monitored
   * output (latency-compensated model), so during the pass the existing loop
   * (1.0) is heard while the +0.5 lands in the buffer for the next pass. */
  CHECK(le_engine_record(e, 0) == LE_OK); /* snapshot taken, -> OVERDUBBING */
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 1);
  process_const(e, 0.5f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.0f) < 1e-6f);

  le_engine_record(e, 0); /* OVERDUBBING -> PLAYING */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);

  /* The recorded layer now plays back: 1.0 + 0.5 == 1.5. */
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.5f) < 1e-6f);

  /* Undo immediately swaps back to the pre-overdub content (1.0). */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.0f) < 1e-6f);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 0);
  CHECK(s.tracks[0].redo_depth == 1);

  /* Redo brings the overdub back (1.5). */
  CHECK(le_engine_redo(e, 0) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.5f) < 1e-6f);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 1);
  CHECK(s.tracks[0].redo_depth == 0);

  le_engine_destroy(e);
}

static void test_looper_multilevel_undo(void) {
  printf("test_looper_multilevel_undo\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  /* Base loop of 1.0. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);

  /* Two overdubs of +0.5 -> 1.5 then 2.0. */
  for (int layer = 0; layer < 2; ++layer) {
    le_engine_record(e, 0); /* start overdub */
    process_const(e, 0.5f, LOOP_N, out);
    le_engine_record(e, 0); /* stop overdub */
    drain(e);
  }
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 2);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 2.0f) < 1e-6f);

  /* Undo twice: 2.0 -> 1.5 -> 1.0. */
  le_engine_undo(e, 0);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.5f) < 1e-6f);
  le_engine_undo(e, 0);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.0f) < 1e-6f);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 0);
  CHECK(s.tracks[0].redo_depth == 2);

  /* A fresh overdub from here invalidates redo. */
  le_engine_record(e, 0);
  process_const(e, 0.25f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].redo_depth == 0);
  CHECK(s.tracks[0].undo_depth == 1);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.25f) < 1e-6f);

  le_engine_destroy(e);
}

static void test_looper_volume_and_mute(void) {
  printf("test_looper_volume_and_mute\n");
  le_engine* e = make_configured_engine();
  float out[64];

  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0); /* PLAYING, loop == 1.0 */
  drain(e);

  CHECK(le_engine_set_track_volume(e, 0, 0.5f) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 0.5f) < 1e-6f);

  CHECK(le_engine_set_track_mute(e, 0, 1) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i]) < 1e-6f);

  le_engine_destroy(e);
}

static void test_looper_clear(void) {
  printf("test_looper_clear\n");
  le_engine* e = make_configured_engine();
  float out[64];

  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);

  CHECK(le_engine_clear(e, 0) == LE_OK);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.master_length_frames == 0);

  /* Cleared track is silent. */
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i]) < 1e-6f);

  le_engine_destroy(e);
}

static void test_looper_requires_configure(void) {
  printf("test_looper_requires_configure\n");
  le_engine* e = le_engine_create();
  CHECK(le_engine_record(e, 0) == LE_ERR_NOT_RUNNING); /* not configured yet */
  le_engine_configure(e, 48000, 1, 1, 100);
  CHECK(le_engine_record(e, 0) == LE_OK);
  le_engine_destroy(e);
}

static void test_looper_multitrack(void) {
  printf("test_looper_multitrack\n");
  le_engine* e = make_configured_engine();
  float out[64];

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.track_count == LE_MAX_TRACKS);

  /* Track 0 defines the master loop at 1.0. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);

  /* Track 1 records a fresh layer at 0.5. It begins at the loop top and records
   * freely; during its recording pass only track 0 is audible (1.0). A second
   * record press finalizes it, rounding up to one whole base loop. */
  CHECK(le_engine_record(e, 1) == LE_OK);
  process_const(e, 0.5f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.0f) < 1e-6f);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);

  CHECK(le_engine_record(e, 1) == LE_OK); /* finalize -> PLAYING */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].length_frames == LOOP_N);
  CHECK(s.tracks[1].multiple == 1);

  /* Now both tracks mix: 1.0 + 0.5 == 1.5. */
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.5f) < 1e-6f);

  /* Muting track 0 leaves only track 1 (0.5). */
  le_engine_set_track_mute(e, 0, 1);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 0.5f) < 1e-6f);

  /* Clearing both tracks resets the master. */
  le_engine_set_track_mute(e, 0, 0);
  le_engine_clear(e, 0);
  le_engine_clear(e, 1);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 0);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY);

  le_engine_destroy(e);
}

/* A restored/explicit record offset is published as a completed measurement so
 * the UI shows the loaded latency rather than "not measured". */
static void test_set_record_offset_publishes_latency(void) {
  printf("test_set_record_offset_publishes_latency\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 1000);
  le_snapshot s;

  le_engine_get_snapshot(e, &s);
  CHECK(s.latency_state == LE_LATENCY_IDLE); /* nothing set yet */

  CHECK(le_engine_set_record_offset(e, 480) == LE_OK); /* 480 frames @ 48k */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.record_offset_frames == 480);
  CHECK(s.latency_state == LE_LATENCY_DONE);
  CHECK(fabs(s.measured_latency_ms - 10.0) < 1e-6); /* 480/48000 s == 10 ms */

  le_engine_destroy(e);
}

static void test_latency_compensation(void) {
  printf("test_latency_compensation\n");
  le_engine* e = make_configured_engine();
  float out[16];

  /* Record a 10-frame silent base loop. */
  le_engine_record(e, 0);
  process_const(e, 0.0f, 10, out);
  le_engine_record(e, 0); /* finalize: master == 10, silent */
  drain(e);

  /* Compensate by 3 frames, then overdub a single impulse at loop position 0.
   * It must land at position (0 - 3) wrapped == 7. */
  CHECK(le_engine_set_record_offset(e, 3) == LE_OK);
  le_engine_record(e, 0); /* -> OVERDUBBING (drained with the offset) */
  process_const(e, 1.0f, 1, out); /* impulse at pos 0 -> writes buf[7] */
  process_const(e, 0.0f, 9, out); /* finish the loop with silence */
  le_engine_record(e, 0);         /* stop overdub -> PLAYING */
  drain(e);

  float loop[16] = {0};
  process_const(e, 0.0f, 10, loop);
  for (int i = 0; i < 10; ++i) {
    CHECK(fabsf(loop[i] - (i == 7 ? 1.0f : 0.0f)) < 1e-6f);
  }

  le_engine_destroy(e);
}

static void test_record_is_exclusive(void) {
  printf("test_record_is_exclusive\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  /* Start recording track 0 (defining); do not stop it. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING);
  CHECK(s.master_length_frames == 0); /* not finalized yet */

  /* Pressing record on track 1 finalizes track 0 (defines the master) and
   * starts track 1 — only one track captures at a time. */
  le_engine_record(e, 1);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == LOOP_N);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);

  le_engine_destroy(e);
}

/* ---- loop multiples (#4) ---- */

static void test_loop_multiple_records_two_loops(void) {
  printf("test_loop_multiple_records_two_loops\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  /* Track 0 defines the base loop (1.0) over LOOP_N frames. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0); /* finalize */
  drain(e);

  /* Track 1 records a 2-base-loop pattern (2.0 then 3.0). It begins at the loop
   * top and records freely; a second press finalizes it, rounding to k = 2. */
  le_engine_record(e, 1);
  process_const(e, 2.0f, LOOP_N, out); /* first base loop */
  process_const(e, 3.0f, LOOP_N, out); /* second base loop */
  le_engine_record(e, 1);              /* finalize -> PLAYING */
  drain(e);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].multiple == 2);
  CHECK(s.tracks[1].length_frames == 2 * LOOP_N);

  /* The 2-loop track alternates its segments under the 1.0 base: 1+2 then 1+3,
   * repeating (the iteration count is even here, so segment 0 plays first). */
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 3.0f) < 1e-6f);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 4.0f) < 1e-6f);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 3.0f) < 1e-6f);

  le_engine_destroy(e);
}

static void test_loop_multiple_rounds_up_partial(void) {
  printf("test_loop_multiple_rounds_up_partial\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  /* Base loop (1.0), then mute it so track 1 can be observed alone. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);
  le_engine_set_track_mute(e, 0, 1);

  /* Track 1 records 1.5 base loops of 2.0; the length rounds UP to 2 loops. */
  le_engine_record(e, 1);
  process_const(e, 2.0f, LOOP_N, out);     /* full first loop */
  process_const(e, 2.0f, LOOP_N / 2, out); /* half of the second loop */
  le_engine_record(e, 1);                  /* finalize -> PLAYING */
  drain(e);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].multiple == 2);
  CHECK(s.tracks[1].length_frames == 2 * LOOP_N);

  /* Align to the loop top (also drains the mute), then read the two segments:
   * segment 0 is the full 2.0 loop; segment 1 is the recorded half followed by
   * the rounded-up silent tail (zeroed on the control thread at record start). */
  process_const(e, 0.0f, LOOP_N / 2, out); /* pos 2..3 -> wrap to the top */
  process_const(e, 0.0f, LOOP_N, out);     /* segment 0: all 2.0 */
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 2.0f) < 1e-6f);
  process_const(e, 0.0f, LOOP_N, out);     /* segment 1: 2.0, 2.0, 0, 0 */
  for (int i = 0; i < LOOP_N; ++i) {
    const float want = i < LOOP_N / 2 ? 2.0f : 0.0f;
    CHECK(fabsf(out[i] - want) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* A new track recorded while the master loop is mid-cycle must begin capturing
 * immediately (no arming, no waiting for the loop top). The capture is
 * phase-locked: audio lands at the master phase where it was played, and the
 * slice before the press stays silent. */
static void test_new_track_records_mid_loop(void) {
  printf("test_new_track_records_mid_loop\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  /* Base loop (1.0) of LOOP_N, then mute it so track 1 is observed alone. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0); /* finalize */
  drain(e);
  le_engine_set_track_mute(e, 0, 1);

  /* Advance the master one frame past the loop top (pos 0 -> 1). */
  process_const(e, 0.0f, 1, out);

  /* Press record on track 1 mid-loop. It must already be RECORDING (not armed)
   * and capture immediately from pos 1 for the rest of this loop. */
  le_engine_record(e, 1);
  process_const(e, 2.0f, LOOP_N - 1, out); /* pos 1,2,3 -> wraps to the top */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);

  le_engine_record(e, 1); /* finalize -> PLAYING */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].multiple == 1);
  CHECK(s.tracks[1].length_frames == LOOP_N);

  /* One full loop from the top: silence at pos 0 (the pre-press slice), the
   * recorded 2.0 at pos 1..3. */
  process_const(e, 0.0f, LOOP_N, out);
  CHECK(fabsf(out[0] - 0.0f) < 1e-6f);
  for (int i = 1; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 2.0f) < 1e-6f);

  le_engine_destroy(e);
}

/* The transport must not free-run in silence: once every track is stopped the
 * master position holds at the top, and the next play starts from there. */
static void test_transport_resets_when_all_stopped(void) {
  printf("test_transport_resets_when_all_stopped\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  /* Record a LOOP_N master loop, then let it play. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);

  /* While playing, the master position advances. */
  process_const(e, 0.0f, 2, out);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == 2);

  /* Stop the only track: the transport holds at the top instead of looping. */
  le_engine_stop_track(e, 0);
  drain(e);
  process_const(e, 0.0f, 3, out); /* would reach 5 if it kept free-running */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(s.master_position_frames == 0);

  /* Playing again resumes from the beginning. */
  le_engine_play(e, 0);
  drain(e);
  process_const(e, 0.0f, 1, out);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.master_position_frames == 1);

  le_engine_destroy(e);
}

/* The transport keeps running while any track plays, and only resets to the top
 * once the last one stops. */
static void test_transport_runs_until_last_track_stops(void) {
  printf("test_transport_runs_until_last_track_stops\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  /* Track 0 defines the master loop and plays. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);

  /* Track 1 records one base loop and plays. */
  le_engine_record(e, 1);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 1);
  drain(e);

  /* Both playing: the transport advances. */
  process_const(e, 0.0f, 2, out);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == 2);

  /* Stop track 0 — track 1 still plays, so the transport keeps advancing. */
  le_engine_stop_track(e, 0);
  drain(e);
  process_const(e, 0.0f, 1, out);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.master_position_frames == 3);

  /* Stop track 1 — now everything is stopped, so the transport resets. */
  le_engine_stop_track(e, 1);
  drain(e);
  process_const(e, 0.0f, 2, out);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == 0);

  le_engine_destroy(e);
}

/* ---- per-track I/O routing ---- */

/* A track records from its selected hardware input channel (not channel 0), and
 * the negotiated I/O channel counts + routing are reflected in the snapshot. */
static void test_routing_input_mask(void) {
  printf("test_routing_input_mask\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000); /* 2-in, 2-out */
  float out[64];
  le_snapshot s;

  /* Route track 0 to record from input channel 1 only, then capture a loop
   * where channel 0 carries a decoy (9.0) and channel 1 the signal (2.0). */
  CHECK(le_engine_set_input_mask(e, 0, 0x2) == LE_OK); /* bit 1 */
  le_engine_record(e, 0);
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 9.0f; /* decoy on channel 0 */
    in[i * 2 + 1] = 2.0f; /* signal on channel 1 */
  }
  le_engine_process(e, out, in, LOOP_N);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);

  le_engine_get_snapshot(e, &s);
  CHECK(s.input_channels == 2);
  CHECK(s.output_channels == 2);
  CHECK(s.tracks[0].input_mask == 0x2u);
  CHECK(s.tracks[0].output_mask == 0x3u); /* default stereo pair */

  /* Playback over silent input: the loop replays channel 1's 2.0, routed to the
   * default output pair (channels 0 and 1) — not channel 0's decoy. */
  float zin[2 * LOOP_N] = {0};
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 2.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 2.0f) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* Selecting multiple inputs records their average into the mono track buffer. */
static void test_routing_input_mask_averages(void) {
  printf("test_routing_input_mask_averages\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000); /* 2-in, 2-out */
  float out[64];
  le_snapshot s;

  CHECK(le_engine_set_input_mask(e, 0, 0x3) == LE_OK); /* inputs 0 and 1 */
  le_engine_record(e, 0);
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 2.0f;
    in[i * 2 + 1] = 4.0f;
  }
  le_engine_process(e, out, in, LOOP_N);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].input_mask == 0x3u);

  /* The mono buffer holds the average (2.0 + 4.0) / 2 == 3.0, on outputs 0+1. */
  float zin[2 * LOOP_N] = {0};
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 3.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 3.0f) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* An output mask routes a track's mono loop to exactly the selected output
 * channels and leaves the others silent. */
static void test_routing_output_mask(void) {
  printf("test_routing_output_mask\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000); /* 2-in, 2-out */
  float out[64];

  /* Record a 1.0 loop from the default input channel 0. */
  le_engine_record(e, 0);
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 1.0f;
    in[i * 2 + 1] = 0.0f;
  }
  le_engine_process(e, out, in, LOOP_N);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);

  float zin[2 * LOOP_N] = {0};

  /* Route to output channel 1 only: channel 0 must be silent. */
  CHECK(le_engine_set_output_mask(e, 0, 0x2) == LE_OK);
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0]) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 1.0f) < 1e-6f);
  }

  /* Route to output channel 0 only: channel 1 must now be silent. */
  CHECK(le_engine_set_output_mask(e, 0, 0x1) == LE_OK);
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1]) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* Default routing on a mono-in / stereo-out device sends the recorded input to
 * both output channels (preserving today's stereo behaviour). */
static void test_routing_default_stereo(void) {
  printf("test_routing_default_stereo\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 2, 1000); /* mono in, stereo out */
  float out[64];

  le_engine_record(e, 0);
  float in[LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) in[i] = 1.0f;
  le_engine_process(e, out, in, LOOP_N);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);

  float zin[LOOP_N] = {0};
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 1.0f) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* Input-mask bits beyond the available input channels are dropped. */
static void test_routing_input_mask_clamped(void) {
  printf("test_routing_input_mask_clamped\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000); /* 2-in */
  le_snapshot s;

  CHECK(le_engine_set_input_mask(e, 0, 0xF) == LE_OK); /* request 4 inputs */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].input_mask == 0x3u); /* only inputs 0 and 1 exist */

  le_engine_destroy(e);
}

/* Output-mask bits beyond the available output channels are dropped. */
static void test_routing_output_mask_clamped(void) {
  printf("test_routing_output_mask_clamped\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000); /* 2-out */
  le_snapshot s;

  CHECK(le_engine_set_output_mask(e, 0, 0xF) == LE_OK); /* request 4 channels */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].output_mask == 0x3u); /* only outputs 0 and 1 exist */

  le_engine_destroy(e);
}

/* ---- loop visualization tap ---- */

static float max_of(const float* a, int n) {
  float m = 0.0f;
  for (int i = 0; i < n; ++i) {
    if (a[i] > m) m = a[i];
  }
  return m;
}

static void test_visualization_tap(void) {
  printf("test_visualization_tap\n");
  le_engine* e = make_configured_engine(); /* sr 48000, max 1000 frames */
  float out[64];
  float viz[LE_VIZ_POINTS];

  /* Silent before any loop. */
  CHECK(le_engine_read_visual(e, viz, LE_VIZ_POINTS) == LE_VIZ_POINTS);
  CHECK(max_of(viz, LE_VIZ_POINTS) < 1e-6f);

  /* Record a ~640-frame 1.0 loop (longer than the bucket count), then play it
   * for more than one full loop so every bucket is published. */
  le_engine_record(e, 0);
  for (int i = 0; i < 10; ++i) process_const(e, 1.0f, 64, out);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);
  for (int i = 0; i < 12; ++i) process_const(e, 0.0f, 64, out); /* 768 frames */

  /* The loop waveform captured the ~1.0 output across the loop. */
  le_engine_read_visual(e, viz, LE_VIZ_POINTS);
  CHECK(max_of(viz, LE_VIZ_POINTS) > 0.9f);

  /* Per-track waveform also captured (track 0 is the only contributor). */
  float tviz[LE_VIZ_POINTS];
  CHECK(le_engine_read_track_visual(e, 0, tviz, LE_VIZ_POINTS) == LE_VIZ_POINTS);
  CHECK(max_of(tviz, LE_VIZ_POINTS) > 0.9f);

  /* Clearing the loop resets the waveform to silence. */
  le_engine_clear(e, 0);
  drain(e);
  le_engine_read_visual(e, viz, LE_VIZ_POINTS);
  CHECK(max_of(viz, LE_VIZ_POINTS) < 1e-6f);

  /* Bad arguments are safe. */
  CHECK(le_engine_read_visual(e, viz, 0) == 0);
  CHECK(le_engine_read_visual(NULL, viz, LE_VIZ_POINTS) == 0);
  CHECK(le_engine_read_track_visual(e, 99, tviz, LE_VIZ_POINTS) == 0);

  le_engine_destroy(e);
}

static void test_classify_capture_device(void) {
  printf("test_classify_capture_device\n");
  /* PulseAudio monitor sources. */
  CHECK(le_classify_capture_device("Monitor of Built-in Audio") ==
        LE_LOOPBACK_MONITOR);
  CHECK(le_classify_capture_device("monitor of scarlett") ==
        LE_LOOPBACK_MONITOR);
  /* Virtual drivers (case-insensitive substring). */
  CHECK(le_classify_capture_device("BlackHole 2ch") == LE_LOOPBACK_VIRTUAL);
  CHECK(le_classify_capture_device("CABLE Output (VB-Audio)") ==
        LE_LOOPBACK_VIRTUAL);
  CHECK(le_classify_capture_device("VoiceMeeter Output") ==
        LE_LOOPBACK_VIRTUAL);
  CHECK(le_classify_capture_device("Loopback Audio") == LE_LOOPBACK_VIRTUAL);
  /* Ordinary inputs are not loopbacks. */
  CHECK(le_classify_capture_device("Scarlett 2i2 USB") == LE_LOOPBACK_NONE);
  CHECK(le_classify_capture_device("Built-in Microphone") == LE_LOOPBACK_NONE);
  CHECK(le_classify_capture_device(NULL) == LE_LOOPBACK_NONE);
  CHECK(le_classify_capture_device("") == LE_LOOPBACK_NONE);
}

static void test_detect_loopback_runs(void) {
  printf("test_detect_loopback_runs\n");
  /* Enumeration result is environment-dependent; assert it runs safely and
   * fills a consistent struct rather than asserting a specific device. */
  le_loopback_info info;
  CHECK(le_detect_loopback(&info) == LE_OK);
  CHECK(info.available == 0 || info.available == 1);
  if (!info.available) CHECK(info.kind == LE_LOOPBACK_NONE);
  CHECK(le_detect_loopback(NULL) == LE_ERR_INVALID);
}

/* Enumeration is environment-dependent (a headless box may report zero devices),
 * so assert it runs safely and fills a consistent, NUL-terminated struct rather
 * than asserting any specific device. This is the device-free smoke test for the
 * id/name plumbing; pinning a resolved id into a live device is covered by the
 * manual unplug acceptance test (it requires an open device). */
static void test_enumerate_devices_runs(void) {
  printf("test_enumerate_devices_runs\n");
  enum { MAXD = 32 };
  le_device_info devices[MAXD];
  int32_t count = -1;

  CHECK(le_enumerate_playback_devices(devices, MAXD, &count) == LE_OK);
  CHECK(count >= 0 && count <= MAXD);
  for (int32_t i = 0; i < count; ++i) {
    CHECK(strlen(devices[i].id) < sizeof(devices[i].id));     /* NUL-terminated */
    CHECK(strlen(devices[i].name) < sizeof(devices[i].name)); /* NUL-terminated */
    CHECK(devices[i].is_default == 0 || devices[i].is_default == 1);
  }

  count = -1;
  CHECK(le_enumerate_capture_devices(devices, MAXD, &count) == LE_OK);
  CHECK(count >= 0 && count <= MAXD);

  /* Bad arguments are rejected without touching the output. */
  CHECK(le_enumerate_playback_devices(NULL, MAXD, &count) == LE_ERR_INVALID);
  CHECK(le_enumerate_playback_devices(devices, MAXD, NULL) == LE_ERR_INVALID);
  CHECK(le_enumerate_playback_devices(devices, 0, &count) == LE_ERR_INVALID);
  CHECK(le_enumerate_capture_devices(NULL, MAXD, &count) == LE_ERR_INVALID);
}

/* ---- loopback channel exclusion (PR B) ---- */

static void test_label_is_loopback(void) {
  printf("test_label_is_loopback\n");
  CHECK(le_label_is_loopback("Loopback 1") == 1);
  CHECK(le_label_is_loopback("loopback") == 1);
  CHECK(le_label_is_loopback("My LOOPBACK channel") == 1);
  CHECK(le_label_is_loopback("Analog Loopback 2") == 1);
  /* Focusrite Scarlett labels its loopback inputs "Loop 1" / "Loop 2". */
  CHECK(le_label_is_loopback("Loop 1") == 1);
  CHECK(le_label_is_loopback("Loop 2") == 1);
  CHECK(le_label_is_loopback("loop") == 1);
  CHECK(le_label_is_loopback("Input 1") == 0);
  CHECK(le_label_is_loopback("Input 4") == 0);
  CHECK(le_label_is_loopback("Microphone") == 0);
  CHECK(le_label_is_loopback("") == 0);
  CHECK(le_label_is_loopback(NULL) == 0);
}

/* An excluded channel is stripped from a track's input mask by SET_INPUT_MASK,
 * and is dropped from the capture average even if a mask still selects it. */
static void test_loopback_exclusion(void) {
  printf("test_loopback_exclusion\n");
  float out[64];
  le_snapshot s;

  /* (a) SET_INPUT_MASK strips excluded bits. */
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000);    /* 2-in, 2-out */
  le_engine_set_excluded_input_mask_for_test(e, 0x1u); /* exclude channel 0 */
  CHECK(le_engine_set_input_mask(e, 0, 0x3) == LE_OK); /* request both inputs */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.excluded_input_mask == 0x1u);
  CHECK(s.tracks[0].input_mask == 0x2u); /* channel 0 stripped, only ch1 left */

  /* The recorded loop carries channel 1 (2.0), never the excluded channel 0
   * decoy (9.0). */
  le_engine_record(e, 0);
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 9.0f; /* excluded channel 0 */
    in[i * 2 + 1] = 2.0f; /* channel 1 */
  }
  le_engine_process(e, out, in, LOOP_N);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);
  float zin[2 * LOOP_N] = {0};
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 2.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 2.0f) < 1e-6f);
  }
  le_engine_destroy(e);

  /* (b) Average-drop: a track whose mask still includes the excluded channel
   * (the default mask 0x1 == channel 0) records silence from it. */
  le_engine* e2 = le_engine_create();
  le_engine_configure(e2, 48000, 2, 2, 1000); /* default track mask 0x1 */
  le_engine_set_excluded_input_mask_for_test(e2, 0x1u);
  le_engine_record(e2, 0);
  float in2[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in2[i * 2 + 0] = 5.0f; /* excluded channel 0 only */
    in2[i * 2 + 1] = 0.0f;
  }
  le_engine_process(e2, out, in2, LOOP_N);

  /* (c) Metering: a signal present only on the excluded channel must not show
   * up in the input level (it carries our own output, not a real input). The
   * snapshot reflects the block just processed (ch0 == 5.0, excluded). */
  le_engine_get_snapshot(e2, &s);
  CHECK(s.input_peak < 1e-6f);
  CHECK(s.input_rms < 1e-6f);

  le_engine_record(e2, 0); /* finalize */
  drain(e2);
  le_engine_process(e2, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0]) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1]) < 1e-6f);
  }
  le_engine_destroy(e2);
}

/* The round-trip latency harness times the pulse returning on the loopback
 * channel(s) when the interface exposes them, and ignores the real inputs. */
static void test_loopback_latency_uses_loopback_channel(void) {
  printf("test_loopback_latency_uses_loopback_channel\n");
  enum { N = 200, RET = 150 };
  float out[2 * N];
  float in[2 * N];
  le_snapshot s;

  // ch1 is the loopback; the looped-back pulse arrives there at frame RET,
  // after the detector's dead-time. ch0 (a real input) stays silent.
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 100000);
  le_engine_set_excluded_input_mask_for_test(e, 0x2u);
  CHECK(le_engine_begin_latency_for_test(e) == LE_OK);
  drain(e); // apply MEASURE_LATENCY
  for (int i = 0; i < N; ++i) {
    in[i * 2 + 0] = 0.0f;
    in[i * 2 + 1] = i >= RET ? 0.5f : 0.0f;
  }
  le_engine_process(e, out, in, N);
  le_engine_get_snapshot(e, &s);
  CHECK(s.latency_state == LE_LATENCY_DONE);
  CHECK(s.record_offset_frames >= RET && s.record_offset_frames <= RET + 2);
  le_engine_destroy(e);

  // Control: the same pulse on a real input (ch0) must NOT be mistaken for the
  // loopback return — detection stays on the loopback channel only.
  le_engine* e2 = le_engine_create();
  le_engine_configure(e2, 48000, 2, 2, 100000);
  le_engine_set_excluded_input_mask_for_test(e2, 0x2u);
  le_engine_begin_latency_for_test(e2);
  drain(e2);
  for (int i = 0; i < N; ++i) {
    in[i * 2 + 0] = i >= RET ? 0.5f : 0.0f;
    in[i * 2 + 1] = 0.0f;
  }
  le_engine_process(e2, out, in, N);
  le_engine_get_snapshot(e2, &s);
  CHECK(s.latency_state == LE_LATENCY_MEASURING); // not detected on a real input
  le_engine_destroy(e2);
}

/* Regression: an empty input mask records silence even with a hot input bus.
 * (The single-channel-only case is covered by test_routing_input_mask.) */
static void test_routing_input_mask_empty_records_silence(void) {
  printf("test_routing_input_mask_empty_records_silence\n");
  float out[64];
  float zin[2 * LOOP_N] = {0};
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 9.0f; /* hot bus on both channels */
    in[i * 2 + 1] = 2.0f;
  }

  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000);
  CHECK(le_engine_set_input_mask(e, 0, 0x0) == LE_OK);
  le_engine_record(e, 0);
  le_engine_process(e, out, in, LOOP_N);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i * 2 + 0]) < 1e-6f);
  le_engine_destroy(e);
}

/* Records the defining loop (1.0 x LOOP_N) and leaves the master PLAYING at
 * position 0. */
static void establish_master(le_engine* e, float* out) {
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0); /* finalize -> master length = LOOP_N */
  drain(e);
}

/* Quantized: a new-track record arms and starts/finalizes exactly on the loop
 * top, so the capture is a full base loop with no silent pre-press slice. */
static void test_quantize_start_and_finalize_on_grid(void) {
  printf("test_quantize_start_and_finalize_on_grid\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  establish_master(e, out);
  le_engine_set_track_mute(e, 0, 1); /* observe track 1 alone */
  CHECK(le_engine_set_quantize(e, 1) == LE_OK);

  /* Move the master off the top (pos 0 -> 1), then press record mid-loop. */
  process_const(e, 0.0f, 1, out);
  le_engine_record(e, 1);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY); /* armed, not recording */

  /* pos 1 -> 2 -> 3 -> wrap(0): the decoy 9.0 must not be captured; recording
   * begins exactly at the wrap. */
  process_const(e, 9.0f, 3, out);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);

  /* Arm the finalize (reconciles the spent start arm), then record one full
   * loop of 2.0; the finalize fires at the next top -> exactly one base loop. */
  le_engine_record(e, 1);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING); /* not finalized yet */

  process_const(e, 2.0f, LOOP_N, out);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].multiple == 1);
  CHECK(s.tracks[1].length_frames == LOOP_N);

  /* The win: a full loop of 2.0, no silent slice (cf. the mid-loop test). */
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 2.0f) < 1e-6f);

  le_engine_destroy(e);
}

/* A second record press before the boundary cancels the pending capture. */
static void test_quantize_second_press_disarms(void) {
  printf("test_quantize_second_press_disarms\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  establish_master(e, out);
  le_engine_set_quantize(e, 1);
  process_const(e, 0.0f, 1, out); /* pos -> 1 */

  le_engine_record(e, 1); /* arm */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY);

  le_engine_record(e, 1); /* second press -> disarm */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY);

  /* Past two boundaries: the cancelled capture never starts. */
  process_const(e, 2.0f, 2 * LOOP_N, out);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY);

  le_engine_destroy(e);
}

/* The defining recording (no master yet) ignores quantize and acts immediately,
 * since it is what defines the grid. */
static void test_quantize_defining_track_is_immediate(void) {
  printf("test_quantize_defining_track_is_immediate\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  le_engine_set_quantize(e, 1);
  le_engine_record(e, 0); /* no master -> immediate RECORDING */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING);

  (void)out;
  le_engine_destroy(e);
}

/* An armed overdub takes its pre-overdub undo snapshot at arm time; cancelling
 * it reverses that snapshot, leaving no phantom undo layer. */
static void test_quantize_overdub_arm_disarm_reverses_undo(void) {
  printf("test_quantize_overdub_arm_disarm_reverses_undo\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  establish_master(e, out); /* track 0 PLAYING, length LOOP_N */
  le_engine_set_quantize(e, 1);
  process_const(e, 0.0f, 1, out); /* pos -> 1 */

  le_engine_record(e, 0); /* arm overdub: snapshot pushed */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING); /* armed, not overdubbing */
  CHECK(s.tracks[0].undo_depth == 1);

  le_engine_record(e, 0); /* second press -> disarm -> reverse snapshot */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].undo_depth == 0); /* no phantom layer */

  le_engine_destroy(e);
}

/* An armed overdub fires at the next loop top. */
static void test_quantize_overdub_fires_on_grid(void) {
  printf("test_quantize_overdub_fires_on_grid\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  establish_master(e, out);
  le_engine_set_quantize(e, 1);
  process_const(e, 0.0f, 1, out); /* pos -> 1 */

  le_engine_record(e, 0); /* arm overdub */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);

  process_const(e, 0.5f, 3, out); /* pos 1->2->3->wrap: fires at the top */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);

  le_engine_destroy(e);
}

int main(void) {
  printf("== loopy_engine_core native tests ==\n");
  test_quantize_start_and_finalize_on_grid();
  test_quantize_second_press_disarms();
  test_quantize_defining_track_is_immediate();
  test_quantize_overdub_arm_disarm_reverses_undo();
  test_quantize_overdub_fires_on_grid();
  test_ring_init_rejects_bad_capacity();
  test_ring_push_pop_fifo();
  test_ring_reports_full();
  test_ring_wraps_around();
  test_engine_lifecycle_without_device();
  test_null_safety();
  test_loop_clock();
  test_looper_record_then_play();
  test_looper_overdub_and_undo();
  test_looper_multilevel_undo();
  test_looper_volume_and_mute();
  test_looper_clear();
  test_looper_requires_configure();
  test_looper_multitrack();
  test_latency_compensation();
  test_record_is_exclusive();
  test_loop_multiple_records_two_loops();
  test_loop_multiple_rounds_up_partial();
  test_new_track_records_mid_loop();
  test_transport_resets_when_all_stopped();
  test_transport_runs_until_last_track_stops();
  test_routing_input_mask();
  test_routing_input_mask_averages();
  test_routing_input_mask_empty_records_silence();
  test_routing_output_mask();
  test_routing_default_stereo();
  test_routing_input_mask_clamped();
  test_routing_output_mask_clamped();
  test_visualization_tap();
  test_classify_capture_device();
  test_detect_loopback_runs();
  test_enumerate_devices_runs();
  test_label_is_loopback();
  test_loopback_exclusion();
  test_loopback_latency_uses_loopback_channel();
  test_set_record_offset_publishes_latency();

  if (g_failures == 0) {
    printf("ALL PASSED\n");
    return 0;
  }
  printf("%d CHECK(S) FAILED\n", g_failures);
  return 1;
}
