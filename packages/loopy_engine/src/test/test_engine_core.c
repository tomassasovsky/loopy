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
  le_engine_configure(e, 48000, 1, 1000);
  /* These DSP tests exercise the immediate (un-quantized) looper path; quantize
   * defaults to BAR, so disable it here. Quantize-start has its own tests. */
  le_engine_set_quantize(e, LE_QUANTIZE_OFF);
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
  le_engine_configure(e, 48000, 1, 100);
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

  /* Track 1 records (overwrites one master loop) at 0.5. During its recording
   * pass only track 0 is audible (1.0); track 1 is not mixed until it loops. */
  CHECK(le_engine_record(e, 1) == LE_OK);
  process_const(e, 0.5f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.0f) < 1e-6f);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].length_frames == LOOP_N);

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

/* ---- tempo / metronome ---- */

/* Processes `total` frames of silence in <=64-frame chunks. */
static void advance(le_engine* e, int total) {
  float in[64] = {0};
  float out[64];
  while (total > 0) {
    const int n = total > 64 ? 64 : total;
    le_engine_process(e, out, in, (uint32_t)n);
    total -= n;
  }
}

static le_engine* make_engine_sr(int sr) {
  le_engine* e = le_engine_create();
  le_engine_configure(e, sr, 1, 1000);
  return e;
}

static void test_tempo_set_and_clamp(void) {
  printf("test_tempo_set_and_clamp\n");
  le_engine* e = make_engine_sr(48000);
  le_snapshot s;

  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 90.0f) < 0.5f);

  le_engine_set_tempo(e, 10.0f); /* clamps to 30 */
  advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 30.0f) < 0.5f);

  le_engine_set_tempo(e, 1000.0f); /* clamps to 300 */
  advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 300.0f) < 0.5f);

  le_engine_destroy(e);
}

static void test_metronome_click(void) {
  printf("test_metronome_click\n");
  float out[64];

  /* Metronome off: the first beat passes but no click is emitted. */
  le_engine* off = make_engine_sr(48000);
  process_const(off, 0.0f, 64, out);
  float max_off = 0.0f;
  for (int i = 0; i < 64; ++i) {
    if (fabsf(out[i]) > max_off) max_off = fabsf(out[i]);
  }
  CHECK(max_off < 1e-6f);
  le_engine_destroy(off);

  /* Metronome on from the start: a click fires on the first beat (frame 0). */
  le_engine* on = make_engine_sr(48000);
  le_engine_set_metronome(on, 1);
  process_const(on, 0.0f, 64, out);
  float max_on = 0.0f;
  for (int i = 0; i < 64; ++i) {
    if (fabsf(out[i]) > max_on) max_on = fabsf(out[i]);
  }
  CHECK(max_on > 0.05f);
  le_engine_destroy(on);
}

static void test_tap_tempo(void) {
  printf("test_tap_tempo\n");
  le_engine* e = make_engine_sr(100);
  le_snapshot s;

  le_engine_set_tempo(e, 200.0f);
  advance(e, 1);

  /* Two taps 50 frames apart at 100 Hz == 0.5 s == 120 bpm. */
  le_engine_tap_tempo(e);
  advance(e, 50);
  le_engine_tap_tempo(e);
  advance(e, 1);

  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 2.0f);

  le_engine_destroy(e);
}

static void test_count_in_delays_recording(void) {
  printf("test_count_in_delays_recording\n");
  le_engine* e = make_engine_sr(100); /* 120 bpm -> 50 fpb -> 200-frame count-in */
  le_snapshot s;

  le_engine_set_count_in(e, 1);
  advance(e, 1);

  le_engine_record(e, 0);
  advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 1);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY); /* not recording yet */

  advance(e, 250); /* outlast the 200-frame count-in */
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 0);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING);

  le_engine_destroy(e);
}

/* ---- loop <-> tempo sync ---- */

/* Records a `len`-frame silent defining loop on track 0 and finalizes it. */
static void record_defining_loop(le_engine* e, int len) {
  le_engine_record(e, 0);
  advance(e, len);
  le_engine_record(e, 0); /* queue finalize */
  drain(e);               /* apply it */
}

static void test_loop_syncs_tempo(void) {
  printf("test_loop_syncs_tempo\n");
  /* sr 1000, 120 bpm -> 500 frames/beat, 2000 frames/bar. A 4000-frame loop is
   * exactly 2 bars, so the tempo stays 120 and the snapshot reports 2 bars. */
  le_engine* e = le_engine_create();
  le_engine_configure(e, 1000, 1, 20000);
  le_snapshot s;

  le_engine_get_snapshot(e, &s);
  CHECK(s.sync_loop_to_tempo == 1); /* default on */

  le_engine_set_tempo(e, 120.0f);
  advance(e, 1);
  record_defining_loop(e, 4000);

  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 4000);
  CHECK(s.loop_bars == 2);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.5f);

  le_engine_destroy(e);
}

static void test_loop_tempo_rounds_to_bar(void) {
  printf("test_loop_tempo_rounds_to_bar\n");
  /* sr 1000, 120 bpm -> 2000 frames/bar. An 1800-frame loop is 0.9 bars, which
   * rounds to 1 bar; the grid is then derived back from the loop (4 beats over
   * 1800 frames -> 450 frames/beat -> ~133.33 bpm). The loop length is NOT
   * altered — only the tempo snaps to fit it. */
  le_engine* e = le_engine_create();
  le_engine_configure(e, 1000, 1, 20000);
  le_snapshot s;

  le_engine_set_tempo(e, 120.0f);
  advance(e, 1);
  record_defining_loop(e, 1800);

  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 1800);
  CHECK(s.loop_bars == 1);
  CHECK(fabsf(s.tempo_bpm - 133.333f) < 0.2f);

  le_engine_destroy(e);
}

static void test_loop_drives_metronome_grid(void) {
  printf("test_loop_drives_metronome_grid\n");
  /* With a 2-bar loop (8 beats over 4000 frames, a beat every 500 frames), the
   * beat grid is locked to the loop position rather than free-running: the
   * published beat advances 0,1,2,3 then wraps to 0 at the bar boundary. */
  le_engine* e = le_engine_create();
  le_engine_configure(e, 1000, 1, 20000);
  le_snapshot s;

  le_engine_set_tempo(e, 120.0f);
  le_engine_set_metronome(e, 1);
  advance(e, 1);
  record_defining_loop(e, 4000);

  advance(e, 1); /* pos 0 -> downbeat */
  le_engine_get_snapshot(e, &s);
  CHECK(s.loop_bars == 2);
  CHECK(s.current_beat == 0);

  advance(e, 600); /* cross 500 -> beat 1 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 1);
  advance(e, 500); /* cross 1000 -> beat 2 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 2);
  advance(e, 500); /* cross 1500 -> beat 3 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 3);
  advance(e, 500); /* cross 2000 -> bar boundary, beat 4 % 4 == 0 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 0);

  le_engine_destroy(e);
}

static void test_sync_off_keeps_free_form(void) {
  printf("test_sync_off_keeps_free_form\n");
  /* With sync disabled the loop keeps its recorded length, no bars are derived,
   * and the tempo is left exactly as the user set it. */
  le_engine* e = le_engine_create();
  le_engine_configure(e, 1000, 1, 20000);
  le_snapshot s;

  CHECK(le_engine_set_sync_tempo(e, 0) == LE_OK);
  le_engine_set_tempo(e, 137.0f);
  advance(e, 1);
  record_defining_loop(e, 1800);

  le_engine_get_snapshot(e, &s);
  CHECK(s.sync_loop_to_tempo == 0);
  CHECK(s.master_length_frames == 1800); /* not rounded */
  CHECK(s.loop_bars == 0);               /* no bar relationship */
  CHECK(fabsf(s.tempo_bpm - 137.0f) < 0.5f); /* tempo untouched */

  le_engine_destroy(e);
}

/* ---- quantize-start ---- */

/* sr 1000, 120 bpm: a 4000-frame defining loop is 2 bars (a beat every 500
 * frames, a bar every 2000). Returns an engine playing that loop, with the
 * given quantize mode applied. */
static le_engine* make_quantized_loop_engine(int mode) {
  le_engine* e = le_engine_create();
  le_engine_configure(e, 1000, 1, 20000);
  le_engine_set_quantize(e, mode);
  le_engine_set_tempo(e, 120.0f);
  advance(e, 1); /* apply the quantize + tempo commands */
  record_defining_loop(e, 4000);
  return e;
}

static void test_quantize_default_is_bar(void) {
  printf("test_quantize_default_is_bar\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 1000, 1, 20000);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.quantize_mode == LE_QUANTIZE_BAR);
  CHECK(s.armed_channel == -1);
  le_engine_destroy(e);
}

static void test_quantize_bar_arms_overdub(void) {
  printf("test_quantize_bar_arms_overdub\n");
  le_engine* e = make_quantized_loop_engine(LE_QUANTIZE_BAR);
  le_snapshot s;

  advance(e, 600); /* move off the loop top (past beat 1 at 500) */

  /* Pressing record arms the overdub instead of starting it now. */
  le_engine_record(e, 0);
  advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.armed_channel == 0);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING); /* not overdubbing yet */
  CHECK(s.tracks[0].undo_depth == 1);           /* snapshot taken at the press */

  /* Crossing intermediate beats (1000, 1500) must NOT start it. */
  advance(e, 1300); /* pos ~1901, still before the bar line at 2000 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.armed_channel == 0);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);

  /* Crossing the bar boundary at 2000 begins the overdub. */
  advance(e, 200); /* pos ~2101 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.armed_channel == -1);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);

  le_engine_destroy(e);
}

static void test_quantize_beat_arms_to_next_beat(void) {
  printf("test_quantize_beat_arms_to_next_beat\n");
  le_engine* e = make_quantized_loop_engine(LE_QUANTIZE_BEAT);
  le_snapshot s;

  advance(e, 600); /* pos 600, between beats 1 (500) and 2 (1000) */
  le_engine_record(e, 0);
  advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.armed_channel == 0);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);

  advance(e, 300); /* pos ~901, still before beat 2 at 1000 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);

  advance(e, 200); /* cross 1000 -> begin overdub at the next beat */
  le_engine_get_snapshot(e, &s);
  CHECK(s.armed_channel == -1);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);

  le_engine_destroy(e);
}

static void test_quantize_off_is_immediate(void) {
  printf("test_quantize_off_is_immediate\n");
  le_engine* e = make_quantized_loop_engine(LE_QUANTIZE_OFF);
  le_snapshot s;

  advance(e, 600);
  le_engine_record(e, 0); /* no arming: overdub starts now */
  advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.armed_channel == -1);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);

  le_engine_destroy(e);
}

static void test_quantize_arm_cancelled_by_second_press(void) {
  printf("test_quantize_arm_cancelled_by_second_press\n");
  le_engine* e = make_quantized_loop_engine(LE_QUANTIZE_BAR);
  le_snapshot s;

  advance(e, 600);
  le_engine_record(e, 0); /* arm */
  advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.armed_channel == 0);

  le_engine_record(e, 0); /* second press cancels the pending arm */
  advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.armed_channel == -1);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);

  /* Crossing the bar boundary now does nothing — there is no pending arm. */
  advance(e, 2000);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);

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

int main(void) {
  printf("== loopy_engine_core native tests ==\n");
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
  test_tempo_set_and_clamp();
  test_metronome_click();
  test_tap_tempo();
  test_count_in_delays_recording();
  test_loop_syncs_tempo();
  test_loop_tempo_rounds_to_bar();
  test_loop_drives_metronome_grid();
  test_sync_off_keeps_free_form();
  test_quantize_default_is_bar();
  test_quantize_bar_arms_overdub();
  test_quantize_beat_arms_to_next_beat();
  test_quantize_off_is_immediate();
  test_quantize_arm_cancelled_by_second_press();
  test_classify_capture_device();
  test_detect_loopback_runs();

  if (g_failures == 0) {
    printf("ALL PASSED\n");
    return 0;
  }
  printf("%d CHECK(S) FAILED\n", g_failures);
  return 1;
}
