/*
 * test_engine_core.c — native unit tests for the real-time-critical core.
 *
 * Covers the lock-free SPSC command ring (wrap-around, full/empty, FIFO order)
 * and the engine lifecycle paths that do not require an audio device. These are
 * the pieces with the strictest correctness/real-time requirements.
 *
 * The engine sources span core/ (the portable engine + the miniaudio backend)
 * and platform/ (the three per-OS seam TUs, all listed unconditionally — the two
 * that don't match the host compile to near-empty objects — so the le_platform_*
 * symbols resolve at link time).
 *
 * Build & run: use the helper, which picks the right per-OS toolchain flags and
 * source/include paths and runs both native suites:
 *   bash src/test/run_native_tests.sh
 * It expects "ALL PASSED". The engine source set it compiles mirrors
 * src/CMakeLists.txt (minus the MIDI TUs this suite does not link).
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "audio_ring.h"       /* le_audio_ring (performance-recording capture) */
#include "engine_internal.h"
#include "engine_private.h"   /* LE_POOL_SLOTS (per-pass undo pool cap) */
#include "engine_miniaudio.h" /* le_miniaudio_backend (le_select_backend target) */
#include "engine_platform.h"  /* le_platform_device_id_to_str, ma_device_id */
#include "fft.h"              /* le_fft, le_rfft_fwd, le_rfft_inv, le_hann_init */
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
    le_command cmd = {.code = i, .arg_i = i * 10, .arg_f = (float)i};
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

  le_command cmd = {.code = 1};
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
    le_command cmd = {.code = i};
    CHECK(le_ring_push(&ring, cmd) == 1);
    CHECK(le_ring_pop(&ring, &out) == 1);
    CHECK(out.code == i);
  }
}

/* ---- le_audio_ring (performance-recording capture ring) ---- */

static void test_audio_ring_init_rejects_bad_capacity(void) {
  printf("test_audio_ring_init_rejects_bad_capacity\n");
  float storage[8];
  le_audio_ring ring;
  CHECK(le_audio_ring_init(&ring, storage, 8) == 1); /* power of two */
  CHECK(le_audio_ring_init(&ring, storage, 6) == 0); /* not power of two */
  CHECK(le_audio_ring_init(&ring, storage, 1) == 0); /* too small */
  CHECK(le_audio_ring_init(&ring, storage, 0) == 0); /* zero */
  CHECK(le_audio_ring_init(NULL, storage, 8) == 0);  /* null ring */
  CHECK(le_audio_ring_init(&ring, NULL, 8) == 0);    /* null buffer */
}

static void test_audio_ring_push_pop_fifo(void) {
  printf("test_audio_ring_push_pop_fifo\n");
  float storage[8];
  le_audio_ring ring;
  le_audio_ring_init(&ring, storage, 8);

  float out[8];
  CHECK(le_audio_ring_pop(&ring, out, 8) == 0); /* empty */

  for (int i = 0; i < 3; ++i) {
    float frame[2] = {(float)i, (float)i + 0.5f};
    CHECK(le_audio_ring_push_frame(&ring, frame, 2) == 1);
  }
  CHECK(le_audio_ring_pop(&ring, out, 8) == 6);
  for (int i = 0; i < 3; ++i) {
    CHECK(out[i * 2 + 0] == (float)i);
    CHECK(out[i * 2 + 1] == (float)i + 0.5f);
  }
  CHECK(le_audio_ring_pop(&ring, out, 8) == 0); /* drained */
}

static void test_audio_ring_push_frame_all_or_nothing(void) {
  printf("test_audio_ring_push_frame_all_or_nothing\n");
  float storage[4]; /* usable slots == capacity - 1 == 3 samples */
  le_audio_ring ring;
  le_audio_ring_init(&ring, storage, 4);

  float mono[1] = {1.0f};
  CHECK(le_audio_ring_push_frame(&ring, mono, 1) == 1); /* 1/3 used */
  CHECK(le_audio_ring_push_frame(&ring, mono, 1) == 1); /* 2/3 used */

  /* Only 1 sample free; a 2-sample frame must be refused WHOLESALE, never
   * partially written (a torn stereo frame would be worse than a dropped
   * one). */
  float stereo[2] = {2.0f, 3.0f};
  CHECK(le_audio_ring_push_frame(&ring, stereo, 2) == 0);

  float out[4];
  CHECK(le_audio_ring_pop(&ring, out, 4) == 2); /* exactly the two mono pushes */
  CHECK(out[0] == 1.0f);
  CHECK(out[1] == 1.0f);
}

static void test_audio_ring_reports_full(void) {
  printf("test_audio_ring_reports_full\n");
  float storage[4];
  le_audio_ring ring;
  le_audio_ring_init(&ring, storage, 4);

  float v = 1.0f;
  CHECK(le_audio_ring_push_frame(&ring, &v, 1) == 1);
  CHECK(le_audio_ring_push_frame(&ring, &v, 1) == 1);
  CHECK(le_audio_ring_push_frame(&ring, &v, 1) == 1);
  CHECK(le_audio_ring_push_frame(&ring, &v, 1) == 0); /* full at capacity-1 */

  float out[1];
  CHECK(le_audio_ring_pop(&ring, out, 1) == 1);
  CHECK(le_audio_ring_push_frame(&ring, &v, 1) == 1); /* room again after a pop */
}

static void test_audio_ring_wraps_around(void) {
  printf("test_audio_ring_wraps_around\n");
  float storage[4];
  le_audio_ring ring;
  le_audio_ring_init(&ring, storage, 4);

  float out[1];
  for (int i = 0; i < 100; ++i) {
    float v = (float)i;
    CHECK(le_audio_ring_push_frame(&ring, &v, 1) == 1);
    CHECK(le_audio_ring_pop(&ring, out, 1) == 1);
    CHECK(out[0] == v);
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

/* THE DRY-RECORDING INVARIANT (umbrella D-P1, part 7 headline): an FX in a
 * lane chain colours playback only — the captured loop buffer is byte-identical
 * to the same take with no FX. The record route is FX-agnostic, so this holds
 * for a hosted plugin exactly as for the built-in drive used here (a plugin
 * slot can't be wired without a scan in this harness). */
static void test_dry_recording_invariant(void) {
  printf("test_dry_recording_invariant\n");
  const float kIn = 0.8f;

  /* Take 1: record with a drive FX (which audibly alters 0.8) in the chain. */
  le_engine* e = make_configured_engine();
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, 1 /* drive */) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1) == LE_OK);
  float out[64];
  le_engine_record(e, 0);
  process_const(e, kIn, LOOP_N, out);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);
  float withFx[LOOP_N];
  CHECK(le_engine_export_track(e, 0, withFx, LOOP_N) == LOOP_N);
  le_engine_destroy(e);

  /* Take 2: identical input, no FX. */
  e = make_configured_engine();
  le_engine_record(e, 0);
  process_const(e, kIn, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);
  float noFx[LOOP_N];
  CHECK(le_engine_export_track(e, 0, noFx, LOOP_N) == LOOP_N);
  le_engine_destroy(e);

  /* Byte-identical to each other AND to the dry input — the FX never touched
   * the recorded buffer. */
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(memcmp(&withFx[i], &noFx[i], sizeof(float)) == 0);
    CHECK(withFx[i] == kIn);
  }
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
   * (1.0) is heard while the +0.5 lands in the buffer for the next pass. The
   * undo layer is captured incrementally on the audio thread (backup-on-write)
   * and retires when the pass completes — no depth yet at punch-in. */
  CHECK(le_engine_record(e, 0) == LE_OK); /* -> OVERDUBBING */
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 0); /* layer not complete yet */
  process_const(e, 0.5f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.0f) < 1e-6f);

  le_engine_record(e, 0); /* OVERDUBBING -> PLAYING */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].undo_depth == 1); /* the completed pass retired */

  /* The recorded layer now plays back: 1.0 + 0.5 == 1.5. */
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.5f) < 1e-6f);
  drain(e); /* punch envelope quiet: the capture session winds down */

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
  drain(e); /* punch envelope quiet: the capture session winds down */

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

/* ---- per-pass layer capture ----
 *
 * The audio thread backs up each overdub write's pre-value into a pre-posted
 * shadow slot; a completed pass retires through the evt_ring as one undo
 * layer. These tests drive that machinery end to end: multi-pass dubs, the
 * post-punch-out drain, queued undo, spare starvation, undo past the base
 * layer, and the redo-from-empty resurrection. Content is asserted through
 * le_engine_export_track (the raw live buffer), which is playhead-agnostic. */

/* Records a LOOP_N base loop of `value` on track 0 and leaves it PLAYING at
 * the loop top with the command ring drained. */
static void record_base_loop(le_engine* e, float value) {
  float out[64];
  le_engine_record(e, 0);
  process_const(e, value, LOOP_N, out);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);
}

/* Winds a punched-out capture session down: one frame settles the punch
 * envelope, the block update then drains/retires the in-flight layer. */
static void settle_dub(le_engine* e) {
  float out[64];
  process_const(e, 0.0f, 1, out);
  drain(e);
  drain(e);
}

/* Exports track 0 and checks every frame equals `want`. */
static void check_content(le_engine* e, float want) {
  float pcm[LOOP_N];
  CHECK(le_engine_export_track(e, 0, pcm, LOOP_N) == LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - want) < 1e-6f);
}

/* One continuous overdub held across three passes yields three undo layers —
 * undo peels one PASS at a time, not the whole press session. */
static void test_per_pass_undo_layers(void) {
  printf("test_per_pass_undo_layers\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch in, hold across 3 passes */
  for (int pass = 0; pass < 3; ++pass) {
    process_const(e, 0.5f, LOOP_N, out);
    /* The poll tick: collects the retired pass and replenishes the spare. */
    le_engine_get_snapshot(e, &s);
    CHECK(s.tracks[0].undo_depth == pass + 1);
  }
  le_engine_record(e, 0); /* punch out */
  drain(e);
  settle_dub(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 3);
  check_content(e, 2.5f);

  /* Peel one pass per undo: 2.5 -> 2.0 -> 1.5 -> 1.0. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 2.0f);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 1.5f);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 1.0f);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 0);
  CHECK(s.tracks[0].redo_depth == 3);

  /* Redo climbs back layer by layer. */
  CHECK(le_engine_redo(e, 0) == LE_OK);
  check_content(e, 1.5f);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  check_content(e, 2.5f);

  le_engine_destroy(e);
}

/* A punch-out mid-pass leaves live authoritative; the uncovered remainder of
 * the layer drains live -> shadow and the partial pass undoes alone. */
static void test_punch_out_mid_pass_drains(void) {
  printf("test_punch_out_mid_pass_drains\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch in at the loop top */
  process_const(e, 0.5f, 2, out);         /* half a pass: positions 0,1 */
  le_engine_record(e, 0);                 /* punch out mid-pass */
  drain(e);
  settle_dub(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 1);

  /* Live holds the partial dub; undo restores the full pre-dub loop. */
  float pcm[LOOP_N];
  CHECK(le_engine_export_track(e, 0, pcm, LOOP_N) == LOOP_N);
  CHECK(fabsf(pcm[0] - 1.5f) < 1e-6f);
  CHECK(fabsf(pcm[1] - 1.5f) < 1e-6f);
  CHECK(fabsf(pcm[2] - 1.0f) < 1e-6f);
  CHECK(fabsf(pcm[3] - 1.0f) < 1e-6f);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 1.0f);

  /* Redo restores the partial dub exactly. */
  CHECK(le_engine_redo(e, 0) == LE_OK);
  CHECK(le_engine_export_track(e, 0, pcm, LOOP_N) == LOOP_N);
  CHECK(fabsf(pcm[0] - 1.5f) < 1e-6f);
  CHECK(fabsf(pcm[2] - 1.0f) < 1e-6f);

  le_engine_destroy(e);
}

/* An undo tapped while the punched-out layer is still in flight (fade tail /
 * drain) is queued — never rejected, never lost — and applies as soon as the
 * layer retires. */
static void test_undo_queued_during_drain(void) {
  printf("test_undo_queued_during_drain\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, 0.5f, LOOP_N, out); /* one full pass -> 1.5 */
  le_engine_record(e, 0);              /* punch out */
  drain(e); /* state flips, but the punch envelope is still up */

  /* The immediate tap: the session has not wound down yet, so it queues. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  settle_dub(e);
  le_engine_get_snapshot(e, &s); /* the drain applies the queued tap */
  CHECK(s.tracks[0].undo_depth == 0);
  CHECK(s.tracks[0].redo_depth == 1);
  check_content(e, 1.0f);

  le_engine_destroy(e);
}

/* A queued undo that falls through to undo-to-empty must pre-zero the
 * published length control-side (mirroring the live-tap and clear paths), so
 * a snapshot poll can never pair EMPTY with a stale nonzero length — the
 * audio thread's state flip and length zeroing are separate stores, and the
 * UI's depths-sane invariant asserts on every poll. */
static void test_queued_undo_to_empty_coherent_snapshot(void) {
  printf("test_queued_undo_to_empty_coherent_snapshot\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, 0.5f, LOOP_N, out); /* one full pass -> 1.5 */
  le_engine_record(e, 0);              /* punch out */
  drain(e); /* state flips, but the punch envelope is still up */

  /* Two taps while the layer is in flight: both queue. On the flush the
   * first peels the dub layer, the second falls through to undo-to-empty. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  settle_dub(e);
  le_engine_get_snapshot(e, &s); /* the drain applies the queued taps */

  /* UNDO_TO_EMPTY is posted but not yet applied by the audio thread: the
   * published length must already read 0 (and the history must be fully on
   * the redo side) so no poll can see EMPTY with the old length. */
  CHECK(s.tracks[0].length_frames == 0);
  CHECK(s.tracks[0].undo_depth == 0);
  CHECK(s.tracks[0].redo_depth == 2);

  drain(e); /* the audio thread applies the state flip */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[0].length_frames == 0);

  /* The resurrect path is intact: redo reinstates base, then the dub. */
  CHECK(le_engine_redo(e, 0) == LE_OK);
  drain(e);
  check_content(e, 1.0f);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  check_content(e, 1.5f);

  le_engine_destroy(e);
}

/* Undoing past the base layer empties the track for the pedal/UI while redo
 * keeps the whole history; the master grid deliberately survives (redo needs
 * it — Clear remains the full reset). */
static void test_undo_to_empty_and_redo(void) {
  printf("test_undo_to_empty_and_redo\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, 0.5f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);
  settle_dub(e);

  CHECK(le_engine_undo(e, 0) == LE_OK); /* 1.5 -> 1.0 */
  check_content(e, 1.0f);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* past the base layer -> EMPTY */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[0].length_frames == 0);
  CHECK(s.tracks[0].undo_depth == 0);
  CHECK(s.tracks[0].redo_depth == 2);
  CHECK(s.master_length_frames == LOOP_N); /* the grid survives */

  /* A third undo on the empty track is a no-op. */
  CHECK(le_engine_undo(e, 0) == LE_ERR_INVALID);

  /* Redo reinstates layer by layer: base first, then the dub. */
  CHECK(le_engine_redo(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].length_frames == LOOP_N);
  CHECK(s.tracks[0].redo_depth == 1);
  check_content(e, 1.0f);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  check_content(e, 1.5f);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 1);
  CHECK(s.tracks[0].redo_depth == 0);

  le_engine_destroy(e);
}

/* A fresh recording on an undone-to-empty track invalidates the resurrect
 * path: redo history clears, and the new take records against the kept grid. */
static void test_record_after_undo_to_empty_clears_redo(void) {
  printf("test_record_after_undo_to_empty_clears_redo\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  record_base_loop(e, 1.0f);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* no layers -> undo-to-empty */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[0].redo_depth == 1);

  CHECK(le_engine_record(e, 0) == LE_OK); /* fresh take over the kept grid */
  process_const(e, 2.0f, LOOP_N, out);
  le_engine_record(e, 0); /* finalize */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].redo_depth == 0); /* resurrection invalidated */
  CHECK(le_engine_redo(e, 0) == LE_ERR_INVALID);
  check_content(e, 2.0f);

  le_engine_destroy(e);
}

/* Clear resets the track to its default armed-to-play state: unmuted (a
 * leftover Stop-mute never silences the next take) with all capture state
 * dropped. */
static void test_clear_unmutes(void) {
  printf("test_clear_unmutes\n");
  le_engine* e = make_configured_engine();
  le_snapshot s;

  record_base_loop(e, 1.0f);
  le_engine_set_track_mute(e, 0, 1);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].muted == 1);

  CHECK(le_engine_clear(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[0].muted == 0); /* cleared -> unmuted */
  CHECK(s.tracks[0].undo_depth == 0);
  CHECK(s.tracks[0].redo_depth == 0);
  CHECK(s.master_length_frames == 0); /* all tracks empty: full reset */

  le_engine_destroy(e);
}

/* Recording into an EMPTY track unmutes it — covers the record-after-undo-to-
 * empty path, where undo itself must NOT touch mute (undo/redo stay exact
 * inverses). */
static void test_record_from_empty_unmutes(void) {
  printf("test_record_from_empty_unmutes\n");
  le_engine* e = make_configured_engine();
  le_snapshot s;

  record_base_loop(e, 1.0f);
  le_engine_set_track_mute(e, 0, 1);
  drain(e);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* undo-to-empty keeps the mute */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[0].muted == 1);

  CHECK(le_engine_record(e, 0) == LE_OK); /* fresh take: always audible */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING);
  CHECK(s.tracks[0].muted == 0);

  le_engine_destroy(e);
}

/* With the control thread stalled (no event drains), the shadow supply runs
 * dry after two passes; later passes merge coherently into the last layer —
 * undo never restores a torn image that never existed. */
static void test_spare_starvation_merges_passes(void) {
  printf("test_spare_starvation_merges_passes\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK);
  /* Five back-to-back passes with NO control-thread activity in between: the
   * two posted shadows capture passes 1 and 2; passes 3..5 run un-backed and
   * merge into the pass-2 layer. */
  for (int pass = 0; pass < 5; ++pass) {
    process_const(e, 0.5f, LOOP_N, out);
  }
  le_engine_record(e, 0); /* punch out */
  drain(e);
  settle_dub(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 2);
  check_content(e, 3.5f); /* 1.0 + 5 x 0.5 */

  /* Undo restores states that actually existed at pass starts. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 1.5f); /* pre-pass-2 (passes 2..5 merged) */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 1.0f);

  le_engine_destroy(e);
}

/* A record-offset change mid-dub cannot tear the layer: the write trajectory
 * is latched per session, so the pass still covers every position exactly
 * once and undo restores the pre-dub loop bit-exactly. */
static void test_offset_latched_across_dub(void) {
  printf("test_offset_latched_across_dub\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  CHECK(le_engine_set_record_offset(e, 1) == LE_OK);
  drain(e);
  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch in with offset 1 */
  process_const(e, 0.5f, 2, out);
  CHECK(le_engine_set_record_offset(e, 0) == LE_OK); /* mid-dub change */
  process_const(e, 0.5f, 2, out); /* completes the pass on the latched 1 */
  le_engine_record(e, 0);         /* punch out */
  drain(e);
  settle_dub(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 1);
  check_content(e, 1.5f); /* every position got exactly one +0.5 write */

  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 1.0f); /* bit-exact pre-dub restore, no tear */

  le_engine_destroy(e);
}

/* Redo-from-empty is always audible: a leftover Stop-mute clears when the
 * track is reinstated (mirroring record-from-empty), so a resurrected loop
 * can never come back playing-but-silent. */
static void test_redo_from_empty_unmutes(void) {
  printf("test_redo_from_empty_unmutes\n");
  le_engine* e = make_configured_engine();
  le_snapshot s;

  record_base_loop(e, 1.0f);
  le_engine_set_track_mute(e, 0, 1);
  drain(e);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* to empty; undo never touches mute */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[0].muted == 1);

  CHECK(le_engine_redo(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].muted == 0); /* resurrection is audible */
  check_content(e, 1.0f);

  le_engine_destroy(e);
}

/* Undo past the base layer cancels a pending quantized arm: the emptied track
 * must not fire a surprise fresh recording at the next loop top (another
 * track keeps the transport running across the wrap). */
static void test_undo_to_empty_cancels_pending_arm(void) {
  printf("test_undo_to_empty_cancels_pending_arm\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  record_base_loop(e, 1.0f); /* track 0: the base loop (defines the master) */
  /* Track 1 plays too, so the loop clock keeps running once track 0 empties. */
  CHECK(le_engine_record(e, 1) == LE_OK);
  process_const(e, 0.25f, LOOP_N, out);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);

  le_engine_set_quantize(e, 1);
  process_const(e, 0.0f, 1, out);         /* move off the loop top */
  CHECK(le_engine_record(e, 0) == LE_OK); /* arm a quantized overdub on 0 */
  drain(e);

  CHECK(le_engine_undo(e, 0) == LE_OK); /* no layers -> undo-to-empty */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);

  /* Cross the loop top twice: the cancelled arm must not fire anything. */
  process_const(e, 0.0f, 2 * LOOP_N, out);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[0].length_frames == 0);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING); /* the clock really ran */

  le_engine_destroy(e);
}

/* Commands pushed while the device is stopped/lost must NOT replay onto the
 * next configuration — le_engine_configure re-initialises the command ring, so
 * a reconnect can't fire a surprise recording from a stale press. */
static void test_configure_drops_stale_commands(void) {
  printf("test_configure_drops_stale_commands\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  /* A press with no audio callbacks running: it sits in the ring. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  /* Device-loss recovery path: reconfigure, then audio resumes. */
  le_engine_configure(e, 48000, 1, 1, 1000);
  process_const(e, 0.0f, LOOP_N, out);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY); /* no surprise recording */

  le_engine_destroy(e);
}

/* A fresh recording on an otherwise-empty looper redefines the master grid:
 * the grid kept for redo must not lock the new take to the dead tempo once
 * redo has been invalidated. */
static void test_fresh_record_after_undo_to_empty_redefines_grid(void) {
  printf("test_fresh_record_after_undo_to_empty_redefines_grid\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  record_base_loop(e, 1.0f); /* master = LOOP_N */
  CHECK(le_engine_undo(e, 0) == LE_OK); /* to empty; grid kept for redo */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == LOOP_N);

  /* Fresh take, deliberately LONGER than the old grid: it must define a new
   * master of exactly its own length, not round to the ghost tempo. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, 2.0f, LOOP_N + 2, out);
  CHECK(le_engine_record(e, 0) == LE_OK); /* finalize the defining master */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == LOOP_N + 2);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].length_frames == LOOP_N + 2);
  CHECK(s.tracks[0].redo_depth == 0);

  le_engine_destroy(e);
}

/* The ghost grid IS kept when a sibling still needs it: an undone-to-empty
 * track's redo resurrects onto that tempo, so a fresh take elsewhere stays
 * grid-locked. */
static void test_grid_kept_when_sibling_redo_alive(void) {
  printf("test_grid_kept_when_sibling_redo_alive\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  record_base_loop(e, 1.0f); /* track 0: master = LOOP_N */
  CHECK(le_engine_undo(e, 0) == LE_OK); /* track 0 empty, redo alive */
  drain(e);

  /* Record on track 1: track 0's redo still needs the grid, so this take is
   * phase-locked and rounds up to the kept base. */
  CHECK(le_engine_record(e, 1) == LE_OK);
  process_const(e, 2.0f, 2, out); /* under one base loop */
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);
  process_const(e, 0.0f, 1, out); /* settle the finalize */
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == LOOP_N); /* grid survived */
  CHECK(s.tracks[1].length_frames == LOOP_N); /* rounded to the kept base */
  CHECK(s.tracks[0].redo_depth == 1); /* resurrection still possible */
  CHECK(le_engine_redo(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].length_frames == LOOP_N);

  le_engine_destroy(e);
}

/* A quantized record press while the transport is held (everything parked)
 * acts immediately instead of arming for a loop top the held clock never
 * reaches. */
static void test_quantize_acts_immediately_when_transport_held(void) {
  printf("test_quantize_acts_immediately_when_transport_held\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  record_base_loop(e, 1.0f);
  CHECK(le_engine_stop_track(e, 0) == LE_OK); /* park: clock holds at top */
  drain(e);
  CHECK(le_engine_set_quantize(e, 1) == LE_OK);

  CHECK(le_engine_record(e, 1) == LE_OK); /* would deadlock if it armed */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING); /* acted immediately */

  le_engine_destroy(e);
}

/* A quick re-punch after a mid-pass punch-out (the drain window) restarts the
 * layer capture on the same slot instead of resuming gapped coverage — undo
 * must never restore a torn snapshot contaminated by the second dub. */
static void test_repunch_during_drain_restarts_capture(void) {
  printf("test_repunch_during_drain_restarts_capture\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;
  float pcm[LOOP_N];

  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch in at the loop top */
  process_const(e, 0.5f, 2, out);         /* partial pass: positions 0,1 */
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch out mid-pass */
  drain(e);
  process_const(e, 0.0f, 1, out); /* punch envelope decays; drain pending */

  /* Re-punch inside the drain window and dub one full pass. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, 0.5f, LOOP_N, out);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch out */
  drain(e);
  settle_dub(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 1); /* one coherent layer (P1a merged) */

  /* Live holds both dubs; positions 0,1 got both, 2,3 only the second. */
  CHECK(le_engine_export_track(e, 0, pcm, LOOP_N) == LOOP_N);
  CHECK(fabsf(pcm[0] - 2.0f) < 1e-6f);
  CHECK(fabsf(pcm[2] - 1.5f) < 1e-6f);

  /* Undo restores exactly the pre-re-punch state: the partial first dub is
   * intact and NOT contaminated by second-dub fragments. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  CHECK(le_engine_export_track(e, 0, pcm, LOOP_N) == LOOP_N);
  CHECK(fabsf(pcm[0] - 1.5f) < 1e-6f);
  CHECK(fabsf(pcm[1] - 1.5f) < 1e-6f);
  CHECK(fabsf(pcm[2] - 1.0f) < 1e-6f);
  CHECK(fabsf(pcm[3] - 1.0f) < 1e-6f);

  le_engine_destroy(e);
}

/* Pumps [frames] frames of constant [value] in <= 64-frame blocks. */
static void pump_frames(le_engine* e, float value, int frames) {
  float out[64];
  while (frames > 0) {
    const int n = frames > 64 ? 64 : frames;
    process_const(e, value, n, out);
    frames -= n;
  }
}

/* Undo layers are sized to the loop length rounded to LE_LAYER_QUANTUM — a
 * tiny loop's layer costs one quantum, not the recording cap — while the live
 * slot of a fresh capture always regrows to the full cap (undo can leave a
 * quantized snapshot slot live). */
static void test_undo_layers_quantized_and_live_regrows(void) {
  printf("test_undo_layers_quantized_and_live_regrows\n");
  le_engine* e = le_engine_create();
  const int32_t cap = 200000; /* > LE_LAYER_QUANTUM so sizes are observable */
  le_engine_configure(e, 48000, 1, 1, cap);
  float out[64];
  le_snapshot s;
  float pcm[LOOP_N];

  /* Tiny base loop + one dub pass -> one retired quantum-sized layer. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);
  CHECK(le_engine_lane_slot_cap_for_test(e, 0, 0, -1) == cap); /* live = cap */
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, 0.5f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);
  settle_dub(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 1);

  /* Undo swaps the quantized snapshot slot live: content correct, size is one
   * quantum (not the cap). */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  CHECK(le_engine_lane_slot_cap_for_test(e, 0, 0, -1) == LE_LAYER_QUANTUM);
  CHECK(le_engine_export_track(e, 0, pcm, LOOP_N) == LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - 1.0f) < 1e-6f);

  /* Undo to empty, record fresh: the capture target regrows to the cap. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING);
  CHECK(le_engine_lane_slot_cap_for_test(e, 0, 0, -1) == cap);

  le_engine_destroy(e);
}

/* A slot reused for a LONGER loop regrows: a loop spanning more than one
 * quantum gets a two-quantum layer. */
static void test_undo_layer_slot_regrows_for_longer_loop(void) {
  printf("test_undo_layer_slot_regrows_for_longer_loop\n");
  le_engine* e = le_engine_create();
  const int32_t cap = 200000;
  le_engine_configure(e, 48000, 1, 1, cap);
  float out[64];
  le_snapshot s;

  /* Base loop longer than one quantum (50k > 48k). The defining finalize
   * defers ~10 ms for the seam crossfade — pump the overlap to complete it. */
  const int32_t len = LE_LAYER_QUANTUM + 2000;
  le_engine_record(e, 0);
  pump_frames(e, 1.0f, len);
  le_engine_record(e, 0);
  drain(e);
  pump_frames(e, 1.0f, 600); /* crossfade overlap -> auto-finalize */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].length_frames == len);

  /* One full dub pass; at this loop size the punch fade is engaged, so the
   * post-punch-out tail commits a second sliver layer after the drain. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  pump_frames(e, 0.5f, len);
  le_engine_record(e, 0); /* punch out */
  drain(e);
  pump_frames(e, 0.0f, 600); /* fade tail decays; the drain completes */
  drain(e);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 2); /* the pass + the punch-tail sliver */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  CHECK(le_engine_lane_slot_cap_for_test(e, 0, 0, -1) ==
        2 * LE_LAYER_QUANTUM);

  le_engine_destroy(e);
}

/* Depth beyond the pool cap evicts the OLDEST layer and keeps running: a very
 * long dub session stays stable and the newest layers stay undoable. */
static void test_undo_pool_eviction(void) {
  printf("test_undo_pool_eviction\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK);
  /* More passes than the pool holds; the poll tick between passes collects
   * retires and replenishes spares, exactly like the UI does. */
  const int passes = LE_POOL_SLOTS + 10;
  for (int pass = 0; pass < passes; ++pass) {
    process_const(e, 0.5f, LOOP_N, out);
    le_engine_get_snapshot(e, &s);
  }
  le_engine_record(e, 0); /* punch out */
  drain(e);
  settle_dub(e);
  le_engine_get_snapshot(e, &s);
  /* Depth is capped (pool minus live + posted shadows), the engine is sane,
   * and the newest layer still undoes correctly. */
  CHECK(s.tracks[0].undo_depth >= LE_POOL_SLOTS - 6);
  CHECK(s.tracks[0].undo_depth <= LE_POOL_SLOTS - 1);
  const float top = 1.0f + 0.5f * (float)passes;
  check_content(e, top);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, top - 0.5f);

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

static void test_master_gain_scales_output(void) {
  printf("test_master_gain_scales_output\n");
  le_engine* e = make_configured_engine();
  float out[64];

  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0); /* PLAYING, loop == 1.0 */
  drain(e);

  /* Unity by default: the loop plays back untouched and the snapshot agrees. */
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.master_gain - 1.0f) < 1e-6f);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.0f) < 1e-6f);

  /* Half gain halves the output and is published in the snapshot. */
  CHECK(le_engine_set_master_gain(e, 0.5f) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 0.5f) < 1e-6f);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.master_gain - 0.5f) < 1e-6f);

  /* Below 0 clamps to silence. */
  CHECK(le_engine_set_master_gain(e, -1.0f) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i]) < 1e-6f);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.master_gain) < 1e-6f);

  /* Above 1 clamps to unity. */
  CHECK(le_engine_set_master_gain(e, 2.0f) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.0f) < 1e-6f);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.master_gain - 1.0f) < 1e-6f);

  le_engine_destroy(e);
}

static void test_master_gain_rejects_null(void) {
  printf("test_master_gain_rejects_null\n");
  CHECK(le_engine_set_master_gain(NULL, 0.5f) == LE_ERR_INVALID);
}

static void test_master_gain_resets_on_configure(void) {
  printf("test_master_gain_resets_on_configure\n");
  le_engine* e = make_configured_engine();
  float out[8];

  CHECK(le_engine_set_master_gain(e, 0.3f) == LE_OK);
  drain(e); /* apply the ring command */
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.master_gain - 0.3f) < 1e-6f);

  /* A fresh configure (a new device session) returns the gain to unity. */
  le_engine_configure(e, 48000, 1, 1, 1000);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.master_gain - 1.0f) < 1e-6f);

  le_engine_destroy(e);
}

/* le_engine_note_xrun (the device backend's overload hook) tallies into the
 * published snapshot, and a fresh configure resets the per-session count. */
static void test_xrun_count_tallies_and_resets(void) {
  printf("test_xrun_count_tallies_and_resets\n");
  le_engine* e = make_configured_engine();
  le_snapshot s;

  le_engine_get_snapshot(e, &s);
  CHECK(s.xrun_count == 0); /* none yet */

  le_engine_note_xrun(e);
  le_engine_note_xrun(e);
  le_engine_note_xrun(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.xrun_count == 3);

  le_engine_note_xrun(NULL); /* must not crash */
  le_engine_get_snapshot(e, &s);
  CHECK(s.xrun_count == 3);

  /* A fresh configure (a new device session) clears the tally. */
  le_engine_configure(e, 48000, 1, 1, 1000);
  le_engine_get_snapshot(e, &s);
  CHECK(s.xrun_count == 0);

  le_engine_destroy(e);
}

/* le_engine_mark_device_lost (the ASIO reset / sample-rate-change hook) flips
 * device_present to 0 while leaving running set — the "running-but-disconnected"
 * state the control layer reads to drive reconnection. */
static void test_device_lost_keeps_running(void) {
  printf("test_device_lost_keeps_running\n");
  le_engine* e = make_configured_engine();
  le_snapshot s;

  le_engine_mark_started(e); /* device present + running */
  le_engine_get_snapshot(e, &s);
  CHECK(s.device_present == 1);
  CHECK(s.running == 1);

  le_engine_mark_device_lost(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.device_present == 0); /* lost ... */
  CHECK(s.running == 1);        /* ... but still running, awaiting reconnect */

  le_engine_mark_device_lost(NULL); /* must not crash */

  le_engine_destroy(e);
}

/* Exercises the master_bus_frame RT step in isolation (the limiter dynamics):
 * below the ceiling it is bit-transparent; above it, instant attack pins the
 * frame to the ceiling; master gain is applied before the limiter and metering. */
static void test_master_bus_frame_limiter(void) {
  printf("test_master_bus_frame_limiter\n");
  le_engine* e = make_configured_engine(); /* configure seeds lim_gain = 1.0 */
  float out[2];
  float sumsq;
  float peak;

  /* Below the ceiling: unity gain, nothing to limit -> output unchanged. */
  out[0] = 0.5f;
  out[1] = -0.5f;
  sumsq = 0.0f;
  peak = 0.0f;
  le_engine_master_bus_frame_for_test(e, out, 0, 2, 1.0f, 1, 0.99f, 0.001f,
                                      &sumsq, &peak);
  CHECK(fabsf(out[0] - 0.5f) < 1e-6f);
  CHECK(fabsf(out[1] + 0.5f) < 1e-6f);
  CHECK(fabsf(peak - 0.5f) < 1e-6f); /* metering reads the output */

  /* Above the ceiling: instant attack clamps this very frame, no overshoot. */
  out[0] = 2.0f;
  out[1] = 0.0f;
  sumsq = 0.0f;
  peak = 0.0f;
  le_engine_master_bus_frame_for_test(e, out, 0, 2, 1.0f, 1, 0.99f, 0.001f,
                                      &sumsq, &peak);
  CHECK(out[0] <= 0.99f + 1e-4f);
  CHECK(peak <= 0.99f + 1e-4f);

  /* Master gain is applied before the limiter / metering (limiter off here). */
  out[0] = 1.0f;
  out[1] = 1.0f;
  sumsq = 0.0f;
  peak = 0.0f;
  le_engine_master_bus_frame_for_test(e, out, 0, 2, 0.5f, 0, 0.99f, 0.001f,
                                      &sumsq, &peak);
  CHECK(fabsf(out[0] - 0.5f) < 1e-6f);

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

/* Feeds `count` frames of constant `value` through the engine in 64-frame
 * chunks. When `cap` is non-NULL the per-frame output is appended into it,
 * advancing *capn; pass cap=NULL/capn=NULL to discard. */
static void feed_const(le_engine* e, float value, int count, float* cap,
                       int* capn) {
  float in[64];
  float out[64];
  int left = count;
  while (left > 0) {
    const int n = left < 64 ? left : 64;
    for (int i = 0; i < n; ++i) in[i] = value;
    le_engine_process(e, out, in, (uint32_t)n);
    if (cap != NULL) {
      for (int i = 0; i < n; ++i) cap[(*capn)++] = out[i];
    }
    left -= n;
  }
}

/* Overdub punch-in/punch-out must not bake a step discontinuity (a click) into
 * the loop buffer. A real-length loop (long enough to host the ~10 ms declick
 * fade) is overdubbed with a constant level over half a pass and then punched
 * out while the input is still live; the recorded loop must ramp the layer in
 * and out smoothly — no large sample-to-sample jump anywhere, including the
 * loop seam — while still reaching the full overdub level in the steady middle. */
static void test_overdub_punch_no_click(void) {
  printf("test_overdub_punch_no_click\n");
  /* A real-length loop: cap must exceed N (make_configured_engine caps at 1000,
   * which would auto-finalize the master mid-feed). 48k: declick fade == 480. */
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 48000);
  const int N = 2000; /* > 2*480, so the fade engages */

  /* Silent base loop of N frames. The defining record finalizes only on the
   * second press (cap is well above N); at this length it defers ~10 ms to
   * capture the seam-crossfade overlap, so feed a little past the press to let
   * the finalize complete. Master is exactly N frames (length preserved). */
  le_engine_record(e, 0);
  feed_const(e, 0.0f, N, NULL, NULL);
  le_engine_record(e, 0);
  feed_const(e, 0.0f, 512, NULL, NULL); /* > seam overlap (480 @ 48k) */
  drain(e);

  /* Punch in, overdub a constant 0.8 over half the loop, punch out — but keep
   * feeding 0.8 (the player is still strumming) so the fade-out tail has live
   * input to taper, then ride out the rest of the loop. */
  le_engine_record(e, 0); /* -> OVERDUBBING */
  feed_const(e, 0.8f, N / 2, NULL, NULL);
  le_engine_record(e, 0); /* punch out -> PLAYING (fade-out tail begins) */
  feed_const(e, 0.8f, N / 2, NULL, NULL);
  drain(e);

  /* Read the recorded loop back (silence in; od_gain settled to 0 -> pure read). */
  float loop[2000];
  int n = 0;
  feed_const(e, 0.0f, N, loop, &n);
  CHECK(n == N);

  /* No click: the largest single-sample jump (seam included) stays tiny — a
   * step would be ~0.8. The fade spreads 0.8 over ~480 frames (~0.0017/frame). */
  float max_delta = fabsf(loop[0] - loop[N - 1]); /* the loop seam */
  for (int i = 1; i < N; ++i) {
    const float d = fabsf(loop[i] - loop[i - 1]);
    if (d > max_delta) max_delta = d;
  }
  printf("  punch: max sample delta=%.4f\n", max_delta);
  CHECK(max_delta < 0.05f);

  /* The layer still reaches full level in the steady middle of the overdubbed
   * half (past the fade-in, before the punch-out). Find the loudest sample. */
  float peak = 0.0f;
  for (int i = 0; i < N; ++i) {
    if (fabsf(loop[i]) > peak) peak = fabsf(loop[i]);
  }
  CHECK(fabsf(peak - 0.8f) < 0.01f);

  le_engine_destroy(e);
}

/* The master limiter caps the output at its ceiling when the mix would exceed
 * it, is bit-transparent below the ceiling, and is fully bypassed when off. */
static void test_master_limiter_caps_and_transparent(void) {
  printf("test_master_limiter_caps_and_transparent\n");
  le_engine* e = make_configured_engine();
  float out[64];

  /* A loop that plays back at 0.8. */
  le_engine_record(e, 0);
  process_const(e, 0.8f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);

  /* Transparent: ceiling 0.99 > 0.8, so playback is unchanged. */
  le_engine_set_limiter(e, 1, 0.99f);
  drain(e);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 0.8f) < 1e-6f);

  /* Limiting: ceiling 0.5 < 0.8, so every sample is pinned to 0.5 (instant
   * attack — even the first frame, 0.8 * (0.5/0.8) == 0.5). */
  le_engine_set_limiter(e, 1, 0.5f);
  drain(e);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 0.5f) < 1e-4f);

  /* Off: full 0.8 passes again. */
  le_engine_set_limiter(e, 0, 0.5f);
  drain(e);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 0.8f) < 1e-6f);

  le_engine_destroy(e);
}

/* Overdub feedback < 1.0 scales the existing layer before summing the new input,
 * so a layer that would reach 2.0 under classic additive overdub lands lower. */
static void test_overdub_feedback_decays_layers(void) {
  printf("test_overdub_feedback_decays_layers\n");
  le_engine* e = make_configured_engine();
  float out[64];

  le_engine_set_overdub_feedback(e, 0.5f);
  drain(e);

  /* Base loop of 1.0. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);

  /* Overdub +1.0: the write head becomes 1.0 * 0.5 + 1.0 == 1.5, not 2.0. */
  le_engine_record(e, 0); /* -> OVERDUBBING */
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0); /* -> PLAYING */
  drain(e);

  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.5f) < 1e-6f);

  le_engine_destroy(e);
}

/* Feeds `count` frames of a rising ramp (frame k -> (start + k) * slope) through
 * the engine in 64-frame chunks, optionally capturing output (NULL to discard).
 * slope 0 feeds silence — handy for reading the loop back. */
static void feed_ramp(le_engine* e, int start, float slope, int count,
                      float* cap, int* capn) {
  float in[64];
  float out[64];
  int done = 0;
  while (done < count) {
    const int n = (count - done) < 64 ? (count - done) : 64;
    for (int i = 0; i < n; ++i) in[i] = (float)(start + done + i) * slope;
    le_engine_process(e, out, in, (uint32_t)n);
    if (cap != NULL) {
      for (int i = 0; i < n; ++i) cap[(*capn)++] = out[i];
    }
    done += n;
  }
}

/* A freshly recorded master loop must wrap without a click. Recording a rising
 * ramp leaves a hard seam (buf[N-1] ~ 0.8 -> buf[0] = 0); the deferred seam
 * crossfade folds the captured continuation into the head so the wrap is smooth,
 * while the loop length is preserved exactly (tempo/quantize unchanged). */
static void test_master_seam_crossfade_no_click(void) {
  printf("test_master_seam_crossfade_no_click\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 48000);
  const int N = 2000;              /* > 2*480, so the crossfade engages */
  const float s = 0.8f / (float)N; /* ramp slope: buf[i] == i*s, a hard seam */

  le_engine_record(e, 0);
  feed_ramp(e, 0, s, N, NULL, NULL); /* record [0, N) as a rising ramp */
  le_engine_record(e, 0);            /* finalize: defers to capture the overlap */
  feed_ramp(e, N, s, 600, NULL, NULL); /* continue the ramp past the loop point */
  drain(e);

  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  CHECK(snap.master_length_frames == N); /* length preserved exactly */

  float loop[2000];
  int n = 0;
  feed_ramp(e, 0, 0.0f, N, loop, &n); /* read the loop back (silence in) */
  CHECK(n == N);

  /* Every step, the seam (loop[0] vs loop[N-1]) included, stays tiny — the raw
   * ramp seam would jump ~0.8. Max-delta over the captured loop is rotation-
   * invariant, so it holds regardless of the readback's start phase. */
  float max_delta = fabsf(loop[0] - loop[N - 1]);
  for (int i = 1; i < N; ++i) {
    const float d = fabsf(loop[i] - loop[i - 1]);
    if (d > max_delta) max_delta = d;
  }
  printf("  seam: max sample delta=%.4f\n", max_delta);
  CHECK(max_delta < 0.05f);

  /* The recorded ramp survives (the loop was not silenced by the crossfade). */
  float peak = 0.0f;
  for (int i = 0; i < N; ++i) {
    if (fabsf(loop[i]) > peak) peak = fabsf(loop[i]);
  }
  CHECK(peak > 0.5f);

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

/* A fixed-multiple take that starts mid-loop wraps its write head into the
 * known final length (K*base): audio played after the loop top lands at its
 * heard phase at the head of the loop, instead of past K*base where finalize
 * would silently orphan it (recording a full base loop from mid-phase used to
 * play back only the pre-wrap half). */
static void test_fixed_multiple_mid_loop_take_keeps_wrap(void) {
  printf("test_fixed_multiple_mid_loop_take_keeps_wrap\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  /* Base loop (1.0), muted so track 1 is observed alone; force ×1 takes. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0); /* finalize */
  drain(e);
  le_engine_set_track_mute(e, 0, 1);
  CHECK(le_engine_set_default_multiple(e, 1) == LE_OK);
  drain(e);

  /* From mid-loop (pos 2), record exactly one base loop on track 1: 2.0 for
   * the pre-wrap half (pos 2,3), 3.0 past the loop top (pos 0,1). The forced
   * ×1 auto-finalizes at K*base and continues into overdub. */
  process_const(e, 0.0f, LOOP_N / 2, out);
  le_engine_record(e, 1);
  process_const(e, 2.0f, LOOP_N / 2, out);
  process_const(e, 3.0f, LOOP_N / 2, out);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_OVERDUBBING);
  CHECK(s.tracks[1].multiple == 1);
  CHECK(s.tracks[1].length_frames == LOOP_N);
  le_engine_record(e, 1); /* punch out -> PLAYING */
  drain(e);

  /* Align to the loop top, then read one loop: the wrapped half (3.0) at the
   * head, the pre-wrap half (2.0) at the tail — nothing lost. */
  process_const(e, 0.0f, LOOP_N / 2, out); /* pos 2,3 -> top */
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) {
    const float want = i < LOOP_N / 2 ? 3.0f : 2.0f;
    CHECK(fabsf(out[i] - want) < 1e-6f);
  }

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

/* A legacy multi-bit track input mask collapses to lane 0's single input
 * channel: the lowest valid bit. (Multi-input capture is now per-lane and
 * un-merged — see the multi-lane tests — not an average into one buffer.) */
static void test_routing_input_mask_collapses_to_lowest(void) {
  printf("test_routing_input_mask_collapses_to_lowest\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000); /* 2-in, 2-out */
  float out[64];
  le_snapshot s;

  CHECK(le_engine_set_input_mask(e, 0, 0x3) == LE_OK); /* inputs 0 and 1 */
  le_engine_record(e, 0);
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 2.0f; /* lowest selected bit -> lane 0 records this */
    in[i * 2 + 1] = 4.0f;
  }
  le_engine_process(e, out, in, LOOP_N);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].input_mask == 0x1u); /* collapsed to channel 0 */

  /* Lane 0 recorded channel 0 (2.0) cleanly — never an average — on outputs 0+1. */
  float zin[2 * LOOP_N] = {0};
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 2.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 2.0f) < 1e-6f);
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

/* Input-mask bits beyond the available input channels are dropped before the
 * mask collapses to lane 0's single input channel (the lowest valid bit). */
static void test_routing_input_mask_clamped(void) {
  printf("test_routing_input_mask_clamped\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000); /* 2-in */
  le_snapshot s;

  CHECK(le_engine_set_input_mask(e, 0, 0xF) == LE_OK); /* request 4 inputs */
  drain(e);
  le_engine_get_snapshot(e, &s);
  /* Bits 2,3 don't exist; the remaining 0x3 collapses to channel 0 (0x1). */
  CHECK(s.tracks[0].input_mask == 0x1u);

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
    /* miniaudio enumeration reports no per-device channel count, so
     * device_info_copy must zero these — never leak stack garbage as a count.
     * An ASIO probe fills them in (0 = unknown). */
    CHECK(devices[i].input_channels == 0);
    CHECK(devices[i].output_channels == 0);
  }

  count = -1;
  CHECK(le_enumerate_capture_devices(devices, MAXD, &count) == LE_OK);
  CHECK(count >= 0 && count <= MAXD);
  for (int32_t i = 0; i < count; ++i) {
    /* device_info_copy zero-inits the channel counts on the capture path too. */
    CHECK(devices[i].input_channels == 0);
    CHECK(devices[i].output_channels == 0);
  }

  /* Bad arguments are rejected without touching the output. */
  CHECK(le_enumerate_playback_devices(NULL, MAXD, &count) == LE_ERR_INVALID);
  CHECK(le_enumerate_playback_devices(devices, MAXD, NULL) == LE_ERR_INVALID);
  CHECK(le_enumerate_playback_devices(devices, 0, &count) == LE_ERR_INVALID);
  CHECK(le_enumerate_capture_devices(NULL, MAXD, &count) == LE_ERR_INVALID);
}

/* The device-id serializer (engine_platform.h) turns a backend id into a
 * printable token used to match a user-selected device back to its native id.
 * On the char-string backends (CoreAudio/ALSA/PulseAudio) it copies verbatim;
 * on Windows it converts the wchar endpoint string to UTF-8. The Windows
 * branch is the regression guard for the bug where reading the wchar id as a
 * narrow char* collapsed every device id to its first character (e.g. "{"),
 * making every device indistinguishable and crashing the device dropdown. */
static void test_device_id_to_str(void) {
  printf("test_device_id_to_str\n");
  ma_device_id id;
  char out[256];

  /* Zero capacity must never write. */
  out[0] = 'x';
  le_platform_device_id_to_str(&id, out, 0);
  CHECK(out[0] == 'x');

#if defined(_WIN32)
  /* Windows: the full wchar endpoint string survives as UTF-8, not truncated. */
  memset(&id, 0, sizeof(id));
  wcsncpy((wchar_t*)&id, L"{0.0.1.00000000}.{abcd}",
          sizeof(id) / sizeof(wchar_t) - 1);
  le_platform_device_id_to_str(&id, out, sizeof(out));
  CHECK(strcmp(out, "{0.0.1.00000000}.{abcd}") == 0);
  CHECK(strlen(out) > 1); /* not collapsed to "{" */
#else
  /* char-string backends: the id is copied verbatim and round-trips. */
  memset(&id, 0, sizeof(id));
  strncpy((char*)&id, "hw:CARD=USB,DEV=0", sizeof(id) - 1);
  le_platform_device_id_to_str(&id, out, sizeof(out));
  CHECK(strcmp(out, "hw:CARD=USB,DEV=0") == 0);
#endif
}

/* ---- device-backend seam (ASIO Part 1) ---- */

/* le_select_backend resolves every backend choice to the miniaudio backend in
 * this build — including LE_BACKEND_ASIO, which has no implementation yet — and
 * the returned vtable is fully populated. This is the link-time guarantee that
 * the default build never depends on an ASIO symbol. */
static void test_select_backend_defaults_to_miniaudio(void) {
  printf("test_select_backend_defaults_to_miniaudio\n");
  const le_device_backend* miniaudio = le_select_backend(LE_BACKEND_MINIAUDIO);
  const le_device_backend* asio = le_select_backend(LE_BACKEND_ASIO);
  CHECK(miniaudio == &le_miniaudio_backend);
  CHECK(asio == &le_miniaudio_backend);
  /* An unknown/out-of-range choice still resolves to the miniaudio backend. */
  CHECK(le_select_backend(42) == &le_miniaudio_backend);
  /* The vtable is complete — no NULL function pointer the dispatcher could call. */
  CHECK(le_miniaudio_backend.open != NULL);
  CHECK(le_miniaudio_backend.start != NULL);
  CHECK(le_miniaudio_backend.stop != NULL);
  CHECK(le_miniaudio_backend.close != NULL);
}

/* The grown FFI structs default to the miniaudio path when zero-initialized
 * (le_config) and a fresh engine publishes active_backend == miniaudio in its
 * snapshot. Guards against the new fields ever defaulting to a non-zero / non-
 * miniaudio value that would silently change behavior. */
static void test_backend_struct_defaults(void) {
  printf("test_backend_struct_defaults\n");
  le_config cfg;
  memset(&cfg, 0, sizeof(cfg));
  CHECK(cfg.backend == LE_BACKEND_MINIAUDIO); /* 0 */
  CHECK(cfg.asio_driver[0] == '\0');

  le_engine* engine = le_engine_create();
  CHECK(engine != NULL);
  if (engine != NULL) {
    /* Configure without opening a device: the snapshot reports the negotiated
     * defaults, including the miniaudio active backend. */
    CHECK(le_engine_configure(engine, 48000, 2, 2, 48000) == LE_OK);
    le_snapshot snap;
    memset(&snap, 0, sizeof(snap));
    le_engine_get_snapshot(engine, &snap);
    CHECK(snap.active_backend == LE_BACKEND_MINIAUDIO);
    le_engine_destroy(engine);
  }
}

/* ---- ASIO bridge math (Part 2): pure de-interleave / convert / buffer-pick,
 * the riskiest unit of the ASIO backend, tested off-thread without hardware. */

/* f32 survives interleave_out -> deinterleave_in exactly (no quantization). */
static void test_bridge_roundtrip_f32(void) {
  printf("test_bridge_roundtrip_f32\n");
  const int cc = 3, frames = 5, chan = 1;
  const float vals[5] = {0.0f, 0.5f, -0.5f, 0.999f, -1.0f};
  float interleaved[3 * 5];
  memset(interleaved, 0, sizeof(interleaved));
  for (int f = 0; f < frames; ++f) interleaved[f * cc + chan] = vals[f];

  unsigned char native[5 * 4];
  le_interleave_out(native, interleaved, LE_SMP_F32, chan, cc, frames);

  float back[3 * 5];
  memset(back, 0, sizeof(back));
  le_deinterleave_in(back, native, LE_SMP_F32, chan, cc, frames);
  for (int f = 0; f < frames; ++f) CHECK(back[f * cc + chan] == vals[f]);
}

/* Known Int32LSB byte patterns <-> f32, little-endian, round-tripping the bytes. */
static void test_bridge_convert_int32(void) {
  printf("test_bridge_convert_int32\n");
  const unsigned char native[2 * 4] = {
      0x00, 0x00, 0x00, 0x40, /* +2^30 -> +0.5 */
      0x00, 0x00, 0x00, 0xC0, /* -2^30 -> -0.5 */
  };
  float out[2] = {0, 0};
  le_deinterleave_in(out, native, LE_SMP_I32, 0, 1, 2);
  CHECK(fabsf(out[0] - 0.5f) < 1e-6f);
  CHECK(fabsf(out[1] + 0.5f) < 1e-6f);

  unsigned char enc[2 * 4];
  memset(enc, 0xAB, sizeof(enc));
  le_interleave_out(enc, out, LE_SMP_I32, 0, 1, 2);
  for (int i = 0; i < 8; ++i) CHECK(enc[i] == native[i]);
}

/* Known Int24LSB (3 bytes/sample) patterns, including sign-extension. */
static void test_bridge_convert_int24(void) {
  printf("test_bridge_convert_int24\n");
  const unsigned char native[2 * 3] = {
      0x00, 0x00, 0x40, /* +2^22 -> +0.5 */
      0x00, 0x00, 0xC0, /* -2^22 -> -0.5 (sign bit set, must sign-extend) */
  };
  float out[2] = {0, 0};
  le_deinterleave_in(out, native, LE_SMP_I24, 0, 1, 2);
  CHECK(fabsf(out[0] - 0.5f) < 1e-6f);
  CHECK(fabsf(out[1] + 0.5f) < 1e-6f);

  unsigned char enc[2 * 3];
  memset(enc, 0xAB, sizeof(enc));
  le_interleave_out(enc, out, LE_SMP_I24, 0, 1, 2);
  for (int i = 0; i < 6; ++i) CHECK(enc[i] == native[i]);
}

/* Known Int16LSB patterns. */
static void test_bridge_convert_int16(void) {
  printf("test_bridge_convert_int16\n");
  const unsigned char native[2 * 2] = {
      0x00, 0x40, /* +2^14 -> +0.5 */
      0x00, 0xC0, /* -2^14 -> -0.5 */
  };
  float out[2] = {0, 0};
  le_deinterleave_in(out, native, LE_SMP_I16, 0, 1, 2);
  CHECK(fabsf(out[0] - 0.5f) < 1e-6f);
  CHECK(fabsf(out[1] + 0.5f) < 1e-6f);

  unsigned char enc[2 * 2];
  memset(enc, 0xAB, sizeof(enc));
  le_interleave_out(enc, out, LE_SMP_I16, 0, 1, 2);
  for (int i = 0; i < 4; ++i) CHECK(enc[i] == native[i]);
}

/* Each per-channel native block lands at the right interleaved positions, and
 * gathering one channel back reads exactly that channel's samples. */
static void test_bridge_channel_scatter_gather(void) {
  printf("test_bridge_channel_scatter_gather\n");
  const int cc = 3, frames = 2;
  const float ch0[2] = {0.1f, 0.2f};
  const float ch1[2] = {0.3f, 0.4f};
  const float ch2[2] = {0.5f, 0.6f};
  float inter[3 * 2];
  memset(inter, 0, sizeof(inter));
  le_deinterleave_in(inter, ch0, LE_SMP_F32, 0, cc, frames);
  le_deinterleave_in(inter, ch1, LE_SMP_F32, 1, cc, frames);
  le_deinterleave_in(inter, ch2, LE_SMP_F32, 2, cc, frames);
  CHECK(inter[0 * cc + 0] == 0.1f);
  CHECK(inter[0 * cc + 1] == 0.3f);
  CHECK(inter[0 * cc + 2] == 0.5f);
  CHECK(inter[1 * cc + 0] == 0.2f);
  CHECK(inter[1 * cc + 1] == 0.4f);
  CHECK(inter[1 * cc + 2] == 0.6f);

  float gathered[2] = {0, 0};
  le_interleave_out(gathered, inter, LE_SMP_F32, 1, cc, frames);
  CHECK(gathered[0] == 0.3f);
  CHECK(gathered[1] == 0.4f);

  /* Out-of-range / null channel arguments are no-ops (never write OOB). */
  float untouched[2] = {7.0f, 7.0f};
  le_deinterleave_in(untouched, ch0, LE_SMP_F32, 5, cc, frames);
  CHECK(untouched[0] == 7.0f);

  /* Integer formats use the format's byte stride (not f32's): a 2-channel
   * Int32 block written at chan 1 lands at the right interleaved positions. */
  const unsigned char i32_block[2 * 4] = {
      0x00, 0x00, 0x00, 0x40, /* +0.5 */
      0x00, 0x00, 0x00, 0xC0, /* -0.5 */
  };
  float i_inter[2 * 2];
  memset(i_inter, 0, sizeof(i_inter));
  le_deinterleave_in(i_inter, i32_block, LE_SMP_I32, 1, 2, 2);
  CHECK(i_inter[0 * 2 + 0] == 0.0f); /* chan 0 untouched */
  CHECK(fabsf(i_inter[0 * 2 + 1] - 0.5f) < 1e-6f);
  CHECK(fabsf(i_inter[1 * 2 + 1] + 0.5f) < 1e-6f);
}

/* le_asio_pick_buffer snaps a requested size to a driver-allowed one across all
 * three granularity modes; an un-honorable request falls back to `preferred`. */
static void test_asio_pick_buffer(void) {
  printf("test_asio_pick_buffer\n");
  /* Fixed driver (granularity 0): always `preferred`. */
  CHECK(le_asio_pick_buffer(256, 64, 1024, 512, 0) == 512);
  CHECK(le_asio_pick_buffer(99999, 64, 1024, 512, 0) == 512);

  /* Powers of two (granularity -1): nearest pow2 in [min,max]. */
  CHECK(le_asio_pick_buffer(256, 64, 2048, 512, -1) == 256);
  CHECK(le_asio_pick_buffer(300, 64, 2048, 512, -1) == 256);
  CHECK(le_asio_pick_buffer(400, 64, 2048, 512, -1) == 512);
  CHECK(le_asio_pick_buffer(64, 64, 2048, 512, -1) == 64);
  CHECK(le_asio_pick_buffer(2048, 64, 2048, 512, -1) == 2048);

  /* Linear steps (granularity 32): nearest min + k*32. */
  CHECK(le_asio_pick_buffer(100, 64, 1024, 256, 32) == 96);
  CHECK(le_asio_pick_buffer(112, 64, 1024, 256, 32) == 128);
  CHECK(le_asio_pick_buffer(64, 64, 1024, 256, 32) == 64);

  /* A request outside [min,max] -> preferred, for every mode. */
  CHECK(le_asio_pick_buffer(32, 64, 1024, 256, 32) == 256);
  CHECK(le_asio_pick_buffer(5000, 64, 1024, 256, 32) == 256);
  CHECK(le_asio_pick_buffer(5000, 64, 2048, 512, -1) == 512);
  /* Powers of two with NO power of two inside [min,max] -> preferred. */
  CHECK(le_asio_pick_buffer(110, 100, 120, 256, -1) == 256);
}

/* The default (non-ASIO) build's enumeration stub: always empty, never errors,
 * and rejects bad arguments. (An ASIO build replaces this with the real probe.) */
static void test_enumerate_asio_drivers_stub(void) {
  printf("test_enumerate_asio_drivers_stub\n");
  le_device_info out[8];
  int32_t count = -1;
  CHECK(le_enumerate_asio_drivers(out, 8, &count) == LE_OK);
  CHECK(count == 0);
  CHECK(le_enumerate_asio_drivers(NULL, 8, &count) == LE_ERR_INVALID);
  CHECK(le_enumerate_asio_drivers(out, 0, &count) == LE_ERR_INVALID);
  CHECK(le_enumerate_asio_drivers(out, 8, NULL) == LE_ERR_INVALID);
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

/* Fake per-channel name provider for the mask test: `ctx` is a NULL-terminable
 * array of channel labels indexed by channel. */
static const char* fake_channel_name(void* ctx, int channel) {
  const char* const* names = (const char* const*)ctx;
  return names[channel];
}

/* le_excluded_mask_from_names is the platform-agnostic bit-setting core every
 * label probe (Core Audio today, ASIO on Windows behind LOOPY_ENABLE_ASIO)
 * shares; only the name source is OS-specific. This exercises it with a fake
 * provider so the masking logic is covered without any OS calls. */
static void test_excluded_mask_from_names(void) {
  printf("test_excluded_mask_from_names\n");
  /* ch0 Input(no), ch1 Input(no), ch2 "Loopback 1"(yes), ch3 "Loop 2"(yes,
   * Focusrite naming), ch4 NULL(no), ch5 Mic(no). */
  const char* names[] = {"Input 1",    "Input 2", "Loopback 1",
                         "Loop 2", NULL,      "Microphone"};
  CHECK(le_excluded_mask_from_names(fake_channel_name, names, 6) ==
        ((1u << 2) | (1u << 3)));
  /* channel_count clamps which channels are inspected. */
  CHECK(le_excluded_mask_from_names(fake_channel_name, names, 2) == 0);
  CHECK(le_excluded_mask_from_names(fake_channel_name, names, 3) == (1u << 2));
  /* Defensive: NULL provider and non-positive counts yield no bits. */
  CHECK(le_excluded_mask_from_names(NULL, names, 6) == 0);
  CHECK(le_excluded_mask_from_names(fake_channel_name, names, 0) == 0);
  CHECK(le_excluded_mask_from_names(fake_channel_name, names, -1) == 0);
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

/* The round-trip latency harness captures the input envelope over a fixed
 * window and cross-correlates it with the pulse to find the round-trip by the
 * correlation peak. It uses the loopback channel(s) when the interface exposes
 * them, and ignores the real inputs. */
static void test_loopback_latency_uses_loopback_channel(void) {
  printf("test_loopback_latency_uses_loopback_channel\n");
  enum { SR = 48000, RET = 150, PULSE = SR / 100, CAP = SR / 10 };
  le_snapshot s;
  float* out = calloc((size_t)CAP * 2, sizeof(float));
  float* in = calloc((size_t)CAP * 2, sizeof(float));
  CHECK(out != NULL && in != NULL);

  // ch1 is the loopback; the looped-back pulse returns there as a PULSE-length
  // plateau starting at frame RET. ch0 (a real input) stays silent. Processing
  // a full capture window resolves the measurement by correlation peak = RET.
  le_engine* e = le_engine_create();
  le_engine_configure(e, SR, 2, 2, 100000);
  le_engine_set_excluded_input_mask_for_test(e, 0x2u);
  CHECK(le_engine_begin_latency_for_test(e) == LE_OK);
  drain(e); // apply MEASURE_LATENCY
  for (int i = 0; i < CAP; ++i) {
    in[i * 2 + 0] = 0.0f;
    in[i * 2 + 1] = (i >= RET && i < RET + PULSE) ? 0.5f : 0.0f;
  }
  le_engine_process(e, out, in, CAP);
  le_engine_get_snapshot(e, &s);
  CHECK(s.latency_state == LE_LATENCY_DONE);
  CHECK(s.record_offset_frames >= RET && s.record_offset_frames <= RET + 2);
  le_engine_destroy(e);

  // Control: the same pulse on a real input (ch0) must NOT be mistaken for the
  // loopback return — the loopback channel stays silent, so there is no signal.
  le_engine* e2 = le_engine_create();
  le_engine_configure(e2, SR, 2, 2, 100000);
  le_engine_set_excluded_input_mask_for_test(e2, 0x2u);
  le_engine_begin_latency_for_test(e2);
  drain(e2);
  for (int i = 0; i < CAP; ++i) {
    in[i * 2 + 0] = (i >= RET && i < RET + PULSE) ? 0.5f : 0.0f;
    in[i * 2 + 1] = 0.0f;
  }
  le_engine_process(e2, out, in, CAP);
  le_engine_get_snapshot(e2, &s);
  CHECK(s.latency_state == LE_LATENCY_TIMEOUT); // nothing on the loopback channel
  le_engine_destroy(e2);

  free(out);
  free(in);
}

/* The correlator is level-independent (peak vs baseline ratio), so a weak echo
 * still resolves; pure silence reports a timeout rather than locking onto noise. */
static void test_loopback_latency_weak_echo_and_silence(void) {
  printf("test_loopback_latency_weak_echo_and_silence\n");
  enum { SR = 48000, RET = 150, PULSE = SR / 100, CAP = SR / 10 };
  le_snapshot s;
  float* out = calloc((size_t)CAP * 2, sizeof(float));
  float* in = calloc((size_t)CAP * 2, sizeof(float));
  CHECK(out != NULL && in != NULL);

  /* A faint (-34 dBFS) plateau on the loopback channel still resolves to RET. */
  le_engine* e = le_engine_create();
  le_engine_configure(e, SR, 2, 2, 100000);
  le_engine_set_excluded_input_mask_for_test(e, 0x2u);
  le_engine_begin_latency_for_test(e);
  drain(e);
  for (int i = 0; i < CAP; ++i) {
    in[i * 2 + 0] = 0.0f;
    in[i * 2 + 1] = (i >= RET && i < RET + PULSE) ? 0.02f : 0.0f;
  }
  le_engine_process(e, out, in, CAP);
  le_engine_get_snapshot(e, &s);
  CHECK(s.latency_state == LE_LATENCY_DONE);
  CHECK(s.record_offset_frames >= RET && s.record_offset_frames <= RET + 2);
  le_engine_destroy(e);

  /* Pure silence -> timeout, not a spurious lock. */
  le_engine* e2 = le_engine_create();
  le_engine_configure(e2, SR, 2, 2, 100000);
  le_engine_set_excluded_input_mask_for_test(e2, 0x2u);
  le_engine_begin_latency_for_test(e2);
  drain(e2);
  for (int i = 0; i < CAP * 2; ++i) in[i] = 0.0f;
  le_engine_process(e2, out, in, CAP);
  le_engine_get_snapshot(e2, &s);
  CHECK(s.latency_state == LE_LATENCY_TIMEOUT);
  le_engine_destroy(e2);

  free(out);
  free(in);
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

/* Arming an overdub creates no undo layer (layers are captured per pass once
 * the overdub actually runs), so an arm/disarm round trip leaves the undo
 * stack untouched — no phantom layer to reverse. */
static void test_quantize_overdub_arm_disarm_no_phantom_layer(void) {
  printf("test_quantize_overdub_arm_disarm_no_phantom_layer\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  establish_master(e, out); /* track 0 PLAYING, length LOOP_N */
  le_engine_set_quantize(e, 1);
  process_const(e, 0.0f, 1, out); /* pos -> 1 */

  le_engine_record(e, 0); /* arm overdub: no snapshot, no layer */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING); /* armed, not overdubbing */
  CHECK(s.tracks[0].undo_depth == 0);

  le_engine_record(e, 0); /* second press -> disarm */
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

/* A hardware input's single monitor chain routes its live signal through its
 * effect chain to the outputs its mask selects, independent of any track. */
static void test_monitor_single_chain(void) {
  printf("test_monitor_single_chain\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000); /* 2-in, 2-out */
  float out[2 * LOOP_N];
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 1.0f; /* channel 0 */
    in[i * 2 + 1] = 9.0f; /* channel 1 (not monitored) */
  }

  /* Enable input 0, route to output 0 only, no effects: out 0 == 1.0, out 1
   * silent (input 1 is not monitored). An empty chain is the clean (dry) path. */
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 0x1) == LE_OK);
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1]) < 1e-6f);
  }

  /* Engage a unity drive on the chain: out 0 == tanh(1.0). */
  CHECK(le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_DRIVE) == LE_OK);
  le_engine_set_monitor_input_fx_param(e, 0, 0, 0, 0.0f); /* 1x pre-gain */
  le_engine_set_monitor_input_fx_param(e, 0, 0, 1, 1.0f); /* unity level */
  CHECK(le_engine_set_monitor_input_fx_count(e, 0, 1) == LE_OK);
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - tanhf(1.0f)) < 1e-5f);
  }

  le_engine_destroy(e);
}

/* A monitor's gain scales its chain; clamps to [0, 1]; invalid input rejected. */
static void test_monitor_volume(void) {
  printf("test_monitor_volume\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000); /* 2-in, 2-out */
  float out[2 * LOOP_N];
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 1.0f;
    in[i * 2 + 1] = 0.0f;
  }

  /* Input 0, clean to out 0: unity == 1.0. */
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 0x1) == LE_OK);
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);
  }

  /* Half volume scales the chain: 0.5. */
  CHECK(le_engine_set_monitor_input_volume(e, 0, 0.5f) == LE_OK);
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 0.5f) < 1e-6f);
  }

  /* Volume 0 silences it. */
  CHECK(le_engine_set_monitor_input_volume(e, 0, 0.0f) == LE_OK);
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0]) < 1e-6f);
  }

  /* Volume can boost to the +6 dB ceiling (LE_MAX_GAIN = 2.0): a const 1.0
   * input scales to 2.0. */
  CHECK(le_engine_set_monitor_input_volume(e, 0, 2.0f) == LE_OK);
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 2.0f) < 1e-6f);
  }

  /* Beyond the ceiling clamps to +6 dB (2.0); invalid args rejected. */
  CHECK(le_engine_set_monitor_input_volume(e, 0, 3.0f) == LE_OK); /* -> 2.0 */
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 2.0f) < 1e-6f);
  }
  CHECK(le_engine_set_monitor_input_volume(NULL, 0, 0.5f) == LE_ERR_INVALID);
  CHECK(le_engine_set_monitor_input_volume(e, -1, 0.5f) == LE_ERR_INVALID);
  CHECK(le_engine_set_monitor_input_volume(e, LE_MAX_INPUTS, 0.5f) ==
        LE_ERR_INVALID);

  le_engine_destroy(e);
}

/* Muting a monitor silences its chain; unmuting restores it. */
static void test_monitor_mute(void) {
  printf("test_monitor_mute\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000); /* 2-in, 2-out */
  float out[2 * LOOP_N];
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 1.0f;
    in[i * 2 + 1] = 0.0f;
  }

  /* Input 0, clean to out 0: 1.0. */
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 0x1) == LE_OK);
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);
  }

  /* Mute: silent. */
  CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0]) < 1e-6f);
  }

  /* Unmute: back to 1.0. */
  CHECK(le_engine_set_monitor_input_mute(e, 0, 0) == LE_OK);
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);
  }
  CHECK(le_engine_set_monitor_input_mute(e, -1, 1) == LE_ERR_INVALID);
  CHECK(le_engine_set_monitor_input_mute(e, LE_MAX_INPUTS, 1) == LE_ERR_INVALID);

  le_engine_destroy(e);
}

/* A latency measurement temporarily suppresses input monitoring (to break the
 * out->cable->in->monitor->out feedback loop during the pulse), then RESTORES
 * it when the measurement finishes — monitoring must resume, not stop forever. */
static void test_latency_restores_monitoring(void) {
  printf("test_latency_restores_monitoring\n");
  enum { SR = 48000, RET = 150, PULSE = SR / 100, CAP = SR / 10 };
  le_engine* e = le_engine_create();
  le_engine_configure(e, SR, 2, 2, 100000);
  le_engine_set_excluded_input_mask_for_test(e, 0x2u); /* ch1 = loopback */

  /* Enable monitoring of input 0 -> output 0, and apply it before measuring. */
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 0x1) == LE_OK);
  drain(e);

  /* Run a measurement to completion (the pulse returns on the loopback ch1). */
  CHECK(le_engine_begin_latency_for_test(e) == LE_OK);
  drain(e);
  float* out = calloc((size_t)CAP * 2, sizeof(float));
  float* in = calloc((size_t)CAP * 2, sizeof(float));
  CHECK(out != NULL && in != NULL);
  for (int i = 0; i < CAP; ++i) {
    in[i * 2 + 0] = 0.0f;
    in[i * 2 + 1] = (i >= RET && i < RET + PULSE) ? 0.5f : 0.0f;
  }
  le_engine_process(e, out, in, CAP);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.latency_state == LE_LATENCY_DONE);

  /* Monitoring must be active again: input 0 is audible on output 0. */
  float out2[2 * LOOP_N];
  float in2[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in2[i * 2 + 0] = 1.0f;
    in2[i * 2 + 1] = 0.0f;
  }
  le_engine_process(e, out2, in2, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out2[i * 2 + 0] - 1.0f) < 1e-6f);
  }

  free(out);
  free(in);
  le_engine_destroy(e);
}

/* A clean (no-FX) monitor chain is never printed into a recording: a track
 * records its raw input even while that input is being monitored clean. */
static void test_monitor_clean_chain_not_recorded(void) {
  printf("test_monitor_clean_chain_not_recorded\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000);
  float out[2 * LOOP_N];

  /* Monitor input 0 with a single clean chain to both outputs (no effects). */
  le_engine_set_monitor_input(e, 0, 1); /* defaults to full stereo */
  drain(e);

  /* Record input 0 (1.0) on track 0 while the clean lane is active. */
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 1.0f;
    in[i * 2 + 1] = 0.0f;
  }
  le_engine_record(e, 0);
  le_engine_process(e, out, in, LOOP_N);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);

  /* Playback over silence: the loop is the raw 1.0 (the clean lane added nothing
   * to the recording — it would read 2.0 if it had been printed in). */
  float zin[2 * LOOP_N] = {0};
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 1.0f) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* The monitored (effected) live signal is never printed into a recording: the
 * captured BUFFER stays dry even though the input is monitored through FX. And
 * because the engine no longer self-snapshots the monitor chain onto the lane
 * (the host owns the record-time snapshot), playback of a take the engine
 * recorded — with no host push — is DRY: the lane FX are whatever the host
 * pushed, nothing more. */
static void test_monitor_input_not_recorded(void) {
  printf("test_monitor_input_not_recorded\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000);
  float out[2 * LOOP_N];

  /* Monitor input 0 through a unity drive (distinct from the dry). */
  le_engine_set_monitor_input(e, 0, 1);
  le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_DRIVE);
  le_engine_set_monitor_input_fx_param(e, 0, 0, 0, 0.0f);
  le_engine_set_monitor_input_fx_param(e, 0, 0, 1, 1.0f);
  le_engine_set_monitor_input_fx_count(e, 0, 1);
  drain(e);

  /* Record input 0 (1.0) on track 0 while monitoring it. */
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 1.0f;
    in[i * 2 + 1] = 0.0f;
  }
  le_engine_record(e, 0);
  le_engine_process(e, out, in, LOOP_N);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);

  /* The recorded BUFFER is dry 1.0 (never wet-printed) — exported PCM proves it. */
  float pcm[LOOP_N];
  CHECK(le_engine_export_track(e, 0, pcm, LOOP_N) == LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - 1.0f) < 1e-6f);

  /* Playback is DRY 1.0: the engine performed no self-snapshot, so the lane has
   * no FX (the host would push the monitored chain — see the repository's
   * record-snapshot tests). */
  float zin[2 * LOOP_N] = {0};
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 1.0f) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* Two inputs monitored with different chains and outputs do not interfere. */
static void test_two_monitored_inputs_dont_interfere(void) {
  printf("test_two_monitored_inputs_dont_interfere\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000);
  float out[2 * LOOP_N];
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 1.0f;
    in[i * 2 + 1] = 2.0f;
  }

  /* Input 0 -> out 0 through a unity drive; input 1 -> out 1 clean. */
  le_engine_set_monitor_input(e, 0, 1);
  le_engine_set_monitor_input_output(e, 0, 0x1);
  le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_DRIVE);
  le_engine_set_monitor_input_fx_param(e, 0, 0, 0, 0.0f);
  le_engine_set_monitor_input_fx_param(e, 0, 0, 1, 1.0f);
  le_engine_set_monitor_input_fx_count(e, 0, 1);
  CHECK(le_engine_set_monitor_input(e, 1, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 1, 0x2) == LE_OK);
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - tanhf(1.0f)) < 1e-5f); /* in0 driven on out0 */
    CHECK(fabsf(out[i * 2 + 1] - 2.0f) < 1e-6f);        /* in1 dry on out1 */
  }

  le_engine_destroy(e);
}

/* Disabling a monitor stops it; a loopback-excluded input is never monitored
 * even when enabled. */
static void test_monitor_disable_and_excluded(void) {
  printf("test_monitor_disable_and_excluded\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000);
  float out[2 * LOOP_N];
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 1.0f;
    in[i * 2 + 1] = 0.0f;
  }

  /* Enabled: input 0 on both outputs (lane 0 defaults to full stereo). */
  le_engine_set_monitor_input(e, 0, 1);
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 1.0f) < 1e-6f);
  }

  /* Disabled: silent. */
  CHECK(le_engine_set_monitor_input(e, 0, 0) == LE_OK);
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0]) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1]) < 1e-6f);
  }

  /* Excluded channel 0: enabling it monitors nothing (it carries our output). */
  le_engine_set_excluded_input_mask_for_test(e, 0x1);
  le_engine_set_monitor_input(e, 0, 1);
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0]) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1]) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* The dual-route core: a live monitor and a playing loop sum on the same output
 * channel. A track plays its recorded loop while a different input is monitored
 * live, and both land additively on the shared outputs. */
static void test_monitor_and_playback_sum(void) {
  printf("test_monitor_and_playback_sum\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000); /* 2-in, 2-out */
  float out[2 * LOOP_N];

  /* Record track 0 (lane 0 records input 0) a 1.0 loop -> PLAYING on out 0+1. */
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 1.0f;
    in[i * 2 + 1] = 0.0f;
  }
  le_engine_record(e, 0);
  le_engine_process(e, out, in, LOOP_N);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);

  /* Monitor input 1 (live) to both outputs while the loop plays (lane 0
   * defaults to full stereo). */
  CHECK(le_engine_set_monitor_input(e, 1, 1) == LE_OK);

  /* Live input 1 = 2.0; input 0 silent (the loop is the source on out 0+1).
   * Each output = loop playback (1.0) + live monitor (2.0) = 3.0. */
  float mix_in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    mix_in[i * 2 + 0] = 0.0f;
    mix_in[i * 2 + 1] = 2.0f;
  }
  le_engine_process(e, out, mix_in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 3.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 3.0f) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* ---- performance recording (le_perf_arm / le_perf_disarm / perf_drain) ---- *
 * The control-thread ABI (engine_commands.c): addressing + error paths, and
 * the disarm fast path (a_running == 0, taken by every test below since this
 * suite never opens a device). The success + quiescent-handshake path (and
 * its LE_ERR_DEVICE stalled-callback branch) needs a running device callback
 * and is covered by manual/integration testing — the same scope note
 * test_plugin_slot.c's test_engine_abi_errors makes for the plugin-slot
 * quiescent handshake, which the perf-capture teardown mirrors. */

/* One shared scratch directory for every perf-capture test's drain files
 * *within this process*, under the system temp dir, qualified by PID so
 * concurrent invocations of this test binary (e.g. a developer running
 * locally while CI also runs) never collide. Reused rather than
 * unique-per-test within the process: every arm reopens its files with "wb"
 * (truncating), and every test calls le_engine_destroy before returning —
 * which joins any still-running drain thread (engine.c's teardown hook) — so
 * no test's files or thread can bleed into the next one's assertions. This
 * guarantee is process-scoped only: these tests must run sequentially within
 * one process (never `ctest -j` / a parallel test runner against this
 * binary), since two threads/processes sharing one PID-qualified directory
 * would still race each other. */
#if defined(_WIN32)
#include <process.h> /* _getpid */
#define test_getpid() _getpid()
#else
#include <unistd.h> /* getpid */
#define test_getpid() getpid()
#endif

static const char* perf_test_dir(void) {
  static char dir[512];
  static int initialized = 0;
  if (!initialized) {
    const char* tmp = getenv("TMPDIR");
    if (tmp == NULL || tmp[0] == '\0') tmp = "/tmp";
    /* PID-qualified: concurrent copies of this test binary (a re-run racing
     * a still-shutting-down previous one, or genuinely parallel CI jobs)
     * must never share a directory — every perf_drain test truncates
     * ("wb") and free-runs a real background thread against these files, so
     * a shared path across processes corrupts unrelated runs. */
    snprintf(dir, sizeof(dir), "%s/loopy_perf_test_%d", tmp,
            (int)test_getpid());
    initialized = 1;
  }
  return dir;
}

/* The drain thread flushes every ~250 ms (LE_PD_FLUSH_MS, perf_drain.c) on a
 * real background thread — the perf_drain tests below need to actually wait
 * for it rather than call it synchronously. */
#if defined(_WIN32)
#include <windows.h>
static void test_sleep_ms(int ms) { Sleep((DWORD)ms); }
#else
#include <time.h>
static void test_sleep_ms(int ms) {
  struct timespec ts = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&ts, NULL);
}
#endif

/* Reads up to `cap - 1` bytes of `path` into `out` and NUL-terminates it, for
 * substring-matching a hand-rolled sidecar (no JSON library in this tree — see
 * perf_drain.c). Returns the byte count read, or 0 if the file could not be
 * opened. */
static size_t read_file_for_test(const char* path, char* out, size_t cap) {
  FILE* f = fopen(path, "rb");
  if (f == NULL) return 0;
  const size_t n = fread(out, 1, cap - 1, f);
  fclose(f);
  out[n] = '\0';
  return n;
}

/* Polls a condition every 10 ms up to `timeout_ms`, rather than a fixed
 * sleep — deterministic regardless of how fast the drain thread's real
 * background scheduling actually runs (a fixed sleep only has as much
 * margin as its duration minus the flush cadence; a poll loop has none of
 * that risk and is normally much faster than the timeout in the common
 * case). Used only by the handful of perf_drain tests that need to observe
 * the drain thread's OWN background cycle rather than a call that already
 * blocks until it (le_perf_disarm, le_engine_configure). */
static int poll_drain_self_stopped_for_test(struct le_perf_drain* drain,
                                            int timeout_ms) {
  for (int waited = 0; waited < timeout_ms; waited += 10) {
    if (le_perf_drain_self_stopped_for_test(drain)) return 1;
    test_sleep_ms(10);
  }
  return le_perf_drain_self_stopped_for_test(drain);
}

static int poll_file_reaches_size_for_test(const char* path, long min_bytes,
                                           int timeout_ms) {
  for (int waited = 0; waited < timeout_ms; waited += 10) {
    FILE* f = fopen(path, "rb");
    if (f != NULL) {
      fseek(f, 0, SEEK_END);
      const long size = ftell(f);
      fclose(f);
      if (size >= min_bytes) return 1;
    }
    test_sleep_ms(10);
  }
  return 0;
}

/* ---- events.log test helpers (part 3, docs/design/performance-event-log-
 * format.md): a 12-byte header, then fixed 28-byte entries. Decoding mirrors
 * perf_drain.c's le_pd_write_log_entry exactly (frame, then code, then the
 * union's raw 16 bytes), so a round-trip through these helpers proves the
 * on-disk format, not just the in-memory ring. ---- */
#define LE_TEST_EVENTS_HEADER_BYTES 12
#define LE_TEST_EVENTS_ENTRY_BYTES 28

static size_t read_binary_file_for_test(const char* path, unsigned char* out,
                                        size_t cap) {
  FILE* f = fopen(path, "rb");
  if (f == NULL) return 0;
  const size_t n = fread(out, 1, cap, f);
  fclose(f);
  return n;
}

static void decode_log_entry(const unsigned char* raw, le_perf_log_entry* out) {
  memcpy(&out->frame, raw, sizeof(out->frame));
  memcpy(&out->cmd.code, raw + sizeof(out->frame), sizeof(out->cmd.code));
  memcpy(((char*)&out->cmd) + sizeof(out->cmd.code),
        raw + sizeof(out->frame) + sizeof(out->cmd.code),
        LE_TEST_EVENTS_ENTRY_BYTES - sizeof(out->frame) -
            sizeof(out->cmd.code));
}

/* Number of whole 28-byte entries in an events.log read of `n` bytes
 * (n must be >= the 12-byte header; entries start right after it). */
static size_t log_entry_count(size_t n) {
  if (n < LE_TEST_EVENTS_HEADER_BYTES) return 0;
  return (n - LE_TEST_EVENTS_HEADER_BYTES) / LE_TEST_EVENTS_ENTRY_BYTES;
}

static void decode_log_entry_at(const unsigned char* buf, size_t index,
                                le_perf_log_entry* out) {
  decode_log_entry(buf + LE_TEST_EVENTS_HEADER_BYTES +
                       index * LE_TEST_EVENTS_ENTRY_BYTES,
                   out);
}

/* Finds the first entry at or after `from` whose code matches; returns its
 * index, or -1 if none remain. */
static int find_log_entry(const unsigned char* buf, size_t count, int from,
                          int32_t code, le_perf_log_entry* out) {
  for (size_t i = (size_t)(from < 0 ? 0 : from); i < count; ++i) {
    decode_log_entry_at(buf, i, out);
    if (out->cmd.code == code) return (int)i;
  }
  return -1;
}

static void test_perf_arm_requires_configure(void) {
  printf("test_perf_arm_requires_configure\n");
  le_engine* e = le_engine_create();
  CHECK(le_perf_arm(e, perf_test_dir()) == LE_ERR_NOT_RUNNING); /* not configured yet */
  le_engine_configure(e, 48000, 1, 1, 100);
  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  le_engine_destroy(e);
}

/* A reconfigure while armed (le_engine_configure, always device-free here)
 * frees the perf rings and resets every perf atomic, rather than leaking the
 * old rings or leaving a stale armed flag behind — the device is closed
 * during configure, so this is a direct free, not the quiescent handshake. A
 * subsequent arm must work cleanly afterward (no double-free, no stale
 * pointer reuse). */
static void test_perf_reconfigure_while_armed_resets_cleanly(void) {
  printf("test_perf_reconfigure_while_armed_resets_cleanly\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 1000);

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.perf_armed == 1);

  /* Reconfigure while still armed. */
  CHECK(le_engine_configure(e, 48000, 1, 1, 1000) == LE_OK);
  le_engine_get_snapshot(e, &s);
  CHECK(s.perf_armed == 0);
  CHECK(s.perf_frames == 0);
  CHECK(s.perf_overruns == 0);

  /* A fresh arm afterward works cleanly (the old rings were actually freed,
   * not merely forgotten). */
  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.perf_armed == 1);

  le_engine_destroy(e);
}

static void test_perf_arm_rejects_no_enabled_output(void) {
  printf("test_perf_arm_rejects_no_enabled_output\n");
  le_engine* e = make_configured_engine(); /* mono in/out */
  CHECK(le_engine_set_output_enabled(e, 0, 0) == LE_OK); /* disable the only output */
  drain(e);
  CHECK(le_perf_arm(e, perf_test_dir()) == LE_ERR_INVALID); /* nothing to capture */
  le_engine_destroy(e);
}

/* When the drain thread fails to start (here: capture_dir names a plain FILE,
 * not a directory — le_pd_mkdir_recursive "succeeds" since something already
 * exists there (POSIX mkdir reports EEXIST regardless of type), but opening
 * master.pcm inside it then fails since it isn't actually a directory),
 * le_perf_arm returns LE_ERR_DEVICE and cleanly unwinds every ring it had
 * already allocated — proven by a subsequent successful arm at a real path,
 * which would fail loudly (a stale input_mask, a leaked ring) if the unwind
 * were incomplete. */
static void test_perf_arm_cleans_up_when_drain_thread_fails_to_start(void) {
  printf("test_perf_arm_cleans_up_when_drain_thread_fails_to_start\n");
  le_engine* e = make_configured_engine();

  char blocked_path[600];
  snprintf(blocked_path, sizeof(blocked_path), "%s_blocked_by_a_file",
          perf_test_dir());
  /* Ensure a clean slate: some other test run's directory of the same name
   * would make mkdir's EEXIST ambiguous with "it's actually a real dir". */
  remove(blocked_path);
  FILE* f = fopen(blocked_path, "wb");
  CHECK(f != NULL);
  if (f != NULL) fclose(f);

  CHECK(le_perf_arm(e, blocked_path) == LE_ERR_DEVICE);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.perf_armed == 0); /* never published: the arm never reached that point */

  /* A subsequent arm at a real directory works cleanly — proves the failed
   * attempt didn't leak a ring or leave stale input_mask/config behind. */
  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.perf_armed == 1);

  le_perf_disarm(e);
  remove(blocked_path);
  le_engine_destroy(e);
}

static void test_perf_null_safety(void) {
  printf("test_perf_null_safety\n");
  CHECK(le_perf_arm(NULL, perf_test_dir()) == LE_ERR_INVALID);
  CHECK(le_perf_disarm(NULL) == LE_ERR_INVALID);
}

/* A null or empty capture_dir is rejected before anything else — including
 * before the not-configured check, so an unconfigured engine with a bad path
 * still reports LE_ERR_INVALID, not LE_ERR_NOT_RUNNING. */
static void test_perf_arm_rejects_bad_capture_dir(void) {
  printf("test_perf_arm_rejects_bad_capture_dir\n");
  le_engine* e = make_configured_engine();
  CHECK(le_perf_arm(e, NULL) == LE_ERR_INVALID);
  CHECK(le_perf_arm(e, "") == LE_ERR_INVALID);
  le_engine_destroy(e);
}

/* A capture_dir that would not fit (with room for filenames like
 * "/master.pcm") is refused outright rather than silently truncated by the
 * internal snprintf into a directory the caller never asked for. */
static void test_perf_arm_rejects_capture_dir_too_long(void) {
  printf("test_perf_arm_rejects_capture_dir_too_long\n");
  le_engine* e = make_configured_engine();
  char huge[2048];
  memset(huge, 'a', sizeof(huge) - 1);
  huge[sizeof(huge) - 1] = '\0';
  CHECK(le_perf_arm(e, huge) == LE_ERR_DEVICE);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.perf_armed == 0);
  CHECK(e->perf.drain == NULL);
  le_engine_destroy(e);
}

/* Arm/disarm toggle the snapshot's perf_armed flag; both are idempotent, and a
 * disarm-then-rearm cycle actually frees and rebuilds the rings rather than
 * reusing stale state (perf_overruns resets to 0 on the fresh arm). Device-free
 * (a_running == 0), so le_perf_disarm's quiescent wait is skipped and teardown
 * is immediate. */
static void test_perf_arm_disarm_lifecycle(void) {
  printf("test_perf_arm_disarm_lifecycle\n");
  le_engine* e = make_configured_engine();

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.perf_armed == 0);
  CHECK(le_perf_disarm(e) == LE_OK); /* idempotent: never armed */

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e); /* apply LE_CMD_PERF_ARM */
  le_engine_get_snapshot(e, &s);
  CHECK(s.perf_armed == 1);
  CHECK(s.perf_frames == 0); /* nothing processed yet besides the 0-frame drain */

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK); /* idempotent: already armed */

  CHECK(le_perf_disarm(e) == LE_OK);
  drain(e); /* apply LE_CMD_PERF_DISARM */
  le_engine_get_snapshot(e, &s);
  CHECK(s.perf_armed == 0);
  CHECK(le_perf_disarm(e) == LE_OK); /* idempotent: already disarmed */

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK); /* re-arm after a clean disarm */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.perf_armed == 1);
  CHECK(s.perf_overruns == 0);

  le_engine_destroy(e);
}

/* Regression: a disarm that bails out on a stalled quiescent wait leaves the
 * OLD drain thread + rings alive even when a_perf_armed already reads 0 (the
 * audio thread can apply LE_CMD_PERF_DISARM promptly while the CONTROL
 * thread's own 2-boundary confirmation still times out — e.g. a huge buffer
 * size makes each boundary slow to reach even though the callback isn't
 * literally frozen; this harness has no real concurrent audio thread to
 * reproduce that exact race, so a_perf_armed is poked directly to reach the
 * same state le_perf_disarm's bailout leaves: armed cleared, drain thread
 * and rings untouched). A retry le_perf_arm must refuse — not silently
 * reallocate engine->perf.master_ring/monitor_ring in place while that old
 * thread is still popping from them. */
static void test_perf_arm_refuses_when_drain_thread_still_live(void) {
  printf("test_perf_arm_refuses_when_drain_thread_still_live\n");
  le_engine* e = make_configured_engine();

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  store_i32(&e->a_perf_armed, 0); /* the state a stalled-bailout disarm leaves */
  CHECK(e->perf.drain != NULL); /* the old session's thread/rings are still live */

  /* A retry must refuse, not orphan the still-live old session. */
  CHECK(le_perf_arm(e, perf_test_dir()) == LE_ERR_DEVICE);

  /* Recovery: once the session is actually torn down (a real disarm, which
   * clears perf.drain), a fresh arm works cleanly again. */
  store_i32(&e->a_perf_armed, 1); /* restore so le_perf_disarm doesn't no-op */
  CHECK(le_perf_disarm(e) == LE_OK);
  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  le_engine_destroy(e);
}

/* The master ring's contents are bit-identical to the processed (post-gain,
 * post-limiter) output for the same input — mono device. */
static void test_perf_master_tap_bit_identical_mono(void) {
  printf("test_perf_master_tap_bit_identical_mono\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 1000);

  le_engine_record(e, 0);
  float out[LOOP_N];
  process_const(e, 1.0f, LOOP_N, out); /* recording: not audible yet */
  le_engine_record(e, 0);              /* finalize -> PLAYING */
  drain(e);

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);
  CHECK(le_engine_perf_master_channels_for_test(e) == 1);

  float out2[LOOP_N];
  process_const(e, 0.0f, LOOP_N, out2); /* now playing the recorded 1.0 loop */
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out2[i] - 1.0f) < 1e-6f);

  float captured[LOOP_N];
  CHECK(le_engine_perf_master_pop_for_test(e, captured, LOOP_N) == LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(captured[i] == out2[i]);

  le_engine_destroy(e);
}

/* Stereo device: the tap runs post master-gain (and would run post-limiter,
 * were it engaged) — proving the capture point matches the doc'd "after
 * master_bus_frame" placement, not a pre-gain source. */
static void test_perf_master_tap_bit_identical_stereo_post_gain(void) {
  printf("test_perf_master_tap_bit_identical_stereo_post_gain\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 2, 1000); /* mono in, stereo out */

  le_engine_record(e, 0);
  float out[2 * LOOP_N];
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0); /* finalize -> PLAYING, lane 0 defaults to out 0+1 */
  drain(e);

  CHECK(le_engine_set_master_gain(e, 0.5f) == LE_OK);
  drain(e);

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);
  CHECK(le_engine_perf_master_channels_for_test(e) == 2);

  float out2[2 * LOOP_N];
  process_const(e, 0.0f, LOOP_N, out2);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out2[i * 2 + 0] - 0.5f) < 1e-6f);
    CHECK(fabsf(out2[i * 2 + 1] - 0.5f) < 1e-6f);
  }

  float captured[2 * LOOP_N];
  CHECK(le_engine_perf_master_pop_for_test(e, captured, LOOP_N) == LOOP_N);
  for (int i = 0; i < 2 * LOOP_N; ++i) CHECK(captured[i] == out2[i]);

  le_engine_destroy(e);
}

/* A monitor input active at arm is captured post-FX/post-volume, pre-route: the
 * ring holds the same stereo pair that would be summed into the mix, even
 * though only one output channel is actually routed. Input 1 (never
 * monitored) has no ring at all. */
static void test_perf_monitor_tap_matches_mix_contribution(void) {
  printf("test_perf_monitor_tap_matches_mix_contribution\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000); /* 2-in, 2-out */
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 1.0f; /* monitored + captured */
    in[i * 2 + 1] = 9.0f; /* neither monitored nor captured */
  }
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 0x1) == LE_OK); /* out 0 only */
  CHECK(le_engine_set_monitor_input_volume(e, 0, 0.5f) == LE_OK);
  drain(e);

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK); /* freezes input_mask = {0} */
  drain(e);

  float out[2 * LOOP_N];
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 0.5f) < 1e-6f); /* routed */
    CHECK(fabsf(out[i * 2 + 1]) < 1e-6f);        /* not routed */
  }

  /* The captured pair is (0.5, 0.5) — the pre-route stereo contribution — on
   * BOTH channels, even though only out 0 received it. */
  float captured[2 * LOOP_N];
  CHECK(le_engine_perf_monitor_pop_for_test(e, 0, captured, LOOP_N) == LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(captured[i * 2 + 0] - 0.5f) < 1e-6f);
    CHECK(fabsf(captured[i * 2 + 1] - 0.5f) < 1e-6f);
  }

  /* Input 1 was never monitored/captured: no ring for it. */
  CHECK(le_engine_perf_monitor_pop_for_test(e, 1, captured, LOOP_N) == 0);

  le_engine_destroy(e);
}

/* An input captured at arm keeps writing a time-aligned frame even while it is
 * currently muted (contributing nothing to the mix) — silence, not a gap —
 * so a later DAW export can line every captured track up against the master
 * on one shared timeline. */
static void test_perf_monitor_tap_pads_silence_when_muted(void) {
  printf("test_perf_monitor_tap_pads_silence_when_muted\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 1000);
  float in[LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) in[i] = 1.0f;
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 0x1) == LE_OK);
  drain(e);

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK); /* mute after arm */
  drain(e);

  float out[LOOP_N];
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i]) < 1e-6f); /* silent out */

  float captured[2 * LOOP_N];
  CHECK(le_engine_perf_monitor_pop_for_test(e, 0, captured, LOOP_N) == LOOP_N);
  for (int i = 0; i < 2 * LOOP_N; ++i) CHECK(captured[i] == 0.0f);

  le_engine_destroy(e);
}

/* Same silence-padding guarantee as the muted case above, but for the OTHER
 * `!mon_on[c]` branch condition: the input disabled outright (rather than
 * muted) after arm. Both paths share one `if (!mon_on[c] || mon_mut[c])`
 * guard in mix_monitors_frame, so this pins the disabled half of it too. */
static void test_perf_monitor_tap_pads_silence_when_disabled(void) {
  printf("test_perf_monitor_tap_pads_silence_when_disabled\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 1000);
  float in[LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) in[i] = 1.0f;
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 0x1) == LE_OK);
  drain(e);

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  CHECK(le_engine_set_monitor_input(e, 0, 0) == LE_OK); /* disable after arm */
  drain(e);

  float out[LOOP_N];
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i]) < 1e-6f); /* silent out */

  float captured[2 * LOOP_N];
  CHECK(le_engine_perf_monitor_pop_for_test(e, 0, captured, LOOP_N) == LOOP_N);
  for (int i = 0; i < 2 * LOOP_N; ++i) CHECK(captured[i] == 0.0f);

  le_engine_destroy(e);
}

/* On a full ring the audio thread drops the whole frame and increments the
 * shared overrun atomic; it never blocks. A tiny sample rate yields a tiny
 * (deterministic) ring capacity so the overflow is exactly reproducible: mono
 * capacity = next_pow2(1 * 4 * LE_PERF_CAPTURE_SECONDS) = 8 samples, 7 usable. */
static void test_perf_overflow_counts_and_drops(void) {
  printf("test_perf_overflow_counts_and_drops\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 4, 1, 1, 1000); /* tiny sample rate -> tiny ring */

  le_engine_record(e, 0);
  float out[LOOP_N];
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  float big_out[32];
  process_const(e, 0.0f, 32, big_out); /* far more frames than the ring holds */

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.perf_frames == 32);      /* elapsed frames counted regardless of drops */
  CHECK(s.perf_overruns == 32 - 7); /* only the first 7 fit */

  le_engine_destroy(e);
}

/* Regression: perf_frames advances even across a concurrent latency
 * measurement, whose harness diverts every frame in the capture window
 * (process_input_frame's `continue`) before the master tap would otherwise
 * run. Counted once per le_engine_process call (batched with a_frames, not a
 * per-frame atomic add), so it reads as wall-clock frames since arm, not
 * "frames the master tap actually saw". */
static void test_perf_frames_advance_during_latency_measurement(void) {
  printf("test_perf_frames_advance_during_latency_measurement\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 1000); /* lat_buf_cap = 48000/10 = 4800 */

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  CHECK(le_engine_begin_latency_for_test(e) == LE_OK);
  drain(e);

  enum { CAP = 480 }; /* well inside the ~4800-frame capture window */
  float out[CAP];
  float in[CAP] = {0};
  le_engine_process(e, out, in, CAP);

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.latency_state == LE_LATENCY_MEASURING); /* harness still owns every frame */
  CHECK(s.perf_frames == CAP); /* still counted, not stalled by the harness */

  le_engine_destroy(e);
}

/* ---- perf_drain: the capture-to-disk background thread ---- */

/* Drained master.pcm is byte-identical to the processed output for the same
 * input. Disarms BEFORE reading the file rather than sleeping past a flush
 * cycle: le_perf_disarm blocks on joining the drain thread, which runs its
 * own final drain-and-flush pass first — a hard synchronization guarantee,
 * not a timing guess, so this can never flake under scheduling pressure. */
static void test_perf_drain_writes_master_pcm_byte_identical(void) {
  printf("test_perf_drain_writes_master_pcm_byte_identical\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 1000);

  le_engine_record(e, 0);
  float out[LOOP_N];
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  float out2[LOOP_N];
  process_const(e, 0.0f, LOOP_N, out2); /* now playing the recorded 1.0 loop */
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out2[i] - 1.0f) < 1e-6f);

  CHECK(le_perf_disarm(e) == LE_OK); /* blocks until the final flush completes */

  char path[600];
  snprintf(path, sizeof(path), "%s/master.pcm", perf_test_dir());
  FILE* f = fopen(path, "rb");
  CHECK(f != NULL);
  if (f != NULL) {
    float captured[LOOP_N];
    const size_t n = fread(captured, sizeof(float), LOOP_N, f);
    fclose(f);
    CHECK(n == LOOP_N);
    for (int i = 0; i < LOOP_N; ++i) CHECK(captured[i] == out2[i]);
  }

  le_engine_destroy(e);
}

/* A ring overrun (tiny ring capacity via a tiny sample rate, mirroring
 * test_perf_overflow_counts_and_drops) leaves the drain thread's file behind
 * wall-clock elapsed frames; it silence-fills the gap so the file stays
 * sample-consistent and records the gap in the sidecar. */
static void test_perf_drain_silence_fills_overrun_gap(void) {
  printf("test_perf_drain_silence_fills_overrun_gap\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 4, 1, 1, 1000); /* tiny rate -> tiny ring, 7 usable frames */

  le_engine_record(e, 0);
  float out[LOOP_N];
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  float big_out[32];
  process_const(e, 0.0f, 32, big_out); /* 7 pushes succeed, 25 drop (overrun) */

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.perf_frames == 32);
  CHECK(s.perf_overruns == 32 - 7);

  /* Disarm (blocks until the final flush, which does the same catch-up
   * logic as any other cycle) rather than sleeping past one — a hard
   * synchronization guarantee instead of a timing guess. */
  CHECK(le_perf_disarm(e) == LE_OK);

  char path[600];
  snprintf(path, sizeof(path), "%s/master.pcm", perf_test_dir());
  FILE* f = fopen(path, "rb");
  CHECK(f != NULL);
  if (f != NULL) {
    float buf[64];
    const size_t n = fread(buf, sizeof(float), 64, f);
    fclose(f);
    CHECK(n == 32); /* 7 real frames + 25 silence-filled == elapsed */
    for (size_t i = 0; i < 7 && i < n; ++i) {
      CHECK(buf[i] == 1.0f); /* the 7 that actually reached the ring */
    }
    for (size_t i = 7; i < n; ++i) CHECK(buf[i] == 0.0f); /* the padded gap */
  }

  char json[4096];
  char sidecar_path[600];
  snprintf(sidecar_path, sizeof(sidecar_path), "%s/performance.json",
          perf_test_dir());
  CHECK(read_file_for_test(sidecar_path, json, sizeof(json)) > 0);
  CHECK(strstr(json, "\"overrun_gaps\"") != NULL);
  CHECK(strstr(json, "\"frame\": 7") != NULL);
  CHECK(strstr(json, "\"duration_frames\": 25") != NULL);
  CHECK(strstr(json, "\"finalized\": false") != NULL);

  le_engine_destroy(e);
}

/* A write failure (forced deterministically — no real full disk needed) stops
 * the drain thread cleanly: it self-stops rather than retrying, marks the
 * sidecar's final flush `stopped_early: disk_full`, and — critically — the
 * engine itself is never touched (the audio path keeps processing normally
 * regardless of the capture failure). */
static void test_perf_drain_disk_full_stops_cleanly(void) {
  printf("test_perf_drain_disk_full_stops_cleanly\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 1000);

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  le_perf_drain_force_write_failure_for_test(1);

  /* The engine keeps processing audio normally throughout — a capture
   * failure must never touch the audio path. */
  float out[LOOP_N];
  process_const(e, 0.5f, LOOP_N, out);

  /* Poll rather than a fixed sleep: this specifically needs the drain
   * thread's OWN background cycle to observe the forced failure (not just
   * disarm's final pass), so there is no call here that already blocks
   * until it. 2 s is generous; the common case resolves within one flush
   * cycle (~250 ms). */
  const int stopped = poll_drain_self_stopped_for_test(e->perf.drain, 2000);

  le_perf_drain_force_write_failure_for_test(0); /* reset before other tests run */

  CHECK(stopped);
  CHECK(le_perf_drain_self_stopped_for_test(e->perf.drain) == 1);

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.perf_armed == 1); /* the engine itself is unaffected; still "armed" */

  char json[4096];
  char sidecar_path[600];
  snprintf(sidecar_path, sizeof(sidecar_path), "%s/performance.json",
          perf_test_dir());
  CHECK(read_file_for_test(sidecar_path, json, sizeof(json)) > 0);
  CHECK(strstr(json, "\"stopped_early\": \"disk_full\"") != NULL);

  le_perf_disarm(e); /* the thread already exited; this just reaps/joins it */
  le_engine_destroy(e);
}

/* Crash consistency: the sidecar and PCM files on disk are already fully
 * valid (parseable, readable up to the last flush) at any point during a
 * still-running capture — no clean disarm/finalize ever happens in this
 * test. This is the actual invariant a process kill relies on (umbrella
 * D-FMT/D-SALVAGE): reading the files from a second handle while the drain
 * thread is still alive proves it directly, rather than literally killing a
 * thread (no portable, safe API for that — it would only test an OS/thread-
 * implementation detail, not the on-disk format this part actually owns). */
static void test_perf_drain_files_are_crash_consistent_mid_capture(void) {
  printf("test_perf_drain_files_are_crash_consistent_mid_capture\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 1000);

  /* The shared scratch dir (perf_test_dir) can still hold a PREVIOUS test's
   * sidecar (e.g. test_perf_drain_disk_full_stops_cleanly's, which does
   * write `stopped_early`) — it is only overwritten once THIS session's
   * drain thread completes its own first cycle, whereas the PCM files below
   * are truncated immediately at arm (fopen "wb"). Remove it explicitly so
   * "stopped_early is absent" can't spuriously pass by reading stale
   * content from a different session. */
  char sidecar_path[600];
  snprintf(sidecar_path, sizeof(sidecar_path), "%s/performance.json",
          perf_test_dir());
  remove(sidecar_path);

  le_engine_record(e, 0);
  float out[LOOP_N];
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  float out2[LOOP_N];
  process_const(e, 0.0f, LOOP_N, out2);

  /* This test's whole point is to read the files WHILE the drain thread is
   * still alive (no disarm/finalize yet), so it can't just block on a call
   * that joins the thread. Poll for the sidecar to reappear (removed above)
   * instead of a fixed sleep: since it's the LAST step of a drain cycle
   * (after the PCM flush), its mere presence proves this session's PCM
   * flush already happened too — a hard ordering guarantee, not a timing
   * guess, and immune to a stale prior session's file since that was
   * deleted. */
  CHECK(poll_file_reaches_size_for_test(sidecar_path, 1, 2000));

  char json[4096];
  CHECK(read_file_for_test(sidecar_path, json, sizeof(json)) > 0);
  CHECK(json[0] == '{'); /* minimal well-formedness: no library to parse with */
  CHECK(strstr(json, "\"finalized\": false") != NULL);
  CHECK(strstr(json, "\"slug\"") != NULL);
  CHECK(strstr(json, "\"capture_frames\"") != NULL);
  CHECK(strstr(json, "\"stopped_early\"") == NULL); /* still running normally */

  char pcm_path[600];
  snprintf(pcm_path, sizeof(pcm_path), "%s/master.pcm", perf_test_dir());
  FILE* pf = fopen(pcm_path, "rb");
  CHECK(pf != NULL);
  if (pf != NULL) {
    float buf[LOOP_N];
    const size_t n = fread(buf, sizeof(float), LOOP_N, pf);
    fclose(pf);
    CHECK(n == LOOP_N);
  }

  le_perf_disarm(e);
  le_engine_destroy(e);
}

/* The capture-to-disk counterpart to
 * test_perf_reconfigure_while_armed_resets_cleanly: a reconfigure while armed
 * stops+joins the drain thread (le_engine_configure blocks on the join, so no
 * sleep is needed before reading the sidecar back), and its final flush marks
 * the reason. */
static void test_perf_reconfigure_while_armed_marks_sidecar_device_changed(void) {
  printf("test_perf_reconfigure_while_armed_marks_sidecar_device_changed\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 1000);

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  float out[LOOP_N];
  process_const(e, 0.5f, LOOP_N, out);

  CHECK(le_engine_configure(e, 48000, 1, 1, 1000) == LE_OK); /* reconfigure, still armed */

  char json[4096];
  char sidecar_path[600];
  snprintf(sidecar_path, sizeof(sidecar_path), "%s/performance.json",
          perf_test_dir());
  CHECK(read_file_for_test(sidecar_path, json, sizeof(json)) > 0);
  CHECK(strstr(json, "\"stopped_early\": \"device_changed\"") != NULL);
  CHECK(strstr(json, "\"finalized\": false") != NULL);

  le_engine_destroy(e);
}

/* Acceptance criteria 1 (audited table round-trips through ring -> file) and
 * 2 (events carry the correct capture frame): arms, advances a known number
 * of frames, pushes one representative command per union-arm shape the
 * audited table covers (plus one excluded code, to prove it is NOT logged),
 * then asserts every logged entry's frame matches the buffer-start snapshot
 * and its payload matches what was pushed. */
static void test_perf_events_log_table_round_trip_and_frame_accuracy(void) {
  printf("test_perf_events_log_table_round_trip_and_frame_accuracy\n");
  le_engine* e = make_configured_engine();
  float out[LOOP_N];

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  process_const(e, 0.0f, LOOP_N, out);
  const uint64_t expected_frame =
      atomic_load_explicit(&e->a_perf_frames, memory_order_relaxed);

  CHECK(le_engine_set_master_gain(e, 0.7f) == LE_OK);           /* generic */
  CHECK(le_engine_set_track_volume(e, 0, 0.4f) == LE_OK);       /* generic */
  CHECK(le_engine_set_track_mute(e, 0, 1) == LE_OK);            /* generic */
  CHECK(le_engine_set_output_enabled(e, 0, 0) == LE_OK);        /* generic */
  CHECK(le_engine_set_input_mask(e, 0, 1) == LE_OK);            /* trackmask */
  CHECK(le_engine_set_output_mask(e, 0, 1) == LE_OK);           /* trackmask */
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DRIVE) == LE_OK); /* fx */
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1) == LE_OK);      /* fxcount */
  CHECK(le_engine_set_lane_input(e, 0, 0, 0) == LE_OK);         /* lanei */
  CHECK(le_engine_set_lane_output(e, 0, 0, 1) == LE_OK);        /* lanei */
  CHECK(le_engine_set_lane_volume(e, 0, 0, 0.5f) == LE_OK);     /* lanef */
  CHECK(le_engine_set_lane_mute(e, 0, 0, 1) == LE_OK);          /* lanef */
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);         /* generic */
  CHECK(le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_DELAY) == LE_OK); /* fx */
  CHECK(le_engine_set_monitor_input_fx_count(e, 0, 1) == LE_OK); /* fxcount */
  CHECK(le_engine_set_monitor_input_output(e, 0, 1) == LE_OK);  /* trackmask */
  CHECK(le_engine_set_monitor_input_volume(e, 0, 0.6f) == LE_OK); /* generic */
  CHECK(le_engine_set_monitor_input_mute(e, 0, 1) == LE_OK);    /* generic */
  CHECK(le_engine_set_record_offset(e, 480) == LE_OK); /* EXCLUDED: must not log */
  drain(e); /* apply_command runs once here — every entry above tags `expected_frame` */

  /* Control-side emission (bypasses the command ring entirely): logged via
   * log_ctrl_ring, drained into the same events.log, tagged with the same
   * a_perf_frames snapshot since it hasn't advanced since `expected_frame`
   * was captured above. */
  CHECK(le_engine_set_limiter(e, 1, 0.9f) == LE_OK);
  CHECK(le_engine_set_overdub_feedback(e, 0.8f) == LE_OK);
  CHECK(atomic_load_explicit(&e->a_perf_log_ctrl_overruns,
                            memory_order_relaxed) == 0u);

  CHECK(le_perf_disarm(e) == LE_OK); /* blocks: final flush + join */

  char path[600];
  snprintf(path, sizeof(path), "%s/events.log", perf_test_dir());
  static unsigned char buf[16384];
  const size_t n = read_binary_file_for_test(path, buf, sizeof(buf));
  CHECK(n >= LE_TEST_EVENTS_HEADER_BYTES);
  CHECK(memcmp(buf, "PLEV", 4) == 0);
  uint32_t version;
  memcpy(&version, buf + 4, 4);
  CHECK(version == 1);
  int32_t sample_rate;
  memcpy(&sample_rate, buf + 8, 4);
  CHECK(sample_rate == 48000);

  const size_t count = log_entry_count(n);
  le_perf_log_entry entry;

  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_MASTER_GAIN, &entry) >= 0);
  CHECK(entry.frame == expected_frame);
  CHECK(entry.cmd.arg_f == 0.7f);

  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_VOLUME, &entry) >= 0);
  CHECK(entry.frame == expected_frame);
  CHECK(entry.cmd.arg_i == 0 && entry.cmd.arg_f == 0.4f);

  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_MUTE, &entry) >= 0);
  CHECK(entry.frame == expected_frame);
  CHECK(entry.cmd.arg_i == 0 && entry.cmd.arg_f != 0.0f);

  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_OUTPUT_ENABLED, &entry) >= 0);
  CHECK(entry.frame == expected_frame);

  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_INPUT_MASK, &entry) >= 0);
  CHECK(entry.frame == expected_frame);
  CHECK(entry.cmd.trackmask.channel == 0 && entry.cmd.trackmask.mask == 1u);

  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_OUTPUT_MASK, &entry) >= 0);
  CHECK(entry.frame == expected_frame);
  CHECK(entry.cmd.trackmask.channel == 0 && entry.cmd.trackmask.mask == 1u);

  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_LANE_FX, &entry) >= 0);
  CHECK(entry.frame == expected_frame);
  CHECK(entry.cmd.fx.channel == 0 && entry.cmd.fx.lane == 0 &&
        entry.cmd.fx.index == 0 && entry.cmd.fx.type == LE_FX_DRIVE);

  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_LANE_FX_COUNT, &entry) >= 0);
  CHECK(entry.frame == expected_frame);
  CHECK(entry.cmd.fxcount.channel == 0 && entry.cmd.fxcount.count == 1);

  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_LANE_INPUT, &entry) >= 0);
  CHECK(entry.frame == expected_frame);
  CHECK(entry.cmd.lanei.channel == 0 && entry.cmd.lanei.value == 0);

  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_LANE_OUTPUT, &entry) >= 0);
  CHECK(entry.frame == expected_frame);
  CHECK(entry.cmd.lanei.channel == 0 && entry.cmd.lanei.value == 1);

  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_LANE_VOLUME, &entry) >= 0);
  CHECK(entry.frame == expected_frame);
  CHECK(entry.cmd.lanef.value == 0.5f);

  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_LANE_MUTE, &entry) >= 0);
  CHECK(entry.frame == expected_frame);
  CHECK(entry.cmd.lanef.value != 0.0f);

  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_MONITOR_INPUT, &entry) >= 0);
  CHECK(entry.frame == expected_frame);

  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_MONITOR_INPUT_FX, &entry) >= 0);
  CHECK(entry.frame == expected_frame);
  CHECK(entry.cmd.fx.type == LE_FX_DELAY);

  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_MONITOR_INPUT_FX_COUNT,
                       &entry) >= 0);
  CHECK(entry.frame == expected_frame);
  CHECK(entry.cmd.fxcount.channel == 0 && entry.cmd.fxcount.count == 1);

  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_MONITOR_INPUT_OUTPUT,
                       &entry) >= 0);
  CHECK(entry.frame == expected_frame);
  CHECK(entry.cmd.trackmask.channel == 0 && entry.cmd.trackmask.mask == 1u);

  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_MONITOR_INPUT_VOLUME,
                       &entry) >= 0);
  CHECK(entry.frame == expected_frame);
  CHECK(entry.cmd.arg_i == 0 && entry.cmd.arg_f == 0.6f);

  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_MONITOR_INPUT_MUTE, &entry) >=
        0);
  CHECK(entry.frame == expected_frame);
  CHECK(entry.cmd.arg_i == 0 && entry.cmd.arg_f != 0.0f);

  /* Excluded: a calibration value, never logged. */
  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_RECORD_OFFSET, &entry) < 0);

  /* Control-side codes (log_ctrl_ring). */
  CHECK(find_log_entry(buf, count, 0, LE_PLOG_SET_LIMITER, &entry) >= 0);
  CHECK(entry.frame == expected_frame);
  CHECK(entry.cmd.arg_i == 1 && entry.cmd.arg_f == 0.9f);

  CHECK(find_log_entry(buf, count, 0, LE_PLOG_SET_OVERDUB_FEEDBACK, &entry) >=
        0);
  CHECK(entry.frame == expected_frame);
  CHECK(entry.cmd.arg_f == 0.8f);

  le_engine_destroy(e);
}

/* Acceptance criterion: transport facts (record start/end, loop length
 * locked, layer retired) are logged sample-accurately, distinct from the raw
 * commands that triggered them. Also covers undo/redo (control-side
 * emission, the common in-track swap path). */
static void test_perf_events_log_transport_facts(void) {
  printf("test_perf_events_log_transport_facts\n");
  le_engine* e = make_configured_engine();
  float out[LOOP_N];

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  CHECK(le_engine_record(e, 0) == LE_OK); /* EMPTY -> RECORDING, no master yet */
  drain(e);
  process_const(e, 1.0f, LOOP_N, out);
  CHECK(le_engine_record(e, 0) == LE_OK); /* finalize: defines the master loop */
  drain(e);

  /* One overdub pass so a layer actually retires — mirrors
   * test_looper_overdub_and_undo's exact sequence (punch-in, one pass equal
   * to the loop length so the capture wraps and retires within it, punch-out,
   * then let the punch envelope settle before touching undo). */
  CHECK(le_engine_record(e, 0) == LE_OK); /* PLAYING -> OVERDUBBING (punch-in) */
  process_const(e, 0.5f, LOOP_N, out);
  CHECK(le_engine_record(e, 0) == LE_OK); /* OVERDUBBING -> PLAYING (punch-out) */
  drain(e);
  process_const(e, 0.0f, LOOP_N, out); /* punch envelope quiet: session winds down */
  drain(e);

  /* Bounded poll on the actual retirement signal (snapshot's undo_depth, the
   * same field test_looper_overdub_and_undo asserts on) rather than assuming
   * one drain suffices — belt-and-braces against scheduling-independent
   * per-pass capture timing. */
  le_snapshot snap;
  for (int i = 0; i < 64; ++i) {
    le_engine_get_snapshot(e, &snap);
    if (snap.tracks[0].undo_depth > 0) break;
    drain(e);
  }
  CHECK(snap.tracks[0].undo_depth > 0);

  CHECK(le_engine_undo(e, 0) == LE_OK); /* common in-track swap: control-side log */
  drain(e);
  CHECK(le_engine_redo(e, 0) == LE_OK); /* same */
  drain(e);

  /* LE_CMD_STOP / LE_CMD_PLAY coverage. */
  CHECK(le_engine_stop_track(e, 0) == LE_OK); /* PLAYING -> STOPPED */
  drain(e);
  CHECK(le_engine_play(e, 0) == LE_OK); /* STOPPED -> PLAYING */
  drain(e);

  /* LE_CMD_UNDO_TO_EMPTY / LE_CMD_REDO_FROM_EMPTY coverage (the audio-thread
   * edge cases of undo/redo, distinct from the control-side common swap
   * already exercised above): undo the overdub (back to the common-swap
   * path once more), then undo PAST the base layer — with no stacked undo
   * layer left, this takes the to-EMPTY branch and posts LE_CMD_UNDO_TO_EMPTY
   * instead of the common swap; both still log LE_PLOG_UNDO, just from a
   * different code path (see docs/design/performance-event-log-format.md). */
  CHECK(le_engine_undo(e, 0) == LE_OK); /* removes the overdub again */
  drain(e);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* past the base layer -> EMPTY */
  drain(e);
  CHECK(le_engine_redo(e, 0) == LE_OK); /* from-EMPTY edge case -> LE_PLOG_REDO */
  drain(e);

  CHECK(le_engine_clear(e, 0) == LE_OK); /* LE_CMD_CLEAR coverage */
  drain(e);

  CHECK(le_perf_disarm(e) == LE_OK);

  char path[600];
  snprintf(path, sizeof(path), "%s/events.log", perf_test_dir());
  static unsigned char buf[16384];
  const size_t n = read_binary_file_for_test(path, buf, sizeof(buf));
  CHECK(n >= LE_TEST_EVENTS_HEADER_BYTES);
  const size_t count = log_entry_count(n);
  le_perf_log_entry entry;

  CHECK(find_log_entry(buf, count, 0, LE_PLOG_RECORD_START, &entry) >= 0);
  CHECK(entry.cmd.arg_i == 0);
  CHECK(find_log_entry(buf, count, 0, LE_PLOG_RECORD_END, &entry) >= 0);
  CHECK(entry.cmd.arg_i == 0);
  CHECK(find_log_entry(buf, count, 0, LE_PLOG_LOOP_LENGTH_LOCKED, &entry) >= 0);
  CHECK(entry.cmd.arg_i == LOOP_N);
  CHECK(find_log_entry(buf, count, 0, LE_PLOG_LAYER_RETIRED, &entry) >= 0);
  CHECK(entry.cmd.evt.channel == 0);
  CHECK(find_log_entry(buf, count, 0, LE_CMD_RECORD, &entry) >= 0);
  CHECK(find_log_entry(buf, count, 0, LE_CMD_STOP, &entry) >= 0);
  CHECK(entry.cmd.arg_i == 0);
  CHECK(find_log_entry(buf, count, 0, LE_CMD_PLAY, &entry) >= 0);
  CHECK(entry.cmd.arg_i == 0);
  CHECK(find_log_entry(buf, count, 0, LE_CMD_CLEAR, &entry) >= 0);
  CHECK(entry.cmd.arg_i == 0);

  /* LE_PLOG_UNDO fires 3 times (common swap x2, then the to-EMPTY edge case)
   * and LE_PLOG_REDO fires twice (common swap, then the from-EMPTY edge
   * case) — counting proves BOTH code paths actually logged, not just
   * whichever ran first (find_log_entry alone can't distinguish them, since
   * both paths emit the identical code). */
  size_t undo_entries = 0, redo_entries = 0;
  for (size_t i = 0; i < count; ++i) {
    decode_log_entry_at(buf, i, &entry);
    if (entry.cmd.code == LE_PLOG_UNDO) ++undo_entries;
    if (entry.cmd.code == LE_PLOG_REDO) ++redo_entries;
  }
  CHECK(undo_entries == 3);
  CHECK(redo_entries == 2);

  le_engine_destroy(e);
}

/* Acceptance criterion: a command storm (>= 2000 events) loses nothing —
 * the 4096-slot log_ring absorbs it with headroom to spare. Pushed in
 * batches bounded by the 256-slot command ring's own capacity, draining
 * between batches (drain(e) applies every pushed command in one call,
 * pushing one log_ring entry per command); the real assertion is that the
 * dedicated overrun atomic never increments and every command that was
 * pushed shows up in the file after a clean disarm — not that it all landed
 * within one wall-clock 250ms window, which no deterministic single-process
 * test can force against a real background thread without flakiness. */
static void test_perf_events_log_command_storm_no_loss(void) {
  printf("test_perf_events_log_command_storm_no_loss\n");
  le_engine* e = make_configured_engine();

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  const int total = 2500;
  const int batch = 200; /* well under the 256-slot command ring's capacity */
  int pushed = 0;
  while (pushed < total) {
    const int this_batch = (total - pushed) < batch ? (total - pushed) : batch;
    for (int i = 0; i < this_batch; ++i) {
      CHECK(le_engine_set_master_gain(e, (float)(pushed + i) / (float)total) ==
            LE_OK);
    }
    drain(e);
    pushed += this_batch;
  }

  CHECK(atomic_load_explicit(&e->a_perf_log_overruns, memory_order_relaxed) ==
        0u);

  CHECK(le_perf_disarm(e) == LE_OK);

  char path[600];
  snprintf(path, sizeof(path), "%s/events.log", perf_test_dir());
  /* 2500 entries x 28 bytes + the 12-byte header, plus slack. */
  static unsigned char buf[2500 * LE_TEST_EVENTS_ENTRY_BYTES + 4096];
  const size_t n = read_binary_file_for_test(path, buf, sizeof(buf));
  CHECK(n >= LE_TEST_EVENTS_HEADER_BYTES);
  const size_t count = log_entry_count(n);

  size_t gain_entries = 0;
  le_perf_log_entry entry;
  for (size_t i = 0; i < count; ++i) {
    decode_log_entry_at(buf, i, &entry);
    if (entry.cmd.code == LE_CMD_SET_MASTER_GAIN) ++gain_entries;
  }
  CHECK(gain_entries == (size_t)total);

  le_engine_destroy(e);
}

/* Acceptance criterion: FX param sweeps are logged (control-side emission)
 * with monotonic frames. Each le_engine_set_lane_fx_param call reads a fresh
 * a_perf_frames snapshot, so processing frames between calls should produce
 * a strictly non-decreasing frame sequence in the log. */
static void test_perf_events_log_fx_param_sweep_monotonic_frames(void) {
  printf("test_perf_events_log_fx_param_sweep_monotonic_frames\n");
  le_engine* e = make_configured_engine();
  float out[LOOP_N];

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DRIVE) == LE_OK);
  CHECK(le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_DELAY) == LE_OK);
  drain(e);

  const int sweeps = 10;
  const int lane_param = 1;    /* non-zero, to prove the packing isn't just
                                * coincidentally right for param==0 */
  const int monitor_param = 2; /* different again, on the monitor sibling */
  for (int i = 0; i < sweeps; ++i) {
    process_const(e, 0.0f, LOOP_N, out); /* advance a_perf_frames between calls */
    CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, lane_param,
                                      (float)i / (float)sweeps) == LE_OK);
    CHECK(le_engine_set_monitor_input_fx_param(
              e, 0, 0, monitor_param, (float)(sweeps - i) / (float)sweeps) ==
          LE_OK);
  }
  drain(e);

  CHECK(le_perf_disarm(e) == LE_OK);

  char path[600];
  snprintf(path, sizeof(path), "%s/events.log", perf_test_dir());
  static unsigned char buf[16384];
  const size_t n = read_binary_file_for_test(path, buf, sizeof(buf));
  CHECK(n >= LE_TEST_EVENTS_HEADER_BYTES);
  const size_t count = log_entry_count(n);

  /* Lane FX param sweep: decode the packed payload at every step (not just
   * the code/frame ordering) — index/param unpacked from fx.index, the swept
   * float recovered by bit-casting fx.type back. */
  uint64_t last_frame = 0;
  int seen = 0;
  le_perf_log_entry entry;
  for (size_t i = 0; i < count; ++i) {
    decode_log_entry_at(buf, i, &entry);
    if (entry.cmd.code != LE_PLOG_SET_LANE_FX_PARAM) continue;
    if (seen > 0) CHECK(entry.frame >= last_frame);
    last_frame = entry.frame;
    CHECK(entry.cmd.fx.channel == 0 && entry.cmd.fx.lane == 0);
    CHECK(LE_PLOG_FX_PARAM_INDEX(entry.cmd.fx.index) == 0);
    CHECK(LE_PLOG_FX_PARAM_PARAM(entry.cmd.fx.index) == lane_param);
    const float value = bits_to_f32((uint32_t)entry.cmd.fx.type);
    CHECK(fabsf(value - (float)seen / (float)sweeps) < 1e-6f);
    ++seen;
  }
  CHECK(seen == sweeps);

  /* Monitor FX param sibling: same packing, distinct param value, lane == -1
   * sentinel (input effects have no lane) — proves the low-byte packing
   * doesn't collide between the two independently-chosen param indices. */
  uint64_t last_mon_frame = 0;
  int seen_mon = 0;
  for (size_t i = 0; i < count; ++i) {
    decode_log_entry_at(buf, i, &entry);
    if (entry.cmd.code != LE_PLOG_SET_MONITOR_FX_PARAM) continue;
    if (seen_mon > 0) CHECK(entry.frame >= last_mon_frame);
    last_mon_frame = entry.frame;
    CHECK(entry.cmd.fx.channel == 0 && entry.cmd.fx.lane == -1);
    CHECK(LE_PLOG_FX_PARAM_INDEX(entry.cmd.fx.index) == 0);
    CHECK(LE_PLOG_FX_PARAM_PARAM(entry.cmd.fx.index) == monitor_param);
    const float value = bits_to_f32((uint32_t)entry.cmd.fx.type);
    CHECK(fabsf(value - (float)(sweeps - seen_mon) / (float)sweeps) < 1e-6f);
    ++seen_mon;
  }
  CHECK(seen_mon == sweeps);

  le_engine_destroy(e);
}

/* Acceptance criterion: the log file is readable after an abrupt stop, up to
 * the last flush — mirroring part 2's crash-consistency test's documented
 * scope substitution (no portable safe way to SIGKILL this test process
 * mid-capture; reading a live, still-running capture proves the same
 * on-disk-format invariant: parseable header + whole entries up to the last
 * completed drain cycle). */
static void test_perf_events_log_readable_after_abrupt_stop(void) {
  printf("test_perf_events_log_readable_after_abrupt_stop\n");
  le_engine* e = make_configured_engine();

  char path[600];
  snprintf(path, sizeof(path), "%s/events.log", perf_test_dir());
  remove(path); /* clear any stale content from a prior test session */

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);
  CHECK(le_engine_set_master_gain(e, 0.42f) == LE_OK);
  drain(e);

  /* Wait for the drain thread's own background cycle to flush this session's
   * events.log (removed above, so its reappearance can only be this
   * session's own first cycle — same reasoning as part 2's crash-consistency
   * test's sidecar poll). */
  CHECK(poll_file_reaches_size_for_test(
      path, LE_TEST_EVENTS_HEADER_BYTES + LE_TEST_EVENTS_ENTRY_BYTES, 2000));

  static unsigned char buf[4096];
  const size_t n = read_binary_file_for_test(path, buf, sizeof(buf));
  CHECK(n >= LE_TEST_EVENTS_HEADER_BYTES + LE_TEST_EVENTS_ENTRY_BYTES);
  CHECK(memcmp(buf, "PLEV", 4) == 0);
  const size_t count = log_entry_count(n);
  le_perf_log_entry entry;
  CHECK(find_log_entry(buf, count, 0, LE_CMD_SET_MASTER_GAIN, &entry) >= 0);

  le_perf_disarm(e);
  le_engine_destroy(e);
}

/* The engine's record-time snapshot of the recorded input's monitor FX chain
 * onto the take's lane — and its copy-on-record independence (D3) — moved to the
 * host (LooperRepository), which is now the single record-time snapshot
 * authority. The engine-level tests that asserted the self-snapshot were retired
 * with it; the behavior is re-asserted at the repository level (deterministic
 * race + plugin + non-clobber tests) and the engine's pure-sink contract is
 * pinned by test_record_does_not_self_snapshot below. */

/* The engine is a pure sink for lane FX: it does NOT self-snapshot the recorded
 * input's monitor chain onto the lane on record. The host (LooperRepository) is
 * the sole record-time snapshot authority and pushes the take's lane FX through
 * the command ring like any other lane edit — so there is no second, ring-
 * deferred computation to race (the dry-take-when-FX-monitored bug). Asserted on
 * the PUBLISHED-chain fingerprints: a record-from-EMPTY over a HOT monitor
 * leaves the lane's chain untouched (still the empty basis). */
static void test_record_does_not_self_snapshot(void) {
  printf("test_record_does_not_self_snapshot\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000);

  /* Monitor a drive on input 0; lane 0 of empty track 0 records input 0. */
  le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_DRIVE);
  le_engine_set_monitor_input_fx_count(e, 0, 1);
  drain(e);

  const uint64_t empty_lane_fp = le_engine_lane_fx_fingerprint(e, 0, 0);
  CHECK(le_engine_monitor_fx_fingerprint(e, 0) != empty_lane_fp); /* hot */

  /* Record from EMPTY: the engine must NOT copy the monitor chain onto the
   * lane. The lane's published chain stays exactly what it was (empty). */
  le_engine_record(e, 0);
  drain(e);
  CHECK(le_engine_lane_fx_fingerprint(e, 0, 0) == empty_lane_fp);

  le_engine_destroy(e);
}

/* The engine never touches a lane's FX on record — it is a pure sink for the
 * host-pushed chain. A staged lane chain survives a fresh take whether the
 * recorded input's monitor chain is clean OR hot: the host (LooperRepository)
 * owns the record-time snapshot and pushes any overwrite itself. (Previously the
 * engine self-snapshotted, so a hot monitor overwrote the staged lane chain
 * here; that authority now lives entirely in the host — see the repository's
 * record-snapshot tests.) */
static void test_record_never_touches_lane_fx(void) {
  printf("test_record_never_touches_lane_fx\n");
  le_engine* e = make_configured_engine();
  float out[64];

  /* Stage a unity drive on empty track 0's lane 0; input 0's monitor chain
   * stays clean. */
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DRIVE) == LE_OK);
  le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 0.0f); /* 1x pre-gain */
  le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 1.0f); /* unity level */
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1) == LE_OK);
  drain(e);

  /* Record a take: the staged chain survives and colours playback — tanh drive
   * on the recorded 0.5. */
  le_engine_record(e, 0);
  process_const(e, 0.5f, LOOP_N, out);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i] - tanhf(0.5f)) < 1e-5f);
  }

  /* A HOT monitor chain no longer overwrites the staged one engine-side — the
   * engine performs no self-snapshot. Clear the take, re-stage a UNITY drive,
   * and monitor input 0 through a HOT drive: the new take still plays the STAGED
   * unity chain (tanh(0.5)), NOT the hot monitor one — proving the engine left
   * the lane's chain alone. */
  CHECK(le_engine_clear(e, 0) == LE_OK);
  drain(e);
  le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DRIVE);
  le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 0.0f); /* 1x pre-gain (unity) */
  le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 1.0f);
  le_engine_set_lane_fx_count(e, 0, 0, 1);
  le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_DRIVE);
  le_engine_set_monitor_input_fx_param(e, 0, 0, 0, 1.0f); /* hot pre-gain */
  le_engine_set_monitor_input_fx_param(e, 0, 0, 1, 1.0f);
  le_engine_set_monitor_input_fx_count(e, 0, 1);
  drain(e);
  le_engine_record(e, 0);
  process_const(e, 0.5f, LOOP_N, out);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i] - tanhf(0.5f)) < 1e-5f);
  }

  le_engine_destroy(e);
}

/* A disabled output is structurally removed as a mix target — silent regardless
 * of any mask pointing at it — while the stored masks are preserved (D5/D6). */
static void test_output_disabled_is_silent_routes_preserved(void) {
  printf("test_output_disabled_is_silent_routes_preserved\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000); /* 2-in, 2-out */
  float out[2 * LOOP_N];
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 1.0f;
    in[i * 2 + 1] = 0.0f;
  }

  /* Monitor input 0 to both outputs (default full stereo). */
  le_engine_set_monitor_input(e, 0, 1);
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 1.0f) < 1e-6f);
  }

  /* Disable output 1: out 1 falls silent; out 0 unchanged (the input's mask is
   * untouched — bit 1 is still set, it is just not a target now). */
  CHECK(le_engine_set_output_enabled(e, 1, 0) == LE_OK);
  drain(e);
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1]) < 1e-6f);
  }

  /* The snapshot publishes the gate (bit 1 cleared, bit 0 set). */
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK((s.output_enabled_mask & 0x1u) != 0u);
  CHECK((s.output_enabled_mask & 0x2u) == 0u);

  /* Invalid args rejected. */
  CHECK(le_engine_set_output_enabled(NULL, 0, 1) == LE_ERR_INVALID);
  CHECK(le_engine_set_output_enabled(e, -1, 1) == LE_ERR_INVALID);

  le_engine_destroy(e);
}

/* Re-enabling a gated output restores its audio: the stored route mask was
 * preserved, so the output sounds again with no re-routing (D6). */
static void test_reenable_restores_audio(void) {
  printf("test_reenable_restores_audio\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000);
  float out[2 * LOOP_N];
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 1.0f;
    in[i * 2 + 1] = 0.0f;
  }

  le_engine_set_monitor_input(e, 0, 1); /* both outputs */
  CHECK(le_engine_set_output_enabled(e, 1, 0) == LE_OK);
  drain(e);
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i * 2 + 1]) < 1e-6f);

  /* Re-enable output 1: audible again with no mask edit in between. */
  CHECK(le_engine_set_output_enabled(e, 1, 1) == LE_OK);
  drain(e);
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 1.0f) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* A gate state for an output beyond the device's channel count is accepted but
 * never affects audio (NF-3 / E11): in-range outputs keep sounding. */
static void test_gate_beyond_channel_count_ignored(void) {
  printf("test_gate_beyond_channel_count_ignored\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000); /* only outputs 0,1 exist */
  float out[2 * LOOP_N];
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 1.0f;
    in[i * 2 + 1] = 0.0f;
  }

  le_engine_set_monitor_input(e, 0, 1);
  /* Disable output 5 (well past the 2-channel device): accepted, but the mix
   * only iterates [0, 2), so outputs 0 and 1 are unaffected. */
  CHECK(le_engine_set_output_enabled(e, 5, 0) == LE_OK);
  drain(e);
  le_engine_process(e, out, in, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 1.0f) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* A per-track quantize override wins over the global default: force-on captures
 * on a track while the global default is off (arms instead of starting now). */
static void test_quantize_track_override_forces_on(void) {
  printf("test_quantize_track_override_forces_on\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  establish_master(e, out);
  // Global default off (the engine default); force quantize on for track 1.
  CHECK(le_engine_set_track_quantize(e, 1, 1) == LE_OK);
  process_const(e, 0.0f, 1, out); /* move off the loop top */

  le_engine_record(e, 1); /* should ARM (override on), not start now */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY);

  process_const(e, 2.0f, 3, out); /* wrap -> fires at the top */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);

  le_engine_destroy(e);
}

/* A force-off override wins over a global default of on: the track records
 * immediately even though quantize is globally enabled. */
static void test_quantize_track_override_forces_off(void) {
  printf("test_quantize_track_override_forces_off\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  establish_master(e, out);
  le_engine_set_quantize(e, 1);              /* global on */
  CHECK(le_engine_set_track_quantize(e, 1, 0) == LE_OK); /* force off track 1 */
  process_const(e, 0.0f, 1, out);

  le_engine_record(e, 1); /* immediate, not armed */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);

  le_engine_destroy(e);
}

/* Inheriting tracks (override < 0) follow the global default. */
static void test_quantize_track_override_inherits(void) {
  printf("test_quantize_track_override_inherits\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  establish_master(e, out);
  le_engine_set_quantize(e, 1);                /* global on */
  le_engine_set_track_quantize(e, 1, -1);      /* explicit inherit */
  process_const(e, 0.0f, 1, out);

  le_engine_record(e, 1); /* inherits global on -> arms */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY); /* armed, not recording */

  le_engine_destroy(e);
}

/* A forced per-track multiple fixes the finalized length to exactly K base
 * loops, regardless of how much was recorded. */
static void test_target_multiple_forces_length(void) {
  printf("test_target_multiple_forces_length\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  establish_master(e, out); /* base loop length == LOOP_N */
  CHECK(le_engine_set_track_multiple(e, 1, 2) == LE_OK);

  le_engine_record(e, 1);
  process_const(e, 2.0f, LOOP_N, out); /* record ~one base loop */
  le_engine_record(e, 1); /* finalize */
  drain(e);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].multiple == 2);
  CHECK(s.tracks[1].length_frames == 2 * LOOP_N);

  le_engine_destroy(e);
}

/* The global default multiple applies to tracks that inherit (no per-track
 * override), and a per-track override wins over it. */
static void test_default_multiple_applies_to_inheriting_tracks(void) {
  printf("test_default_multiple_applies_to_inheriting_tracks\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  establish_master(e, out); /* base loop length == LOOP_N */
  CHECK(le_engine_set_default_multiple(e, 2) == LE_OK);

  /* Track 1 inherits (target 0) -> uses the global default of 2. */
  le_engine_record(e, 1);
  process_const(e, 2.0f, LOOP_N, out);
  le_engine_record(e, 1); /* finalize */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].multiple == 2);
  CHECK(s.tracks[1].length_frames == 2 * LOOP_N);

  /* Track 2 overrides to x1, beating the global default of 2. */
  le_engine_set_track_multiple(e, 2, 1);
  le_engine_record(e, 2);
  process_const(e, 3.0f, LOOP_N, out);
  le_engine_record(e, 2); /* finalize */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[2].multiple == 1);

  le_engine_destroy(e);
}

/* A track recorded over an existing master auto-finalizes after exactly K base
 * loops without a manual press, and always continues into overdub — layering
 * stays live rather than auto-stopping to playback. The rec/dub toggle governs
 * only the master's second-press finalize, so this holds with rec/dub off too. */
static void test_fixed_multiple_auto_finalizes(void) {
  printf("test_fixed_multiple_auto_finalizes\n");
  float out[64];
  le_snapshot s;

  /* x1, rec/dub off -> overdubs after one base loop (keeps layering). */
  le_engine* e = make_configured_engine();
  establish_master(e, out); /* base == LOOP_N, master at the loop top */
  le_engine_set_track_multiple(e, 1, 1);
  le_engine_record(e, 1);
  drain(e); /* RECORDING from position 0 */
  process_const(e, 2.0f, LOOP_N, out); /* exactly one base loop */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_OVERDUBBING); /* auto-finalized, no press */
  CHECK(s.tracks[1].multiple == 1);
  CHECK(s.tracks[1].length_frames == LOOP_N);
  le_engine_destroy(e);

  /* x2 + rec/dub on -> also continues into overdub after two base loops. */
  le_engine* e2 = make_configured_engine();
  establish_master(e2, out);
  le_engine_set_rec_dub(e2, 1);
  le_engine_set_track_multiple(e2, 1, 2);
  le_engine_record(e2, 1);
  drain(e2);
  process_const(e2, 2.0f, 2 * LOOP_N, out); /* two base loops */
  le_engine_get_snapshot(e2, &s);
  CHECK(s.tracks[1].state == LE_TRACK_OVERDUBBING);
  CHECK(s.tracks[1].multiple == 2);
  le_engine_destroy(e2);
}

/* In rec/dub mode a record press finalizes into overdub; a stop press still
 * ends in stopped. */
static void test_rec_dub_continues_into_overdub(void) {
  printf("test_rec_dub_continues_into_overdub\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  CHECK(le_engine_set_rec_dub(e, 1) == LE_OK);

  /* Defining track: record then a record press finalizes -> OVERDUBBING. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0); /* finalize via record press */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);

  /* A new track stopped with a stop press ends STOPPED, never overdub. */
  le_engine_record(e, 1);
  process_const(e, 2.0f, LOOP_N, out);
  le_engine_stop_track(e, 1);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_STOPPED);

  le_engine_destroy(e);
}

/* The reported flow, rec/dub off: record the master on tr0 and stop it to
 * playback, then record a second track that auto-finishes at the loop length.
 * It must continue into overdub (keep layering), not auto-stop to playback —
 * while a manual second press on a subsequent track still finalizes to playback
 * (the rec/dub toggle, off here, governs that press). */
static void test_new_track_autofinish_overdubs_with_rec_dub_off(void) {
  printf("test_new_track_autofinish_overdubs_with_rec_dub_off\n");
  le_engine* e = make_configured_engine(); /* rec/dub off by default */
  float out[64];
  le_snapshot s;

  /* tr0 defines the master, finalized to playback by a record press. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0); /* finalize master -> PLAYING (rec/dub off) */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);

  /* tr1 is one base loop long and auto-finishes with no second press: it must
   * land in OVERDUBBING, not PLAYING. */
  le_engine_set_track_multiple(e, 1, 1);
  le_engine_record(e, 1);
  drain(e);
  process_const(e, 2.0f, LOOP_N, out); /* exactly one base loop -> auto-finish */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_OVERDUBBING);

  /* A manual second press on tr2 still finalizes to playback with rec/dub off. */
  le_engine_record(e, 2);
  process_const(e, 3.0f, LOOP_N, out);
  le_engine_record(e, 2); /* manual finalize -> PLAYING */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[2].state == LE_TRACK_PLAYING);

  le_engine_destroy(e);
}

/* Sound-activated recording arms on the press and starts only once the input
 * crosses the threshold; a second press cancels the arm. */
static void test_auto_record_starts_on_signal(void) {
  printf("test_auto_record_starts_on_signal\n");
  float out[64];
  le_snapshot s;

  le_engine* e = make_configured_engine();
  CHECK(le_engine_set_auto_record(e, 1) == LE_OK);
  le_engine_record(e, 0); /* arms; waits for signal */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);

  process_const(e, 0.0f, LOOP_N, out); /* below threshold: still waiting */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);

  process_const(e, 0.5f, LOOP_N, out); /* crosses threshold: starts now */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING);
  le_engine_destroy(e);

  /* A second press before the signal cancels the arm. */
  le_engine* e2 = make_configured_engine();
  le_engine_set_auto_record(e2, 1);
  le_engine_record(e2, 0); /* arm */
  drain(e2);
  le_engine_record(e2, 0); /* cancel */
  drain(e2);
  process_const(e2, 0.5f, LOOP_N, out); /* loud, but cancelled */
  le_engine_get_snapshot(e2, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  le_engine_destroy(e2);
}

/* ---- per-lane effects ---- */

/* Records a LOOP_N loop of constant `value` on track 0 and finalizes it to
 * PLAYING, so subsequent silent-input blocks play that constant back. */
static void establish_loop(le_engine* e, float value) {
  float out[64];
  le_engine_record(e, 0);
  process_const(e, value, LOOP_N, out);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);
}

/* Sets lane 0 chain entry [idx] to a unity tanh drive (its two params). The
 * chain is stageless; the caller activates entries via the lane-fx count. */
static void fx_drive_unity(le_engine* e, int idx) {
  le_engine_set_lane_fx(e, 0, 0, idx, LE_FX_DRIVE);
  le_engine_set_lane_fx_param(e, 0, 0, idx, 0, 0.0f); /* drive: 1x pre-gain */
  le_engine_set_lane_fx_param(e, 0, 0, idx, 1, 1.0f); /* level: unity */
}

static void test_fx_bypass_is_transparent(void) {
  printf("test_fx_bypass_is_transparent\n");
  le_engine* e = make_configured_engine();
  float out[64];
  establish_loop(e, 1.0f);

  /* Empty chain: playback is the loop, untouched. */
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.0f) < 1e-6f);

  /* Engaging then emptying the chain returns to transparent. */
  fx_drive_unity(e, 0);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - tanhf(1.0f)) < 1e-5f);

  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 0) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.0f) < 1e-6f);

  le_engine_destroy(e);
}

static void test_fx_count_gates_the_chain(void) {
  printf("test_fx_count_gates_the_chain\n");
  le_engine* e = make_configured_engine();
  float out[64];
  establish_loop(e, 1.0f);

  /* Entry 0 is set but count is 0: it must not process. */
  fx_drive_unity(e, 0);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 0) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.0f) < 1e-6f);

  /* Activating it engages the effect. */
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - tanhf(1.0f)) < 1e-5f);

  le_engine_destroy(e);
}

static void test_fx_drive_saturates(void) {
  printf("test_fx_drive_saturates\n");
  le_engine* e = make_configured_engine();
  float out[64];
  establish_loop(e, 1.0f);

  /* drive p0 = 0 -> 1x pre-gain, level p1 = 1 -> out = tanh(1) ~= 0.7616. */
  fx_drive_unity(e, 0);
  le_engine_set_lane_fx_count(e, 0, 0, 1);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - tanhf(1.0f)) < 1e-5f);

  le_engine_destroy(e);
}

static void test_fx_filter_attenuates_low_cutoff(void) {
  printf("test_fx_filter_attenuates_low_cutoff\n");
  le_engine* e = make_configured_engine();
  float out[64];
  establish_loop(e, 1.0f);

  /* A 20 Hz low-pass barely moves over a few samples: the step to 1.0 is
   * heavily attenuated at the loop start. */
  le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_FILTER);
  le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 0.0f); /* min cutoff */
  le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 0.0f); /* no res */
  le_engine_set_lane_fx_count(e, 0, 0, 1);
  process_const(e, 0.0f, LOOP_N, out);
  CHECK(out[0] < 0.05f);
  /* The DC component still passes after the filter settles over many frames. */
  for (int b = 0; b < 4000; ++b) process_const(e, 0.0f, 12, out);
  CHECK(out[11] > 0.9f);

  le_engine_destroy(e);
}

static void test_fx_delay_is_silent_until_time(void) {
  printf("test_fx_delay_is_silent_until_time\n");
  le_engine* e = make_configured_engine();
  float out[64];
  establish_loop(e, 1.0f);

  /* Fully wet, no feedback, a short delay: the line starts empty, so the first
   * output samples are silent and the (delayed) signal arrives later. */
  le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DELAY);
  /* time ~ 10 frames: 10 / (48000 - 1). */
  le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 10.0f / 47999.0f);
  le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 0.0f); /* no fb */
  le_engine_set_lane_fx_param(e, 0, 0, 0, 2, 1.0f); /* full wet */
  le_engine_set_lane_fx_count(e, 0, 0, 1);
  process_const(e, 0.0f, 64, out);
  CHECK(fabsf(out[0]) < 1e-6f);  /* nothing in the line yet */
  CHECK(out[63] > 0.9f);         /* the delayed signal has arrived */

  le_engine_destroy(e);
}

/* Reverb is a dense decaying tail, not discrete repeats: at full wet the output
 * starts silent (the wet path carries only reflections, the lines start empty)
 * then a sustained, bounded tail builds as reflections accumulate; at zero mix
 * it passes the dry signal through untouched. */
static void test_fx_reverb_builds_a_tail(void) {
  printf("test_fx_reverb_builds_a_tail\n");
  le_engine* e = make_configured_engine();
  float out[64];
  establish_loop(e, 1.0f); /* the loop plays a constant 1.0 */

  le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_REVERB);
  le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 0.6f); /* size */
  le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 0.5f); /* damping */
  le_engine_set_lane_fx_param(e, 0, 0, 0, 2, 0.0f); /* mix = fully dry */
  le_engine_set_lane_fx_count(e, 0, 0, 1);

  /* Dry: the loop passes through unchanged. */
  process_const(e, 0.0f, 64, out);
  for (int i = 0; i < 64; ++i) CHECK(fabsf(out[i] - 1.0f) < 1e-6f);

  /* Full wet: the first reflected sample is still silent (shortest comb line is
   * far longer than the blocks processed so far). */
  le_engine_set_lane_fx_param(e, 0, 0, 0, 2, 1.0f); /* mix = fully wet */
  process_const(e, 0.0f, 64, out);
  CHECK(fabsf(out[0]) < 1e-6f);

  /* Process ~12.8 k more frames: a real tail appears, stays finite, and never
   * blows up despite the comb feedback. */
  float peak = 0.0f;
  int sustained = 0;
  for (int b = 0; b < 200; ++b) {
    process_const(e, 0.0f, 64, out);
    for (int i = 0; i < 64; ++i) {
      const float a = fabsf(out[i]);
      if (a > peak) peak = a;
      if (a > 1e-4f) sustained++;
      CHECK(out[i] == out[i]); /* never NaN */
      CHECK(a < 8.0f);         /* stable, never blows up */
    }
  }
  CHECK(peak > 0.05f);     /* a genuine tail developed */
  CHECK(sustained > 2000); /* dense and sustained, not a lone blip */

  le_engine_destroy(e);
}

/* Reverb turns a mono source into a decorrelated stereo tail: routed to two
 * output channels, the left and right tails both develop but are not identical
 * (the right bank's lines are offset by the stereo spread). A lane with one
 * output instead gets the collapsed (L+R)/2 mono sum (covered above). */
static void test_fx_reverb_is_stereo(void) {
  printf("test_fx_reverb_is_stereo\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 2, 1000); /* mono in, STEREO out */
  float out[128];                            /* 2 channels * 64 frames */
  establish_loop(e, 1.0f); /* track 0 plays a constant 1.0 to outs 0 + 1 */

  le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_REVERB);
  le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 0.6f); /* size */
  le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 0.3f); /* damping */
  le_engine_set_lane_fx_param(e, 0, 0, 0, 2, 1.0f); /* mix = fully wet */
  le_engine_set_lane_fx_count(e, 0, 0, 1);

  float peak_l = 0.0f;
  float peak_r = 0.0f;
  float max_diff = 0.0f;
  for (int b = 0; b < 200; ++b) { /* ~12.8 k frames */
    process_const(e, 0.0f, 64, out);
    for (int i = 0; i < 64; ++i) {
      const float l = out[i * 2 + 0];
      const float r = out[i * 2 + 1];
      if (fabsf(l) > peak_l) peak_l = fabsf(l);
      if (fabsf(r) > peak_r) peak_r = fabsf(r);
      if (fabsf(l - r) > max_diff) max_diff = fabsf(l - r);
      CHECK(l == l && r == r);              /* never NaN */
      CHECK(fabsf(l) < 8.0f && fabsf(r) < 8.0f); /* stable */
    }
  }
  CHECK(peak_l > 0.05f);   /* a tail on the left */
  CHECK(peak_r > 0.05f);   /* a tail on the right */
  CHECK(max_diff > 0.01f); /* the two are decorrelated, not a dup */

  le_engine_destroy(e);
}

static void test_fx_tremolo_modulates_amplitude(void) {
  printf("test_fx_tremolo_modulates_amplitude\n");
  le_engine* e = make_configured_engine();
  float out[64];
  establish_loop(e, 1.0f);

  /* Full depth, phase reset to 0 at engage: the first sample sees lfo = 0.5, so
   * out[0] = 1 * (1 - depth * (1 - 0.5)) = 0.5. */
  le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_TREMOLO);
  le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 0.0f); /* slow rate */
  le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 1.0f); /* full depth */
  le_engine_set_lane_fx_count(e, 0, 0, 1);
  process_const(e, 0.0f, LOOP_N, out);
  CHECK(fabsf(out[0] - 0.5f) < 1e-3f);
  /* Stays within the modulation bound [0, 1] for a constant 1.0 source. */
  for (int i = 0; i < LOOP_N; ++i)
    CHECK(out[i] >= -1e-6f && out[i] <= 1.0f + 1e-6f);

  le_engine_destroy(e);
}

static void test_fx_chain_applies_in_order(void) {
  printf("test_fx_chain_applies_in_order\n");
  le_engine* e = make_configured_engine();
  float out[64];
  establish_loop(e, 1.0f);

  /* Entry 0 drive (out = tanh(1) ~= 0.7616), entry 1 a unity drive feeding on
   * the previous result: tanh(0.7616) ~= 0.6420. Confirms entries compose. */
  fx_drive_unity(e, 0);
  fx_drive_unity(e, 1);
  le_engine_set_lane_fx_count(e, 0, 0, 2);
  process_const(e, 0.0f, LOOP_N, out);
  const float expected = tanhf(tanhf(1.0f));
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - expected) < 1e-5f);

  le_engine_destroy(e);
}

/* A lane's effect chain is non-destructive: it never prints into the recording
 * (the buffer stays dry) but does color playback. */
static void test_fx_nondestructive_and_colors_playback(void) {
  printf("test_fx_nondestructive_and_colors_playback\n");
  le_engine* e = make_configured_engine();
  float out[64];

  /* Record the DRY input (1.0); the input monitor chain is empty, so the
   * snapshot leaves lane 0 clean. */
  establish_loop(e, 1.0f);

  /* Engage a drive on the lane post-record (the per-lane editor): the buffer is
   * untouched. */
  fx_drive_unity(e, 0);
  le_engine_set_lane_fx_count(e, 0, 0, 1);
  drain(e);

  /* With the effect engaged, playback runs it: out = tanh(loop) = tanh(1). */
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - tanhf(1.0f)) < 1e-5f);

  /* Remove every effect: the loop now plays back dry (1.0), proving the
   * recording was never wet-printed. */
  le_engine_set_lane_fx_count(e, 0, 0, 0);
  drain(e);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.0f) < 1e-6f);

  le_engine_destroy(e);
}

static void test_fx_muted_track_is_silent(void) {
  printf("test_fx_muted_track_is_silent\n");
  le_engine* e = make_configured_engine();
  float out[64];
  establish_loop(e, 1.0f);

  fx_drive_unity(e, 0);
  le_engine_set_lane_fx_count(e, 0, 0, 1);
  le_engine_set_track_mute(e, 0, 1);
  drain(e);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i]) < 1e-6f);

  le_engine_destroy(e);
}

static void test_fx_rejects_invalid_args(void) {
  printf("test_fx_rejects_invalid_args\n");
  le_engine* e = make_configured_engine();

  CHECK(le_engine_set_lane_fx(e, -1, 0, 0, LE_FX_DRIVE) == LE_ERR_INVALID);
  CHECK(le_engine_set_lane_fx(e, 0, LE_MAX_LANES, 0, LE_FX_DRIVE) ==
        LE_ERR_INVALID);
  CHECK(le_engine_set_lane_fx(e, 0, 0, LE_FX_MAX, LE_FX_DRIVE) ==
        LE_ERR_INVALID);
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, 99) == LE_ERR_INVALID);
  CHECK(le_engine_set_lane_fx(NULL, 0, 0, 0, LE_FX_DRIVE) == LE_ERR_INVALID);
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, -1, 0, 0.5f) == LE_ERR_INVALID);
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, LE_FX_PARAMS, 0.5f) ==
        LE_ERR_INVALID);
  CHECK(le_engine_set_lane_fx_count(e, 0, LE_MAX_LANES, 1) == LE_ERR_INVALID);

  /* LE_FX_REVERB is the current highest type: accepted, while one past it is
   * rejected — locking the validated upper bound. */
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_REVERB) == LE_OK);
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_REVERB + 1) == LE_ERR_INVALID);

  /* Out-of-range parameter values clamp to [0, 1] rather than erroring; an
   * over-large count clamps to LE_FX_MAX. */
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 5.0f) == LE_OK);
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 0, -5.0f) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 999) == LE_OK);

  le_engine_destroy(e);
}

/* Regression guard for the reported Reverb -> Drive bug. The old engine only
 * spread to stereo on the reverb and processed every later effect on the left
 * channel alone, so a drive after a reverb saturated the left while the right
 * passed through clean (audibly lopsided). With the full-stereo chain the drive
 * must colour BOTH channels.
 *
 * Two identical runs: reverb only, then reverb -> drive. The drive sits
 * downstream of the reverb and never feeds back into it, so the reverb tail is
 * bit-identical between runs; comparing the driven output against the clean
 * reverb output isolates exactly what the drive did to each channel. */
static void test_fx_reverb_then_mono_effect_is_stereo(void) {
  printf("test_fx_reverb_then_mono_effect_is_stereo\n");
  /* WARM blocks of 64 frames let the reverb tail (shortest comb ~1116 samples)
   * fully develop into a dense, sustained level before we sample it. */
  const int WARM = 200; /* ~12.8 k frames */
  float rev_l[64], rev_r[64], drv_l[64], drv_r[64];

  /* Run A: reverb only — capture the steady-state stereo tail. */
  {
    le_engine* e = le_engine_create();
    le_engine_configure(e, 48000, 1, 2, 1000); /* mono in, STEREO out */
    float out[128];
    establish_loop(e, 1.0f); /* constant 1.0 to outs 0 + 1 */
    le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_REVERB);
    le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 0.6f); /* size */
    le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 0.3f); /* damping */
    le_engine_set_lane_fx_param(e, 0, 0, 0, 2, 1.0f); /* fully wet */
    le_engine_set_lane_fx_count(e, 0, 0, 1);
    for (int b = 0; b < WARM; ++b) process_const(e, 0.0f, 64, out);
    process_const(e, 0.0f, 64, out);
    for (int i = 0; i < 64; ++i) {
      rev_l[i] = out[i * 2 + 0];
      rev_r[i] = out[i * 2 + 1];
    }
    le_engine_destroy(e);
  }

  /* Run B: reverb -> drive (max pre-gain) — identical reverb input. */
  {
    le_engine* e = le_engine_create();
    le_engine_configure(e, 48000, 1, 2, 1000);
    float out[128];
    establish_loop(e, 1.0f);
    le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_REVERB);
    le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 0.6f);
    le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 0.3f);
    le_engine_set_lane_fx_param(e, 0, 0, 0, 2, 1.0f);
    le_engine_set_lane_fx(e, 0, 0, 1, LE_FX_DRIVE);
    le_engine_set_lane_fx_param(e, 0, 0, 1, 0, 1.0f); /* 30x pre-gain */
    le_engine_set_lane_fx_param(e, 0, 0, 1, 1, 1.0f); /* unity output level */
    le_engine_set_lane_fx_count(e, 0, 0, 2);
    for (int b = 0; b < WARM; ++b) process_const(e, 0.0f, 64, out);
    process_const(e, 0.0f, 64, out);
    for (int i = 0; i < 64; ++i) {
      drv_l[i] = out[i * 2 + 0];
      drv_r[i] = out[i * 2 + 1];
    }
    le_engine_destroy(e);
  }

  float diff_l = 0.0f, diff_r = 0.0f, peak_l = 0.0f, peak_r = 0.0f;
  for (int i = 0; i < 64; ++i) {
    diff_l += fabsf(drv_l[i] - rev_l[i]);
    diff_r += fabsf(drv_r[i] - rev_r[i]);
    if (fabsf(drv_l[i]) > peak_l) peak_l = fabsf(drv_l[i]);
    if (fabsf(drv_r[i]) > peak_r) peak_r = fabsf(drv_r[i]);
  }
  /* The drive moved BOTH channels off their clean reverb value — the bug left
   * the right channel passing through untouched (diff_r would be exactly 0). The
   * 0.1 floor is far above float noise yet far below the real per-channel delta:
   * at 30x pre-gain tanh saturates the sustained tail, so each channel's summed
   * change over 64 frames is order ~1, not ~0.1. */
  CHECK(diff_l > 0.1f);
  CHECK(diff_r > 0.1f);
  /* and pushed both toward the saturation level (|tanh| -> 1), not just one. */
  CHECK(peak_l > 0.5f);
  CHECK(peak_r > 0.5f);
}

/* Drives a fresh DELAY chain with an impulse on a single channel, returning the
 * tap on that channel after `d` samples and the largest leak onto the other
 * channel. A fresh engine per call keeps each ring's contents clean. */
static void impulse_through_delay(int on_right, int d, float* tap,
                                  float* max_off) {
  le_engine* e = make_configured_engine();
  le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DELAY);
  le_engine_set_lane_fx_param(e, 0, 0, 0, 0, (float)d / 47999.0f); /* ~d frames */
  le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 0.0f);               /* no feedback */
  le_engine_set_lane_fx_param(e, 0, 0, 0, 2, 1.0f);              /* full wet */
  le_engine_set_lane_fx_count(e, 0, 0, 1);
  drain(e); /* allocate both rings + reset DSP state before driving the chain */

  *tap = 0.0f;
  *max_off = 0.0f;
  for (int n = 0; n <= d; ++n) {
    float l = (!on_right && n == 0) ? 1.0f : 0.0f;
    float r = (on_right && n == 0) ? 1.0f : 0.0f;
    le_engine_lane_fx_chain_for_test(e, 0, 0, &l, &r);
    const float sig = on_right ? r : l; /* the impulse's own channel */
    const float off = on_right ? l : r; /* the other channel */
    if (n == d) *tap = sig;
    if (fabsf(off) > *max_off) *max_off = fabsf(off);
  }
  le_engine_destroy(e);
}

/* Proves the [slot][1] ring is wired and fully independent of [slot][0]: an
 * impulse on one channel taps only that channel after the delay time, never
 * leaking onto the other. A shared/interleaved ring would cross-talk. */
static void test_fx_stereo_chain_independent_lr_state(void) {
  printf("test_fx_stereo_chain_independent_lr_state\n");
  const int d = 10;
  float tap, max_off;

  impulse_through_delay(0, d, &tap, &max_off); /* impulse on L only */
  CHECK(fabsf(tap - 1.0f) < 1e-6f);            /* the L tap returns */
  CHECK(max_off < 1e-6f);                      /* R never saw the L impulse */

  impulse_through_delay(1, d, &tap, &max_off); /* impulse on R only */
  CHECK(fabsf(tap - 1.0f) < 1e-6f);            /* the R tap returns */
  CHECK(max_off < 1e-6f);                      /* L never saw the R impulse */
}

/* Acceptance: one slot reordered DELAY -> REVERB -> DELAY within its lifetime
 * reuses its rings without leaking, double-allocating, or misreading. The first
 * DELAY allocates both rings; REVERB keeps ring[0] and retains ring[1] (it never
 * frees it); the second DELAY reuses both. After the round trip the delay must
 * still tap correctly with the right channel fully independent — proving ring[1]
 * survived and was reused — and destroy must free each retained ring exactly
 * once (no double-free). */
static void test_fx_stereo_ring_retained_across_type_reorder(void) {
  printf("test_fx_stereo_ring_retained_across_type_reorder\n");
  le_engine* e = make_configured_engine();
  const int d = 10;

  le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DELAY);  /* allocates [0] and [1] */
  le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_REVERB); /* keeps [0], retains [1] */
  le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DELAY);  /* reuses both rings */
  le_engine_set_lane_fx_param(e, 0, 0, 0, 0, (float)d / 47999.0f);
  le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 0.0f); /* no feedback */
  le_engine_set_lane_fx_param(e, 0, 0, 0, 2, 1.0f); /* full wet */
  le_engine_set_lane_fx_count(e, 0, 0, 1);
  drain(e);

  float tap = 0.0f, max_off = 0.0f;
  for (int n = 0; n <= d; ++n) {
    float l = (n == 0) ? 1.0f : 0.0f;
    float r = 0.0f;
    le_engine_lane_fx_chain_for_test(e, 0, 0, &l, &r);
    if (n == d) tap = l;
    if (fabsf(r) > max_off) max_off = fabsf(r);
  }
  CHECK(fabsf(tap - 1.0f) < 1e-6f); /* the delay still taps after the reorder */
  CHECK(max_off < 1e-6f);           /* the reused R ring is still independent */

  le_engine_destroy(e); /* must free each retained ring exactly once */
}

/* The monitor-lane setters reject a null engine and out-of-range input / lane /
 * index / type / param args; values clamp rather than erroring. */
static void test_monitor_input_fx_rejects_invalid_args(void) {
  printf("test_monitor_input_fx_rejects_invalid_args\n");
  le_engine* e = make_configured_engine();

  CHECK(le_engine_set_monitor_input(NULL, 0, 1) == LE_ERR_INVALID);
  CHECK(le_engine_set_monitor_input(e, -1, 1) == LE_ERR_INVALID);
  CHECK(le_engine_set_monitor_input(e, LE_MAX_INPUTS, 1) == LE_ERR_INVALID);

  /* The single-chain setters reject an out-of-range input. */
  CHECK(le_engine_set_monitor_input_output(e, -1, 0x1) == LE_ERR_INVALID);
  CHECK(le_engine_set_monitor_input_output(e, LE_MAX_INPUTS, 0x1) ==
        LE_ERR_INVALID);
  CHECK(le_engine_set_monitor_input_mute(e, -1, 1) == LE_ERR_INVALID);

  CHECK(le_engine_set_monitor_input_fx(NULL, 0, 0, LE_FX_DRIVE) ==
        LE_ERR_INVALID);
  CHECK(le_engine_set_monitor_input_fx(e, -1, 0, LE_FX_DRIVE) == LE_ERR_INVALID);
  CHECK(le_engine_set_monitor_input_fx(e, LE_MAX_INPUTS, 0, LE_FX_DRIVE) ==
        LE_ERR_INVALID);
  CHECK(le_engine_set_monitor_input_fx(e, 0, LE_FX_MAX, LE_FX_DRIVE) ==
        LE_ERR_INVALID);
  CHECK(le_engine_set_monitor_input_fx(e, 0, 0, 99) == LE_ERR_INVALID);
  CHECK(le_engine_set_monitor_input_fx_param(e, 0, -1, 0, 0.5f) ==
        LE_ERR_INVALID);
  CHECK(le_engine_set_monitor_input_fx_param(e, 0, 0, LE_FX_PARAMS, 0.5f) ==
        LE_ERR_INVALID);

  /* Over-range values clamp; an over-large count clamps to LE_FX_MAX. */
  CHECK(le_engine_set_monitor_input_fx_param(e, 0, 0, 0, 5.0f) == LE_OK);
  CHECK(le_engine_set_monitor_input_fx_count(e, 0, 999) == LE_OK);

  le_engine_destroy(e);
}

/* ---- session persistence ---- */

static void test_session_export_import_roundtrip(void) {
  printf("test_session_export_import_roundtrip\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  /* Build a session: track 0 = base loop 1.0; track 1 = 2-loop 2.0 then 3.0. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);
  le_engine_record(e, 1);
  process_const(e, 2.0f, LOOP_N, out);
  process_const(e, 3.0f, LOOP_N, out);
  le_engine_record(e, 1); /* finalize -> k = 2 */
  drain(e);

  /* Export both tracks' PCM (mono here, so frames == samples). */
  float stem0[64];
  float stem1[64];
  CHECK(le_engine_export_track(e, 0, stem0, 64) == LOOP_N);
  CHECK(le_engine_export_track(e, 1, stem1, 64) == 2 * LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(stem0[i] - 1.0f) < 1e-6f);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(stem1[i] - 2.0f) < 1e-6f);
  for (int i = LOOP_N; i < 2 * LOOP_N; ++i) {
    CHECK(fabsf(stem1[i] - 3.0f) < 1e-6f);
  }

  /* Tear the session down. */
  le_engine_clear(e, 0);
  le_engine_clear(e, 1);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 0);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);

  /* Reload from the exported stems and commit. */
  CHECK(le_engine_import_track(e, 0, stem0, LOOP_N) == LE_OK);
  CHECK(le_engine_import_track(e, 1, stem1, 2 * LOOP_N) == LE_OK);
  CHECK(le_engine_commit_session(e, LOOP_N) == LE_OK);
  drain(e);

  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == LOOP_N);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].multiple == 1);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].multiple == 2);
  CHECK(s.tracks[1].length_frames == 2 * LOOP_N);

  /* Playback reproduces it: 1+2 then 1+3, alternating. */
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 3.0f) < 1e-6f);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 4.0f) < 1e-6f);

  /* Importing into a non-empty track is rejected. */
  CHECK(le_engine_import_track(e, 0, stem0, LOOP_N) == LE_ERR_INVALID);

  le_engine_destroy(e);
}

/* ---- multi-lane tracks ---- */

/* Configures a 2-in/2-out engine, gives track 0 two lanes recording inputs 0
 * and 1, and routes BOTH lanes to output channel 0 only (so the un-merged sum
 * is observable on out 0 while out 1 stays clear). */
static le_engine* make_two_lane_engine(void) {
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000);
  le_engine_set_lane_count(e, 0, 2);
  le_engine_set_lane_input(e, 0, 0, 0);  /* lane 0 records input 0 */
  le_engine_set_lane_input(e, 0, 1, 1);  /* lane 1 records input 1 */
  le_engine_set_lane_output(e, 0, 0, 0x1);
  le_engine_set_lane_output(e, 0, 1, 0x1);
  drain(e);
  return e;
}

/* Records LOOP_N frames into track 0 with ch0 = `a`, ch1 = `b`, then finalizes
 * the loop to PLAYING. */
static void record_two_lane(le_engine* e, float a, float b) {
  float out[2 * LOOP_N];
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = a;
    in[i * 2 + 1] = b;
  }
  le_engine_record(e, 0);
  le_engine_process(e, out, in, LOOP_N);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);
}

/* Two inputs assigned to one track record as two separate clean lanes; both
 * play back and are summed (never merged/averaged) on the shared output. */
static void test_two_lanes_unmerged_both_play(void) {
  printf("test_two_lanes_unmerged_both_play\n");
  le_engine* e = make_two_lane_engine();
  float out[2 * LOOP_N];
  le_snapshot s;

  record_two_lane(e, 1.0f, 2.0f);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].lane_count == 2);

  le_lane_snapshot ls0, ls1;
  le_engine_get_lane(e, 0, 0, &ls0);
  le_engine_get_lane(e, 0, 1, &ls1);
  CHECK(ls0.input_channel == 0);
  CHECK(ls1.input_channel == 1);
  CHECK(ls0.length_frames == LOOP_N);
  CHECK(ls1.length_frames == LOOP_N);

  /* Playback over silence: lane 0 (1.0) + lane 1 (2.0) summed on out 0 == 3.0
   * (an average would be 1.5); out 1 is silent (both lanes route to out 0). */
  float zin[2 * LOOP_N] = {0};
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 3.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1]) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* A lane's effect chain colors only its own lane: a drive on lane 0 wets only
 * lane 0's playback while sibling lane 1 stays dry. */
static void test_lane_fx_colors_only_its_lane(void) {
  printf("test_lane_fx_colors_only_its_lane\n");
  le_engine* e = make_two_lane_engine();
  float out[2 * LOOP_N];
  float zin[2 * LOOP_N] = {0};

  /* Observe the lanes separately: lane 1 -> out 1. */
  le_engine_set_lane_output(e, 0, 1, 0x2);
  drain(e);

  record_two_lane(e, 1.0f, 2.0f); /* lane0 records 1.0, lane1 records 2.0 */

  /* Post-record, set a unity drive on lane 0 only (the per-lane "tweak this take"
   * editor — distinct from the pre-record input chain that the snapshot copies). */
  le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DRIVE);
  le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 0.0f); /* 1x pre-gain */
  le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 1.0f); /* unity level */
  le_engine_set_lane_fx_count(e, 0, 0, 1);
  drain(e);

  /* Playback over silence: lane 0 is driven (tanh(1.0)) on out 0; lane 1 is dry
   * (2.0) on out 1 — the effect never bled across lanes. */
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - tanhf(1.0f)) < 1e-5f);
    CHECK(fabsf(out[i * 2 + 1] - 2.0f) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* Per-lane volume and mute act independently on each lane's contribution. */
static void test_lane_volume_and_mute(void) {
  printf("test_lane_volume_and_mute\n");
  le_engine* e = make_two_lane_engine();
  float out[2 * LOOP_N];
  float zin[2 * LOOP_N] = {0};

  record_two_lane(e, 1.0f, 2.0f); /* lane0 = 1.0, lane1 = 2.0 */

  /* Halve lane 1 only: out 0 == 1.0 + 2.0*0.5 == 2.0. */
  CHECK(le_engine_set_lane_volume(e, 0, 1, 0.5f) == LE_OK);
  drain(e);
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i * 2 + 0] - 2.0f) < 1e-6f);

  /* Mute lane 0: only the halved lane 1 remains, out 0 == 1.0. */
  CHECK(le_engine_set_lane_mute(e, 0, 0, 1) == LE_OK);
  drain(e);
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);

  le_lane_snapshot ls1;
  le_engine_get_lane(e, 0, 1, &ls1);
  CHECK(fabsf(ls1.volume - 0.5f) < 1e-6f);

  le_engine_destroy(e);
}

/* One undo on the track removes the last overdub pass across ALL its lanes
 * consistently (the one shared undo span drives every lane in lockstep). */
static void test_undo_across_lanes(void) {
  printf("test_undo_across_lanes\n");
  le_engine* e = make_two_lane_engine();
  float out[2 * LOOP_N];
  float zin[2 * LOOP_N] = {0};
  le_snapshot s;

  /* Route the lanes to SEPARATE outputs so each lane's undo is observed alone
   * (a lane-aliasing bug would surface as one output taking the other's value),
   * and overdub with ASYMMETRIC per-lane deltas so the two lanes never share a
   * value the undo could accidentally satisfy. */
  CHECK(le_engine_set_lane_output(e, 0, 1, 0x2) == LE_OK); /* lane 1 -> out 1 */
  drain(e);
  record_two_lane(e, 1.0f, 2.0f); /* lane0 = 1.0 (out0), lane1 = 2.0 (out1) */
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 2.0f) < 1e-6f);
  }

  /* Overdub +0.25 on input 0, +0.5 on input 1: lane0 -> 1.25, lane1 -> 2.5.
   * The layer is captured per pass on the audio thread and retires when the
   * pass completes. */
  CHECK(le_engine_record(e, 0) == LE_OK); /* -> OVERDUBBING */
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 0.25f;
    in[i * 2 + 1] = 0.5f;
  }
  le_engine_process(e, out, in, LOOP_N);
  le_engine_record(e, 0); /* OVERDUBBING -> PLAYING */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 1); /* the completed pass retired */
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.25f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 2.5f) < 1e-6f);
  }
  drain(e); /* punch envelope quiet: the capture session winds down */

  /* Undo reverts BOTH lanes' last pass at once, each back to its own value. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 2.0f) < 1e-6f);
  }
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 0);
  CHECK(s.tracks[0].redo_depth == 1);

  /* Redo restores both lanes to their own overdubbed values. */
  CHECK(le_engine_redo(e, 0) == LE_OK);
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.25f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 2.5f) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* Idle lanes stay unallocated; growing the lane count lazily allocates the new
 * lanes' buffers on the control thread (keeping idle memory flat). */
static void test_lazy_lane_allocation(void) {
  printf("test_lazy_lane_allocation\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000);

  /* Fresh: only lane 0 of each track is allocated. */
  CHECK(le_engine_lane_buffer_allocated_for_test(e, 0, 0) == 1);
  CHECK(le_engine_lane_buffer_allocated_for_test(e, 0, 1) == 0);
  CHECK(le_engine_lane_buffer_allocated_for_test(e, 3, 0) == 1);
  CHECK(le_engine_lane_buffer_allocated_for_test(e, 3, 1) == 0);

  /* Growing track 0 to three lanes allocates lanes 1 and 2 (and only those). */
  CHECK(le_engine_set_lane_count(e, 0, 3) == LE_OK);
  CHECK(le_engine_lane_buffer_allocated_for_test(e, 0, 1) == 1);
  CHECK(le_engine_lane_buffer_allocated_for_test(e, 0, 2) == 1);
  CHECK(le_engine_lane_buffer_allocated_for_test(e, 0, 3) == 0);
  /* Untouched tracks keep just lane 0. */
  CHECK(le_engine_lane_buffer_allocated_for_test(e, 1, 1) == 0);

  le_engine_destroy(e);
}

/* Each lane's phase-locked write head matches the single-buffer baseline: a new
 * two-lane track recorded mid-loop captures the silent pre-press slice and the
 * post-press signal identically on every lane (cf. the single-lane
 * test_new_track_records_mid_loop). */
static void test_lane_phase_lock_matches_baseline(void) {
  printf("test_lane_phase_lock_matches_baseline\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000);
  float out[2 * 64];
  le_snapshot s;

  /* Track 0 (single lane) defines the master loop, then is muted. */
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 1.0f;
    in[i * 2 + 1] = 0.0f;
  }
  le_engine_record(e, 0);
  le_engine_process(e, out, in, LOOP_N);
  le_engine_record(e, 0); /* finalize -> master == LOOP_N */
  drain(e);
  le_engine_set_lane_mute(e, 0, 0, 1);

  /* Track 1 gets two lanes (in0 -> out0, in1 -> out1). */
  le_engine_set_lane_count(e, 1, 2);
  le_engine_set_lane_input(e, 1, 0, 0);
  le_engine_set_lane_input(e, 1, 1, 1);
  le_engine_set_lane_output(e, 1, 0, 0x1);
  le_engine_set_lane_output(e, 1, 1, 0x2);
  drain(e);

  /* Advance one frame past the loop top, then record mid-loop. */
  float zin[2 * LOOP_N] = {0};
  le_engine_process(e, out, zin, 1);
  le_engine_record(e, 1);
  for (int i = 0; i < LOOP_N - 1; ++i) {
    in[i * 2 + 0] = 2.0f;
    in[i * 2 + 1] = 3.0f;
  }
  le_engine_process(e, out, in, LOOP_N - 1); /* pos 1,2,3 -> wraps to the top */
  le_engine_record(e, 1);                    /* finalize -> PLAYING */
  drain(e);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].lane_count == 2);

  /* One full loop from the top: each lane is phase-locked — pos 0 silent (the
   * pre-press slice), pos 1..3 its recorded signal — identically. */
  le_engine_process(e, out, zin, LOOP_N);
  CHECK(fabsf(out[0]) < 1e-6f);     /* lane 0 -> out 0, pos 0 silent */
  CHECK(fabsf(out[1]) < 1e-6f);     /* lane 1 -> out 1, pos 0 silent */
  for (int i = 1; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 2.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 3.0f) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* Real-time null-guard: when the active lane count claims more lanes than are
 * allocated (the lazy-alloc window, forced here), the audio thread plays/records
 * the allocated lanes and leaves the unallocated ones silent — never
 * dereferencing a NULL pool. */
static void test_lane_null_guard(void) {
  printf("test_lane_null_guard\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000);
  float out[2 * LOOP_N];

  /* Force three lanes without allocating lanes 1 and 2. */
  le_engine_set_lane_count_unsafe_for_test(e, 0, 3);
  CHECK(le_engine_lane_buffer_allocated_for_test(e, 0, 1) == 0);
  CHECK(le_engine_lane_buffer_allocated_for_test(e, 0, 2) == 0);

  /* Record and play with a hot bus on every input: lane 0 (allocated) captures
   * input 0; lanes 1 and 2 (NULL buffers) record/play nothing, no crash. */
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 1.0f;
    in[i * 2 + 1] = 1.0f;
  }
  le_engine_record(e, 0);
  le_engine_process(e, out, in, LOOP_N);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);

  /* Lane 0 plays its 1.0 to the default output pair; the guarded lanes add
   * nothing (out == lane 0 alone, not 2.0/3.0 from the would-be NULL lanes). */
  float zin[2 * LOOP_N] = {0};
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 1.0f) < 1e-6f);
  }

  /* The OVERDUBBING path does a read-before-write on each lane's buffer — drive
   * it with the guarded NULL lanes present to prove that path is guarded too. */
  CHECK(le_engine_record(e, 0) == LE_OK); /* -> OVERDUBBING */
  le_engine_process(e, out, in, LOOP_N);  /* overdubs lane 0, skips NULL lanes */
  le_engine_record(e, 0);                 /* -> PLAYING */
  drain(e);
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    /* lane 0 now holds 1.0 + 1.0 == 2.0; the guarded lanes still contribute 0. */
    CHECK(fabsf(out[i * 2 + 0] - 2.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 2.0f) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* Shrinking the lane count stops the dropped lanes; re-growing reactivates them
 * cleanly (a clean buffer, not stale content) without re-allocating from
 * scratch — the lazy buffers are retained for reuse. */
static void test_lane_count_shrink_then_regrow(void) {
  printf("test_lane_count_shrink_then_regrow\n");
  le_engine* e = make_two_lane_engine();
  float out[2 * LOOP_N];
  float zin[2 * LOOP_N] = {0};
  le_snapshot s;

  record_two_lane(e, 1.0f, 2.0f); /* lane0 -> out0, lane1 -> out0; sum 3.0 */
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i * 2 + 0] - 3.0f) < 1e-6f);

  /* Shrink to one lane: lane 1 stops contributing, only lane 0 (1.0) plays. Its
   * buffer is retained for reuse (still allocated). */
  CHECK(le_engine_set_lane_count(e, 0, 1) == LE_OK);
  CHECK(le_engine_lane_buffer_allocated_for_test(e, 0, 1) == 1);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].lane_count == 1);
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);

  /* Re-grow to two lanes: lane 1 comes back reset (default input 1, clean buffer
   * — NOT the stale 2.0), so it plays silence until recorded again. */
  CHECK(le_engine_set_lane_count(e, 0, 2) == LE_OK);
  drain(e);
  le_lane_snapshot ls1;
  le_engine_get_lane(e, 0, 1, &ls1);
  CHECK(ls1.input_channel == 1);
  CHECK(ls1.length_frames == 0);
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);

  le_engine_destroy(e);
}

/* A quantized overdub on a multi-lane track fires on the grid, its layer is
 * captured per pass across ALL active lanes (one shared undo span), and a
 * later undo reverts every lane in lockstep. */
static void test_multi_lane_quantize_overdub_arm(void) {
  printf("test_multi_lane_quantize_overdub_arm\n");
  le_engine* e = make_two_lane_engine();
  float out[2 * LOOP_N];
  float zin[2 * LOOP_N] = {0};
  le_snapshot s;

  le_engine_set_lane_output(e, 0, 1, 0x2); /* lane 1 -> out 1 (observe alone) */
  drain(e);
  record_two_lane(e, 1.0f, 2.0f); /* master LOOP_N; lane0=1.0, lane1=2.0 */
  CHECK(le_engine_set_quantize(e, 1) == LE_OK);

  /* Move off the loop top, then arm the overdub: arming creates no layer (the
   * pass captures itself once the overdub runs). */
  le_engine_process(e, out, zin, 1); /* pos -> 1 */
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING); /* armed, not overdubbing yet */
  CHECK(s.tracks[0].undo_depth == 0);

  /* pos 1 -> 2 -> 3 -> wrap: the overdub fires at the loop top. */
  le_engine_process(e, out, zin, 3);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);

  /* Overdub one full loop with asymmetric per-lane deltas, then finalize. */
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 0.25f;
    in[i * 2 + 1] = 0.5f;
  }
  le_engine_process(e, out, in, LOOP_N);
  le_engine_record(e, 0); /* punch-out press — quantized: fires at the wrap */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 1); /* the completed dub pass retired */
  /* While the quantized punch-out waits for the loop top the overdub keeps
   * running one more (silent-input) pass — itself a completed layer under
   * per-pass undo. The wrap then flips the track back to PLAYING. */
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.25f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 2.5f) < 1e-6f);
  }
  le_engine_process(e, out, zin, 1); /* settle the punch envelope */
  drain(e); /* punch envelope quiet: the capture session winds down */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].undo_depth == 2);

  /* Undo peels the silent waiting pass (no audible change), then the dub —
   * both lanes reverted at once each step (the one shared undo span). */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 1.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 2.0f) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* A multi-lane track with a fixed 2-base-loop length plays each lane's two
 * segments in lockstep: the shared segment base applies identically to every
 * lane. */
static void test_multi_lane_loop_multiple(void) {
  printf("test_multi_lane_loop_multiple\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000);
  float out[2 * LOOP_N];
  float zin[2 * LOOP_N] = {0};
  float in[2 * LOOP_N];
  le_snapshot s;

  /* Track 0 (single lane) defines the master loop, then muted. */
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 1.0f;
    in[i * 2 + 1] = 0.0f;
  }
  le_engine_record(e, 0);
  le_engine_process(e, out, in, LOOP_N);
  le_engine_record(e, 0); /* finalize -> master == LOOP_N */
  drain(e);
  le_engine_set_lane_mute(e, 0, 0, 1);

  /* Track 1: two lanes (in0 -> out0, in1 -> out1), fixed to two base loops. */
  le_engine_set_lane_count(e, 1, 2);
  le_engine_set_lane_input(e, 1, 0, 0);
  le_engine_set_lane_input(e, 1, 1, 1);
  le_engine_set_lane_output(e, 1, 0, 0x1);
  le_engine_set_lane_output(e, 1, 1, 0x2);
  le_engine_set_track_multiple(e, 1, 2);
  drain(e);

  /* Record two base loops: segment 0 (ch0=2, ch1=5), segment 1 (ch0=3, ch1=6).
   * Pressed at the loop top, it auto-finalizes after exactly two base loops. */
  le_engine_record(e, 1);
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 2.0f;
    in[i * 2 + 1] = 5.0f;
  }
  le_engine_process(e, out, in, LOOP_N); /* segment 0 */
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 3.0f;
    in[i * 2 + 1] = 6.0f;
  }
  le_engine_process(e, out, in, LOOP_N); /* segment 1 -> auto-finalize */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_OVERDUBBING); /* auto-finish keeps layering */
  CHECK(s.tracks[1].multiple == 2);
  CHECK(s.tracks[1].lane_count == 2);

  /* Playback: both lanes alternate their two segments together. */
  le_engine_process(e, out, zin, LOOP_N); /* segment 0 */
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 2.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 5.0f) < 1e-6f);
  }
  le_engine_process(e, out, zin, LOOP_N); /* segment 1 */
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 3.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 6.0f) < 1e-6f);
  }
  le_engine_process(e, out, zin, LOOP_N); /* wraps back to segment 0 */
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(out[i * 2 + 0] - 2.0f) < 1e-6f);
    CHECK(fabsf(out[i * 2 + 1] - 5.0f) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* The lane setters reject a null engine, an out-of-range lane, and (for the
 * count) an out-of-range channel; the count clamps rather than erroring. */
static void test_lane_setters_reject_invalid_args(void) {
  printf("test_lane_setters_reject_invalid_args\n");
  le_engine* e = make_configured_engine(); /* configured, device-free */

  CHECK(le_engine_set_lane_count(NULL, 0, 2) == LE_ERR_INVALID);
  CHECK(le_engine_set_lane_count(e, -1, 2) == LE_ERR_INVALID);
  CHECK(le_engine_set_lane_count(e, 99, 2) == LE_ERR_INVALID);

  CHECK(le_engine_set_lane_input(e, 0, -1, 0) == LE_ERR_INVALID);
  CHECK(le_engine_set_lane_input(e, 0, LE_MAX_LANES, 0) == LE_ERR_INVALID);
  CHECK(le_engine_set_lane_output(e, 0, LE_MAX_LANES, 0x1) == LE_ERR_INVALID);
  CHECK(le_engine_set_lane_volume(e, 0, -1, 0.5f) == LE_ERR_INVALID);
  CHECK(le_engine_set_lane_mute(e, 0, LE_MAX_LANES, 1) == LE_ERR_INVALID);

  /* Count clamps to [1, LE_MAX_LANES] rather than erroring. */
  CHECK(le_engine_set_lane_count(e, 0, 999) == LE_OK);
  CHECK(le_engine_set_lane_count(e, 0, 0) == LE_OK);

  /* get_lane on out-of-range indices yields an empty (input -1) lane. */
  le_lane_snapshot ls;
  le_engine_get_lane(e, 0, LE_MAX_LANES, &ls);
  CHECK(ls.input_channel == -1);

  le_engine_destroy(e);
}

/* Widening LE_FX_PARAMS from 3 to 4 must leave EVERY non-octaver effect inert in
 * the new slot: p3 is never read, so its value cannot change the output. Two
 * identically-driven engines — one with p3 = 0 (the default), one with p3 = 1 —
 * must produce byte-for-byte identical output across many blocks (so stateful
 * delay/echo/reverb tails are exercised too). This is the M3 "identical after
 * the widening" guard. Index 3 is also now a valid param (rejected before the
 * widening). The octaver is excluded — it will read p3 in parts 3-4. */
static void test_fx_fourth_param_is_inert(void) {
  printf("test_fx_fourth_param_is_inert\n");
  CHECK(LE_FX_PARAMS == 4);

  const int32_t types[] = {LE_FX_DRIVE,   LE_FX_FILTER, LE_FX_DELAY,
                           LE_FX_TREMOLO, LE_FX_ECHO,   LE_FX_REVERB};
  for (int t = 0; t < (int)(sizeof(types) / sizeof(types[0])); ++t) {
    le_engine* a = make_configured_engine();
    le_engine* b = make_configured_engine();
    establish_loop(a, 1.0f);
    establish_loop(b, 1.0f);

    le_engine_set_lane_fx(a, 0, 0, 0, types[t]); /* seeds p3 = 0 */
    le_engine_set_lane_fx(b, 0, 0, 0, types[t]);
    CHECK(le_engine_set_lane_fx_param(b, 0, 0, 0, 3, 1.0f) == LE_OK); /* drive p3 */
    le_engine_set_lane_fx_count(a, 0, 0, 1);
    le_engine_set_lane_fx_count(b, 0, 0, 1);

    float oa[64];
    float ob[64];
    for (int block = 0; block < 8; ++block) {
      process_const(a, 0.0f, 64, oa);
      process_const(b, 0.0f, 64, ob);
      for (int i = 0; i < 64; ++i) CHECK(oa[i] == ob[i]); /* byte-for-byte */
    }

    le_engine_destroy(a);
    le_engine_destroy(b);
  }
}

/* ---- phase-vocoder octaver (LE_FX_OCTAVER) ---- */

#define OCT_SR 48000
/* Mirrors engine.c's internal LE_PV_N (the phase-vocoder window / latency); kept
 * local because that constant is private to the engine translation unit. */
#define OCT_PV_N 1024

/* A fixed formant envelope: a resonance near 1 kHz (Gaussian in log-frequency).
 * A harmonic tone shaped by it has a spectral centroid that a formant-preserving
 * shift must hold roughly fixed — a naive resample would drag it with the pitch. */
static float oct_formant(float f) {
  const float x = log2f((f + 1.0f) / 1000.0f) / 0.9f;
  return expf(-0.5f * x * x);
}

/* Fills buf with a harmonic tone at f0 shaped by oct_formant, peak-normalized. */
static void oct_harmonic(float* buf, int n, float f0) {
  for (int i = 0; i < n; ++i) buf[i] = 0.0f;
  for (int k = 1; (float)k * f0 < (float)OCT_SR * 0.45f; ++k) {
    const float f = (float)k * f0;
    const float a = oct_formant(f);
    for (int i = 0; i < n; ++i) {
      buf[i] += a * sinf(2.0f * LE_FFT_PI * f * (float)i / (float)OCT_SR);
    }
  }
  float peak = 0.0f;
  for (int i = 0; i < n; ++i) {
    const float m = fabsf(buf[i]);
    if (m > peak) peak = m;
  }
  if (peak > 0.0f) {
    for (int i = 0; i < n; ++i) buf[i] *= 0.5f / peak;
  }
}

/* Runs `total` samples of `in` through one octaver on a mono monitor lane (full
 * wet, tone open, PV mode) at the given shift, capturing the output. */
static void oct_run(float shift, const float* in, int total, float* out) {
  le_engine* e = le_engine_create();
  const int blk = 2048;
  le_engine_configure(e, OCT_SR, 1, 1, blk);
  le_engine_set_monitor_input(e, 0, 1);
  le_engine_set_monitor_input_output(e, 0, 0x1);
  le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_OCTAVER);
  le_engine_set_monitor_input_fx_param(e, 0, 0, 0, shift); /* shift */
  le_engine_set_monitor_input_fx_param(e, 0, 0, 1, 1.0f);  /* tone open */
  le_engine_set_monitor_input_fx_param(e, 0, 0, 2, 1.0f);  /* full wet */
  le_engine_set_monitor_input_fx_param(e, 0, 0, 3, 0.0f);  /* PV mode */
  le_engine_set_monitor_input_fx_count(e, 0, 1);
  int done = 0;
  while (done < total) {
    int n = total - done;
    if (n > blk) n = blk;
    le_engine_process(e, out + done, in + done, (uint32_t)n);
    done += n;
  }
  le_engine_destroy(e);
}

/* Fundamental via autocorrelation. The first lag whose correlation reaches 90%
 * of the global peak is the true period: this avoids the octave error where a
 * sparse harmonic series (e.g. an octave-up signal whose partials are also even
 * multiples of the original f0) correlates equally at the longer period. */
static float oct_detect_f0(const float* x, int n) {
  const int minlag = OCT_SR / 1000;
  const int maxlag = OCT_SR / 70;
  double best = 0.0;
  for (int lag = minlag; lag <= maxlag; ++lag) {
    double s = 0.0;
    for (int i = 0; i + lag < n; ++i) s += (double)x[i] * (double)x[i + lag];
    if (s > best) best = s;
  }
  for (int lag = minlag; lag <= maxlag; ++lag) {
    double s = 0.0;
    for (int i = 0; i + lag < n; ++i) s += (double)x[i] * (double)x[i + lag];
    if (s >= 0.9 * best) return (float)OCT_SR / (float)lag;
  }
  return (float)OCT_SR / (float)maxlag;
}

/* Spectral centroid (Hz), averaged over 1024-sample Hann frames at 50% overlap. */
static float oct_centroid(const float* x, int n) {
  enum { F = 1024 };
  float win[F];
  float re[F / 2 + 1];
  float im[F / 2 + 1];
  double num = 0.0;
  double den = 0.0;
  for (int start = 0; start + F <= n; start += F / 2) {
    for (int i = 0; i < F; ++i) {
      const float w = 0.5f - 0.5f * cosf(2.0f * LE_FFT_PI * (float)i / (float)F);
      win[i] = x[start + i] * w;
    }
    le_rfft_fwd(win, re, im, F);
    for (int k = 1; k <= F / 2; ++k) {
      const float mag = sqrtf(re[k] * re[k] + im[k] * im[k]);
      num += (double)((float)k * (float)OCT_SR / (float)F) * mag;
      den += mag;
    }
  }
  return den > 0.0 ? (float)(num / den) : 0.0f;
}

/* Octave up/down shifts the fundamental by the ratio while a formant-preserving
 * vocoder holds the spectral centroid near the input's — measurably unlike a
 * naive resample, whose centroid tracks the pitch. */
static void test_octaver_pv_shifts_pitch_preserves_formant(void) {
  printf("test_octaver_pv_shifts_pitch_preserves_formant\n");
  const int total = 24000;
  const int skip = 12000;
  const int an = total - skip;
  float* in = (float*)malloc(sizeof(float) * (size_t)total);
  float* out = (float*)malloc(sizeof(float) * (size_t)total);
  oct_harmonic(in, total, 220.0f);
  const float cin = oct_centroid(in + skip, an);

  oct_run(0.75f, in, total, out); /* octave up: ratio 2 */
  const float f0_up = oct_detect_f0(out + skip, an);
  const float c_up = oct_centroid(out + skip, an);
  printf("  up: f0=%.1f (want 440) centroid=%.1f in=%.1f\n", f0_up, c_up, cin);
  CHECK(fabsf(f0_up - 440.0f) < 30.0f);
  CHECK(fabsf(c_up - cin) < 0.35f * cin); /* formant centroid held */
  CHECK(c_up < 1.6f * cin);               /* not a naive resample (~2x) */

  oct_run(0.25f, in, total, out); /* octave down: ratio 0.5 */
  const float f0_dn = oct_detect_f0(out + skip, an);
  const float c_dn = oct_centroid(out + skip, an);
  printf("  down: f0=%.1f (want 110) centroid=%.1f\n", f0_dn, c_dn);
  CHECK(fabsf(f0_dn - 110.0f) < 20.0f);
  CHECK(fabsf(c_dn - cin) < 0.45f * cin);

  free(in);
  free(out);
}

/* Window-size gate: a low (100 Hz) fundamental octave-up still preserves the
 * centroid at N = 1024. If this fails the documented fix is N = 2048. */
static void test_octaver_pv_low_fundamental(void) {
  printf("test_octaver_pv_low_fundamental\n");
  const int total = 24000;
  const int skip = 12000;
  const int an = total - skip;
  float* in = (float*)malloc(sizeof(float) * (size_t)total);
  float* out = (float*)malloc(sizeof(float) * (size_t)total);
  oct_harmonic(in, total, 100.0f);
  const float cin = oct_centroid(in + skip, an);

  /* The window-size gate is centroid (formant) preservation; f0 is not asserted
   * here because a 100 Hz fundamental sits near the N = 1024 resolution floor and
   * its octave-up partials (even multiples of 100) make autocorrelation octave-
   * ambiguous. The 220 Hz test above already pins the shift ratio. */
  oct_run(0.75f, in, total, out);
  const float c = oct_centroid(out + skip, an);
  printf("  low-f0: centroid=%.1f in=%.1f\n", c, cin);
  CHECK(fabsf(c - cin) < 0.45f * cin);
  CHECK(c < 1.7f * cin);

  free(in);
  free(out);
}

/* Mono coherence (D5): identical left/right in -> identical out (each channel is
 * deterministic and the chain runs them with separate but identically-seeded
 * state). Checked for BOTH modes — PV (mode = 0) and PSOLA (mode = 1) — since each
 * runs its own per-channel DSP state. */
static void oct_mono_coherent_mode(float mode) {
  /* Two output channels are needed so the chain runs the octaver on both the
   * left and right of a mono-seeded input and we can compare the two results. */
  le_engine* e = le_engine_create();
  const int blk = 2048;
  le_engine_configure(e, OCT_SR, 2, 2, blk); /* 2-in, 2-out */
  le_engine_set_monitor_input(e, 0, 1);
  le_engine_set_monitor_input_output(e, 0, 0x3); /* both outputs */
  le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_OCTAVER);
  le_engine_set_monitor_input_fx_param(e, 0, 0, 0, 0.75f);
  le_engine_set_monitor_input_fx_param(e, 0, 0, 2, 1.0f);
  le_engine_set_monitor_input_fx_param(e, 0, 0, 3, mode); /* PV or PSOLA */
  le_engine_set_monitor_input_fx_count(e, 0, 1);

  float* in = (float*)malloc(sizeof(float) * (size_t)(2 * blk));
  float* out = (float*)malloc(sizeof(float) * (size_t)(2 * blk));
  for (int pass = 0; pass < 8; ++pass) {
    for (int i = 0; i < blk; ++i) {
      const float s = 0.4f * sinf(2.0f * LE_FFT_PI * 220.0f *
                                  (float)(pass * blk + i) / (float)OCT_SR);
      in[i * 2 + 0] = s;
      in[i * 2 + 1] = s;
    }
    le_engine_process(e, out, in, (uint32_t)blk);
    for (int i = 0; i < blk; ++i) {
      CHECK(out[i * 2 + 0] == out[i * 2 + 1]);
    }
  }
  free(in);
  free(out);
  le_engine_destroy(e);
}

static void test_octaver_mono_coherent(void) {
  printf("test_octaver_mono_coherent\n");
  oct_mono_coherent_mode(0.0f); /* phase vocoder */
  oct_mono_coherent_mode(1.0f); /* PSOLA */
}

/* Delay-matched dry (D2): the dry tap is delayed by the same LE_PV_N as the wet
 * voice, so the two stay time-aligned in the mix instead of combing (the old
 * granular octaver mixed a zero-delay dry against a delayed wet). An impulse on
 * the dry-only path (mix = 0) emerges delayed by ~LE_PV_N, not at t = 0. */
static void test_octaver_mix_no_comb(void) {
  printf("test_octaver_mix_no_comb\n");
  const int total = 2 * OCT_PV_N;
  float* in = (float*)calloc((size_t)total, sizeof(float));
  float* out = (float*)calloc((size_t)total, sizeof(float));
  in[0] = 1.0f; /* unit impulse at t = 0 */

  le_engine* e = le_engine_create();
  const int blk = 512;
  le_engine_configure(e, OCT_SR, 1, 1, blk);
  le_engine_set_monitor_input(e, 0, 1);
  le_engine_set_monitor_input_output(e, 0, 0x1);
  le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_OCTAVER);
  le_engine_set_monitor_input_fx_param(e, 0, 0, 0, 0.5f); /* unison */
  le_engine_set_monitor_input_fx_param(e, 0, 0, 2, 0.0f); /* dry only */
  le_engine_set_monitor_input_fx_param(e, 0, 0, 3, 0.0f);
  le_engine_set_monitor_input_fx_count(e, 0, 1);
  int done = 0;
  while (done < total) {
    int n = total - done;
    if (n > blk) n = blk;
    le_engine_process(e, out + done, in + done, (uint32_t)n);
    done += n;
  }
  le_engine_destroy(e);

  /* Find the dry impulse in the output; it must arrive near LE_PV_N, not at 0. */
  int peak = 0;
  for (int i = 0; i < total; ++i) {
    if (fabsf(out[i]) > fabsf(out[peak])) peak = i;
  }
  printf("  dry-delay: impulse at out[%d] (want ~%d)\n", peak, OCT_PV_N - 1);
  CHECK(abs(peak - OCT_PV_N) <= 2); /* delay-matched to the wet latency (N-1) */
  CHECK(out[0] == 0.0f);           /* not a zero-delay dry (the old comb bug) */

  /* PSOLA leg (D2): the dry tap re-matches on a mode switch because both modes
   * report the same added latency, so an impulse through PSOLA at mix = 0.5 still
   * lands the dry energy near LE_PV_N (comb-free) — never at t = 0. An impulse is
   * unvoiced, so PSOLA's own voice is gated to the delay-matched dry, keeping the
   * whole response time-aligned. */
  memset(out, 0, sizeof(float) * (size_t)total);
  le_engine* e2 = le_engine_create();
  le_engine_configure(e2, OCT_SR, 1, 1, blk);
  le_engine_set_monitor_input(e2, 0, 1);
  le_engine_set_monitor_input_output(e2, 0, 0x1);
  le_engine_set_monitor_input_fx(e2, 0, 0, LE_FX_OCTAVER);
  le_engine_set_monitor_input_fx_param(e2, 0, 0, 0, 0.5f); /* unison */
  le_engine_set_monitor_input_fx_param(e2, 0, 0, 1, 1.0f); /* tone open */
  le_engine_set_monitor_input_fx_param(e2, 0, 0, 2, 0.5f); /* equal dry/wet */
  le_engine_set_monitor_input_fx_param(e2, 0, 0, 3, 1.0f); /* PSOLA */
  le_engine_set_monitor_input_fx_count(e2, 0, 1);
  done = 0;
  while (done < total) {
    int n = total - done;
    if (n > blk) n = blk;
    le_engine_process(e2, out + done, in + done, (uint32_t)n);
    done += n;
  }
  le_engine_destroy(e2);
  int ppeak = 0;
  for (int i = 0; i < total; ++i) {
    if (fabsf(out[i]) > fabsf(out[ppeak])) ppeak = i;
  }
  printf("  psola dry-delay: impulse at out[%d] (want ~%d)\n", ppeak, OCT_PV_N - 1);
  CHECK(abs(ppeak - OCT_PV_N) <= 4); /* still delay-matched in PSOLA mode */
  /* No early (pre-latency) energy spike: the mix is not combing a zero-delay dry
   * against a delayed wet. */
  float early = 0.0f;
  for (int i = 0; i < OCT_PV_N - 64; ++i) {
    if (fabsf(out[i]) > early) early = fabsf(out[i]);
  }
  CHECK(early < 0.05f);

  free(in);
  free(out);
}

/* Zipper-free (H3): dragging shift and mix full-range produces no clicks — the
 * sample-to-sample delta stays bounded well below a discontinuity. */
static void test_octaver_param_smoothing_no_zipper(void) {
  printf("test_octaver_param_smoothing_no_zipper\n");
  le_engine* e = le_engine_create();
  const int blk = 1024;
  le_engine_configure(e, OCT_SR, 1, 1, blk);
  le_engine_set_monitor_input(e, 0, 1);
  le_engine_set_monitor_input_output(e, 0, 0x1);
  le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_OCTAVER);
  le_engine_set_monitor_input_fx_param(e, 0, 0, 2, 1.0f);
  le_engine_set_monitor_input_fx_count(e, 0, 1);

  float in[1024];
  float out[1024];
  float prev = 0.0f;
  float max_delta = 0.0f;
  for (int pass = 0; pass < 24; ++pass) {
    const float shift = (pass % 2 == 0) ? 0.25f : 0.75f;
    le_engine_set_monitor_input_fx_param(e, 0, 0, 0, shift);
    le_engine_set_monitor_input_fx_param(e, 0, 0, 1, (pass % 2) ? 0.0f : 1.0f);
    le_engine_set_monitor_input_fx_param(e, 0, 0, 2, (pass % 2) ? 0.2f : 1.0f);
    for (int i = 0; i < blk; ++i) {
      in[i] = 0.4f * sinf(2.0f * LE_FFT_PI * 220.0f *
                          (float)(pass * blk + i) / (float)OCT_SR);
    }
    le_engine_process(e, out, in, (uint32_t)blk);
    if (pass >= 4) { /* past warm-up */
      for (int i = 0; i < blk; ++i) {
        const float d = fabsf(out[i] - prev);
        if (d > max_delta) max_delta = d;
        prev = out[i];
      }
    } else {
      prev = out[blk - 1];
    }
  }
  printf("  zipper: max sample delta=%.4f\n", max_delta);
  CHECK(max_delta < 0.2f); /* a click would be a large jump */
  le_engine_destroy(e);
}

/* Lifecycle (M1): reorder/retype/remove an octaver slot under processing — the
 * engine survives, output stays finite, and a different effect later landing on
 * the slot is unaffected. */
static void test_octaver_lifecycle(void) {
  printf("test_octaver_lifecycle\n");
  le_engine* e = le_engine_create();
  const int blk = 512;
  le_engine_configure(e, OCT_SR, 1, 1, blk);
  le_engine_set_monitor_input(e, 0, 1);
  le_engine_set_monitor_input_output(e, 0, 0x1);

  float in[512];
  float out[512];
  for (int i = 0; i < blk; ++i) {
    in[i] = 0.4f * sinf(2.0f * LE_FFT_PI * 220.0f * (float)i / (float)OCT_SR);
  }

  const int32_t seq[] = {LE_FX_OCTAVER, LE_FX_DRIVE, LE_FX_OCTAVER,
                         LE_FX_NONE,    LE_FX_REVERB, LE_FX_OCTAVER};
  for (int t = 0; t < (int)(sizeof(seq) / sizeof(seq[0])); ++t) {
    CHECK(le_engine_set_monitor_input_fx(e, 0, 0, seq[t]) == LE_OK);
    le_engine_set_monitor_input_fx_param(e, 0, 0, 2, 1.0f);
    le_engine_set_monitor_input_fx_count(e, 0, seq[t] == LE_FX_NONE ? 0 : 1);
    for (int pass = 0; pass < 6; ++pass) {
      le_engine_process(e, out, in, (uint32_t)blk);
      for (int i = 0; i < blk; ++i) {
        CHECK(isfinite(out[i]));
        CHECK(fabsf(out[i]) < 8.0f); /* bounded, no blow-up */
      }
    }
  }
  le_engine_destroy(e);
}

/* Mode switch (D1): toggling p3 runs the equal-power gain dip and resets the DSP
 * runtime. Both legs are real now (PV phase vocoder <-> PSOLA grain shifter), and
 * the test alternates so it exercises BOTH directions (PV->PSOLA and PSOLA->PV).
 * The switch must stay finite and click-free — the dip bounds the sample-to-sample
 * delta — and because both modes report the same added latency the dry tap does
 * not jump, so the dry leg adds no discontinuity either. */
static void test_octaver_mode_switch_no_click(void) {
  printf("test_octaver_mode_switch_no_click\n");
  le_engine* e = le_engine_create();
  const int blk = 1024;
  le_engine_configure(e, OCT_SR, 1, 1, blk);
  le_engine_set_monitor_input(e, 0, 1);
  le_engine_set_monitor_input_output(e, 0, 0x1);
  le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_OCTAVER);
  le_engine_set_monitor_input_fx_param(e, 0, 0, 0, 0.75f); /* octave up */
  le_engine_set_monitor_input_fx_param(e, 0, 0, 2, 1.0f);  /* full wet */
  le_engine_set_monitor_input_fx_count(e, 0, 1);

  float in[1024];
  float out[1024];
  float prev = 0.0f;
  float max_delta = 0.0f;
  for (int pass = 0; pass < 20; ++pass) {
    /* PV for 5 passes, PSOLA for 5, repeating — exercises both switch legs. */
    const float mode = ((pass / 5) % 2 == 0) ? 0.0f : 1.0f;
    le_engine_set_monitor_input_fx_param(e, 0, 0, 3, mode);
    for (int i = 0; i < blk; ++i) {
      in[i] = 0.4f * sinf(2.0f * LE_FFT_PI * 220.0f *
                          (float)(pass * blk + i) / (float)OCT_SR);
    }
    le_engine_process(e, out, in, (uint32_t)blk);
    for (int i = 0; i < blk; ++i) {
      CHECK(isfinite(out[i]));
      CHECK(fabsf(out[i]) < 4.0f);
      if (pass >= 1) {
        const float d = fabsf(out[i] - prev);
        if (d > max_delta) max_delta = d;
      }
      prev = out[i];
    }
  }
  printf("  mode-switch: max sample delta=%.4f\n", max_delta);
  CHECK(max_delta < 0.3f); /* equal-power dip masks the discontinuity */
  le_engine_destroy(e);
}

/* PSOLA-mode runner: full wet, tone open, PSOLA (mode = 1) at the given shift. */
static void oct_run_psola(float shift, const float* in, int total, float* out) {
  le_engine* e = le_engine_create();
  const int blk = 2048;
  le_engine_configure(e, OCT_SR, 1, 1, blk);
  le_engine_set_monitor_input(e, 0, 1);
  le_engine_set_monitor_input_output(e, 0, 0x1);
  le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_OCTAVER);
  le_engine_set_monitor_input_fx_param(e, 0, 0, 0, shift); /* shift */
  le_engine_set_monitor_input_fx_param(e, 0, 0, 1, 1.0f);  /* tone open */
  le_engine_set_monitor_input_fx_param(e, 0, 0, 2, 1.0f);  /* full wet */
  le_engine_set_monitor_input_fx_param(e, 0, 0, 3, 1.0f);  /* PSOLA mode */
  le_engine_set_monitor_input_fx_count(e, 0, 1);
  int done = 0;
  while (done < total) {
    int n = total - done;
    if (n > blk) n = blk;
    le_engine_process(e, out + done, in + done, (uint32_t)n);
    done += n;
  }
  le_engine_destroy(e);
}

/* PSOLA pitch detector (YIN): the engine-internal le_psola_detect reports the true
 * period within tolerance across the vocal band with NO octave error (the half/
 * double-period trap that plain autocorrelation falls into), reads noise as
 * unvoiced, and — crucially for the soft voiced<->unvoiced gate — yields a SMOOTH,
 * monotone-graded confidence as a tone is buried in noise. A graded confidence fed
 * through the tick's one-pole smoothing cannot flap dry<->wet frame to frame, which
 * is what the no-chatter (hysteresis) criterion asks for. */
static void test_octaver_psola_pitch_detect(void) {
  printf("test_octaver_psola_pitch_detect\n");
  enum { W = 1600 };
  float* b = (float*)malloc(sizeof(float) * (size_t)W);
  float* noise = (float*)malloc(sizeof(float) * (size_t)W);

  /* No octave error: detected period within 5% of the true period, 80..400 Hz. */
  const float f0s[] = {80.0f, 110.0f, 150.0f, 200.0f, 260.0f, 330.0f, 400.0f};
  for (int k = 0; k < (int)(sizeof(f0s) / sizeof(f0s[0])); ++k) {
    oct_harmonic(b, W, f0s[k]);
    float period = 0.0f;
    float voiced = 0.0f;
    le_psola_detect(b, W, OCT_SR, &period, &voiced);
    const float truep = (float)OCT_SR / f0s[k];
    printf("  f0=%.0f -> period=%.1f (true %.1f) voiced=%.2f\n", f0s[k], period,
           truep, voiced);
    CHECK(fabsf(period - truep) < 0.05f * truep); /* no half/double period */
    CHECK(voiced > 0.8f);                         /* clean tone reads voiced */
  }

  /* A shared noise vector, so scaling it gives a deterministic, monotone sweep. */
  uint32_t rng = 0x1234567u;
  for (int i = 0; i < W; ++i) {
    rng = rng * 1664525u + 1013904223u;
    noise[i] = ((float)(rng >> 9) / (float)(1u << 23)) * 2.0f - 1.0f; /* [-1,1) */
  }

  /* Aperiodic noise -> unvoiced (so the gate falls back to dry, D4). */
  for (int i = 0; i < W; ++i) b[i] = 0.4f * noise[i];
  {
    float period = 0.0f;
    float voiced = 0.0f;
    le_psola_detect(b, W, OCT_SR, &period, &voiced);
    printf("  noise -> voiced=%.2f\n", voiced);
    CHECK(voiced < 0.4f);
  }

  /* Graded confidence (anti-chatter foundation): a 200 Hz tone progressively
   * buried in the SAME noise yields a monotone-decreasing confidence with no
   * bistable jump — a smoothly varying gate input, never a hard 0/1 flip. */
  float prevc = 2.0f;
  float span_hi = 0.0f;
  float span_lo = 1.0f;
  for (int s = 0; s <= 5; ++s) {
    const float nz = 0.1f * (float)s;
    for (int i = 0; i < W; ++i) {
      b[i] = 0.4f * sinf(2.0f * LE_FFT_PI * 200.0f * (float)i / (float)OCT_SR) +
             nz * noise[i];
    }
    float period = 0.0f;
    float voiced = 0.0f;
    le_psola_detect(b, W, OCT_SR, &period, &voiced);
    printf("  noise=%.1f -> voiced=%.2f\n", nz, voiced);
    CHECK(voiced <= prevc + 0.02f); /* monotone non-increasing */
    prevc = voiced;
    if (voiced > span_hi) span_hi = voiced;
    if (voiced < span_lo) span_lo = voiced;
  }
  CHECK(span_hi - span_lo > 0.3f); /* genuinely graded, not stuck at 0 or 1 */

  free(noise);
  free(b);
}

/* PSOLA voice + fallback (D4): a voiced harmonic tone shifts up an octave with the
 * formant (spectral centroid) preserved — like the phase vocoder, at lower
 * latency; silence -> silence (no buzz); aperiodic noise -> the delay-matched dry
 * (no grain artifacts). Polyphonic input stays finite/bounded (degrades, never
 * glitches). Up-shift is PSOLA's documented sweet spot; extreme down-shift degrades
 * and is not asserted here. */
static void test_octaver_psola_voice_and_fallback(void) {
  printf("test_octaver_psola_voice_and_fallback\n");
  const int total = 48000;
  const int skip = 24000;
  const int an = total - skip;
  float* in = (float*)malloc(sizeof(float) * (size_t)total);
  float* out = (float*)malloc(sizeof(float) * (size_t)total);

  /* Voiced: 200 Hz harmonic tone, octave up (ratio 2). */
  oct_harmonic(in, total, 200.0f);
  const float cin = oct_centroid(in + skip, an);
  oct_run_psola(0.75f, in, total, out);
  const float f0 = oct_detect_f0(out + skip, an);
  const float c = oct_centroid(out + skip, an);
  printf("  voiced up: f0=%.1f (want 400) centroid=%.1f in=%.1f\n", f0, c, cin);
  CHECK(fabsf(f0 - 400.0f) < 40.0f);   /* pitch shifted up an octave */
  CHECK(fabsf(c - cin) < 0.35f * cin); /* formant centroid held */
  CHECK(c < 1.6f * cin);               /* not a naive resample (~2x) */

  /* Silence -> silence (no grain buzz). */
  for (int i = 0; i < total; ++i) in[i] = 0.0f;
  oct_run_psola(0.75f, in, total, out);
  float speak = 0.0f;
  for (int i = skip; i < total; ++i) {
    if (fabsf(out[i]) > speak) speak = fabsf(out[i]);
  }
  printf("  silence peak=%.6f\n", speak);
  CHECK(speak < 1e-4f);

  /* Aperiodic noise -> delay-matched dry passthrough (D4): the output tracks the
   * input delayed by the octaver latency, not a buzzy grain voice. */
  uint32_t rng = 0x0badf00du;
  for (int i = 0; i < total; ++i) {
    rng = rng * 1664525u + 1013904223u;
    in[i] = 0.3f * (((float)(rng >> 9) / (float)(1u << 23)) * 2.0f - 1.0f);
  }
  oct_run_psola(0.75f, in, total, out);
  double err = 0.0;
  double ref = 0.0;
  for (int i = skip; i < total; ++i) {
    /* PSOLA reports the same added latency as PV (le_octaver_latency), so the dry
     * tap sits OCT_PV_N - 1 behind the newest sample in both modes. */
    const float dry = in[i - (OCT_PV_N - 1)];
    err += (double)(out[i] - dry) * (out[i] - dry);
    ref += (double)dry * dry;
  }
  const float rel = (float)sqrt(err / ref);
  printf("  noise vs delayed-dry rel-err=%.3f\n", rel);
  CHECK(rel < 0.2f);

  /* Polyphonic (two inharmonic notes): degrades without glitching — finite and
   * bounded, no blow-up. */
  for (int i = 0; i < total; ++i) {
    in[i] = 0.25f * sinf(2.0f * LE_FFT_PI * 196.0f * (float)i / (float)OCT_SR) +
            0.25f * sinf(2.0f * LE_FFT_PI * 277.0f * (float)i / (float)OCT_SR);
  }
  oct_run_psola(0.75f, in, total, out);
  float ppeak = 0.0f;
  int bad = 0;
  for (int i = 0; i < total; ++i) {
    if (!isfinite(out[i])) bad++;
    if (fabsf(out[i]) > ppeak) ppeak = fabsf(out[i]);
  }
  printf("  polyphonic peak=%.3f nonfinite=%d\n", ppeak, bad);
  CHECK(bad == 0);
  CHECK(ppeak < 2.0f);

  free(in);
  free(out);
}

/* No dry<->wet chatter (AC3), end to end: a STEADY borderline-voiced signal (a
 * harmonic tone half-buried in noise, YIN confidence hovering ~0.5) is driven
 * through the full le_psola_tick gate in PSOLA mode. The one-pole-smoothed
 * confidence holds the soft gate at a steady blend, so the per-block output level
 * stays stable — it does NOT alternate between a fully-wet and a fully-dry block
 * (which a per-frame flapping gate would produce). Complements the detector-level
 * graded-confidence check in test_octaver_psola_pitch_detect: that proves the gate
 * INPUT is smoothly graded; this proves the gate OUTPUT does not flap. */
static void test_octaver_psola_no_chatter(void) {
  printf("test_octaver_psola_no_chatter\n");
  const int total = 72000;
  const int skip = 36000; /* past warm-up + confidence settling */
  float* in = (float*)malloc(sizeof(float) * (size_t)total);
  float* out = (float*)malloc(sizeof(float) * (size_t)total);

  /* 200 Hz harmonic tone + deterministic noise -> borderline confidence. */
  float* tone = (float*)malloc(sizeof(float) * (size_t)total);
  oct_harmonic(tone, total, 200.0f);
  uint32_t rng = 0x13572468u;
  for (int i = 0; i < total; ++i) {
    rng = rng * 1664525u + 1013904223u;
    const float n = ((float)(rng >> 9) / (float)(1u << 23)) * 2.0f - 1.0f;
    in[i] = tone[i] + 0.3f * n;
  }
  free(tone);
  oct_run_psola(0.75f, in, total, out);

  /* Per-analysis-block (256-sample) RMS; a steady gate keeps its coefficient of
   * variation low. A gate flapping wet<->dry every frame would swing the block
   * level by ~3x (cv > ~0.5). */
  const int B = 256;
  double sum = 0.0;
  double sum2 = 0.0;
  int cnt = 0;
  int bad = 0;
  for (int s = skip; s + B <= total; s += B) {
    double e = 0.0;
    for (int i = 0; i < B; ++i) {
      if (!isfinite(out[s + i])) bad++;
      e += (double)out[s + i] * out[s + i];
    }
    const double r = sqrt(e / B);
    sum += r;
    sum2 += r * r;
    cnt++;
  }
  const double mean = sum / cnt;
  const double cv = sqrt(sum2 / cnt - mean * mean) / mean;
  printf("  borderline blockRMS mean=%.4f cv=%.3f nonfinite=%d\n", mean, cv, bad);
  CHECK(bad == 0);
  CHECK(mean > 0.02f);  /* output is live, not gated to silence */
  CHECK(cv < 0.4f);     /* steady gate -> no frame-rate flapping */

  free(in);
  free(out);
}

/* Part 5: the snapshot surfaces the octaver's added latency (frames) so the UI
 * can warn about monitoring lag. A PV octaver on a monitor lane reports LE_PV_N
 * (1024, engine.c); a chain with no octaver reports 0. Informational only — the
 * record offset stays untouched (compensation is out of scope). */
static void test_octaver_added_latency(void) {
  printf("test_octaver_added_latency\n");
  le_engine* e = make_configured_engine();
  le_snapshot s;

  /* No effects engaged: nothing adds latency, and the record offset is unset. */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.fx_added_latency_frames == 0);
  CHECK(s.record_offset_frames == 0);

  /* Engage a PV octaver on a monitor lane -> LE_PV_N frames of added latency. */
  le_engine_set_monitor_input(e, 0, 1);
  le_engine_set_monitor_input_fx(e, 0, 0, LE_FX_OCTAVER);
  le_engine_set_monitor_input_fx_param(e, 0, 0, 3, 0.0f); /* PV mode */
  le_engine_set_monitor_input_fx_count(e, 0, 1);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.fx_added_latency_frames == 1024); /* == LE_PV_N */
  CHECK(s.record_offset_frames == 0);       /* compensation untouched */

  /* Switching the same octaver to PSOLA reports the same latency (both modes
   * read LE_PV_N today, so the dry tap does not jump on a mode switch). */
  le_engine_set_monitor_input_fx_param(e, 0, 0, 3, 1.0f); /* PSOLA mode */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.fx_added_latency_frames == 1024);

  /* Disengage the chain -> the reported latency falls back to 0. */
  le_engine_set_monitor_input_fx_count(e, 0, 0);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.fx_added_latency_frames == 0);

  /* An octaver on a record-route lane (audible on playback) is reported too:
   * the snapshot's latency is the max across every audible/monitored chain, so
   * the hint also fires in the track lane editor, not just the monitor graph. */
  le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_OCTAVER);
  le_engine_set_lane_fx_param(e, 0, 0, 0, 3, 0.0f); /* PV mode */
  le_engine_set_lane_fx_count(e, 0, 0, 1);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.fx_added_latency_frames == 1024);

  le_engine_set_lane_fx_count(e, 0, 0, 0);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.fx_added_latency_frames == 0);

  le_engine_destroy(e);
}

/* ---- FFT primitive (fft.h) ---- */

/* Verifies the header-only FFT in isolation, before the phase vocoder (part 3)
 * consumes it: a random round-trip, a single-sine single-peak, an impulse's flat
 * spectrum, the 1/n scaling via a constant's DC, and the shared Hann table. */
static void test_fft_roundtrip(void) {
  printf("test_fft_roundtrip\n");
  enum { N = 1024 };
  float x[N];
  float y[N];
  float re[N / 2 + 1];
  float im[N / 2 + 1];

  /* Deterministic pseudo-random signal in [-1, 1] (LCG; no global rand state). */
  uint32_t seed = 0x1234567u;
  for (int i = 0; i < N; ++i) {
    seed = seed * 1664525u + 1013904223u;
    x[i] = (float)(seed >> 8) / (float)(1u << 23) - 1.0f;
  }

  /* Round-trip reconstructs the signal to within a small epsilon. */
  le_rfft_fwd(x, re, im, N);
  le_rfft_inv(re, im, y, N);
  float max_err = 0.0f;
  for (int i = 0; i < N; ++i) {
    float e = fabsf(y[i] - x[i]);
    if (e > max_err) max_err = e;
  }
  CHECK(max_err < 1e-4f);

  /* A pure sine at bin k yields a single dominant magnitude peak at bin k. */
  const int k = 17;
  for (int i = 0; i < N; ++i) {
    x[i] = sinf(2.0f * LE_FFT_PI * (float)k * (float)i / (float)N);
  }
  le_rfft_fwd(x, re, im, N);
  float peak = 0.0f;
  int peak_bin = -1;
  for (int b = 0; b <= N / 2; ++b) {
    float mag = re[b] * re[b] + im[b] * im[b];
    if (mag > peak) {
      peak = mag;
      peak_bin = b;
    }
  }
  CHECK(peak_bin == k);
  /* Immediate neighbours are negligible against the peak. */
  float left = re[k - 1] * re[k - 1] + im[k - 1] * im[k - 1];
  float right = re[k + 1] * re[k + 1] + im[k + 1] * im[k + 1];
  CHECK(left < peak * 1e-3f);
  CHECK(right < peak * 1e-3f);
  /* The Nyquist bin's imaginary part is zero for a real signal. */
  CHECK(fabsf(im[N / 2]) < 1e-4f);

  /* A unit impulse has a flat magnitude spectrum (|X[b]| == 1 for every bin). */
  for (int i = 0; i < N; ++i) x[i] = 0.0f;
  x[0] = 1.0f;
  le_rfft_fwd(x, re, im, N);
  for (int b = 0; b <= N / 2; ++b) {
    float mag = sqrtf(re[b] * re[b] + im[b] * im[b]);
    CHECK(fabsf(mag - 1.0f) < 1e-4f);
  }

  /* A constant input is pure DC, and the inverse is correctly 1/n-scaled: the
   * constant round-trips to itself. */
  for (int i = 0; i < N; ++i) x[i] = 0.75f;
  le_rfft_fwd(x, re, im, N);
  CHECK(fabsf(re[0] - 0.75f * (float)N) < 1e-2f); /* DC == sum == 0.75 * N */
  CHECK(fabsf(im[0]) < 1e-4f);
  for (int b = 1; b <= N / 2; ++b) {
    float mag = sqrtf(re[b] * re[b] + im[b] * im[b]);
    CHECK(mag < 1e-3f); /* no energy outside DC */
  }
  le_rfft_inv(re, im, y, N);
  for (int i = 0; i < N; ++i) CHECK(fabsf(y[i] - 0.75f) < 1e-4f);

  /* Shared Hann table: built once, guarded by the ready flag. Endpoints are the
   * troughs (0), the centre is the crest (1), and the window is symmetric. */
  float hann[N];
  int ready = 0;
  le_hann_init(hann, N, &ready);
  CHECK(ready == 1);
  CHECK(fabsf(hann[0]) < 1e-6f);
  CHECK(fabsf(hann[N / 2] - 1.0f) < 1e-6f);
  /* Periodic Hann is symmetric about the centre: hann[i] == hann[N-i] for the
   * interior bins (i from 1, since hann[N] is out of range / the period wrap). */
  for (int i = 1; i < N / 2; ++i) CHECK(fabsf(hann[i] - hann[N - i]) < 1e-6f);
  /* A second call with the flag still set is a no-op: poisoned input survives. */
  hann[3] = -42.0f;
  le_hann_init(hann, N, &ready);
  CHECK(hann[3] == -42.0f);
}

int main(void) {
  printf("== loopy_engine_core native tests ==\n");
  test_lane_setters_reject_invalid_args();
  test_two_lanes_unmerged_both_play();
  test_lane_fx_colors_only_its_lane();
  test_lane_volume_and_mute();
  test_undo_across_lanes();
  test_lazy_lane_allocation();
  test_lane_phase_lock_matches_baseline();
  test_lane_null_guard();
  test_lane_count_shrink_then_regrow();
  test_multi_lane_quantize_overdub_arm();
  test_multi_lane_loop_multiple();
  test_session_export_import_roundtrip();
  test_target_multiple_forces_length();
  test_default_multiple_applies_to_inheriting_tracks();
  test_fixed_multiple_auto_finalizes();
  test_rec_dub_continues_into_overdub();
  test_new_track_autofinish_overdubs_with_rec_dub_off();
  test_auto_record_starts_on_signal();
  test_quantize_track_override_forces_on();
  test_quantize_track_override_forces_off();
  test_quantize_track_override_inherits();
  test_monitor_single_chain();
  test_monitor_volume();
  test_monitor_mute();
  test_latency_restores_monitoring();
  test_monitor_clean_chain_not_recorded();
  test_monitor_input_not_recorded();
  test_two_monitored_inputs_dont_interfere();
  test_monitor_disable_and_excluded();
  test_monitor_and_playback_sum();
  test_perf_arm_requires_configure();
  test_perf_reconfigure_while_armed_resets_cleanly();
  test_perf_arm_rejects_no_enabled_output();
  test_perf_arm_cleans_up_when_drain_thread_fails_to_start();
  test_perf_null_safety();
  test_perf_arm_rejects_bad_capture_dir();
  test_perf_arm_rejects_capture_dir_too_long();
  test_perf_arm_disarm_lifecycle();
  test_perf_arm_refuses_when_drain_thread_still_live();
  test_perf_master_tap_bit_identical_mono();
  test_perf_master_tap_bit_identical_stereo_post_gain();
  test_perf_monitor_tap_matches_mix_contribution();
  test_perf_monitor_tap_pads_silence_when_muted();
  test_perf_overflow_counts_and_drops();
  test_perf_frames_advance_during_latency_measurement();
  test_perf_monitor_tap_pads_silence_when_disabled();
  test_perf_drain_writes_master_pcm_byte_identical();
  test_perf_drain_silence_fills_overrun_gap();
  test_perf_drain_disk_full_stops_cleanly();
  test_perf_drain_files_are_crash_consistent_mid_capture();
  test_perf_reconfigure_while_armed_marks_sidecar_device_changed();
  test_perf_events_log_table_round_trip_and_frame_accuracy();
  test_perf_events_log_transport_facts();
  test_perf_events_log_command_storm_no_loss();
  test_perf_events_log_fx_param_sweep_monotonic_frames();
  test_perf_events_log_readable_after_abrupt_stop();
  test_record_does_not_self_snapshot();
  test_record_never_touches_lane_fx();
  test_output_disabled_is_silent_routes_preserved();
  test_reenable_restores_audio();
  test_gate_beyond_channel_count_ignored();
  test_quantize_start_and_finalize_on_grid();
  test_quantize_second_press_disarms();
  test_quantize_defining_track_is_immediate();
  test_quantize_overdub_arm_disarm_no_phantom_layer();
  test_quantize_overdub_fires_on_grid();
  test_ring_init_rejects_bad_capacity();
  test_ring_push_pop_fifo();
  test_ring_reports_full();
  test_ring_wraps_around();
  test_audio_ring_init_rejects_bad_capacity();
  test_audio_ring_push_pop_fifo();
  test_audio_ring_push_frame_all_or_nothing();
  test_audio_ring_reports_full();
  test_audio_ring_wraps_around();
  test_engine_lifecycle_without_device();
  test_null_safety();
  test_loop_clock();
  test_looper_record_then_play();
  test_dry_recording_invariant();
  test_looper_overdub_and_undo();
  test_looper_multilevel_undo();
  test_per_pass_undo_layers();
  test_punch_out_mid_pass_drains();
  test_undo_queued_during_drain();
  test_queued_undo_to_empty_coherent_snapshot();
  test_undo_to_empty_and_redo();
  test_record_after_undo_to_empty_clears_redo();
  test_clear_unmutes();
  test_record_from_empty_unmutes();
  test_spare_starvation_merges_passes();
  test_offset_latched_across_dub();
  test_redo_from_empty_unmutes();
  test_undo_to_empty_cancels_pending_arm();
  test_configure_drops_stale_commands();
  test_undo_layers_quantized_and_live_regrows();
  test_undo_layer_slot_regrows_for_longer_loop();
  test_fresh_record_after_undo_to_empty_redefines_grid();
  test_grid_kept_when_sibling_redo_alive();
  test_quantize_acts_immediately_when_transport_held();
  test_repunch_during_drain_restarts_capture();
  test_undo_pool_eviction();
  test_looper_volume_and_mute();
  test_master_gain_scales_output();
  test_master_gain_rejects_null();
  test_master_gain_resets_on_configure();
  test_xrun_count_tallies_and_resets();
  test_device_lost_keeps_running();
  test_master_bus_frame_limiter();
  test_looper_clear();
  test_looper_requires_configure();
  test_looper_multitrack();
  test_latency_compensation();
  test_overdub_punch_no_click();
  test_master_limiter_caps_and_transparent();
  test_overdub_feedback_decays_layers();
  test_master_seam_crossfade_no_click();
  test_record_is_exclusive();
  test_loop_multiple_records_two_loops();
  test_loop_multiple_rounds_up_partial();
  test_new_track_records_mid_loop();
  test_fixed_multiple_mid_loop_take_keeps_wrap();
  test_transport_resets_when_all_stopped();
  test_transport_runs_until_last_track_stops();
  test_routing_input_mask();
  test_routing_input_mask_collapses_to_lowest();
  test_routing_input_mask_empty_records_silence();
  test_routing_output_mask();
  test_routing_default_stereo();
  test_routing_input_mask_clamped();
  test_routing_output_mask_clamped();
  test_visualization_tap();
  test_classify_capture_device();
  test_detect_loopback_runs();
  test_enumerate_devices_runs();
  test_device_id_to_str();
  test_select_backend_defaults_to_miniaudio();
  test_backend_struct_defaults();
  test_bridge_roundtrip_f32();
  test_bridge_convert_int32();
  test_bridge_convert_int24();
  test_bridge_convert_int16();
  test_bridge_channel_scatter_gather();
  test_asio_pick_buffer();
  test_enumerate_asio_drivers_stub();
  test_label_is_loopback();
  test_excluded_mask_from_names();
  test_loopback_exclusion();
  test_loopback_latency_uses_loopback_channel();
  test_loopback_latency_weak_echo_and_silence();
  test_set_record_offset_publishes_latency();
  test_fx_bypass_is_transparent();
  test_fx_count_gates_the_chain();
  test_fx_drive_saturates();
  test_fx_reverb_builds_a_tail();
  test_fx_reverb_is_stereo();
  test_fx_filter_attenuates_low_cutoff();
  test_fx_delay_is_silent_until_time();
  test_fx_tremolo_modulates_amplitude();
  test_fx_chain_applies_in_order();
  test_fx_nondestructive_and_colors_playback();
  test_fx_muted_track_is_silent();
  test_fx_rejects_invalid_args();
  test_fx_reverb_then_mono_effect_is_stereo();
  test_fx_stereo_chain_independent_lr_state();
  test_fx_stereo_ring_retained_across_type_reorder();
  test_monitor_input_fx_rejects_invalid_args();
  test_fx_fourth_param_is_inert();
  test_octaver_pv_shifts_pitch_preserves_formant();
  test_octaver_pv_low_fundamental();
  test_octaver_mono_coherent();
  test_octaver_mix_no_comb();
  test_octaver_param_smoothing_no_zipper();
  test_octaver_lifecycle();
  test_octaver_mode_switch_no_click();
  test_octaver_psola_pitch_detect();
  test_octaver_psola_voice_and_fallback();
  test_octaver_psola_no_chatter();
  test_octaver_added_latency();
  test_fft_roundtrip();

  if (g_failures == 0) {
    printf("ALL PASSED\n");
    return 0;
  }
  printf("%d CHECK(S) FAILED\n", g_failures);
  return 1;
}
