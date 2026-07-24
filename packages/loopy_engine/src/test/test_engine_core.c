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
#include "engine_core.h"      /* le_push (raw ring pushes for the tempo tests) */
#include "engine_internal.h"
#include "engine_private.h"   /* LE_POOL_SLOTS (per-pass undo pool cap) */
#include "engine_miniaudio.h" /* le_miniaudio_backend (le_select_backend target) */
#include "engine_platform.h"  /* le_platform_device_id_to_str, ma_device_id */
#include "fft.h"              /* le_fft, le_rfft_fwd, le_rfft_inv, le_hann_init */
#include "json_read.h"        /* le_json_parse (part 7 offline renderer) */
#include "lockfree_ring.h"
#include "loop_clock.h"
#include "loopy_engine_api.h"
#include "tempo_grid.h" /* le_tempo_grid, le_grid_* (pure grid math) */

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

/* Processes silent blocks until no track has an overdub layer in flight — the
 * punch-out fade tail must fully retire before undo/redo (a tap during it only
 * queues) or an export (it would copy a mid-fade buffer). Bounded. */
static void settle_layers(le_engine* e) {
  float out[64];
  le_snapshot s;
  for (int k = 0; k < 256; ++k) {
    le_engine_get_snapshot(e, &s);
    int busy = 0;
    for (int32_t t = 0; t < s.track_count; ++t) {
      if (s.tracks[t].layer_in_flight) busy = 1;
    }
    if (!busy) return;
    process_const(e, 0.0f, LOOP_N, out);
  }
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

/* The undoable clear (#219) puts the whole take back — content AND the overdub
 * layers beneath it, which stay peelable exactly as if the clear never happened.
 * That "full stack" restore is the point of the feature. */
static void test_clear_undoable_restores_take_and_layers(void) {
  printf("test_clear_undoable_restores_take_and_layers\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch in */
  process_const(e, 0.5f, LOOP_N, out);
  le_engine_record(e, 0); /* punch out -> 1.5, one layer stacked */
  drain(e);
  settle_dub(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 1);

  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[0].length_frames == 0);
  /* The erased take's layer is still held, but not peelable while the restore
   * point sits above it — an EMPTY track reports no undo steps (the published
   * contract, and the host's EMPTY => undoDepth == 0 invariant). The restore is
   * offered through its own flag instead. */
  CHECK(s.tracks[0].undo_depth == 0);
  CHECK(s.tracks[0].clear_restore == 1);

  CHECK(le_engine_undo(e, 0) == LE_OK); /* undo the clear */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].length_frames == LOOP_N);
  CHECK(s.tracks[0].undo_depth == 1); /* the erased take's layer is back */
  CHECK(s.tracks[0].redo_depth == 1); /* and the clear is redoable */
  check_content(e, 1.5f);

  /* Still peelable: the layer beneath the restore point survived the clear. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 1.0f);

  le_engine_destroy(e);
}

/* Redo re-applies the clear the undo took back, and the pair stays symmetric
 * under repeated undo/redo rather than decaying after one round trip. */
static void test_clear_undoable_redo_reclears(void) {
  printf("test_clear_undoable_redo_reclears\n");
  le_engine* e = make_configured_engine();
  le_snapshot s;

  record_base_loop(e, 1.0f);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  drain(e);

  for (int round = 0; round < 2; ++round) {
    CHECK(le_engine_undo(e, 0) == LE_OK);
    drain(e);
    le_engine_get_snapshot(e, &s);
    CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
    check_content(e, 1.0f);

    CHECK(le_engine_redo(e, 0) == LE_OK); /* re-clear */
    drain(e);
    le_engine_get_snapshot(e, &s);
    CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
    CHECK(s.tracks[0].length_frames == 0);
    CHECK(s.tracks[0].undo_depth == 0);
    CHECK(s.tracks[0].clear_restore == 1); /* restore point back on the stack */
  }

  le_engine_destroy(e);
}

/* Clearing the last track resets the master grid (handle_clear's all-empty
 * path). Undoing that clear must re-establish it — the restored take is
 * unplayable on a dead clock, and REDO_FROM_EMPTY only ever reads the grid,
 * which is why the restore rides its own command. */
static void test_clear_undoable_restores_master_grid(void) {
  printf("test_clear_undoable_restores_master_grid\n");
  le_engine* e = make_configured_engine();
  le_snapshot s;

  record_base_loop(e, 1.0f);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == LOOP_N);

  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 0); /* whole rig empty: the grid is gone */

  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == LOOP_N); /* and back */
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].length_frames == LOOP_N);
  CHECK(s.tracks[0].multiple == 1);
  check_content(e, 1.0f);

  le_engine_destroy(e);
}

/* The restore point carries the pre-clear state and mutes, not just the audio:
 * a stopped, muted track comes back stopped and muted. (Plain clear deliberately
 * unmutes — that rule belongs to clear, not to undoing one.) */
static void test_clear_undoable_restores_state_and_mutes(void) {
  printf("test_clear_undoable_restores_state_and_mutes\n");
  le_engine* e = make_configured_engine();
  le_snapshot s;

  record_base_loop(e, 1.0f);
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  CHECK(le_engine_set_track_mute(e, 0, 1) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[0].muted == 1);

  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].muted == 0); /* the clear itself still unmutes */

  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED); /* not PLAYING */
  CHECK(s.tracks[0].muted == 1);

  le_engine_destroy(e);
}

/* A fresh take records into the live slot the restore point names, so the way
 * back is gone whether or not the bookkeeping admits it — the history must drop
 * rather than offer an undo that would resurrect a half-overwritten buffer. This
 * restores the pre-#219 semantic: after clear-then-record, undo depth is 0. */
static void test_record_after_undoable_clear_drops_restore_point(void) {
  printf("test_record_after_undoable_clear_drops_restore_point\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  record_base_loop(e, 1.0f);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].clear_restore == 1);

  CHECK(le_engine_record(e, 0) == LE_OK); /* fresh take redefines the grid */
  process_const(e, 2.0f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].clear_restore == 0); /* the way back died with the tempo */
  CHECK(s.tracks[0].undo_depth == 0);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* undo-to-empty, not a clear restore */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  check_content(e, 2.0f); /* the new take, never the cleared one */

  le_engine_destroy(e);
}

/* le_engine_clear stays destructive — it is what session load and the internal
 * grid-redefinition clear (le_engine_record) call, and neither may leave a
 * restore point behind. */
static void test_plain_clear_leaves_no_restore_point(void) {
  printf("test_plain_clear_leaves_no_restore_point\n");
  le_engine* e = make_configured_engine();
  le_snapshot s;

  record_base_loop(e, 1.0f);
  CHECK(le_engine_clear(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[0].undo_depth == 0);
  CHECK(s.tracks[0].redo_depth == 0);
  CHECK(le_engine_undo(e, 0) == LE_ERR_INVALID); /* nothing to go back to */

  le_engine_destroy(e);
}

/* Clearing an already-empty track offers no restore point: there is nothing to
 * put back, and a mark whose slot holds no take would resurrect silence. */
static void test_undoable_clear_of_empty_track_is_plain(void) {
  printf("test_undoable_clear_of_empty_track_is_plain\n");
  le_engine* e = make_configured_engine();
  le_snapshot s;

  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 0);
  CHECK(s.tracks[0].clear_restore == 0);
  CHECK(le_engine_undo(e, 0) == LE_ERR_INVALID);

  le_engine_destroy(e);
}

/* A cleared sibling must not hold the master grid hostage: its restore point
 * yields to a fresh recording on another track, which redefines the tempo. The
 * pre-#219 clear reset the stack outright, so le_grid_still_needed found nothing
 * to count — keeping the stack must not silently change that. */
static void test_cleared_sibling_does_not_hold_grid(void) {
  printf("test_cleared_sibling_does_not_hold_grid\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  record_base_loop(e, 1.0f); /* track 0 defines a LOOP_N grid */
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].clear_restore == 1); /* restore point held */
  CHECK(s.master_length_frames == 0);

  /* A fresh take on track 1, twice as long: it must define the new grid rather
   * than be locked to track 0's dead tempo. */
  CHECK(le_engine_record(e, 1) == LE_OK);
  process_const(e, 2.0f, LOOP_N * 2, out);
  le_engine_record(e, 1);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == LOOP_N * 2);
  CHECK(s.tracks[1].multiple == 1);
  /* And track 0's restore point died with the old tempo. */
  CHECK(s.tracks[0].clear_restore == 0);

  le_engine_destroy(e);
}

/* The live-slot overwrite hazard on its own, with the grid-redefinition path
 * taken OUT of the picture: a sibling holds the grid, so recording onto the
 * cleared track never reaches le_engine_record's drop-every-restore-point loop.
 * le_begin_empty_capture must still drop this track's restore point, because the
 * take it names is about to be recorded over in place (pool[live] is regrown and
 * written by the audio thread). Without this the undo would offer a resurrect
 * onto a half-overwritten buffer. */
static void test_record_over_cleared_track_drops_restore_point_grid_held(void) {
  printf("test_record_over_cleared_track_drops_restore_point_grid_held\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  record_base_loop(e, 1.0f); /* track 0 defines the grid */
  /* Track 1 takes real content, so it — not track 0 — holds the grid. */
  CHECK(le_engine_record(e, 1) == LE_OK);
  process_const(e, 3.0f, LOOP_N, out);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);

  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].clear_restore == 1);    /* restore point held */
  CHECK(s.master_length_frames == LOOP_N);  /* sibling kept the grid */

  /* Fresh take on track 0. The grid stands, so the record path's invalidation
   * loop does not run — only le_begin_empty_capture can drop the mark here. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, 2.0f, LOOP_N, out);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == LOOP_N); /* sibling still holds it */
  CHECK(s.tracks[0].clear_restore == 0);   /* the way back is gone */
  check_content(e, 2.0f);

  le_engine_destroy(e);
}

/* redo_stack must not overflow when a restore point pushes the entry count past
 * what the pool bound alone guarantees.
 *
 * Most stack entries name a distinct pool slot, so live + undo + redo +
 * outstanding <= LE_POOL_SLOTS caps undo + redo at 255. The exceptions are the
 * pushes that name the ALREADY-live slot and so consume no new one: undo-to-
 * empty's, and (since #219) the clear restore point's. Pre-#219 there was
 * exactly one such push and redo_count topped out at 256 — the last valid
 * index. The restore point adds a second, which is one too many:
 *
 *   255 layers + 1 restore point  -> undo 256
 *   undo the clear, peel all 255  -> redo 256   (both moves, net zero)
 *   one more undo (to empty)      -> redo_stack[256] — past the end
 *
 * redo_count sits immediately after redo_stack, so the overflow corrupts the
 * very counter that bounds it. Rare (255 overdubs, then clear, then 256 undos)
 * but reachable, and memory corruption either way. */
static void test_redo_stack_bounded_with_restore_point(void) {
  printf("test_redo_stack_bounded_with_restore_point\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  record_base_loop(e, 1.0f);
  /* Stack layers until eviction pins the depth at its ceiling. */
  for (int i = 0; i < LE_POOL_SLOTS + 4; ++i) {
    CHECK(le_engine_record(e, 0) == LE_OK);
    process_const(e, 0.0f, LOOP_N, out);
    CHECK(le_engine_record(e, 0) == LE_OK);
    drain(e);
    settle_dub(e);
  }
  le_engine_get_snapshot(e, &s);
  const int32_t depth = s.tracks[0].undo_depth;
  CHECK(depth > 0 && depth <= LE_POOL_SLOTS);

  CHECK(le_engine_clear_undoable(e, 0) == LE_OK); /* + the restore point */
  drain(e);
  CHECK(le_engine_undo(e, 0) == LE_OK); /* restore: moves it to redo */
  drain(e);

  /* Peel everything, then keep tapping past the base into undo-to-empty. Each
   * tap must either move an entry or refuse — never write past redo_stack. */
  for (int i = 0; i < LE_POOL_SLOTS + 8; ++i) {
    le_engine_undo(e, 0);
    drain(e);
  }
  le_engine_get_snapshot(e, &s);
  /* The counters are still sane: an overflow would have clobbered redo_count
   * itself (it is the next field after redo_stack). */
  CHECK(s.tracks[0].redo_depth >= 0);
  CHECK(s.tracks[0].redo_depth <= LE_POOL_SLOTS);
  CHECK(s.tracks[0].undo_depth >= 0);
  CHECK(s.tracks[0].undo_depth <= LE_POOL_SLOTS);

  le_engine_destroy(e);
}

/* le_engine_undo_restores_clear tells a host whether the next undo puts a
 * cleared take back (so it can restore state the engine does not own, like the
 * take's FX chains) or merely peels a layer. It must track the stack exactly —
 * including going false once a fresh recording retires the restore point. */
static void test_undo_restores_clear_query(void) {
  printf("test_undo_restores_clear_query\n");
  le_engine* e = make_configured_engine();
  float out[64];

  CHECK(le_engine_undo_restores_clear(e, 0) == 0); /* empty track: nothing */

  record_base_loop(e, 1.0f);
  CHECK(le_engine_undo_restores_clear(e, 0) == 0); /* undo would empty it */

  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, 0.5f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);
  settle_dub(e);
  CHECK(le_engine_undo_restores_clear(e, 0) == 0); /* undo would peel a layer */

  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_undo_restores_clear(e, 0) == 1); /* undo would restore */

  /* Consuming the restore point flips it back: the next tap peels the layer
   * the clear had erased. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_undo_restores_clear(e, 0) == 0);

  /* A plain clear never offers one. */
  CHECK(le_engine_clear(e, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_undo_restores_clear(e, 0) == 0);

  /* Bad channel / null engine are 0, not a crash — this is a host-facing query
   * and the host has no way to know the track count. */
  CHECK(le_engine_undo_restores_clear(e, -1) == 0);
  CHECK(le_engine_undo_restores_clear(e, 9999) == 0);
  CHECK(le_engine_undo_restores_clear(NULL, 0) == 0);

  le_engine_destroy(e);
}

/* The query must go false the moment the engine retires the restore point, or a
 * host would put FX back onto a take that no longer exists. */
static void test_undo_restores_clear_query_false_after_record(void) {
  printf("test_undo_restores_clear_query_false_after_record\n");
  le_engine* e = make_configured_engine();
  float out[64];

  record_base_loop(e, 1.0f);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_undo_restores_clear(e, 0) == 1);

  CHECK(le_engine_record(e, 0) == LE_OK); /* retires the restore point */
  process_const(e, 2.0f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);
  CHECK(le_engine_undo_restores_clear(e, 0) == 0);

  le_engine_destroy(e);
}

/* An EMPTY track NEVER reports undo steps, however it got there. undo_depth's
 * published contract is "available undo steps (overdub layers)", and the host
 * asserts EMPTY => undoDepth == 0 as a control invariant (lib/control/
 * invariants.dart, 'depths-sane'). A clear restore point holds real layers, but
 * they are not steps until it is undone — publishing the raw entry count here
 * put the app's fuzzer into a Bad state, which is what this pins.
 *
 * The flag is the escape hatch: it, not undo_depth, answers "would undo do
 * something" on a cleared track. */
static void test_empty_track_never_reports_undo_depth(void) {
  printf("test_empty_track_never_reports_undo_depth\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  /* Deepest case: a take with a stacked layer, then cleared. */
  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, 0.5f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);
  settle_dub(e);
  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  drain(e);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[0].length_frames == 0);
  CHECK(s.tracks[0].undo_depth == 0); /* the invariant the host asserts */
  CHECK(s.tracks[0].clear_restore == 1); /* but undo still does something */

  /* Restoring republishes the real peel depth. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].undo_depth == 1);
  CHECK(s.tracks[0].clear_restore == 0);

  /* Undo-to-empty empties it a different way — same rule. */
  CHECK(le_engine_undo(e, 0) == LE_OK); /* peel */
  CHECK(le_engine_undo(e, 0) == LE_OK); /* to empty */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[0].undo_depth == 0);
  CHECK(s.tracks[0].clear_restore == 0);

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

/* ---- tempo grid (A1: pure math + state + locks + loop<->tempo sync) ---- */

/* Processes `total` frames of silence in <=64-frame chunks. */
static void tg_advance(le_engine* e, int total) {
  float in[64] = {0};
  float out[64];
  while (total > 0) {
    const int n = total > 64 ? 64 : total;
    le_engine_process(e, out, in, (uint32_t)n);
    total -= n;
  }
}

static le_engine* tg_make_engine(int sr) {
  le_engine* e = le_engine_create();
  le_engine_configure(e, sr, 1, 1, 20000);
  return e;
}

/* Like tg_make_engine but with an explicit max_loop_frames cap. Used by the
 * A6 length-preset tests: the D17 worst-case-30-BPM allocation guard
 * (le_engine_set_track_length_preset) needs more headroom than
 * tg_make_engine's tight 20000-frame default gives a several-bar preset at
 * sr 1000 (a 4-bar 4/4 preset alone needs 32000 worst-case). */
static le_engine* tg_make_engine_cap(int sr, int32_t max_loop_frames) {
  le_engine* e = le_engine_create();
  le_engine_configure(e, sr, 1, 1, max_loop_frames);
  return e;
}

/* Records a `len`-frame silent defining loop on track `ch` and finalizes it.
 * The finalize press defers sr/100 frames for the seam crossfade
 * (request_master_finalize), so advance exactly that overlap: the loop
 * finalizes at `len` on the overlap's last frame and the clock ticks once —
 * the master position is 1 on return. */
static void tg_record_defining_loop(le_engine* e, int len) {
  le_engine_record(e, 0);
  tg_advance(e, len);
  le_engine_record(e, 0); /* queue finalize (defers for the seam crossfade) */
  tg_advance(e, e->sample_rate / 100);
}

static void test_tempo_grid_math(void) {
  printf("test_tempo_grid_math\n");
  /* 4/4 at 120: the beat unit is a quarter, 500 frames at sr 1000. */
  le_tempo_grid g44 = {120.0f, 4, 4, 1000};
  CHECK(fabs(le_grid_frames_per_beat_unit(&g44) - 500.0) < 1e-9);
  CHECK(fabs(le_grid_frames_per_bar(&g44) - 2000.0) < 1e-9);
  CHECK(fabs(le_grid_div_frames(&g44, LE_GRID_DIV_BAR) - 2000.0) < 1e-9);
  CHECK(fabs(le_grid_div_frames(&g44, LE_GRID_DIV_HALF) - 1000.0) < 1e-9);
  CHECK(fabs(le_grid_div_frames(&g44, LE_GRID_DIV_QUARTER) - 500.0) < 1e-9);
  CHECK(fabs(le_grid_div_frames(&g44, LE_GRID_DIV_EIGHTH) - 250.0) < 1e-9);
  CHECK(fabs(le_grid_div_frames(&g44, LE_GRID_DIV_SIXTEENTH) - 125.0) < 1e-9);

  /* 7/8 at 120: the beat unit is an EIGHTH (500 frames — same fpb; the
   * denominator cancels), the bar is 7 of them, and the absolute note values
   * double relative to x/4 (a 1/4 note is now two beat units). */
  le_tempo_grid g78 = {120.0f, 7, 8, 1000};
  CHECK(fabs(le_grid_frames_per_beat_unit(&g78) - 500.0) < 1e-9);
  CHECK(fabs(le_grid_frames_per_bar(&g78) - 3500.0) < 1e-9);
  CHECK(fabs(le_grid_div_frames(&g78, LE_GRID_DIV_HALF) - 2000.0) < 1e-9);
  CHECK(fabs(le_grid_div_frames(&g78, LE_GRID_DIV_QUARTER) - 1000.0) < 1e-9);
  CHECK(fabs(le_grid_div_frames(&g78, LE_GRID_DIV_EIGHTH) - 500.0) < 1e-9);
  CHECK(fabs(le_grid_div_frames(&g78, LE_GRID_DIV_SIXTEENTH) - 250.0) < 1e-9);

  /* 15/8 and 3/4 bars. */
  le_tempo_grid g158 = {120.0f, 15, 8, 1000};
  CHECK(fabs(le_grid_frames_per_bar(&g158) - 7500.0) < 1e-9);
  le_tempo_grid g34 = {120.0f, 3, 4, 1000};
  CHECK(fabs(le_grid_frames_per_bar(&g34) - 1500.0) < 1e-9);

  /* bars_for_loop: nearest-bar rounding with the documented min-1 clamp.
   * g44's bar is 2000 frames. */
  CHECK(le_grid_bars_for_loop(&g44, 2000) == 1);
  CHECK(le_grid_bars_for_loop(&g44, 3000) == 2); /* 1.5 rounds up */
  CHECK(le_grid_bars_for_loop(&g44, 1800) == 1); /* 0.9 rounds to 1 */
  CHECK(le_grid_bars_for_loop(&g44, 500) == 1);  /* quarter-bar: min-1 clamp */
  CHECK(le_grid_bars_for_loop(&g44, 4900) == 2); /* 2.45 rounds down */
  CHECK(le_grid_bars_for_loop(&g44, 0) == 0);
  CHECK(le_grid_bars_for_loop(NULL, 2000) == 0);

  /* Degenerate grids yield 0. */
  le_tempo_grid bad = {0.0f, 4, 4, 1000};
  CHECK(le_grid_frames_per_beat_unit(&bad) == 0.0);
  CHECK(le_grid_frames_per_bar(NULL) == 0.0);
  CHECK(le_grid_div_frames(&g44, LE_GRID_DIV_OFF) == 0.0);
  CHECK(le_grid_div_frames(&g44, 99) == 0.0);
}

static void test_tempo_grid_next_boundary(void) {
  printf("test_tempo_grid_next_boundary\n");
  le_tempo_grid g = {120.0f, 4, 4, 1000}; /* quarter beat = 500 frames */

  /* Strictly-after contract at all five subdivisions: a pos exactly ON a
   * boundary yields the NEXT one. */
  CHECK(le_grid_next_boundary(&g, 0, LE_GRID_DIV_BAR) == 2000);
  CHECK(le_grid_next_boundary(&g, 1999, LE_GRID_DIV_BAR) == 2000);
  CHECK(le_grid_next_boundary(&g, 2000, LE_GRID_DIV_BAR) == 4000);
  CHECK(le_grid_next_boundary(&g, 0, LE_GRID_DIV_HALF) == 1000);
  CHECK(le_grid_next_boundary(&g, 600, LE_GRID_DIV_QUARTER) == 1000);
  CHECK(le_grid_next_boundary(&g, 500, LE_GRID_DIV_QUARTER) == 1000);
  CHECK(le_grid_next_boundary(&g, 0, LE_GRID_DIV_EIGHTH) == 250);
  CHECK(le_grid_next_boundary(&g, 130, LE_GRID_DIV_SIXTEENTH) == 250);

  /* Generic signature: in 7/8 the bar is 3500 frames and a 1/16 is 250. */
  le_tempo_grid g78 = {120.0f, 7, 8, 1000};
  CHECK(le_grid_next_boundary(&g78, 3500, LE_GRID_DIV_BAR) == 7000);
  CHECK(le_grid_next_boundary(&g78, 3400, LE_GRID_DIV_BAR) == 3500);
  CHECK(le_grid_next_boundary(&g78, 0, LE_GRID_DIV_SIXTEENTH) == 250);

  /* Non-integer interval (sr 44100 at 113 bpm -> ~23415.93 frames/beat):
   * boundaries render from their index k, so walking 100 of them stays within
   * rounding of the exact grid — no cumulative drift. */
  le_tempo_grid gf = {113.0f, 4, 4, 44100};
  const double interval = le_grid_div_frames(&gf, LE_GRID_DIV_QUARTER);
  int64_t prev = 0;
  for (int k = 1; k <= 100; ++k) {
    const int64_t b = le_grid_next_boundary(&gf, prev, LE_GRID_DIV_QUARTER);
    CHECK(b > prev);
    /* Each boundary sits within 1 frame of the exact multiple. */
    CHECK(fabs((double)b - (double)k * interval) <= 0.5 + 1e-9);
    prev = b;
  }

  /* Degenerate inputs. */
  CHECK(le_grid_next_boundary(&g, 0, LE_GRID_DIV_OFF) == -1);
  CHECK(le_grid_next_boundary(&g, -1, LE_GRID_DIV_BAR) == -1);
  le_tempo_grid bad = {0.0f, 4, 4, 1000};
  CHECK(le_grid_next_boundary(&bad, 0, LE_GRID_DIV_BAR) == -1);

  /* A NaN bpm is refused (positive-form guards), never spun on: a NaN
   * interval used to make the boundary loop non-terminating. */
  le_tempo_grid gnan = {NAN, 4, 4, 1000};
  CHECK(le_grid_frames_per_beat_unit(&gnan) == 0.0);
  CHECK(le_grid_div_frames(&gnan, LE_GRID_DIV_QUARTER) == 0.0);
  CHECK(le_grid_next_boundary(&gnan, 0, LE_GRID_DIV_BAR) == -1);
  CHECK(le_grid_bars_for_loop(&gnan, 4000) == 0);

  /* Past 2^52 frames double integer precision is gone: refuse, don't
   * mis-round. Just below the limit still works. */
  CHECK(le_grid_next_boundary(&g, (int64_t)1 << 52, LE_GRID_DIV_QUARTER) ==
        -1);
  CHECK(le_grid_next_boundary(&g, ((int64_t)1 << 52) - 1,
                              LE_GRID_DIV_QUARTER) > ((int64_t)1 << 52) - 1);
}

static void test_tempo_grid_signature_validation(void) {
  printf("test_tempo_grid_signature_validation\n");
  /* The 17 supported signatures: 2/4..7/4 and 5/8..15/8. */
  for (int n = 2; n <= 7; ++n) CHECK(le_grid_signature_valid(n, 4) == 1);
  for (int n = 5; n <= 15; ++n) CHECK(le_grid_signature_valid(n, 8) == 1);
  /* Rejected: outside either family. */
  CHECK(le_grid_signature_valid(2, 8) == 0);
  CHECK(le_grid_signature_valid(3, 8) == 0);
  CHECK(le_grid_signature_valid(4, 8) == 0);
  CHECK(le_grid_signature_valid(8, 4) == 0);
  CHECK(le_grid_signature_valid(15, 4) == 0);
  CHECK(le_grid_signature_valid(1, 4) == 0);
  CHECK(le_grid_signature_valid(16, 8) == 0);
  CHECK(le_grid_signature_valid(4, 6) == 0);
  CHECK(le_grid_signature_valid(0, 4) == 0);
  CHECK(le_grid_signature_valid(-3, 8) == 0);
}

static void test_tempo_grid_derive_bpm(void) {
  printf("test_tempo_grid_derive_bpm\n");
  int32_t bars = 0;

  /* 4000 frames at sr 1000 in 4/4: whole-bar candidates are 60*b bpm; 120
   * (2 bars) is nearest 120. */
  CHECK(fabsf(le_grid_derive_bpm(4000, 4, 1000, &bars) - 120.0f) < 0.01f);
  CHECK(bars == 2);

  /* 3000 frames: candidates 80/160/240 — 80 and 160 are equidistant from 120
   * and the SLOWER one (fewer bars) wins the tie. */
  CHECK(fabsf(le_grid_derive_bpm(3000, 4, 1000, &bars) - 80.0f) < 0.01f);
  CHECK(bars == 1);

  /* A loop shorter than one bar at 300 bpm clamps to the ceiling. */
  CHECK(fabsf(le_grid_derive_bpm(100, 4, 1000, &bars) - 300.0f) < 0.01f);
  CHECK(bars == 1);

  /* A slow loop walks up into the window: 12000 frames -> 20*b bpm, and b=6
   * lands exactly on 120. */
  CHECK(fabsf(le_grid_derive_bpm(12000, 4, 1000, &bars) - 120.0f) < 0.01f);
  CHECK(bars == 6);

  /* Signature-generic: 7/8 changes the bar size (7 beat units per bar). A
   * 7000-frame loop at sr 1000: bpm(b) = 60*b -> 120 at 2 bars. */
  CHECK(fabsf(le_grid_derive_bpm(7000, 7, 1000, &bars) - 120.0f) < 0.01f);
  CHECK(bars == 2);

  /* One more nearest-120 spot check for the closed form: 6000 frames gives
   * 40*b candidates; b=3 lands exactly on 120. */
  CHECK(fabsf(le_grid_derive_bpm(6000, 4, 1000, &bars) - 120.0f) < 0.01f);
  CHECK(bars == 3);

  /* Extreme-but-valid arguments terminate (the old walk's int32 candidate
   * index overflowed here) and still land in the window near 120. */
  {
    int32_t big_bars = 0;
    const float big = le_grid_derive_bpm(2147483647, 4, 1, &big_bars);
    CHECK(big >= LE_GRID_TEMPO_MIN && big <= LE_GRID_TEMPO_MAX);
    CHECK(fabsf(big - 120.0f) < 1.0f);
    CHECK(big_bars >= 1);
    /* And when even the nearest whole-bar count would overflow int32, the
     * result is grid-free rather than a truncated bar count. */
    CHECK(le_grid_derive_bpm(2147483647, 1, 1, &big_bars) == 0.0f);
    CHECK(big_bars == 0);
  }

  /* Degenerate input. */
  CHECK(le_grid_derive_bpm(0, 4, 1000, &bars) == 0.0f);
  CHECK(bars == 0);
  CHECK(le_grid_derive_bpm(4000, 4, 1000, NULL) == 0.0f);

  /* beat_at distributes a non-dividing remainder evenly (len 10, 3 beats:
   * boundaries at 0, 4, 7). */
  CHECK(le_grid_beat_at(0, 10, 3) == 0);
  CHECK(le_grid_beat_at(3, 10, 3) == 0);
  CHECK(le_grid_beat_at(4, 10, 3) == 1);
  CHECK(le_grid_beat_at(6, 10, 3) == 1);
  CHECK(le_grid_beat_at(7, 10, 3) == 2);
  CHECK(le_grid_beat_at(9, 10, 3) == 2);
  CHECK(le_grid_beat_at(5, 0, 3) == 0);
  CHECK(le_grid_beat_at(5, 10, 0) == 0);
}

static void test_tempo_grid_bpm_for_length(void) {
  printf("test_tempo_grid_bpm_for_length\n");
  /* A6/D17: the exact algebraic inverse of frames-per-bar, unlike
   * le_grid_derive_bpm (which searches for the bar count nearest 120) —
   * `bars` is already fixed by the preset. */

  /* 8000 frames / 4 bars at sr 1000 in 4/4: frames-per-bar 2000 -> 120 bpm
   * (matches every other 120 bpm/4-bar fixture in this suite). */
  CHECK(fabsf(le_grid_bpm_for_length(8000, 4, 4, 1000) - 120.0f) < 0.01f);

  /* 6000 frames / 4 bars: frames-per-bar 1500 -> 160 bpm. */
  CHECK(fabsf(le_grid_bpm_for_length(6000, 4, 4, 1000) - 160.0f) < 0.01f);

  /* Signature-generic: 7/8 changes the bar size just as le_grid_derive_bpm's
   * generic case does. 7000 frames / 2 bars in 7/8 -> 120 bpm. */
  CHECK(fabsf(le_grid_bpm_for_length(7000, 2, 7, 1000) - 120.0f) < 0.01f);

  /* Out-of-range results clamp rather than extrapolate past the engine's
   * tempo ceiling/floor. */
  CHECK(le_grid_bpm_for_length(100, 4, 4, 1000) == LE_GRID_TEMPO_MAX);
  CHECK(le_grid_bpm_for_length(1000000, 1, 4, 1000) == LE_GRID_TEMPO_MIN);

  /* Degenerate input. */
  CHECK(le_grid_bpm_for_length(0, 4, 4, 1000) == 0.0f);
  CHECK(le_grid_bpm_for_length(8000, 0, 4, 1000) == 0.0f);
  CHECK(le_grid_bpm_for_length(8000, 4, 0, 1000) == 0.0f);
  CHECK(le_grid_bpm_for_length(8000, 4, 4, 0) == 0.0f);
}

static void test_tempo_grid_defaults_and_persistence(void) {
  printf("test_tempo_grid_defaults_and_persistence\n");
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  /* Grid-off defaults: no tempo (0 = unset, source none), 4/4, sync on,
   * quantize granularity OFF (deliberately unlike the old stack's BAR). */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tempo_bpm == 0.0f);
  CHECK(s.ts_num == 4);
  CHECK(s.ts_den == 4);
  CHECK(s.sync_tempo == 1);
  CHECK(s.quantize_div == LE_GRID_DIV_OFF);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_NONE);
  CHECK(s.loop_bars == 0);
  CHECK(s.current_beat == 0);

  /* Settings persist across a reconfigure (the 2f0513a pattern): tempo,
   * signature, quantize granularity, and the source survive; the transient
   * loop-derived state resets. */
  CHECK(le_engine_set_tempo(e, 100.0f) == LE_OK);
  CHECK(le_engine_set_time_signature(e, 7, 8) == LE_OK);
  CHECK(le_engine_set_quantize_div(e, LE_GRID_DIV_QUARTER) == LE_OK);
  CHECK(le_engine_set_sync_tempo(e, 0) == LE_OK);
  tg_advance(e, 1);
  le_engine_configure(e, 1000, 1, 1, 20000);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 100.0f) < 0.01f);
  CHECK(s.ts_num == 7);
  CHECK(s.ts_den == 8);
  CHECK(s.quantize_div == LE_GRID_DIV_QUARTER);
  CHECK(s.sync_tempo == 0);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);
  CHECK(s.loop_bars == 0);
  CHECK(s.current_beat == 0);

  /* The reset/survival split with a REAL grid (not fields already at their
   * defaults): derive a live grid + beat, reconfigure, and assert only the
   * per-session state died while the settings — including the source that
   * travels with the tempo value — survived. */
  CHECK(le_engine_set_sync_tempo(e, 1) == LE_OK);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 4200); /* 100 bpm in 7/8: fpbar 4200 -> 1 bar */
  tg_advance(e, 700);               /* onto beat 1 (a beat every 600) */
  le_engine_get_snapshot(e, &s);
  CHECK(s.loop_bars == 1);
  CHECK(s.current_beat == 1);
  le_engine_configure(e, 1000, 1, 1, 20000);
  le_engine_get_snapshot(e, &s);
  CHECK(s.loop_bars == 0);     /* per-session grid state reset... */
  CHECK(s.current_beat == 0);
  CHECK(s.master_length_frames == 0);
  CHECK(fabsf(s.tempo_bpm - 100.0f) < 0.01f); /* ...settings survived */
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);
  CHECK(s.ts_num == 7);
  CHECK(s.ts_den == 8);
  CHECK(s.sync_tempo == 1);
  CHECK(s.quantize_div == LE_GRID_DIV_QUARTER);

  le_engine_destroy(e);
}

static void test_tempo_set_and_clamp(void) {
  printf("test_tempo_set_and_clamp\n");
  le_engine* e = tg_make_engine(48000);
  le_snapshot s;

  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 90.0f) < 0.5f);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);

  le_engine_set_tempo(e, 10.0f); /* clamps to 30 */
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 30.0f) < 0.5f);

  le_engine_set_tempo(e, 1000.0f); /* clamps to 300 */
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 300.0f) < 0.5f);

  /* NaN never reaches the published tempo: the NaN-rejecting clamp treats it
   * like an under-range value (a published NaN would make every derived grid
   * interval NaN and spin next_boundary forever). */
  le_engine_set_tempo(e, NAN);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tempo_bpm == s.tempo_bpm); /* finite (a NaN fails self-equality) */
  CHECK(fabsf(s.tempo_bpm - 30.0f) < 0.5f);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);

  le_engine_destroy(e);
}

static void test_tap_tempo(void) {
  printf("test_tap_tempo\n");
  le_engine* e = tg_make_engine(100);
  le_snapshot s;

  le_engine_set_tempo(e, 200.0f);
  tg_advance(e, 1);

  /* Two taps 50 frames apart at 100 Hz == 0.5 s == 120 bpm. */
  CHECK(le_engine_tap_tempo(e) == LE_OK);
  tg_advance(e, 50);
  le_engine_tap_tempo(e);
  tg_advance(e, 1);

  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 2.0f);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_TAPPED);

  /* An interval outside 30..300 bpm is ignored (600 frames -> 10 bpm). */
  le_engine_tap_tempo(e);
  tg_advance(e, 600);
  le_engine_tap_tempo(e);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 2.0f);

  le_engine_destroy(e);
}

static void test_manual_vs_tap_last_writer(void) {
  printf("test_manual_vs_tap_last_writer\n");
  le_engine* e = tg_make_engine(100);
  le_snapshot s;

  le_engine_set_tempo(e, 100.0f);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);

  /* Tap overrides manual (last writer wins). */
  le_engine_tap_tempo(e);
  tg_advance(e, 50);
  le_engine_tap_tempo(e);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 2.0f);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_TAPPED);

  /* And manual overrides tap right back. */
  le_engine_set_tempo(e, 90.0f);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 90.0f) < 0.5f);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);

  le_engine_destroy(e);
}

static void test_time_signature_validation(void) {
  printf("test_time_signature_validation\n");
  le_engine* e = tg_make_engine(48000);
  le_snapshot s;

  CHECK(le_engine_set_time_signature(e, 7, 8) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.ts_num == 7);
  CHECK(s.ts_den == 8);

  /* The wrapper rejects everything outside the 17 supported signatures. */
  CHECK(le_engine_set_time_signature(e, 16, 8) == LE_ERR_INVALID);
  CHECK(le_engine_set_time_signature(e, 1, 4) == LE_ERR_INVALID);
  CHECK(le_engine_set_time_signature(e, 2, 8) == LE_ERR_INVALID);
  CHECK(le_engine_set_time_signature(e, 8, 4) == LE_ERR_INVALID);
  CHECK(le_engine_set_time_signature(e, 4, 16) == LE_ERR_INVALID);

  /* The audio thread re-validates: a raw ring push of an unsupported
   * signature (bypassing the wrapper) is dropped there too. */
  CHECK(le_push(e, LE_CMD_SET_TIME_SIGNATURE, 10, 4.0f) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.ts_num == 7);
  CHECK(s.ts_den == 8);

  /* 15/8 (the top of the x/8 family) is valid. */
  CHECK(le_engine_set_time_signature(e, 15, 8) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.ts_num == 15);
  CHECK(s.ts_den == 8);

  le_engine_destroy(e);
}

static void test_quantize_div_setter(void) {
  printf("test_quantize_div_setter\n");
  le_engine* e = tg_make_engine(48000);
  le_snapshot s;

  CHECK(le_engine_set_quantize_div(e, LE_GRID_DIV_EIGHTH) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.quantize_div == LE_GRID_DIV_EIGHTH);

  CHECK(le_engine_set_quantize_div(e, -1) == LE_ERR_INVALID);
  CHECK(le_engine_set_quantize_div(e, 6) == LE_ERR_INVALID);

  /* A raw ring push clamps rather than publishing an out-of-range value. */
  CHECK(le_push(e, LE_CMD_SET_QUANTIZE_DIV, 9, 0.0f) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.quantize_div == LE_GRID_DIV_SIXTEENTH);

  le_engine_destroy(e);
}

static void test_loop_syncs_tempo(void) {
  printf("test_loop_syncs_tempo\n");
  /* sr 1000 at 120 bpm in 4/4 -> 500 frames/beat, 2000 frames/bar. A
   * 4000-frame loop is exactly 2 bars: the tempo stays 120 and the snapshot
   * reports 2 bars. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  le_engine_set_tempo(e, 120.0f);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 4000);

  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 4000);
  CHECK(s.loop_bars == 2);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.5f);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);

  le_engine_destroy(e);
}

static void test_loop_rounds_to_bar_keeps_tempo(void) {
  printf("test_loop_rounds_to_bar_keeps_tempo\n");
  /* An 1800-frame loop at 120 bpm is 0.9 bars, which rounds to 1 bar. D7:
   * with a tempo already set the bar COUNT rounds to the existing grid and
   * the tempo is NOT touched (the old stack snapped it to ~133.3 — that
   * behaviour is deliberately gone). The loop's audio length is never
   * altered either. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  le_engine_set_tempo(e, 120.0f);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 1800);

  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 1800); /* audio length untouched */
  CHECK(s.loop_bars == 1);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f); /* tempo untouched */

  le_engine_destroy(e);
}

static void test_sync_off_keeps_free_form(void) {
  printf("test_sync_off_keeps_free_form\n");
  /* With sync disabled the loop keeps its recorded length, no bars are
   * derived, and the tempo is left exactly as the user set it. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  CHECK(le_engine_set_sync_tempo(e, 0) == LE_OK);
  le_engine_set_tempo(e, 137.0f);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 1800);

  le_engine_get_snapshot(e, &s);
  CHECK(s.sync_tempo == 0);
  CHECK(s.master_length_frames == 1800);
  CHECK(s.loop_bars == 0);
  CHECK(fabsf(s.tempo_bpm - 137.0f) < 0.5f);

  le_engine_destroy(e);
}

static void test_loop_derives_tempo_from_none(void) {
  printf("test_loop_derives_tempo_from_none\n");
  /* D7: with sync on (the default) and NO tempo ever set, finalizing the
   * defining loop derives one — whole bars in the current signature, BPM in
   * 30..300 nearest 120 — and marks the source derived. A 4000-frame loop at
   * sr 1000 in 4/4 lands exactly on 120 with 2 bars. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  tg_record_defining_loop(e, 4000);

  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 4000);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f);
  CHECK(s.loop_bars == 2);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_DERIVED);

  le_engine_destroy(e);
}

static void test_derive_only_from_none(void) {
  printf("test_derive_only_from_none\n");
  /* D7's dead-tempo rule end to end: a derived tempo survives clear-all, and
   * the NEXT defining loop rounds to the surviving grid instead of
   * re-deriving. The 3000-frame second loop would re-derive to 80 bpm (the
   * tie-break test above) — instead it must keep 120 and round to 2 bars
   * (3000 / 2000 frames-per-bar = 1.5 -> 2). */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  tg_record_defining_loop(e, 4000); /* derives 120, 2 bars */
  le_engine_clear(e, 0);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 0);
  CHECK(s.loop_bars == 0); /* the grid died with its loop... */
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f); /* ...the tempo did not */
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_DERIVED);

  tg_record_defining_loop(e, 3000);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 3000);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f); /* never re-derived */
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_DERIVED);
  CHECK(s.loop_bars == 2);

  le_engine_destroy(e);
}

/* ---- track length presets (A6, D17; song-mode-spec.md §1 matrix) ---- */

static void test_length_preset_auto_click_off_unchanged(void) {
  printf("test_length_preset_auto_click_off_unchanged\n");
  /* AUTO (the default, and explicitly set to 0) + click off is exactly A1's
   * existing sync_grid_to_loop path: derive tempo AND bars from the loop. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  CHECK(le_engine_set_track_length_preset(e, 0, 0) == LE_OK);
  tg_record_defining_loop(e, 4000);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].length_preset_bars == 0);
  CHECK(s.master_length_frames == 4000);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f);
  CHECK(s.loop_bars == 2);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_DERIVED);

  le_engine_destroy(e);
}

static void test_length_preset_auto_click_on_derives_bars_only(void) {
  printf("test_length_preset_auto_click_on_derives_bars_only\n");
  /* AUTO + click ON, with a tempo already set: only the bar count is
   * derived, tempo untouched — the click-mode axis doesn't change AUTO's
   * behavior at all (sync_grid_to_loop never reads click_mode). */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  le_engine_set_tempo(e, 120.0f);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_REC) == LE_OK);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 1800); /* 0.9 bars at 120 -> rounds to 1 */

  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 1800);
  CHECK(s.loop_bars == 1);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f); /* untouched */
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);

  le_engine_destroy(e);
}

static void test_length_preset_auto_click_on_no_tempo_falls_back(void) {
  printf("test_length_preset_auto_click_on_no_tempo_falls_back\n");
  /* AUTO + click ON with NO tempo set: the documented A6 fallback derives
   * tempo AND bars, identically to click off (nothing else to preserve). */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  CHECK(le_engine_set_click_mode(e, LE_CLICK_REC) == LE_OK);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 4000);

  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 4000);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f);
  CHECK(s.loop_bars == 2);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_DERIVED);

  le_engine_destroy(e);
}

static void test_length_preset_n_bars_click_off_derives_tempo(void) {
  printf("test_length_preset_n_bars_click_off_derives_tempo\n");
  /* N bars + click off: tempo is derived from recorded-length / N
   * UNCONDITIONALLY, even overriding an existing manual tempo — distinct
   * from AUTO's D7 "never re-derive an existing tempo" precedence. */
  le_engine* e = tg_make_engine_cap(1000, 100000);
  le_snapshot s;

  le_engine_set_tempo(e, 90.0f); /* set before any content: unlocked */
  tg_advance(e, 1);
  CHECK(le_engine_set_track_length_preset(e, 0, 4) == LE_OK);
  tg_record_defining_loop(e, 8000); /* length/4 = 2000 fpbar -> 120 bpm */

  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 8000); /* audio length never altered */
  CHECK(s.loop_bars == 4);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f); /* overrides the manual 90 */
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_DERIVED);

  le_engine_destroy(e);
}

static void test_length_preset_n_bars_click_on_auto_finalizes(void) {
  printf("test_length_preset_n_bars_click_on_auto_finalizes\n");
  /* N bars + click ON, with a tempo already set: the defining recording
   * auto-finalizes into overdub at EXACTLY N bars' worth of frames, no
   * second press — and (unlike the click-off row) the already-set tempo is
   * NOT re-derived. */
  le_engine* e = tg_make_engine_cap(1000, 100000);
  le_snapshot s;

  le_engine_set_tempo(e, 120.0f);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_REC) == LE_OK);
  CHECK(le_engine_set_track_length_preset(e, 0, 4) == LE_OK);
  tg_advance(e, 1);

  le_engine_record(e, 0); /* single press: no manual finalize */
  tg_advance(e, 8000 - 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING); /* not yet: one frame short */

  tg_advance(e, 1 + 1000 / 100); /* reach the target + the seam crossfade */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING); /* auto-finalized */
  CHECK(s.master_length_frames == 8000);
  CHECK(s.loop_bars == 4);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f); /* untouched, not re-derived */
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);

  le_engine_destroy(e);
}

static void test_length_preset_n_bars_click_on_arms_through_count_in(void) {
  printf("test_length_preset_n_bars_click_on_arms_through_count_in\n");
  /* Code-review coverage gap: le_arm_length_preset_target has TWO call
   * sites — handle_record's immediate-press EMPTY branch (covered by
   * test_length_preset_n_bars_click_on_auto_finalizes above) and
   * le_count_in_commit, the count-in downbeat path, entirely untested until
   * now (confirmed by mutation: deleting the count-in call site left every
   * other length-preset test green). With a count-in running, the defining
   * take does not actually begin until the commit fires — the target must
   * arm THERE, not at the original press, and then auto-finalize correctly
   * from that later start. */
  le_engine* e = tg_make_engine_cap(1000, 100000);
  le_snapshot s;

  le_engine_set_tempo(e, 120.0f); /* 500 frames/beat, 2000 frames/bar (4/4) */
  CHECK(le_engine_set_count_in(e, 1) == LE_OK); /* 1 bar = 4*500 = 2000 frames */
  CHECK(le_engine_set_click_mode(e, LE_CLICK_REC) == LE_OK);
  CHECK(le_engine_set_track_length_preset(e, 0, 4) == LE_OK); /* target 8000 */
  tg_advance(e, 1);

  le_engine_record(e, 0); /* enters the count-in, not RECORDING yet */
  tg_advance(e, 1999);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 1);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);

  tg_advance(e, 1); /* the 2000th frame: count-in commits, defining take begins */
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 0);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING);

  /* From the commit, the SAME 8000-frame target as the plain-press case must
   * arm and fire — proving le_count_in_commit's le_arm_length_preset_target
   * call actually ran (not the mutant that skips it, which would leave this
   * take running forever with no auto-finalize). */
  tg_advance(e, 8000 - 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING); /* one frame short */

  tg_advance(e, 1 + 1000 / 100); /* reach the target + the seam crossfade */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING); /* auto-finalized */
  CHECK(s.master_length_frames == 8000);
  CHECK(s.loop_bars == 4);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f); /* untouched, not re-derived */
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);

  le_engine_destroy(e);
}

static void test_length_preset_n_bars_click_on_early_press_disarms(void) {
  printf("test_length_preset_n_bars_click_on_early_press_disarms\n");
  /* D17: an early record press before the N-bar target disarms the preset —
   * the take closes through the NORMAL path (existing tempo, round to
   * whatever bars the shorter take actually spans), not the derive-from-
   * length override, and NOT forced into overdub (a manual press without
   * rec/dub ends in PLAYING). */
  le_engine* e = tg_make_engine_cap(1000, 100000);
  le_snapshot s;

  le_engine_set_tempo(e, 120.0f);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_REC) == LE_OK);
  CHECK(le_engine_set_track_length_preset(e, 0, 4) == LE_OK); /* target 8000 */
  tg_advance(e, 1);

  le_engine_record(e, 0);
  tg_advance(e, 3000); /* well short of the 8000-frame target */
  le_engine_record(e, 0); /* manual finalize: disarms the preset */
  tg_advance(e, 1000 / 100); /* seam crossfade */

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING); /* not forced into overdub */
  CHECK(s.master_length_frames == 3000);
  CHECK(s.loop_bars == 2); /* 3000 / 2000 fpbar = 1.5 -> round to 2 */
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f); /* untouched */
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);

  le_engine_destroy(e);
}

static void test_length_preset_n_bars_click_on_handoff_before_target(void) {
  printf("test_length_preset_n_bars_click_on_handoff_before_target\n");
  /* Code-review coverage gap: a DIFFERENT track's record press (the one-
   * capturer hand-off, close_active_capture) is a second way the defining
   * track's capture can end before its target — distinct from the same-
   * track early re-press covered above. close_active_capture finalizes the
   * defining track IMMEDIATELY via finalize_master (bypassing request_
   * master_finalize's seam crossfade — "one capturer" is a hard cut), with
   * whatever record_pos it currently holds. length_preset_target_frames is
   * still armed (nonzero) and not yet reached, so this must behave exactly
   * like the same-track early-press case: normal path, tempo untouched,
   * bars rounded from the actual (short) length. */
  le_engine* e = tg_make_engine_cap(1000, 100000);
  le_snapshot s;

  le_engine_set_tempo(e, 120.0f);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_REC) == LE_OK);
  CHECK(le_engine_set_track_length_preset(e, 0, 4) == LE_OK); /* target 8000 */
  tg_advance(e, 1);

  le_engine_record(e, 0);
  tg_advance(e, 3000); /* well short of the 8000-frame target */
  le_engine_record(e, 1); /* a DIFFERENT track's press: hand-off, not re-press */
  tg_advance(e, 1); /* the hand-off finalize is immediate, no crossfade defer */

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING); /* hand-off always -> PLAYING */
  CHECK(s.master_length_frames == 3000);
  CHECK(s.loop_bars == 2); /* 3000 / 2000 fpbar = 1.5 -> round to 2 */
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f); /* untouched */
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);

  le_engine_destroy(e);
}

static void test_length_preset_n_bars_click_on_handoff_during_crossfade(
    void) {
  printf("test_length_preset_n_bars_click_on_handoff_during_crossfade\n");
  /* Code-review coverage gap: a hand-off landing INSIDE the deferred seam-
   * crossfade window (the target was already reached — request_master_
   * finalize armed xfade_capture — but the crossfade hasn't completed).
   * close_active_capture's xfade_capture>0 branch snaps record_pos back to
   * xfade_len (the intended final length) and cancels the deferral before
   * finalizing, so the result must come out identical to a clean on-time
   * auto-finalize: bars == the full preset, tempo untouched. */
  le_engine* e = tg_make_engine_cap(1000, 100000);
  le_snapshot s;

  le_engine_set_tempo(e, 120.0f);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_REC) == LE_OK);
  CHECK(le_engine_set_track_length_preset(e, 0, 4) == LE_OK); /* target 8000 */
  tg_advance(e, 1);

  le_engine_record(e, 0);
  tg_advance(e, 8000); /* reaches the target: xfade_capture arms (F = 10) */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING); /* still deferring the seam */

  tg_advance(e, 5); /* mid-crossfade: xfade_capture counts 10 -> 5, not done */
  le_engine_record(e, 1); /* hand-off lands inside the deferral window */
  tg_advance(e, 1);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING); /* hand-off always -> PLAYING */
  CHECK(s.master_length_frames == 8000); /* snapped to the intended length */
  CHECK(s.loop_bars == 4); /* the full preset, as if it had finished cleanly */
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f); /* untouched */
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);

  le_engine_destroy(e);
}

static void test_length_preset_n_bars_click_on_no_tempo_fallback(void) {
  printf("test_length_preset_n_bars_click_on_no_tempo_fallback\n");
  /* The A6 edge-case decision: N bars + click ON but NO tempo set at record
   * start cannot arm an auto-finalize target (frames-per-bar is unknowable),
   * so it degrades to the N-bars + click-off behavior — an ordinary manual
   * take, tempo derived from length / N on finalize. Runs well past what
   * would have been the N-bar mark with no auto-finalize firing, proving no
   * target was armed. */
  le_engine* e = tg_make_engine_cap(1000, 100000);
  le_snapshot s;

  CHECK(le_engine_set_click_mode(e, LE_CLICK_REC) == LE_OK);
  CHECK(le_engine_set_track_length_preset(e, 0, 4) == LE_OK);
  tg_advance(e, 1);

  le_engine_record(e, 0);
  tg_advance(e, 8500); /* past where a 4-bar-at-any-tempo target could sit */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING); /* still: no target armed */

  le_engine_record(e, 0); /* manual finalize */
  tg_advance(e, 1000 / 100);

  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 8500);
  CHECK(s.loop_bars == 4);
  /* length/4 = 2125 fpbar -> bpm = 60*1000*4/2125 */
  CHECK(fabsf(s.tempo_bpm - 112.941177f) < 0.01f);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_DERIVED);

  le_engine_destroy(e);
}

static void test_length_preset_signature_drift_after_set_degrades_cleanly(
    void) {
  printf("test_length_preset_signature_drift_after_set_degrades_cleanly\n");
  /* Code-review fix: the D17 capacity guard in le_engine_set_track_length_
   * preset validates ONLY at set time, against whatever signature is live
   * then. Nothing locks the signature/tempo between setting the preset and
   * actually recording (no track has content yet, so D6 doesn't block it),
   * so a drift in between can make the live target unreachable even though
   * the set-time check passed. Exact repro: 2/4 @ 30 BPM, a 5-bar preset
   * (validates: 5 * 4000 fpbar == 20000, the cap, exactly) — then drift to
   * 7/4 (5 * 14000 fpbar = 70000, 3.5x the cap) before recording.
   *
   * le_arm_length_preset_target must re-guard with the LIVE grid and leave
   * NO target armed (rather than arming an unreachable 70000-frame target
   * that finalize_master would later find still nonzero and mistake for "on
   * time", silently taking the plain sync_grid_to_loop path instead of the
   * degrade-to-derive-from-length path — the bug: loop_bars 1 / tempo stuck
   * at the manual 30, with the caller never told anything went wrong). With
   * the fix, the take runs to the pre-existing max_loop_frames safety net
   * (this part was always fine — traced, no overflow) and finalizes through
   * the click-off derive-from-length override: a SANE result that actually
   * reflects the 20000-frame recording as 5 bars, not a nonsense default. */
  le_engine* e = tg_make_engine_cap(1000, 20000);
  le_snapshot s;

  CHECK(le_engine_set_time_signature(e, 2, 4) == LE_OK);
  tg_advance(e, 1);
  le_engine_set_tempo(e, 30.0f);
  tg_advance(e, 1);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_REC) == LE_OK);
  CHECK(le_engine_set_track_length_preset(e, 0, 5) ==
        LE_OK); /* 5*4000 == 20000: fits exactly at set time */
  tg_advance(e, 1);

  CHECK(le_engine_set_time_signature(e, 7, 4) == LE_OK); /* the drift */
  tg_advance(e, 1);

  le_engine_record(e, 0); /* live target would be 5*14000 = 70000: unreachable */
  tg_advance(e, 20000);   /* runs into the max_loop_frames safety net */

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING); /* the cap's own finalize */
  CHECK(s.master_length_frames == 20000);
  /* Sane, NOT the bug's bars=1/bpm=30: reflects the actual 20000-frame take
   * as 5 bars at 7/4 -> bpm = 60*1000*7*5/20000 = 105. */
  CHECK(s.loop_bars == 5);
  CHECK(fabsf(s.tempo_bpm - 105.0f) < 0.01f);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_DERIVED);

  le_engine_destroy(e);
}

static void test_length_preset_setter_validates_args(void) {
  printf("test_length_preset_setter_validates_args\n");
  le_engine* e = tg_make_engine(1000);

  CHECK(le_engine_set_track_length_preset(NULL, 0, 1) == LE_ERR_INVALID);
  CHECK(le_engine_set_track_length_preset(e, -1, 1) == LE_ERR_INVALID);
  CHECK(le_engine_set_track_length_preset(e, 0, -1) == LE_ERR_INVALID);
  CHECK(le_engine_set_track_length_preset(e, 0, LE_LENGTH_PRESET_MAX_BARS + 1) ==
        LE_ERR_INVALID);
  CHECK(le_engine_set_track_length_preset(e, 0, 0) == LE_OK); /* AUTO always ok */
  /* In-range but capacity-rejected (64 bars * 8000 fpbar(30bpm,4/4,sr1000) =
   * 512000 >> the 20000 cap): LE_ERR_CAPACITY, not LE_ERR_INVALID — the
   * allocation guard is a distinct failure mode, covered in depth by
   * test_length_preset_allocation_capacity below. A small in-range value
   * that fits is the LE_OK case. */
  CHECK(le_engine_set_track_length_preset(e, 0, LE_LENGTH_PRESET_MAX_BARS) ==
        LE_ERR_CAPACITY);
  CHECK(le_engine_set_track_length_preset(e, 0, 1) == LE_OK);

  le_engine_destroy(e);
}

static void test_length_preset_allocation_capacity(void) {
  printf("test_length_preset_allocation_capacity\n");
  /* D17: N bars x the CURRENT signature x the slowest possible tempo (30
   * BPM) must fit max_loop_frames, checked before recording starts. */
  le_engine* e = tg_make_engine(1000); /* max_loop_frames 20000 */
  le_snapshot s;

  /* The canonical example: 64 bars of 15/8 at 30 BPM is nowhere close. The
   * signature change must be DRAINED (a ring command, not yet applied to the
   * live engine atomics the capacity check reads) before it takes effect. */
  CHECK(le_engine_set_time_signature(e, 15, 8) == LE_OK);
  tg_advance(e, 1);
  CHECK(le_engine_set_track_length_preset(e, 0, 64) == LE_ERR_CAPACITY);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].length_preset_bars == 0); /* rejected: never applied */

  /* Back to 4/4: worst-case frames-per-bar at 30 BPM is 8000 (sr 1000), so
   * 2 bars (16000) fits the 20000 cap and 3 bars (24000) does not. */
  CHECK(le_engine_set_time_signature(e, 4, 4) == LE_OK);
  tg_advance(e, 1);
  CHECK(le_engine_set_track_length_preset(e, 0, 2) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].length_preset_bars == 2);

  CHECK(le_engine_set_track_length_preset(e, 0, 3) == LE_ERR_CAPACITY);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].length_preset_bars == 2); /* unchanged by the rejection */

  le_engine_destroy(e);
}

static void test_length_preset_allocation_capacity_exact_fit(void) {
  printf("test_length_preset_allocation_capacity_exact_fit\n");
  /* Pins the guard's strict `>` as intentional (code review): a preset that
   * needs EXACTLY max_loop_frames — not one frame more — fits. 4/4 at worst-
   * case 30 BPM, sr 1000: frames-per-bar 8000; 3 bars is exactly 24000. */
  le_engine* e = tg_make_engine_cap(1000, 24000);

  CHECK(le_engine_set_track_length_preset(e, 0, 3) == LE_OK); /* 24000 == cap */
  CHECK(le_engine_set_track_length_preset(e, 0, 4) ==
        LE_ERR_CAPACITY); /* 32000 > cap */

  le_engine_destroy(e);
}

static void test_length_preset_inert_until_rerecord(void) {
  printf("test_length_preset_inert_until_rerecord\n");
  /* Setting a preset on an already-recorded track is stored but never
   * retroactive; it takes effect only on the NEXT defining recording, after
   * a clear + re-record. */
  le_engine* e = tg_make_engine_cap(1000, 100000);
  le_snapshot s;

  tg_record_defining_loop(e, 4000); /* AUTO: derives 120 bpm, 2 bars */
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 4000);
  CHECK(s.loop_bars == 2);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f);

  CHECK(le_engine_set_track_length_preset(e, 0, 4) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].length_preset_bars == 4); /* stored... */
  CHECK(s.master_length_frames == 4000);       /* ...but nothing retroactive */
  CHECK(s.loop_bars == 2);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f);

  le_engine_clear(e, 0);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 6000); /* click off: length/4 = 1500 fpbar -> 160 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 6000);
  CHECK(s.loop_bars == 4);
  CHECK(fabsf(s.tempo_bpm - 160.0f) < 0.01f);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_DERIVED);

  le_engine_destroy(e);
}

static void test_length_preset_dormant_with_sync_off(void) {
  printf("test_length_preset_dormant_with_sync_off\n");
  /* With loop<->grid sync off, an N-bars preset is dormant (matches a plain
   * grid-off recording): no auto-finalize target, no tempo derivation. */
  le_engine* e = tg_make_engine_cap(1000, 100000);
  le_snapshot s;

  CHECK(le_engine_set_sync_tempo(e, 0) == LE_OK);
  le_engine_set_tempo(e, 120.0f);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_REC) == LE_OK);
  CHECK(le_engine_set_track_length_preset(e, 0, 4) == LE_OK);
  tg_advance(e, 1);

  le_engine_record(e, 0);
  tg_advance(e, 8500); /* past where an armed target would have fired */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING); /* no auto-finalize */

  le_engine_record(e, 0);
  tg_advance(e, 1000 / 100);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 8500);
  CHECK(s.loop_bars == 0);                    /* free-form, matches sync off */
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f); /* untouched */

  le_engine_destroy(e);
}

static void test_loop_drives_beat_counter(void) {
  printf("test_loop_drives_beat_counter\n");
  /* With a 2-bar loop (8 beats over 4000 frames, a beat every 500), the beat
   * grid is locked to the loop position: the published beat advances
   * 0,1,2,3 and wraps to 0 at the bar boundary. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  le_engine_set_tempo(e, 120.0f);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 4000); /* master position 1 on return */

  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.loop_bars == 2);
  CHECK(s.current_beat == 0);

  tg_advance(e, 600); /* cross 500 -> beat 1 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 1);
  tg_advance(e, 500); /* cross 1000 -> beat 2 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 2);
  tg_advance(e, 500); /* cross 1500 -> beat 3 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 3);
  tg_advance(e, 500); /* cross 2000 -> bar 2's downbeat: beat 4 % 4 == 0 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 0);

  /* Clear-all resets the published beat along with the grid. */
  tg_advance(e, 600); /* move onto a non-zero beat first */
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 1);
  le_engine_clear(e, 0);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 0);
  CHECK(s.loop_bars == 0);

  le_engine_destroy(e);
}

static void test_beat_counter_generic_signature(void) {
  printf("test_beat_counter_generic_signature\n");
  /* 7/8 at 120: the beat unit is an eighth (500 frames at sr 1000), a bar is
   * 3500 frames. A 7000-frame loop is 2 bars = 14 beats; the counter runs
   * 0..6 within each bar. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  CHECK(le_engine_set_time_signature(e, 7, 8) == LE_OK);
  le_engine_set_tempo(e, 120.0f);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 7000);

  le_engine_get_snapshot(e, &s);
  CHECK(s.loop_bars == 2);
  CHECK(s.ts_num == 7);
  CHECK(s.ts_den == 8);

  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 0);
  tg_advance(e, 600); /* cross 500 -> beat 1 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 1);
  tg_advance(e, 2400); /* pos ~3002 -> beat 6 (3000..3499) */
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 6);
  tg_advance(e, 500); /* cross 3500 -> bar 2's downbeat: beat 7 % 7 == 0 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 0);

  le_engine_destroy(e);
}

static void test_tempo_lock_with_content(void) {
  printf("test_tempo_lock_with_content\n");
  /* D6: while any track has content AND a grid exists, manual tempo, time
   * signature, and taps are all ignored; clearing every track releases the
   * lock (and the tempo VALUE survives the clear). */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  le_engine_set_tempo(e, 120.0f);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 4000);

  le_engine_set_tempo(e, 90.0f); /* locked: ignored */
  le_engine_set_time_signature(e, 3, 4); /* locked: ignored */
  tg_advance(e, 1);
  /* Locked taps at an interval that WOULD otherwise set 100 bpm (600 frames
   * at sr 1000 — inside the 30..300 window, so this assertion is not
   * satisfied vacuously by the interval filter). */
  le_engine_tap_tempo(e);
  tg_advance(e, 600);
  le_engine_tap_tempo(e);
  tg_advance(e, 1);

  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f);
  CHECK(s.ts_num == 4);
  CHECK(s.ts_den == 4);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);

  /* Clear-all unlocks; the tempo value + source survive the clear. */
  le_engine_clear(e, 0);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);
  CHECK(s.loop_bars == 0);

  le_engine_set_tempo(e, 90.0f); /* unlocked: applies */
  le_engine_set_time_signature(e, 3, 4);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 90.0f) < 0.01f);
  CHECK(s.ts_num == 3);

  le_engine_destroy(e);
}

static void test_dead_tempo_survives_source_clear(void) {
  printf("test_dead_tempo_survives_source_clear\n");
  /* Clearing the DEFINING loop while a sibling still plays: the grid (and
   * the lock) survive — tempo, bar count, and the master length all hold,
   * and a fresh recording on the cleared track lands back on the surviving
   * grid unchanged. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  le_engine_set_tempo(e, 120.0f);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 4000);

  /* A second track over the master (immediate start, rounds up on stop). */
  le_engine_record(e, 1);
  tg_advance(e, 2000);
  le_engine_record(e, 1);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_OVERDUBBING ||
        s.tracks[1].state == LE_TRACK_PLAYING);

  /* Clear the source loop: the sibling keeps the grid alive. */
  le_engine_clear(e, 0);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.master_length_frames == 4000);
  CHECK(s.loop_bars == 2);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f);

  /* Still locked (content + grid): a manual change is ignored. */
  le_engine_set_tempo(e, 90.0f);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f);

  /* Re-record the cleared track: a non-defining take rounds up to the
   * existing master — the grid state is untouched by it. */
  le_engine_record(e, 0);
  tg_advance(e, 2000);
  le_engine_record(e, 0);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 4000);
  CHECK(s.loop_bars == 2);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f);

  le_engine_destroy(e);
}

static void test_clear_undo_restores_grid(void) {
  printf("test_clear_undo_restores_grid\n");
  /* Undoing a whole-rig clear must bring the GRID back with the loop: the
   * clear kept the tempo (D6) but dropped loop_bars, so without the restore
   * the state would be locked (content + source) yet grid-less — tempo
   * commands permanently no-ops and the beat frozen. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  tg_record_defining_loop(e, 4000); /* derives 120, 2 bars */
  le_engine_get_snapshot(e, &s);
  CHECK(s.loop_bars == 2);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_DERIVED);

  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 0);
  CHECK(s.loop_bars == 0);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f); /* dead tempo survives */

  CHECK(le_engine_undo(e, 0) == LE_OK); /* restore the cleared take */
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 4000);
  CHECK(s.loop_bars == 2); /* the grid came back with the loop */
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f);

  /* The restored grid is live: the beat advances again... */
  tg_advance(e, 700); /* restore reset the playhead; cross 500 -> beat 1 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 1);

  /* ...and the restored state is locked exactly like the original. */
  le_engine_set_tempo(e, 90.0f);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f);

  /* A plain clear-all still unlocks: tempo commands apply again. */
  le_engine_clear(e, 0);
  tg_advance(e, 1);
  le_engine_set_tempo(e, 90.0f);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 90.0f) < 0.01f);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);

  le_engine_destroy(e);
}

static void test_surviving_grid_regrid_on_tempo_change(void) {
  printf("test_surviving_grid_regrid_on_tempo_change\n");
  /* Undo-to-empty keeps the master + grid while releasing the D6 lock (no
   * content). An unlocked signature or tempo change must then RECOMPUTE the
   * surviving grid (bars and beat cadence), not leave it describing the old
   * value. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  le_engine_set_tempo(e, 120.0f);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 4000); /* 2 bars of 4/4 at 120 */
  CHECK(le_engine_undo(e, 0) == LE_OK); /* undo past the base layer */
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.master_length_frames == 4000); /* grid survives for redo */
  CHECK(s.loop_bars == 2);

  /* Unlocked signature change: 3/4 at 120 is a 1500-frame bar, so the
   * surviving 4000-frame master re-rounds to 3 bars (stale would be 2). */
  CHECK(le_engine_set_time_signature(e, 3, 4) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.ts_num == 3);
  CHECK(s.loop_bars == 3);

  /* Unlocked tempo change: 60 bpm in 3/4 is a 3000-frame bar -> 1 bar. */
  le_engine_set_tempo(e, 60.0f);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 60.0f) < 0.01f);
  CHECK(s.loop_bars == 1);

  le_engine_destroy(e);
}

static void test_commit_session_resets_stale_grid(void) {
  printf("test_commit_session_resets_stale_grid\n");
  /* A session import replaces the loop wholesale: the pre-import grid
   * described the OLD loop and must not be applied to the imported one. The
   * import stays grid-free in this part (manifest-driven derivation is A7);
   * the tempo value and source survive per D6. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  le_engine_set_tempo(e, 120.0f);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 4000); /* 2 bars */
  le_engine_get_snapshot(e, &s);
  CHECK(s.loop_bars == 2);

  CHECK(le_push(e, LE_CMD_COMMIT_SESSION, 3000, 0.0f) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 3000);
  CHECK(s.loop_bars == 0);
  CHECK(s.current_beat == 0);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);

  /* No beat publication on the grid-free imported loop. */
  tg_advance(e, 600);
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 0);

  le_engine_destroy(e);
}

static void test_tap_pair_dies_with_clear(void) {
  printf("test_tap_pair_dies_with_clear\n");
  /* Regression: a lone tap latched BEFORE the D6 lock engaged must not pair
   * with the first tap after clear-all releases it — the record+clear span
   * can land inside the valid 30..300 window and would publish a plausible-
   * looking but meaningless TAPPED tempo over the surviving derived one. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  le_engine_tap_tempo(e); /* lone pre-lock tap (frame ~0) */
  tg_advance(e, 1);
  tg_record_defining_loop(e, 700); /* sub-bar loop: derives the 300 clamp */
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 300.0f) < 0.01f);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_DERIVED);

  le_engine_clear(e, 0); /* all empty: unlock + tap pair reset */
  tg_advance(e, 1);
  le_engine_tap_tempo(e); /* ~713 frames after the first tap: 84 bpm if the
                           * stale pair survived the clear */
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 300.0f) < 0.01f); /* unchanged */
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_DERIVED); /* not TAPPED */

  le_engine_destroy(e);
}

static void test_lock_engages_with_sync_off_content(void) {
  printf("test_lock_engages_with_sync_off_content\n");
  /* Free-form content (sync off -> loop_bars 0) with a manually-set tempo
   * still locks — the tempo_source half of the D6 predicate alone. Pinned
   * deliberately (see le_tempo_locked): the set tempo was audible context
   * for the take, pre-stretch a change cannot be honored, and the Sheeran
   * locks tempo after any recording. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  CHECK(le_engine_set_sync_tempo(e, 0) == LE_OK);
  le_engine_set_tempo(e, 137.0f);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 1800);
  le_engine_get_snapshot(e, &s);
  CHECK(s.loop_bars == 0); /* free-form: no grid half to the lock */

  le_engine_set_tempo(e, 90.0f); /* locked via the source half alone */
  le_engine_set_time_signature(e, 3, 4);
  tg_advance(e, 1);
  le_engine_tap_tempo(e); /* in-window interval: would set ~100 bpm */
  tg_advance(e, 600);
  le_engine_tap_tempo(e);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 137.0f) < 0.01f);
  CHECK(s.ts_num == 4);
  CHECK(s.tempo_source == LE_TEMPO_SOURCE_MANUAL);

  le_engine_destroy(e);
}

static void test_beat_division_locks_to_loop(void) {
  printf("test_beat_division_locks_to_loop\n");
  /* An 1800-frame loop at nominal 120 (2000-frame bar) rounds to 1 bar: its
   * 4 beats divide the LOOP — boundaries every 450 frames — not the nominal
   * tempo's 500. A beat counter running on nominal frames-per-beat would
   * still read beat 0 at position ~460 and beat 1 at ~900. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  le_engine_set_tempo(e, 120.0f);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 1800); /* master position 1 on return */

  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.loop_bars == 1);
  CHECK(s.current_beat == 0);

  tg_advance(e, 460); /* pos ~462: past 450 (loop beat 1), before 500 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 1);

  tg_advance(e, 440); /* pos ~902: past 900 (loop beat 2), before 1000 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 2);

  le_engine_destroy(e);
}

static void test_beat_boundary_on_block_edge(void) {
  printf("test_beat_boundary_on_block_edge\n");
  /* A beat boundary landing exactly on a process-block edge publishes on the
   * block whose FIRST frame is the boundary — no off-by-one at the seam. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;
  float in[1] = {0};
  float out[4];

  le_engine_set_tempo(e, 120.0f);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 4000); /* beats every 500; position 1 on return */

  tg_advance(e, 1);   /* publishes beat 0, position -> 2 */
  tg_advance(e, 498); /* start positions 2..499: still beat 0, position 500 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 0);

  le_engine_process(e, out, in, 1); /* one-frame block AT the boundary */
  le_engine_get_snapshot(e, &s);
  CHECK(s.current_beat == 1);

  le_engine_destroy(e);
}

/* ---- musical quantize arming (A3: loop-locked subdivision grid) ---- */

/* The pure loop-locked subdivision helpers: rational subdivision counts,
 * exact-division boundary rendering (mirroring le_grid_beat_at), and the
 * strictly-after next-boundary convention with the wrap as the final one. */
static void test_loop_subdiv_ratio_and_boundaries(void) {
  printf("test_loop_subdiv_ratio_and_boundaries\n");
  int64_t n = 0, d = 0;

  /* 2 bars of 4/4 (8 beats): 2 bars, 4 halves, 8 quarters, 16 eighths,
   * 32 sixteenths — as unreduced rationals. */
  CHECK(le_grid_loop_subdiv_ratio(8, 4, 4, LE_GRID_DIV_BAR, &n, &d) == 1);
  CHECK(n == 8 && d == 4);
  CHECK(le_grid_loop_subdiv_ratio(8, 4, 4, LE_GRID_DIV_HALF, &n, &d) == 1);
  CHECK(n == 16 && d == 4);
  CHECK(le_grid_loop_subdiv_ratio(8, 4, 4, LE_GRID_DIV_QUARTER, &n, &d) == 1);
  CHECK(n == 32 && d == 4);
  CHECK(le_grid_loop_subdiv_ratio(8, 4, 4, LE_GRID_DIV_EIGHTH, &n, &d) == 1);
  CHECK(n == 64 && d == 4);
  CHECK(le_grid_loop_subdiv_ratio(8, 4, 4, LE_GRID_DIV_SIXTEENTH, &n, &d) == 1);
  CHECK(n == 128 && d == 4);

  /* One 3/4 bar holds 1.5 half notes — the rational (non-integer) count. */
  CHECK(le_grid_loop_subdiv_ratio(3, 3, 4, LE_GRID_DIV_HALF, &n, &d) == 1);
  CHECK(n == 6 && d == 4);

  /* OFF / unknown / degenerate refuse. */
  CHECK(le_grid_loop_subdiv_ratio(8, 4, 4, LE_GRID_DIV_OFF, &n, &d) == 0);
  CHECK(le_grid_loop_subdiv_ratio(8, 4, 4, 99, &n, &d) == 0);
  CHECK(le_grid_loop_subdiv_ratio(0, 4, 4, LE_GRID_DIV_BAR, &n, &d) == 0);
  CHECK(le_grid_loop_subdiv_ratio(8, 0, 4, LE_GRID_DIV_BAR, &n, &d) == 0);
  CHECK(le_grid_loop_subdiv_ratio(8, 4, 4, LE_GRID_DIV_BAR, NULL, &d) == 0);

  /* Exact division over a non-divisible length: 48001 frames, 4 quarters
   * (one 4/4 bar, ratio 16/4) -> boundaries at ceil(i * 48001 / 4) =
   * 0, 12001, 24001, 36001 — remainder distributed, no drift. */
  CHECK(le_grid_loop_subdiv_at(0, 48001, 16, 4) == 0);
  CHECK(le_grid_loop_subdiv_at(12000, 48001, 16, 4) == 0);
  CHECK(le_grid_loop_subdiv_at(12001, 48001, 16, 4) == 1);
  CHECK(le_grid_loop_subdiv_at(24000, 48001, 16, 4) == 1);
  CHECK(le_grid_loop_subdiv_at(24001, 48001, 16, 4) == 2);
  CHECK(le_grid_loop_subdiv_start(1, 48001, 16, 4) == 12001);
  CHECK(le_grid_loop_subdiv_start(2, 48001, 16, 4) == 24001);
  CHECK(le_grid_loop_subdiv_start(3, 48001, 16, 4) == 36001);
  CHECK(le_grid_loop_next_subdiv(0, 48001, 16, 4) == 12001);
  CHECK(le_grid_loop_next_subdiv(12001, 48001, 16, 4) == 24001);
  CHECK(le_grid_loop_next_subdiv(36001, 48001, 16, 4) == 48001); /* wrap */
  CHECK(le_grid_loop_next_subdiv(47000, 48001, 16, 4) == 48001); /* wrap */

  /* Fractional count: 1.5 halves over a 1500-frame 3/4 bar (ratio 6/4) put
   * the ONLY interior boundary at beat 2 = frame 1000, then the wrap. */
  CHECK(le_grid_loop_subdiv_at(999, 1500, 6, 4) == 0);
  CHECK(le_grid_loop_subdiv_at(1000, 1500, 6, 4) == 1);
  CHECK(le_grid_loop_next_subdiv(0, 1500, 6, 4) == 1000);
  CHECK(le_grid_loop_next_subdiv(1000, 1500, 6, 4) == 1500); /* wrap */

  /* Degenerate arguments. */
  CHECK(le_grid_loop_subdiv_at(-1, 1500, 6, 4) == 0);
  CHECK(le_grid_loop_subdiv_at(5, 0, 6, 4) == 0);
  CHECK(le_grid_loop_subdiv_start(0, 1500, 6, 4) == 0);
  CHECK(le_grid_loop_next_subdiv(-1, 1500, 6, 4) == -1);
  CHECK(le_grid_loop_next_subdiv(1500, 1500, 6, 4) == -1); /* pos >= len */
  CHECK(le_grid_loop_next_subdiv(5, 1500, 0, 4) == -1);
}

/* A3 fixture: sr 1000, manual 120 bpm in 4/4 (nominal bar 2000 frames), and a
 * 3000-frame defining loop on track 0 — 1.5 nominal bars, which A1 rounds to
 * 2 bars. The LOOP-LOCKED grid therefore deliberately disagrees with the
 * nominal one: 8 beats over 3000 frames put the loop-locked bar at 1500 and
 * the quarter at 375, where nominal-BPM math says 2000 and 500. Boolean
 * quantize is ON (it gates IF arming happens; the division decides WHERE the
 * armed action fires). Master position is 1 on return. */
static le_engine* qa_make_grid_engine(void) {
  le_engine* e = tg_make_engine(1000);
  le_engine_set_tempo(e, 120.0f);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 3000);
  le_engine_set_quantize(e, 1);
  return e;
}

/* Processes constant-`value` input until the master position is exactly
 * `target` (forward, wrapping). */
static void qa_advance_to(le_engine* e, float value, int32_t target) {
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  int32_t delta = target - s.master_position_frames;
  if (delta < 0) delta += s.master_length_frames;
  float in[64];
  float out[64];
  for (int i = 0; i < 64; ++i) in[i] = value;
  while (delta > 0) {
    const int n = delta > 64 ? 64 : delta;
    le_engine_process(e, out, in, (uint32_t)n);
    delta -= n;
  }
}

/* Plays `len` frames of silent input from the current position, copying the
 * mono output into dst (dst[i] == loop content at position start + i). */
static void qa_capture_out(le_engine* e, float* dst, int len) {
  float in[64] = {0};
  float out[64];
  int off = 0;
  while (off < len) {
    const int n = (len - off) > 64 ? 64 : (len - off);
    le_engine_process(e, out, in, (uint32_t)n);
    memcpy(dst + off, out, (size_t)n * sizeof(float));
    off += n;
  }
}

/* One D8 record-start row: with `div` set, a record press on empty track 1 at
 * master position `arm_pos` arms, stays armed through `fire_pos` - 1, and
 * begins recording exactly at `fire_pos`. Clears track 1 before returning. */
static void qa_check_start_fire(le_engine* e, int32_t div, int32_t arm_pos,
                                int32_t fire_pos) {
  le_snapshot s;
  CHECK(le_engine_set_quantize_div(e, div) == LE_OK);
  qa_advance_to(e, 0.0f, arm_pos);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY); /* armed, not recording */
  CHECK(s.tracks[1].pending == 1);

  qa_advance_to(e, 0.0f, fire_pos - 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY); /* one frame early: still armed */

  tg_advance(e, 1); /* the boundary frame */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);
  CHECK(s.tracks[1].pending == 0);

  le_engine_clear(e, 1);
  drain(e);
}

/* D8 record start, row by row, on a loop whose length is NOT a whole number
 * of nominal bars — the boundaries MUST come from the loop-locked grid.
 * Loop-locked boundaries over the 3000-frame 2-bar loop: bar 1500, half 750,
 * quarter 375, eighth ceil(187.5) = 188, sixteenth ceil(93.75) = 94. The BAR
 * row doubles as the nominal-vs-loop-locked discriminator: nominal-BPM math
 * (le_grid_next_boundary at 120 bpm) would wait until frame 2000. */
static void test_quantize_div_start_fires_on_loop_locked_grid(void) {
  printf("test_quantize_div_start_fires_on_loop_locked_grid\n");
  le_engine* e = qa_make_grid_engine();

  qa_check_start_fire(e, LE_GRID_DIV_BAR, 1, 1500); /* nominal would be 2000 */
  qa_check_start_fire(e, LE_GRID_DIV_HALF, 1, 750);
  qa_check_start_fire(e, LE_GRID_DIV_QUARTER, 1, 375);
  qa_check_start_fire(e, LE_GRID_DIV_EIGHTH, 1, 188);
  qa_check_start_fire(e, LE_GRID_DIV_SIXTEENTH, 1, 94);
  /* Armed past the last interior boundary, the fire is the loop top (the
   * helper's boundary frame at `len` is the wrap into position 0). */
  qa_check_start_fire(e, LE_GRID_DIV_BAR, 1600, 3000);

  le_engine_destroy(e);
}

/* D8 record END, round-down: a finalize press 3.49 quarter units into the
 * capture truncates at unit 3 — the tail past the boundary behind is dropped
 * (zeroed) and the track finalizes immediately at that boundary. */
static void test_quantize_div_record_end_rounds_down(void) {
  printf("test_quantize_div_record_end_rounds_down\n");
  le_engine* e = qa_make_grid_engine();
  le_snapshot s;

  CHECK(le_engine_set_quantize_div(e, LE_GRID_DIV_QUARTER) == LE_OK);
  qa_advance_to(e, 0.0f, 1);
  le_engine_record(e, 1); /* arm the start */
  drain(e);
  qa_advance_to(e, 0.0f, 375); /* fire: capture begins at 375 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);

  /* 3.49 units of 2.0 (1309 frames): behind = 184 < ahead = 191. */
  qa_advance_to(e, 2.0f, 375 + 1309);
  le_engine_record(e, 1); /* finalize press */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING); /* truncated, finalized NOW */
  CHECK(s.tracks[1].pending == 0);
  CHECK(s.tracks[1].multiple == 1);
  CHECK(s.tracks[1].length_frames == 3000);

  /* Content: 2.0 over exactly [375, 1500) — 3 whole units — and silence
   * everywhere else, including the truncated tail [1500, 1684). */
  static float dst[3000];
  qa_advance_to(e, 0.0f, 0);
  qa_capture_out(e, dst, 3000);
  CHECK(fabsf(dst[374]) < 1e-6f);
  CHECK(fabsf(dst[375] - 2.0f) < 1e-6f);
  CHECK(fabsf(dst[1499] - 2.0f) < 1e-6f);
  CHECK(fabsf(dst[1500]) < 1e-6f);
  CHECK(fabsf(dst[1600]) < 1e-6f);
  CHECK(fabsf(dst[1683]) < 1e-6f);
  CHECK(fabsf(dst[2500]) < 1e-6f);

  le_engine_destroy(e);
}

/* D8 record END, round-up: a finalize press 3.51 units in keeps capturing to
 * unit 4 — the pending end fires exactly on the boundary ahead. */
static void test_quantize_div_record_end_rounds_up(void) {
  printf("test_quantize_div_record_end_rounds_up\n");
  le_engine* e = qa_make_grid_engine();
  le_snapshot s;

  CHECK(le_engine_set_quantize_div(e, LE_GRID_DIV_QUARTER) == LE_OK);
  qa_advance_to(e, 0.0f, 1);
  le_engine_record(e, 1);
  drain(e);
  qa_advance_to(e, 0.0f, 375);

  /* 3.51 units of 2.0 (1317 frames, position 1692): behind = 192 >=
   * ahead = 183 -> the end arms for the boundary at 1875. */
  qa_advance_to(e, 2.0f, 375 + 1317);
  le_engine_record(e, 1);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING); /* still capturing */
  CHECK(s.tracks[1].pending == 1);

  qa_advance_to(e, 2.0f, 1874); /* one frame short of the boundary */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);

  qa_advance_to(e, 2.0f, 1875); /* the boundary frame fires the finalize */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].length_frames == 3000);

  /* Content: 2.0 over exactly [375, 1875) — 4 whole units. */
  static float dst[3000];
  qa_advance_to(e, 0.0f, 0);
  qa_capture_out(e, dst, 3000);
  CHECK(fabsf(dst[375] - 2.0f) < 1e-6f);
  CHECK(fabsf(dst[1874] - 2.0f) < 1e-6f);
  CHECK(fabsf(dst[1875]) < 1e-6f);

  le_engine_destroy(e);
}

/* D8 record END, min 1 unit: a finalize press 0.27 units into the capture
 * would truncate to a ZERO-length take — it must round up instead, capturing
 * exactly one whole unit. */
static void test_quantize_div_record_end_min_one_unit(void) {
  printf("test_quantize_div_record_end_min_one_unit\n");
  le_engine* e = qa_make_grid_engine();
  le_snapshot s;

  CHECK(le_engine_set_quantize_div(e, LE_GRID_DIV_QUARTER) == LE_OK);
  qa_advance_to(e, 0.0f, 1);
  le_engine_record(e, 1);
  drain(e);
  qa_advance_to(e, 0.0f, 375);

  /* 100 frames in: behind = 100 < ahead = 275, but truncating would leave a
   * 0-unit capture -> the end arms for the boundary at 750 instead. */
  qa_advance_to(e, 2.0f, 475);
  le_engine_record(e, 1);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING); /* min 1 unit: rounds up */
  CHECK(s.tracks[1].pending == 1);

  qa_advance_to(e, 2.0f, 750); /* the 1-unit boundary fires the finalize */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);

  static float dst[3000];
  qa_advance_to(e, 0.0f, 0);
  qa_capture_out(e, dst, 3000);
  CHECK(fabsf(dst[375] - 2.0f) < 1e-6f);
  CHECK(fabsf(dst[749] - 2.0f) < 1e-6f);
  CHECK(fabsf(dst[750]) < 1e-6f);

  le_engine_destroy(e);
}

/* D8 overdub rows: the START is subdivision-quantized like a record start;
 * the END stays at the layer boundary (the loop top) exactly as today — a
 * punch-out never fires on a mid-loop subdivision boundary. */
static void test_quantize_div_overdub_start_quantized_end_layer(void) {
  printf("test_quantize_div_overdub_start_quantized_end_layer\n");
  le_engine* e = qa_make_grid_engine();
  le_snapshot s;

  CHECK(le_engine_set_quantize_div(e, LE_GRID_DIV_QUARTER) == LE_OK);
  qa_advance_to(e, 0.0f, 400);
  le_engine_record(e, 0); /* arm a punch-in on the playing master track */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING); /* armed, not overdubbing */
  CHECK(s.tracks[0].pending == 1);

  qa_advance_to(e, 0.0f, 749);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  tg_advance(e, 1); /* quarter boundary 750: overdub START fires */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);

  le_engine_record(e, 0); /* arm the punch-OUT */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);
  CHECK(s.tracks[0].pending == 1);

  /* Mid-loop quarter boundaries (1125, 1500, ... 2625) must NOT punch out. */
  qa_advance_to(e, 0.0f, 2900);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);

  qa_advance_to(e, 0.0f, 0); /* the layer boundary (loop top) does */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].pending == 0);

  le_engine_destroy(e);
}

/* Granularity change while armed re-evaluates immediately: a pending BAR arm
 * switched to SIXTEENTH fires on the very next sixteenth boundary. */
static void test_quantize_div_granularity_change_reevaluates(void) {
  printf("test_quantize_div_granularity_change_reevaluates\n");
  le_engine* e = qa_make_grid_engine();
  le_snapshot s;

  CHECK(le_engine_set_quantize_div(e, LE_GRID_DIV_BAR) == LE_OK);
  qa_advance_to(e, 0.0f, 1600); /* past the interior bar boundary at 1500 */
  le_engine_record(e, 1);       /* arm: the BAR fire would be the loop top */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[1].pending == 1);

  /* Switch to SIXTEENTH (93.75 frames/unit): the next sixteenth boundary
   * after 1600 is ceil(18 * 93.75) = 1688 — the pending arm must fire there,
   * within one sixteenth of the change, not wait for the bar. */
  CHECK(le_engine_set_quantize_div(e, LE_GRID_DIV_SIXTEENTH) == LE_OK);
  qa_advance_to(e, 0.0f, 1687);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);

  le_engine_destroy(e);
}

/* A change to OFF while armed reverts the pending fire to the loop top: the
 * boolean loop-top machinery, exactly as before A3. */
static void test_quantize_div_off_reverts_pending_to_loop_top(void) {
  printf("test_quantize_div_off_reverts_pending_to_loop_top\n");
  le_engine* e = qa_make_grid_engine();
  le_snapshot s;

  CHECK(le_engine_set_quantize_div(e, LE_GRID_DIV_SIXTEENTH) == LE_OK);
  qa_advance_to(e, 0.0f, 100);
  le_engine_record(e, 1);
  drain(e);
  CHECK(le_engine_set_quantize_div(e, LE_GRID_DIV_OFF) == LE_OK);

  /* Every interior sixteenth boundary passes without firing... */
  qa_advance_to(e, 0.0f, 2999);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[1].pending == 1);

  tg_advance(e, 1); /* ...the loop top fires. */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);

  le_engine_destroy(e);
}

/* Code-review fix (A3 follow-up), design decision documented at the ARM
 * apply-site's min-1-unit check: "min 1 unit" is scoped to whichever
 * division is live when the boundary actually fires, not the one active
 * when the press armed it (option (a) — the stateless-wait philosophy
 * already used for the record-START and granularity-change-while-armed
 * paths; no target length or armed division is latched anywhere). A press
 * whose round-down candidate fails QUARTER's min-1-unit (leaving < 1 quarter
 * of capture) falls through to the plain wait — and a granularity change to
 * SIXTEENTH during that wait is honored on the SIXTEENTH's own very next
 * boundary, producing a capture shorter than one QUARTER unit: min-1-unit is
 * never re-checked against the division active at press time. */
static void test_quantize_div_min_one_unit_reevaluates_on_granularity_change(
    void) {
  printf("test_quantize_div_min_one_unit_reevaluates_on_granularity_change\n");
  le_engine* e = qa_make_grid_engine(); /* quantize=1 boolean ON, div OFF (default) */
  le_snapshot s;

  /* Arm and fire the start with the division still OFF, so it fires
   * specifically at the loop top (position 0) — the only boundary that
   * exists pre-A3 — rather than the first QUARTER boundary reached on the
   * way there (375), which a div already live at arm time would fire on
   * instead. record_start must be exactly 0 for the span math below. */
  le_engine_record(e, 1); /* arm the start */
  drain(e);
  qa_advance_to(e, 0.0f, 0); /* wrap: fires the start at the loop top, pos 0 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);

  CHECK(le_engine_set_quantize_div(e, LE_GRID_DIV_QUARTER) == LE_OK);

  /* Only 50 frames in: the round-down candidate (boundary 0, `behind` = 50)
   * would leave a ZERO-length capture — min-1-unit under QUARTER (unit 375)
   * fails, so the end falls through to the wait instead of truncating now. */
  qa_advance_to(e, 2.0f, 50);
  le_engine_record(e, 1); /* finalize press */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING); /* not truncated: waiting */
  CHECK(s.tracks[1].pending == 1);

  /* Switch to SIXTEENTH (93.75 frames/unit) immediately: the wait is
   * stateless, so this is honored on SIXTEENTH's own next boundary — 94 —
   * NOT re-checked against QUARTER's 375-frame min-1-unit floor. */
  CHECK(le_engine_set_quantize_div(e, LE_GRID_DIV_SIXTEENTH) == LE_OK);
  qa_advance_to(e, 2.0f, 93);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING); /* one frame short: waiting */

  /* position 94: the sixteenth boundary fires the finalize (still capturing
   * 2.0 through the last frame — a silent tg_advance here would falsely
   * plant a silent sample at index 93 and corrupt the span check below). */
  qa_advance_to(e, 2.0f, 94);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].pending == 0);
  CHECK(s.tracks[1].length_frames == 3000); /* rounded up to the base loop */

  /* The captured span itself proves it: content in [0, 94) only — a 94-frame
   * take, far short of one QUARTER unit (375), exactly as documented. */
  float* lane1 = (float*)calloc(3000, sizeof(float));
  CHECK(le_engine_export_track_lane(e, 1, 0, lane1, 3000) == 3000);
  CHECK(fabsf(lane1[0] - 2.0f) < 1e-6f);
  CHECK(fabsf(lane1[93] - 2.0f) < 1e-6f);
  CHECK(fabsf(lane1[94]) < 1e-6f);
  CHECK(fabsf(lane1[374]) < 1e-6f); /* silent well past the old QUARTER unit */
  free(lane1);

  le_engine_destroy(e);
}

/* Disarm racing the boundary frame inside one process block: ring commands
 * apply at block START, before any frame advances, so a disarm posted before
 * the block containing the boundary DETERMINISTICALLY wins — the fire never
 * happens. (A disarm posted after the boundary's block has already fired
 * loses just as deterministically; the control thread then reconciles the
 * spent arm on the next press.) */
static void test_quantize_div_disarm_wins_at_boundary_block(void) {
  printf("test_quantize_div_disarm_wins_at_boundary_block\n");
  le_engine* e = qa_make_grid_engine();
  le_snapshot s;

  CHECK(le_engine_set_quantize_div(e, LE_GRID_DIV_QUARTER) == LE_OK);
  qa_advance_to(e, 0.0f, 1);
  le_engine_record(e, 1); /* arm: fires at 375 */
  drain(e);
  qa_advance_to(e, 0.0f, 374); /* one frame short of the boundary */

  le_engine_record(e, 1); /* second press -> DISARM, not yet applied */
  /* ONE block that both applies the disarm and crosses frame 375. */
  tg_advance(e, 64);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY); /* disarm won */
  CHECK(s.tracks[1].pending == 0);

  qa_advance_to(e, 0.0f, 1); /* a full wrap later: still cancelled */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY);

  le_engine_destroy(e);
}

/* One-capturer hand-off with a pending quantized END on another track: the
 * hand-off finalizes the recording track immediately AND clears its pending
 * end — a stale arm must not re-fire on the now-playing track (it would start
 * a spurious overdub at the next boundary). */
static void test_quantize_div_handoff_clears_pending_end(void) {
  printf("test_quantize_div_handoff_clears_pending_end\n");
  le_engine* e = qa_make_grid_engine();
  le_snapshot s;

  CHECK(le_engine_set_quantize_div(e, LE_GRID_DIV_QUARTER) == LE_OK);
  qa_advance_to(e, 0.0f, 1);
  le_engine_record(e, 1);
  drain(e);
  qa_advance_to(e, 0.0f, 375);

  /* Round-up end pending (as in the rounds_up test): fires at 1875. */
  qa_advance_to(e, 2.0f, 375 + 1317);
  le_engine_record(e, 1);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);
  CHECK(s.tracks[1].pending == 1);

  /* An immediate record on track 2 (per-track quantize off) hands the one
   * capturer over: track 1 finalizes NOW and its pending end is spent. */
  CHECK(le_engine_set_track_quantize(e, 2, 0) == LE_OK);
  le_engine_record(e, 2);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].pending == 0);
  CHECK(s.tracks[1].length_frames == 3000); /* rounded up to the base loop */
  CHECK(s.tracks[2].state == LE_TRACK_RECORDING);

  /* Past where the stale end would have fired — and past the loop top — the
   * hand-off target keeps recording and track 1 never re-enters a capture. */
  qa_advance_to(e, 0.0f, 1900);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  qa_advance_to(e, 0.0f, 100);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[2].state == LE_TRACK_RECORDING);

  le_engine_destroy(e);
}

/* Code-review fix (A3 follow-up): close_active_capture's pending-record clear
 * (engine_process.c) is shared machinery — it fires for a hand-off whether
 * the closed track's pending arm is a subdivision boundary (A3, div != OFF)
 * or a plain loop-top boundary (the PRE-EXISTING boolean-quantize path,
 * quantize_div == OFF, which predates A3 entirely and must keep working
 * bit-identically). test_quantize_div_handoff_clears_pending_end above only
 * exercises the subdivision case; this is its div-OFF sibling, guarding
 * against a future refactor that conditions the clear on subdivision state
 * and silently reintroduces the bug for the boolean-only path (confirmed to
 * reproduce on master, one commit before this fix). */
static void test_quantize_boolean_handoff_clears_pending_end(void) {
  printf("test_quantize_boolean_handoff_clears_pending_end\n");
  le_engine* e = qa_make_grid_engine(); /* quantize=1 boolean ON, div OFF (default) */
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.quantize_div == LE_GRID_DIV_OFF); /* the pre-A3 boolean-only path */

  /* Arm a boolean loop-top START on track 1 and let it fire at the wrap
   * (master position 1 on return from qa_make_grid_engine). */
  le_engine_record(e, 1);
  drain(e);
  qa_advance_to(e, 0.0f, 0); /* wrap: fires the start */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);

  /* A second press mid-capture arms the boolean loop-top END (D8's
   * pre-existing "stop/mute — immediate" row does not apply here: a record
   * press, not a stop, always quantizes when the boolean is on). */
  qa_advance_to(e, 2.0f, 500);
  le_engine_record(e, 1);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING); /* still capturing */
  CHECK(s.tracks[1].pending == 1);

  /* An immediate record on track 2 (per-track quantize off) hands the one
   * capturer over: track 1 finalizes NOW (rounded up to the base loop) and
   * its pending end is spent — close_active_capture's clear, exercised here
   * on the div-OFF/loop-top path. */
  CHECK(le_engine_set_track_quantize(e, 2, 0) == LE_OK);
  le_engine_record(e, 2);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].pending == 0);
  CHECK(s.tracks[1].length_frames == 3000); /* rounded up to the base loop */
  CHECK(s.tracks[2].state == LE_TRACK_RECORDING);

  /* A full loop later (unconditional, not qa_advance_to's wrap-if-behind
   * math — the master is already sitting at the position this hand-off
   * pressed at, so a same-position target would be a zero-frame no-op and
   * never actually cross the loop top the stale end would fire on) — past
   * where the stale boolean end would have fired — track 1 stays PLAYING:
   * no spurious overdub. */
  tg_advance(e, 3000);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].pending == 0);
  CHECK(s.tracks[2].state == LE_TRACK_RECORDING);

  le_engine_destroy(e);
}

/* Boolean quantize still GATES arming: with it off, a set division alone must
 * not defer anything — record starts and ends act immediately, mid-unit. */
static void test_quantize_div_requires_boolean_quantize(void) {
  printf("test_quantize_div_requires_boolean_quantize\n");
  le_engine* e = qa_make_grid_engine();
  le_snapshot s;

  le_engine_set_quantize(e, 0); /* boolean off, division set */
  CHECK(le_engine_set_quantize_div(e, LE_GRID_DIV_QUARTER) == LE_OK);

  qa_advance_to(e, 0.0f, 100); /* mid-unit */
  le_engine_record(e, 1);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING); /* immediate, no arm */
  CHECK(s.tracks[1].pending == 0);

  qa_advance_to(e, 2.0f, 500); /* mid-unit again */
  le_engine_record(e, 1);      /* finalize press */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING); /* immediate, no rounding */
  CHECK(s.tracks[1].pending == 0);

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

/* Regression: a monitor enabled DURING a measurement must stay enabled after it
 * completes. On launch the saved monitors are restored asynchronously and can
 * land mid-measurement (after the pulse has started). The measurement must not
 * revert that enable — it never touches a_enabled, relying on the pulse path's
 * per-frame mix bypass to silence monitoring while measuring. Reproduces the
 * "some inputs don't monitor on program open until toggled" bug. */
static void test_latency_keeps_monitor_enabled_set_mid_measurement(void) {
  printf("test_latency_keeps_monitor_enabled_set_mid_measurement\n");
  enum { SR = 48000, CAP = SR / 10 };
  le_engine* e = le_engine_create();
  le_engine_configure(e, SR, 2, 2, 100000);
  le_engine_set_excluded_input_mask_for_test(e, 0x2u); /* ch1 = loopback */

  /* Begin measuring FIRST (input 0 not yet monitored — the launch race: the
   * suppression snapshot, if any, is taken before the monitor is restored). */
  CHECK(le_engine_begin_latency_for_test(e) == LE_OK);
  drain(e); /* applies MEASURE: lat_active = 1 */

  /* Now enable monitoring of input 0 -> output 0, mid-measurement. */
  CHECK(le_engine_set_monitor_input(e, 0, 1) == LE_OK);
  CHECK(le_engine_set_monitor_input_output(e, 0, 0x1) == LE_OK);
  drain(e); /* applies the enable while lat_active is still 1 */

  /* Run the capture window to completion over silence (resolves to TIMEOUT; the
   * completion path — which used to revert a_enabled — runs regardless). */
  float* out = calloc((size_t)CAP * 2, sizeof(float));
  float* in = calloc((size_t)CAP * 2, sizeof(float));
  CHECK(out != NULL && in != NULL);
  le_engine_process(e, out, in, CAP);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.latency_state != LE_LATENCY_MEASURING); /* measurement finished */

  /* Monitoring set mid-measurement must have survived: input 0 is audible on
   * output 0. Before the fix, the completion restore reverted a_enabled to the
   * pre-measurement snapshot (0) and this read 0. */
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

/* ---- retired-layer manifest test helpers (part 5, D-LAYER) — the sidecar's
 * "layers" array is hand-rolled JSON like the rest of performance.json, so
 * these are plain strstr-based scans, not a real parser. ---- */

/* Counts occurrences of `"filename"` in the sidecar text — one per layer
 * manifest entry, a cheap proxy for "how many layers were persisted." */
static int count_layer_entries_for_test(const char* json) {
  int count = 0;
  const char* p = json;
  while ((p = strstr(p, "\"filename\"")) != NULL) {
    ++count;
    p += 10;
  }
  return count;
}

/* Extracts the Nth (0-indexed) layer entry's filename field from the
 * sidecar's "layers" array into `out` (a plain scan for `"filename": "..."`,
 * matching le_pd_write_sidecar's own construction exactly). Returns 1 on
 * success, 0 if fewer than n+1 entries exist. */
static int nth_layer_filename_for_test(const char* json, int n, char* out,
                                       size_t out_cap) {
  const char* p = json;
  for (int i = 0; i <= n; ++i) {
    p = strstr(p, "\"filename\": \"");
    if (p == NULL) return 0;
    if (i < n) p += 13;
  }
  p += 13; /* past the opening quote */
  const char* end = strchr(p, '"');
  if (end == NULL) return 0;
  size_t len = (size_t)(end - p);
  if (len >= out_cap) len = out_cap - 1;
  memcpy(out, p, len);
  out[len] = '\0';
  return 1;
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

/* ---- retired-layer persistence (part 5, D-LAYER) ---- */

/* Acceptance criterion: a layer survives pool eviction. Deliberately overflow
 * LE_POOL_SLOTS with overdub passes while armed (mirrors
 * test_undo_pool_eviction's exact technique — one continuous punch-in held
 * across many passes, LOOP_N frames each, polled between passes) and confirm
 * every one of them was persisted to its own file with the fed content,
 * regardless of how many their in-memory undo_stack slot was evicted from. */
static void test_perf_layer_persists_through_pool_eviction(void) {
  printf("test_perf_layer_persists_through_pool_eviction\n");
  le_engine* e = make_configured_engine();
  float out[64];

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch in, hold across many passes */
  const int passes = LE_POOL_SLOTS + 10;
  le_snapshot poll;
  for (int pass = 0; pass < passes; ++pass) {
    process_const(e, 0.5f, LOOP_N, out);
    /* The poll tick: le_engine_get_snapshot drains evt_ring (unlike drain(e),
     * which only pumps the command ring) — this is what actually calls
     * le_handle_retired / stages each retire while armed, matching
     * test_undo_pool_eviction's exact per-pass technique. */
    le_engine_get_snapshot(e, &poll);
  }
  le_engine_record(e, 0); /* punch out */
  drain(e);
  settle_dub(e);

  CHECK(atomic_load_explicit(&e->a_perf_layer_overruns, memory_order_relaxed) ==
        0u);

  CHECK(le_perf_disarm(e) == LE_OK); /* blocks: final flush + join */

  char sidecar_path[600];
  snprintf(sidecar_path, sizeof(sidecar_path), "%s/performance.json",
          perf_test_dir());
  static char json[262144];
  CHECK(read_file_for_test(sidecar_path, json, sizeof(json)) > 0);

  const int layer_count = count_layer_entries_for_test(json);
  /* Every pass retires exactly one layer (dub_len == LOOP_N, one pass per
   * call) — pool eviction only affects the in-memory undo_stack, never
   * whether a layer got staged in the first place. */
  CHECK(layer_count == passes);

  /* Spot-check the first and last persisted layers' content. Undo layers are
   * backup-ON-WRITE snapshots of the PRE-pass content (what undo restores
   * you to), not the post-pass result — so the layer retiring after pass i
   * (0-indexed) holds 1.0 + 0.5*i: the first pass's retiring layer is just
   * the recorded base (1.0), and the last pass's is one step behind the
   * final `top` test_undo_pool_eviction computes. */
  char filename[64];
  CHECK(nth_layer_filename_for_test(json, 0, filename, sizeof(filename)));
  char path[700];
  snprintf(path, sizeof(path), "%s/%s", perf_test_dir(), filename);
  FILE* f = fopen(path, "rb");
  CHECK(f != NULL);
  if (f != NULL) {
    float pcm[LOOP_N];
    CHECK(fread(pcm, sizeof(float), LOOP_N, f) == LOOP_N);
    fclose(f);
    for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - 1.0f) < 1e-6f);
  }

  CHECK(nth_layer_filename_for_test(json, passes - 1, filename,
                                    sizeof(filename)));
  snprintf(path, sizeof(path), "%s/%s", perf_test_dir(), filename);
  f = fopen(path, "rb");
  CHECK(f != NULL);
  if (f != NULL) {
    float pcm[LOOP_N];
    CHECK(fread(pcm, sizeof(float), LOOP_N, f) == LOOP_N);
    fclose(f);
    const float want = 1.0f + 0.5f * (float)(passes - 1);
    for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - want) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* Acceptance criterion: clearing a track mid-overdub while armed loses no
 * already-retired layer. Two full passes retire two layers, then a third
 * pass is left mid-flight (never reaches dub_len) when clear fires — the two
 * completed layers must still be on disk with correct content, and the clear
 * itself must still succeed cleanly. */
static void test_perf_layer_persists_through_clear_during_dub(void) {
  printf("test_perf_layer_persists_through_clear_during_dub\n");
  le_engine* e = make_configured_engine();
  float out[64];

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch in */
  /* Undo layers back up the PRE-pass content: pass 1's retiring layer holds
   * the base (1.0), pass 2's holds 1.5 (post-pass-1). Uses drain(e), not
   * le_engine_get_snapshot: it does not itself reach le_engine_drain_events,
   * so both passes' retire events actually stage together, in the same
   * sweep, inside le_engine_clear's own leading drain call below — this
   * test doubles as (incidental) burst coverage for the unconditional-
   * staging-before-generation-check ordering in le_handle_retired. */
  process_const(e, 0.5f, LOOP_N, out); /* pass 1: retiring layer holds 1.0 */
  drain(e);
  process_const(e, 0.5f, LOOP_N, out); /* pass 2: retiring layer holds 1.5 */
  drain(e);
  /* Pass 3, left mid-flight: less than a full dub_len, never retires. */
  process_const(e, 0.5f, LOOP_N / 2, out);

  CHECK(le_engine_clear(e, 0) == LE_OK);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);

  /* The engine stays usable after the clear. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, 0.25f, LOOP_N, out);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);

  CHECK(le_perf_disarm(e) == LE_OK);

  char sidecar_path[600];
  snprintf(sidecar_path, sizeof(sidecar_path), "%s/performance.json",
          perf_test_dir());
  static char json[262144];
  CHECK(read_file_for_test(sidecar_path, json, sizeof(json)) > 0);

  /* Both completed passes persisted; the mid-flight third never retired, so
   * it contributes nothing (correctly — there was no complete layer to
   * lose). */
  CHECK(count_layer_entries_for_test(json) == 2);

  char filename[64];
  CHECK(nth_layer_filename_for_test(json, 0, filename, sizeof(filename)));
  char path[700];
  snprintf(path, sizeof(path), "%s/%s", perf_test_dir(), filename);
  FILE* f = fopen(path, "rb");
  CHECK(f != NULL);
  if (f != NULL) {
    float pcm[LOOP_N];
    CHECK(fread(pcm, sizeof(float), LOOP_N, f) == LOOP_N);
    fclose(f);
    for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - 1.0f) < 1e-6f);
  }

  CHECK(nth_layer_filename_for_test(json, 1, filename, sizeof(filename)));
  snprintf(path, sizeof(path), "%s/%s", perf_test_dir(), filename);
  f = fopen(path, "rb");
  CHECK(f != NULL);
  if (f != NULL) {
    float pcm[LOOP_N];
    CHECK(fread(pcm, sizeof(float), LOOP_N, f) == LOOP_N);
    fclose(f);
    for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - 1.5f) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* Acceptance criterion: undo -> new overdub while armed persists the
 * invalidated redo layer before its slot is reclaimed. A completed pass
 * retires (and is staged), then undo pushes it onto the redo stack, then a
 * fresh punch-in invalidates that redo stack (le_begin_punch_in's
 * le_clear_redo) — the layer's file must still exist and be correct even
 * though its in-memory redo_stack reference was just discarded. */
static void test_perf_layer_persists_through_redo_invalidation(void) {
  printf("test_perf_layer_persists_through_redo_invalidation\n");
  le_engine* e = make_configured_engine();
  float out[64];

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch in */
  process_const(e, 0.5f, LOOP_N, out); /* one pass: retiring layer holds 1.0 */
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch out */
  drain(e);
  process_const(e, 0.0f, LOOP_N, out); /* settle the punch envelope */
  drain(e);

  le_snapshot s;
  for (int i = 0; i < 64; ++i) {
    le_engine_get_snapshot(e, &s);
    if (s.tracks[0].undo_depth > 0) break;
    drain(e);
  }
  CHECK(s.tracks[0].undo_depth > 0);

  CHECK(le_engine_undo(e, 0) == LE_OK); /* the layer moves to the redo stack */
  drain(e);

  /* A fresh punch-in invalidates the redo stack that layer was sitting on. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, 0.25f, LOOP_N, out);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);

  CHECK(le_perf_disarm(e) == LE_OK);

  char sidecar_path[600];
  snprintf(sidecar_path, sizeof(sidecar_path), "%s/performance.json",
          perf_test_dir());
  static char json[262144];
  CHECK(read_file_for_test(sidecar_path, json, sizeof(json)) > 0);

  /* The undone layer and the fresh punch-in's completed pass both persisted,
   * in retire order — both retiring layers hold 1.0 (the pre-pass base):
   * the undo restored the track to exactly the same content the fresh
   * punch-in then dubbed over again. */
  CHECK(count_layer_entries_for_test(json) == 2);

  char filename[64];
  CHECK(nth_layer_filename_for_test(json, 0, filename, sizeof(filename)));
  char path[700];
  snprintf(path, sizeof(path), "%s/%s", perf_test_dir(), filename);
  FILE* f = fopen(path, "rb");
  CHECK(f != NULL);
  if (f != NULL) {
    float pcm[LOOP_N];
    CHECK(fread(pcm, sizeof(float), LOOP_N, f) == LOOP_N);
    fclose(f);
    for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - 1.0f) < 1e-6f);
  }

  CHECK(nth_layer_filename_for_test(json, 1, filename, sizeof(filename)));
  snprintf(path, sizeof(path), "%s/%s", perf_test_dir(), filename);
  f = fopen(path, "rb");
  CHECK(f != NULL);
  if (f != NULL) {
    float pcm[LOOP_N];
    CHECK(fread(pcm, sizeof(float), LOOP_N, f) == LOOP_N);
    fclose(f);
    for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - 1.0f) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* Acceptance criterion: staging hand-off ordering — a layer is never reported
 * persisted (in the sidecar manifest) before its file is actually flushed;
 * a drain-thread write failure marks the sidecar (disk_full) rather than
 * crashing. Forces every write to fail (the same test hook part 2 uses),
 * drives one retire while armed, and confirms the failing layer never
 * appears in the manifest even though its file was created. */
static void test_perf_layer_hand_off_ordering_on_write_failure(void) {
  printf("test_perf_layer_hand_off_ordering_on_write_failure\n");
  le_engine* e = make_configured_engine();
  float out[64];

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch in */

  le_perf_drain_force_write_failure_for_test(1);

  process_const(e, 0.5f, LOOP_N, out); /* a layer retires and is staged */
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch out */
  drain(e);

  /* Poll rather than a fixed sleep — needs the drain thread's OWN background
   * cycle to observe the forced failure (matches part 2's disk-full test). */
  const int stopped = poll_drain_self_stopped_for_test(e->perf.drain, 2000);
  le_perf_drain_force_write_failure_for_test(0); /* reset before other tests */
  CHECK(stopped);

  char sidecar_path[600];
  snprintf(sidecar_path, sizeof(sidecar_path), "%s/performance.json",
          perf_test_dir());
  static char json[262144];
  CHECK(read_file_for_test(sidecar_path, json, sizeof(json)) > 0);
  CHECK(strstr(json, "\"stopped_early\": \"disk_full\"") != NULL);
  /* Never reported: the write failed, so le_pd_write_staged_layer never
   * reached the point where it records a manifest entry. */
  CHECK(count_layer_entries_for_test(json) == 0);

  le_perf_disarm(e);
  le_engine_destroy(e);
}

/* Acceptance criterion: not armed -> zero behavior change. Every existing
 * undo/redo/clear/pool-eviction test already exercises this path untouched
 * (the broader regression proof), but this pins the part-5-specific
 * invariant directly: an overdub pass retiring with performance capture
 * NEVER armed must not touch the staging ring or its overrun counter at
 * all. */
static void test_perf_layer_no_staging_when_unarmed(void) {
  printf("test_perf_layer_no_staging_when_unarmed\n");
  le_engine* e = make_configured_engine();
  float out[64];

  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch in */
  process_const(e, 0.5f, LOOP_N, out);    /* one pass retires, unarmed */
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch out */
  drain(e);
  settle_dub(e);

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 1); /* the retire itself still worked */
  CHECK(atomic_load_explicit(&e->a_perf_layer_overruns, memory_order_relaxed) ==
        0u);

  le_staged_layer entry;
  CHECK(le_layer_staging_ring_pop(&e->perf.layer_staging_ring, &entry) == 0);

  le_engine_destroy(e);
}

/* Direct ring-level test (no engine, no threads): proves the ring's own
 * full/pop bookkeeping holds at exactly the capacity this engine configures
 * it with (LE_MAX_TRACKS * LE_POOL_SLOTS — the multi-track worst case, see
 * engine_private.h). le_stage_retired_layer's own overrun handling (freeing
 * the copied PCM and incrementing a_perf_layer_overruns on a failed push) is
 * covered by test_perf_layer_no_staging_when_unarmed's sibling arm-time
 * paths; this test isolates the ring primitive itself. */
static void test_layer_staging_ring_overflow_returns_zero(void) {
  printf("test_layer_staging_ring_overflow_returns_zero\n");
  static le_staged_layer storage[LE_LAYER_STAGING_RING_CAPACITY];
  le_layer_staging_ring ring;
  CHECK(le_layer_staging_ring_init(&ring, storage,
                                   LE_LAYER_STAGING_RING_CAPACITY) == 1);

  le_staged_layer entry = {0}; /* lane_count 0: no heap buffers to leak here */

  int pushed = 0;
  for (uint32_t i = 0; i < LE_LAYER_STAGING_RING_CAPACITY; ++i) {
    entry.slot = (int32_t)i;
    if (!le_layer_staging_ring_push(&ring, entry)) break;
    ++pushed;
  }
  CHECK(pushed == (int)LE_LAYER_STAGING_RING_CAPACITY - 1); /* one slot reserved */
  CHECK(le_layer_staging_ring_push(&ring, entry) == 0);     /* still full */

  le_staged_layer out;
  CHECK(le_layer_staging_ring_pop(&ring, &out) == 1);
  CHECK(out.slot == 0);                                 /* FIFO order held */
  CHECK(le_layer_staging_ring_push(&ring, entry) == 1); /* freed slot reusable */
  ++pushed; /* that push added one more entry beyond the initial fill */

  int popped = 1; /* the explicit pop above */
  while (le_layer_staging_ring_pop(&ring, &out)) ++popped;
  CHECK(popped == pushed);
}

/* Acceptance edge case: two retires landing in the SAME le_engine_drain_events
 * sweep (a burst — no poll between the two passes) exercises
 * le_stage_retired_layer's unconditional-staging-before-generation-check
 * ordering differently than the one-retire-per-poll pattern every other test
 * in this cluster uses. Both must still be staged and persisted, in FIFO
 * order, with nothing skipped or reordered. */
static void test_perf_layer_persists_burst_of_two_in_one_drain(void) {
  printf("test_perf_layer_persists_burst_of_two_in_one_drain\n");
  le_engine* e = make_configured_engine();
  float out[64];

  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  record_base_loop(e, 1.0f);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch in */
  /* Two full passes back to back with no poll in between: both retire
   * events sit in evt_ring until the single le_engine_get_snapshot below
   * drains them together. */
  process_const(e, 0.5f, LOOP_N, out);
  process_const(e, 0.5f, LOOP_N, out);
  le_snapshot poll;
  le_engine_get_snapshot(e, &poll); /* one sweep, two retires */
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch out */
  drain(e);
  settle_dub(e);

  CHECK(atomic_load_explicit(&e->a_perf_layer_overruns, memory_order_relaxed) ==
        0u);

  CHECK(le_perf_disarm(e) == LE_OK);

  char sidecar_path[600];
  snprintf(sidecar_path, sizeof(sidecar_path), "%s/performance.json",
          perf_test_dir());
  static char json[262144];
  CHECK(read_file_for_test(sidecar_path, json, sizeof(json)) > 0);

  CHECK(count_layer_entries_for_test(json) == 2);

  char filename[64];
  CHECK(nth_layer_filename_for_test(json, 0, filename, sizeof(filename)));
  char path[700];
  snprintf(path, sizeof(path), "%s/%s", perf_test_dir(), filename);
  FILE* f = fopen(path, "rb");
  CHECK(f != NULL);
  if (f != NULL) {
    float pcm[LOOP_N];
    CHECK(fread(pcm, sizeof(float), LOOP_N, f) == LOOP_N);
    fclose(f);
    for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - 1.0f) < 1e-6f);
  }

  CHECK(nth_layer_filename_for_test(json, 1, filename, sizeof(filename)));
  snprintf(path, sizeof(path), "%s/%s", perf_test_dir(), filename);
  f = fopen(path, "rb");
  CHECK(f != NULL);
  if (f != NULL) {
    float pcm[LOOP_N];
    CHECK(fread(pcm, sizeof(float), LOOP_N, f) == LOOP_N);
    fclose(f);
    for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - 1.5f) < 1e-6f);
  }

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

/* The first wrap of a defining loop that runs STRAIGHT into overdub (rec/dub on)
 * is its own undo layer, not merged into the base: a shadow slot pre-armed
 * during RECORDING backs the first overdub pass on write, so undo peels that
 * pass and restores the base recording bit-exact. (Before this, the first pass
 * went un-backed and folded into the base — undo jumped straight to empty.) */
static void test_rec_dub_first_wrap_is_undoable_layer(void) {
  printf("test_rec_dub_first_wrap_is_undoable_layer\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  CHECK(le_engine_set_rec_dub(e, 1) == LE_OK);
  drain(e);

  le_engine_record(e, 0);              /* defining capture pre-arms a shadow */
  process_const(e, 1.0f, LOOP_N, out); /* base loop = 1.0 */
  le_engine_record(e, 0);              /* record press finalizes -> OVERDUBBING */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);

  process_const(e, 0.5f, LOOP_N, out); /* the first wrap's overdub pass: +0.5 */
  le_engine_record(e, 0);              /* punch out -> PLAYING */
  drain(e);
  settle_dub(e);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].undo_depth == 1); /* the first wrap IS an undoable layer */
  check_content(e, 1.5f);             /* base + first wrap */

  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 1.0f); /* undo restores the base recording, not empty */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 0);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);

  le_engine_destroy(e);
}

/* The other straight-into-overdub path: a non-defining track that auto-finalizes
 * into overdub (fixed multiple, rec/dub off) likewise captures its first wrap as
 * its own undo layer. */
static void test_new_track_first_wrap_is_undoable_layer(void) {
  printf("test_new_track_first_wrap_is_undoable_layer\n");
  le_engine* e = make_configured_engine(); /* rec/dub off */
  float out[64];
  le_snapshot s;
  float pcm[LOOP_N];

  /* tr0 defines the master, to PLAYING. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);

  /* tr1: one base loop, auto-finalizes into overdub with no second press. */
  le_engine_set_track_multiple(e, 1, 1);
  le_engine_record(e, 1);              /* non-defining capture pre-arms a shadow */
  drain(e);
  process_const(e, 2.0f, LOOP_N, out); /* one base loop -> auto-finish into overdub */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_OVERDUBBING);

  process_const(e, 0.5f, LOOP_N, out); /* tr1's first wrap overdub pass: +0.5 */
  le_engine_stop_track(e, 1);          /* punch out -> STOPPED */
  drain(e);
  settle_dub(e);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].undo_depth == 1); /* the first wrap IS an undoable layer */
  CHECK(le_engine_export_track(e, 1, pcm, LOOP_N) == LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - 2.5f) < 1e-6f);

  CHECK(le_engine_undo(e, 1) == LE_OK);
  CHECK(le_engine_export_track(e, 1, pcm, LOOP_N) == LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(pcm[i] - 2.0f) < 1e-6f); /* base */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].undo_depth == 0);

  le_engine_destroy(e);
}

/* The first wrap's layer keeps the loop-length quantization every other layer
 * gets. Its shadow is pre-armed while the loop is still being recorded, so it
 * must be allocated at the full recording cap (the length is unknown then) —
 * le_handle_retired shrinks it back once the pass retires and the length is
 * known, preserving the captured audio. Without that, one cap-sized buffer per
 * lane (up to minutes of floats) would stay pinned for the session. */
static void test_first_wrap_layer_shrinks_to_quantum(void) {
  printf("test_first_wrap_layer_shrinks_to_quantum\n");
  le_engine* e = le_engine_create();
  const int32_t cap = 200000; /* > LE_LAYER_QUANTUM so sizes are observable */
  le_engine_configure(e, 48000, 1, 1, cap);
  float out[64];
  le_snapshot s;

  CHECK(le_engine_set_rec_dub(e, 1) == LE_OK);
  drain(e);

  le_engine_record(e, 0);              /* pre-arms a CAP-sized shadow */
  process_const(e, 1.0f, LOOP_N, out); /* tiny base loop = 1.0 */
  le_engine_record(e, 0);              /* finalize -> OVERDUBBING */
  drain(e);
  process_const(e, 0.5f, LOOP_N, out); /* the first wrap's pass */
  le_engine_record(e, 0);              /* punch out */
  drain(e);
  settle_dub(e);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 1);
  check_content(e, 1.5f);

  /* Undo swaps the first wrap's layer live: its audio survived the shrink, and
   * the slot costs one quantum — not the recording cap it was armed at. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  check_content(e, 1.0f);
  CHECK(le_engine_lane_slot_cap_for_test(e, 0, 0, -1) == LE_LAYER_QUANTUM);

  le_engine_destroy(e);
}

/* Counts lane 0's pool slots allocated at exactly `cap` frames, excluding the
 * live slot (a recording target is legitimately cap-sized). What remains is
 * pre-armed/leftover shadow memory — the footprint the first-wrap feature must
 * keep bounded. */
static int count_cap_sized_nonlive_slots(le_engine* e, int32_t cap) {
  const int32_t live = load_i32(&e->tracks[0].lanes[0].a_live);
  int n = 0;
  for (int32_t s = 0; s < LE_POOL_SLOTS; ++s) {
    if (s == live) continue;
    if (le_engine_lane_slot_cap_for_test(e, 0, 0, s) == cap) n++;
  }
  return n;
}

/* The pre-arm's memory footprint stays bounded: ONE cap-sized slot while a
 * gated capture records (the first wrap's shadow — its spare arrives quantized
 * after finalize), and NONE once that first wrap's layer retires (the shrink
 * right-sizes it). A capture that stops without ever layering keeps exactly the
 * one pre-armed slot, reclaimed on the track's next capture/clear. */
static void test_first_wrap_prearm_footprint_bounded(void) {
  printf("test_first_wrap_prearm_footprint_bounded\n");
  le_engine* e = le_engine_create();
  const int32_t cap = 200000; /* > LE_LAYER_QUANTUM so cap-sized is visible */
  le_engine_configure(e, 48000, 1, 1, cap);
  float out[64];
  le_snapshot s;

  CHECK(le_engine_set_rec_dub(e, 1) == LE_OK);
  drain(e);

  /* Flow A: record -> overdub one pass -> punch out. The pre-armed slot is
   * consumed by the first wrap and shrunk at retire; the spare posted after
   * finalize is quantized. Nothing cap-sized may remain besides live. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  /* Mid-capture: exactly the one pre-armed cap slot (live excluded). */
  CHECK(count_cap_sized_nonlive_slots(e, cap) == 1);
  le_engine_record(e, 0); /* finalize -> OVERDUBBING */
  drain(e);
  le_engine_get_snapshot(e, &s); /* poll: posts the quantized spare */
  process_const(e, 0.5f, LOOP_N, out);
  le_engine_record(e, 0); /* punch out */
  drain(e);
  settle_dub(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 1);
  CHECK(count_cap_sized_nonlive_slots(e, cap) == 0);
  le_engine_destroy(e);

  /* Flow B: record then STOP, never layering. The single pre-armed slot is the
   * irreducible residual (whether the user will layer is unknowable at record
   * time). The SLOT returns to the pool on the track's next capture start or
   * clear; its buffer stays allocated until some later use regrows or shrinks
   * it — the pool is grow-only by design, same as every other slot. */
  le_engine* e2 = le_engine_create();
  le_engine_configure(e2, 48000, 1, 1, cap);
  le_engine_set_rec_dub(e2, 1);
  drain(e2);
  le_engine_record(e2, 0);
  process_const(e2, 1.0f, LOOP_N, out);
  le_engine_stop_track(e2, 0);
  drain(e2);
  process_const(e2, 0.0f, LOOP_N, out);
  CHECK(count_cap_sized_nonlive_slots(e2, cap) == 1);
  le_engine_destroy(e2);

  /* Flow C: the DEFINING capture of a fresh take must not pre-arm even when a
   * ghost master survives an undo-to-empty (rec/dub off, fixed multiple). The
   * record press pushes an internal grid-redefine CLEAR ahead of itself; the
   * gate must trust the caller's corrected has_master, not the a_master_len
   * atomic, which stays stale until the audio thread applies that CLEAR. */
  le_engine* e3 = le_engine_create();
  le_engine_configure(e3, 48000, 1, 1, cap);
  le_engine_set_default_multiple(e3, 2); /* fixed multiple, rec/dub off */
  drain(e3);
  le_engine_record(e3, 0);
  process_const(e3, 1.0f, LOOP_N, out);
  le_engine_record(e3, 0); /* master defined -> PLAYING */
  drain(e3);
  CHECK(le_engine_undo(e3, 0) == LE_OK); /* undo to empty; master kept */
  drain(e3);
  le_engine_record(e3, 0); /* fresh take: internal CLEAR + defining RECORD */
  CHECK(count_cap_sized_nonlive_slots(e3, cap) == 0); /* no stale pre-arm */
  drain(e3);
  le_engine_get_snapshot(e3, &s); /* poll during RECORDING: still none */
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING);
  CHECK(count_cap_sized_nonlive_slots(e3, cap) == 0);
  le_engine_destroy(e3);
}

/* Long-loop (> LE_LAYER_QUANTUM) rec/dub flow, content-exact: the defining
 * finalize takes the seam-crossfade deferral and still runs straight into
 * overdub with the pre-armed shadow, and undo restores the base bit-exact.
 * Positions near the loop top are excluded from the equality checks — the seam
 * crossfade, the finalize->overdub handover, and the punch fade all legitimately
 * shape the first ~2000 frames; the body of the loop must be exact. */
static void test_rec_dub_long_loop_first_wrap_undo(void) {
  printf("test_rec_dub_long_loop_first_wrap_undo\n");
  le_engine* e = le_engine_create();
  const int32_t cap = 400000;
  le_engine_configure(e, 48000, 1, 1, cap);
  le_snapshot s;

  CHECK(le_engine_set_rec_dub(e, 1) == LE_OK);
  drain(e);

  const int32_t len = LE_LAYER_QUANTUM + 2000; /* > one quantum */
  le_engine_record(e, 0);
  pump_frames(e, 1.0f, len);
  le_engine_record(e, 0); /* finalize (deferred for the seam crossfade) */
  drain(e);
  pump_frames(e, 1.0f, 600); /* crossfade overlap -> finalize -> OVERDUBBING */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);
  CHECK(s.tracks[0].length_frames == len);

  pump_frames(e, 0.5f, len); /* the first wrap's pass */
  le_engine_record(e, 0);    /* punch out */
  drain(e);
  pump_frames(e, 0.0f, 600); /* punch fade tail decays */
  settle_layers(e);
  drain(e);

  float* pcm = (float*)malloc((size_t)len * sizeof(float));
  CHECK(pcm != NULL);
  const int32_t body = 2000; /* first frames shaped by seam/handover/fade */

  CHECK(le_engine_export_track(e, 0, pcm, len) == len);
  for (int32_t i = body; i < len; ++i) CHECK(fabsf(pcm[i] - 1.5f) < 1e-6f);

  /* Peel every layer (the punch fade may commit a tail sliver as a second
   * layer at this loop size): the body must return to the base exactly. */
  le_engine_get_snapshot(e, &s);
  const int32_t depth = s.tracks[0].undo_depth;
  CHECK(depth >= 1);
  for (int32_t k = 0; k < depth; ++k) CHECK(le_engine_undo(e, 0) == LE_OK);
  CHECK(le_engine_export_track(e, 0, pcm, len) == len);
  for (int32_t i = body; i < len; ++i) CHECK(fabsf(pcm[i] - 1.0f) < 1e-6f);

  free(pcm);
  le_engine_destroy(e);
}

/* A capture started from a DEFERRED arm (sound-triggered here; quantize takes
 * the same path) is pre-armed by the RECORDING branch of le_engine_drain_events,
 * which polls while the track is mid-capture — when a_len reads as the GROWING
 * record position, not the final loop length. The shadow must still be sized for
 * the WHOLE loop: this loop is deliberately longer than LE_LAYER_QUANTUM, so
 * sizing it to the partial length would leave the first wrap's backup-on-write
 * running past the end of the buffer (an audio-thread heap overflow). Every
 * other loop in this suite is under one quantum, which hides that. */
static void test_deferred_arm_first_wrap_shadow_fits_loop(void) {
  printf("test_deferred_arm_first_wrap_shadow_fits_loop\n");
  le_engine* e = le_engine_create();
  const int32_t cap = 400000;
  le_engine_configure(e, 48000, 1, 1, cap);
  float out[64];
  le_snapshot s;

  CHECK(le_engine_set_rec_dub(e, 1) == LE_OK);
  CHECK(le_engine_set_auto_record(e, 1) == LE_OK);
  drain(e);
  CHECK(le_engine_record(e, 0) == LE_OK); /* deferred arm: no immediate pre-arm */
  drain(e);

  /* Signal fires the arm and the capture runs past one quantum. Poll every
   * block, exactly as the UI does — that is what posts the pre-armed shadow,
   * mid-capture, off a partial a_len. */
  const int32_t len = LE_LAYER_QUANTUM + 4000;
  for (int32_t done = 0; done < len; done += 64) {
    process_const(e, 1.0f, 64, out);
    le_engine_get_snapshot(e, &s); /* drains -> RECORDING pre-arm posts here */
  }
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING);

  le_engine_record(e, 0); /* finalize -> OVERDUBBING (rec/dub) */
  drain(e);
  pump_frames(e, 1.0f, 600); /* seam-crossfade overlap -> finalize completes */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);
  const int32_t loop = s.tracks[0].length_frames;
  CHECK(loop > LE_LAYER_QUANTUM); /* the whole point: > one quantum */

  /* The first wrap's pass: backup-on-write covers the FULL loop. */
  pump_frames(e, 0.5f, loop);
  le_engine_record(e, 0); /* punch out */
  drain(e);
  settle_layers(e);
  drain(e);

  le_engine_get_snapshot(e, &s);
  /* The first wrap's pass, plus a punch-tail sliver at this loop size (the
   * punch fade is engaged) — see test_undo_layer_slot_regrows_for_longer_loop. */
  const int32_t depth = s.tracks[0].undo_depth;
  CHECK(depth >= 1);
  /* Peel every layer: each one's buffer must cover the WHOLE loop. Sized off the
   * partial length the mid-capture pre-arm saw, the first wrap's would be one
   * quantum — short of `loop`, i.e. the pass wrote past its end. */
  for (int32_t k = 0; k < depth; ++k) {
    CHECK(le_engine_undo(e, 0) == LE_OK);
    CHECK(le_engine_lane_slot_cap_for_test(e, 0, 0, -1) >= loop);
  }
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 0);

  le_engine_destroy(e);
}

/* ---- click + count-in (A2: routable click bus, 4-value mode, count-in) ----
 *
 * Audio-carrying tests run at sr 48000 — at the tg tests' sr 1000 a 1000 Hz
 * click aliases to DC and synthesizes near-silence. 300 BPM gives exactly
 * 9600 frames per beat, 38400 per 4/4 bar. State-machine-only tests reuse the
 * cheap sr-1000 grid (120 BPM -> 500 frames per beat). This section sits
 * below the perf-capture helpers because the capture-exclusion test drives
 * le_perf_arm / le_perf_disarm through perf_test_dir(). */

#define CK_SR 48000
#define CK_FPB 9600          /* frames per beat at 300 BPM, sr 48000 */
#define CK_BAR (4 * CK_FPB)  /* one 4/4 bar */
#define CK_CLICK_FRAMES 1440 /* the 30 ms click burst at sr 48000 */

static le_engine* ck_make_engine(int out_ch) {
  le_engine* e = le_engine_create();
  le_engine_configure(e, CK_SR, 1, out_ch, CK_SR * 4);
  return e;
}

/* Processes `frames` frames of silence in <=64-frame blocks, accumulating
 * per-channel output energy (sum of squares) and peak into the caller's
 * arrays (either may be NULL to skip). */
static void ck_run(le_engine* e, int frames, int ch_out, double* energy,
                   float* peak) {
  float in[64] = {0};
  float out[64 * 8];
  while (frames > 0) {
    const int n = frames > 64 ? 64 : frames;
    le_engine_process(e, out, in, (uint32_t)n);
    if (energy != NULL || peak != NULL) {
      for (int f = 0; f < n; ++f) {
        for (int c = 0; c < ch_out; ++c) {
          const float s = out[f * ch_out + c];
          if (energy != NULL) energy[c] += (double)s * (double)s;
          if (peak != NULL && fabsf(s) > peak[c]) peak[c] = fabsf(s);
        }
      }
    }
    frames -= n;
  }
}

/* Processes `frames` frames of silence and returns the sign-flip count on
 * output channel `ch` — a cheap spectral proxy: over the 30 ms burst a
 * 1500 Hz downbeat click flips ~90 times, a 1000 Hz beat click ~60. */
static int ck_crossings(le_engine* e, int frames, int ch_out, int ch) {
  float in[64] = {0};
  float out[64 * 8];
  int crossings = 0;
  float prev = 0.0f;
  while (frames > 0) {
    const int n = frames > 64 ? 64 : frames;
    le_engine_process(e, out, in, (uint32_t)n);
    for (int f = 0; f < n; ++f) {
      const float s = out[f * ch_out + ch];
      if (s != 0.0f) {
        if (prev != 0.0f && (prev < 0.0f) != (s < 0.0f)) crossings++;
        prev = s;
      }
    }
    frames -= n;
  }
  return crossings;
}

static void test_click_defaults_and_validation(void) {
  printf("test_click_defaults_and_validation\n");
  le_engine* e = ck_make_engine(2);
  le_snapshot s;

  /* Click-off defaults: mode off, mask 0 (unrouted), volume unity, count-in
   * 0 bars, no counting state. */
  le_engine_get_snapshot(e, &s);
  CHECK(s.click_mode == LE_CLICK_OFF);
  CHECK(s.click_mask == 0u);
  CHECK(fabsf(s.click_volume - 1.0f) < 1e-6f);
  CHECK(s.count_in_bars == 0);
  CHECK(s.counting_in == 0);
  CHECK(s.count_in_beats_left == 0);

  /* Wrapper validation. */
  CHECK(le_engine_set_click_mode(e, -1) == LE_ERR_INVALID);
  CHECK(le_engine_set_click_mode(e, 4) == LE_ERR_INVALID);
  CHECK(le_engine_set_count_in(e, -1) == LE_ERR_INVALID);
  CHECK(le_engine_set_count_in(e, LE_COUNT_IN_MAX_BARS + 1) ==
        LE_ERR_INVALID);
  CHECK(le_engine_set_count_in(NULL, 1) == LE_ERR_INVALID);

  /* Settings publish, the volume clamps to LE_MAX_GAIN on apply, and all of
   * it persists across a reconfigure (create-seeded, like the tempo
   * settings) while the counting state stays transient. */
  CHECK(le_engine_set_click_mode(e, LE_CLICK_PLAY_REC) == LE_OK);
  CHECK(le_engine_set_click_output(e, 0x2) == LE_OK);
  CHECK(le_engine_set_click_volume(e, 5.0f) == LE_OK);
  CHECK(le_engine_set_count_in(e, 2) == LE_OK);
  ck_run(e, 1, 2, NULL, NULL);
  le_engine_get_snapshot(e, &s);
  CHECK(s.click_mode == LE_CLICK_PLAY_REC);
  CHECK(s.click_mask == 0x2u);
  CHECK(fabsf(s.click_volume - LE_MAX_GAIN) < 1e-6f);
  CHECK(s.count_in_bars == 2);
  le_engine_configure(e, CK_SR, 1, 2, CK_SR * 4);
  le_engine_get_snapshot(e, &s);
  CHECK(s.click_mode == LE_CLICK_PLAY_REC);
  CHECK(s.click_mask == 0x2u);
  CHECK(fabsf(s.click_volume - LE_MAX_GAIN) < 1e-6f);
  CHECK(s.count_in_bars == 2);
  CHECK(s.counting_in == 0);

  le_engine_destroy(e);
}

static void test_click_masked_channels_and_volume(void) {
  printf("test_click_masked_channels_and_volume\n");
  le_engine* e = ck_make_engine(2);
  double energy[2] = {0};
  float peak[2] = {0};

  CHECK(le_engine_set_tempo(e, 300.0f) == LE_OK);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_PLAY_REC) == LE_OK);
  CHECK(le_engine_set_click_output(e, 0x2) == LE_OK); /* channel 1 only */

  /* Idle transport: the gate is off — silence even with tempo + mask set. */
  ck_run(e, 2 * CK_FPB, 2, energy, peak);
  CHECK(energy[0] == 0.0);
  CHECK(energy[1] == 0.0);

  /* A defining recording engages the free-running click: energy on the
   * masked channel only; the unmasked channel stays EXACTLY zero. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  energy[0] = energy[1] = 0.0;
  ck_run(e, CK_FPB, 2, energy, peak);
  CHECK(energy[1] > 0.5);
  CHECK(energy[0] == 0.0);
  /* At unity click volume the burst peaks at ~LE_CLICK_AMP (0.25). */
  CHECK(peak[1] > 0.2f && peak[1] < 0.26f);
  CHECK(peak[0] == 0.0f);

  /* Click volume scales the voice: half volume, half peak. The run starts
   * exactly on the next beat boundary, so it covers one whole burst. */
  CHECK(le_engine_set_click_volume(e, 0.5f) == LE_OK);
  energy[1] = 0.0;
  peak[1] = 0.0f;
  ck_run(e, CK_FPB, 2, energy, peak);
  CHECK(energy[1] > 0.1);
  CHECK(peak[1] > 0.1f && peak[1] < 0.13f);

  le_engine_destroy(e);
}

static void test_click_bypasses_master_bus(void) {
  printf("test_click_bypasses_master_bus\n");
  le_engine* e = ck_make_engine(1);
  le_snapshot s;

  CHECK(le_engine_set_tempo(e, 300.0f) == LE_OK);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_PLAY_REC) == LE_OK);
  CHECK(le_engine_set_click_output(e, 0x1) == LE_OK);
  /* Master gain to ZERO: if the click ran through the master bus this would
   * silence it. It is summed after the bus by design (D5). */
  CHECK(le_engine_set_master_gain(e, 0.0f) == LE_OK);
  ck_run(e, 1, 1, NULL, NULL);

  CHECK(le_engine_record(e, 0) == LE_OK);
  double energy[1] = {0};
  float peak[1] = {0};
  ck_run(e, CK_FPB, 1, energy, peak);
  CHECK(energy[0] > 0.5);  /* audible despite master gain 0... */
  CHECK(peak[0] > 0.2f);   /* ...at full click level, uncut */
  /* ...and invisible to output metering, which is fed upstream of it. */
  le_engine_get_snapshot(e, &s);
  CHECK(s.output_rms == 0.0f);

  le_engine_destroy(e);
}

static void test_click_respects_output_enabled_gate(void) {
  printf("test_click_respects_output_enabled_gate\n");
  /* Code-review fix (MEDIUM): click_frame was called with the raw click
   * mask, never intersected with the structural output-enabled mask —
   * unlike every other source's fan-out (lanes: out_mask & out_enabled in
   * mix_tracks_frame; monitors: mon_out & out_enabled in
   * mix_monitors_frame). A structurally-disabled output must never carry
   * click energy even though the click's own routing mask still points at
   * it. */
  le_engine* e = ck_make_engine(2);
  double energy[2] = {0};

  CHECK(le_engine_set_tempo(e, 300.0f) == LE_OK);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_PLAY_REC) == LE_OK);
  CHECK(le_engine_set_click_output(e, 0x1) == LE_OK); /* channel 0 */
  CHECK(le_engine_set_output_enabled(e, 0, 0) == LE_OK); /* disable it */
  ck_run(e, 1, 2, NULL, NULL);

  CHECK(le_engine_record(e, 0) == LE_OK);
  ck_run(e, CK_BAR, 2, energy, NULL);
  CHECK(energy[0] == 0.0); /* disabled: silent despite the click mask */
  CHECK(energy[1] == 0.0); /* never routed to */

  le_engine_destroy(e);
}

static void test_click_mode_rec_semantics(void) {
  printf("test_click_mode_rec_semantics\n");
  le_engine* e = ck_make_engine(1);
  double energy[1] = {0};
  le_snapshot s;

  CHECK(le_engine_set_tempo(e, 300.0f) == LE_OK);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_REC) == LE_OK);
  CHECK(le_engine_set_click_output(e, 0x1) == LE_OK);

  /* Idle: silent. */
  ck_run(e, CK_FPB, 1, energy, NULL);
  CHECK(energy[0] == 0.0);

  /* Recording (the defining take): clicks. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  energy[0] = 0.0;
  ck_run(e, CK_BAR, 1, energy, NULL);
  CHECK(energy[0] > 0.5);

  /* Finalize (seam xfade defers CK_SR/100 frames), flush the last burst's
   * tail, then a full playing loop: REC is silent during plain playback. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  ck_run(e, CK_SR / 100 + CK_CLICK_FRAMES + 64, 1, NULL, NULL);
  energy[0] = 0.0;
  ck_run(e, CK_BAR, 1, energy, NULL);
  CHECK(energy[0] == 0.0);

  /* Punch-in overdub EXACTLY at the loop top (pos == 0, via the snapshot):
   * the gate rise fires the beat underway immediately, and — because pos==0
   * really is a beat boundary — it's the true bar downbeat, 1500 Hz
   * (grid_beat_frame's pos==0 special case; code-review fix). Verified by
   * frequency/timing (ck_crossings), not just energy>0 — a bare energy
   * check can't tell a correct downbeat from an off-grid click at an
   * arbitrary phase, which is exactly how the punch-in-mid-beat bug this
   * pins shipped unnoticed in the first place. A mid-beat punch (which must
   * NOT fire immediately) is covered separately by
   * test_click_punch_in_overdub_no_off_grid_click. */
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == CK_BAR);
  const int32_t to_top = (CK_BAR - s.master_position_frames) % CK_BAR;
  ck_run(e, to_top, 1, NULL, NULL);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == 0);

  CHECK(le_engine_record(e, 0) == LE_OK);
  const int down = ck_crossings(e, CK_CLICK_FRAMES, 1, 0);
  CHECK(down > 75 && down < 105); /* 1500 Hz downbeat, fired immediately */

  /* Punch-out: back to silence once the last burst decays. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  ck_run(e, CK_CLICK_FRAMES + 64, 1, NULL, NULL);
  energy[0] = 0.0;
  ck_run(e, CK_BAR, 1, energy, NULL);
  CHECK(energy[0] == 0.0);

  le_engine_destroy(e);
}

static void test_click_punch_in_overdub_no_off_grid_click(void) {
  printf("test_click_punch_in_overdub_no_off_grid_click\n");
  /* Code-review fix (HIGH): a punch-in overdub on an ALREADY-PLAYING loop
   * starts capturing at the current transport position, not a beat
   * boundary (handle_record's PLAYING/STOPPED branch). Under LE_CLICK_REC,
   * click_on flips 0->1 the instant the track becomes OVERDUBBING — before
   * the fix, grid_beat_frame's gate-rise handling fired a click immediately
   * at that arbitrary mid-beat phase instead of a real beat. This pins the
   * confirmed scenario (300 BPM, punch mid-beat-1): silence until the next
   * TRUE boundary, then a click exactly there — never at the punch frame
   * itself. */
  le_engine* e = ck_make_engine(1);
  le_snapshot s;

  CHECK(le_engine_set_tempo(e, 300.0f) == LE_OK);
  CHECK(le_engine_set_click_output(e, 0x1) == LE_OK);
  ck_run(e, 1, 1, NULL, NULL);

  /* Finalize a one-bar defining loop with the click off, so its own
   * free-running click doesn't interfere with positioning. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  ck_run(e, CK_BAR, 1, NULL, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  ck_run(e, CK_SR / 100 + 64, 1, NULL, NULL);

  /* REC mode: silent through plain playback (click_grid_gate stays 0 going
   * into the punch — this IS a genuine gate rise, not a coincidence). */
  CHECK(le_engine_set_click_mode(e, LE_CLICK_REC) == LE_OK);

  /* Align to exactly the middle of beat 1 (NOT beat 0, not near any
   * boundary) via the snapshot before punching in. */
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == CK_BAR);
  const int32_t target = CK_FPB + CK_FPB / 2; /* mid beat 1 */
  const int32_t to_target =
      ((target - s.master_position_frames) % CK_BAR + CK_BAR) % CK_BAR;
  ck_run(e, to_target, 1, NULL, NULL);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == target);

  /* Punch in mid-beat: the gate rises here. No click at the punch frame or
   * anywhere before the next real boundary (beat 2, at 2*CK_FPB — CK_FPB/2
   * frames away). */
  CHECK(le_engine_record(e, 0) == LE_OK);
  double energy[1] = {0};
  ck_run(e, CK_FPB / 2, 1, energy, NULL);
  CHECK(energy[0] == 0.0);

  /* The click picks up naturally at that true boundary — beat 2, a plain
   * beat: 1000 Hz, not the downbeat pitch and not an off-grid burst. */
  const int at_boundary = ck_crossings(e, CK_CLICK_FRAMES, 1, 0);
  CHECK(at_boundary > 45 && at_boundary < 75);

  le_engine_destroy(e);
}

static void test_click_mode_rec_first_semantics(void) {
  printf("test_click_mode_rec_first_semantics\n");
  le_engine* e = ck_make_engine(1);
  double energy[1] = {0};

  CHECK(le_engine_set_tempo(e, 300.0f) == LE_OK);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_REC_FIRST) == LE_OK);
  CHECK(le_engine_set_click_output(e, 0x1) == LE_OK);
  ck_run(e, 1, 1, NULL, NULL);

  /* The DEFINING first-layer recording clicks... */
  CHECK(le_engine_record(e, 0) == LE_OK);
  ck_run(e, CK_BAR, 1, energy, NULL);
  CHECK(energy[0] > 0.5);

  /* ...but once the loop exists, nothing does: not playback, and — unlike
   * REC — not an overdub either (it is not the first layer). */
  CHECK(le_engine_record(e, 0) == LE_OK);
  ck_run(e, CK_SR / 100 + CK_CLICK_FRAMES + 64, 1, NULL, NULL);
  energy[0] = 0.0;
  ck_run(e, CK_BAR, 1, energy, NULL);
  CHECK(energy[0] == 0.0);
  CHECK(le_engine_record(e, 0) == LE_OK); /* punch-in overdub */
  energy[0] = 0.0;
  ck_run(e, CK_BAR, 1, energy, NULL);
  CHECK(energy[0] == 0.0);

  le_engine_destroy(e);
}

static void test_click_mode_rec_first_second_track_silent(void) {
  printf("test_click_mode_rec_first_second_track_silent\n");
  /* Code-review fix (HIGH): le_click_gate's REC_FIRST guard —
   * `if (e->clock.length != 0) return 0;` — restricts the mode to the
   * DEFINING first-layer take only. A DIFFERENT track's own first take,
   * recorded fresh once a master already exists, is ALSO state RECORDING
   * but must stay silent under REC_FIRST; nothing exercised that distinction
   * before this test, so the guard could be inverted or deleted without any
   * test noticing. */
  le_engine* e = ck_make_engine(1);
  double energy[1] = {0};

  CHECK(le_engine_set_tempo(e, 300.0f) == LE_OK);
  CHECK(le_engine_set_click_output(e, 0x1) == LE_OK);
  ck_run(e, 1, 1, NULL, NULL);

  /* Finalize a defining track-0 loop first, with the click off so it can't
   * contribute any of the energy checked below. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  ck_run(e, CK_BAR, 1, NULL, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  ck_run(e, CK_SR / 100 + 64, 1, NULL, NULL);

  /* Track 1's OWN first take, now that a master already exists (clock.length
   * != 0): state RECORDING, but the guard says silent under REC_FIRST. */
  CHECK(le_engine_set_click_mode(e, LE_CLICK_REC_FIRST) == LE_OK);
  CHECK(le_engine_record(e, 1) == LE_OK);
  ck_run(e, CK_BAR, 1, energy, NULL);
  CHECK(energy[0] == 0.0);

  le_engine_destroy(e);
}

static void test_click_mode_play_rec_semantics(void) {
  printf("test_click_mode_play_rec_semantics\n");
  le_engine* e = ck_make_engine(1);
  double energy[1] = {0};

  CHECK(le_engine_set_tempo(e, 300.0f) == LE_OK);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_PLAY_REC) == LE_OK);
  CHECK(le_engine_set_click_output(e, 0x1) == LE_OK);
  ck_run(e, 1, 1, NULL, NULL);

  /* Record + finalize a one-bar loop; PLAY_REC keeps clicking through
   * playback (the loop-locked grid drives the beats). */
  CHECK(le_engine_record(e, 0) == LE_OK);
  ck_run(e, CK_BAR, 1, NULL, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  ck_run(e, CK_SR / 100, 1, NULL, NULL);
  ck_run(e, CK_BAR, 1, energy, NULL);
  CHECK(energy[0] > 0.5);

  /* Stopped: the transport is held — silence once the last burst decays. */
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  ck_run(e, CK_CLICK_FRAMES + 64, 1, NULL, NULL);
  energy[0] = 0.0;
  ck_run(e, CK_BAR, 1, energy, NULL);
  CHECK(energy[0] == 0.0);

  /* Resuming playback clicks the downbeat IMMEDIATELY (the gate rise re-arms
   * the loop-locked scheduler; the held transport resumes from the top). */
  CHECK(le_engine_play(e, 0) == LE_OK);
  energy[0] = 0.0;
  ck_run(e, CK_CLICK_FRAMES, 1, energy, NULL);
  CHECK(energy[0] > 0.5);

  le_engine_destroy(e);
}

static void test_click_mode_off_stays_silent(void) {
  printf("test_click_mode_off_stays_silent\n");
  le_engine* e = ck_make_engine(1);
  double energy[1] = {0};
  le_snapshot s;

  /* OFF (the default) with tempo + a mask set: still never audible during a
   * defining recording... */
  CHECK(le_engine_set_tempo(e, 300.0f) == LE_OK);
  CHECK(le_engine_set_click_output(e, 0x1) == LE_OK);
  le_engine_get_snapshot(e, &s);
  CHECK(s.click_mode == LE_CLICK_OFF);
  CHECK(le_engine_record(e, 0) == LE_OK);
  ck_run(e, CK_BAR, 1, energy, NULL);
  CHECK(energy[0] == 0.0);
  CHECK(le_engine_record(e, 0) == LE_OK); /* finalize */
  ck_run(e, CK_SR / 100 + CK_CLICK_FRAMES + 64, 1, NULL, NULL);

  /* ...nor through playback... */
  energy[0] = 0.0;
  ck_run(e, CK_BAR, 1, energy, NULL);
  CHECK(energy[0] == 0.0);

  le_engine_destroy(e);

  /* ...nor during a count-in: the manual's "OFF" means never audible, but the
   * count-in still runs (silently) and still lands the recording exactly on
   * the downbeat — D9's schedule is independent of whether anyone can hear
   * it count. */
  le_engine* e2 = ck_make_engine(1);
  CHECK(le_engine_set_tempo(e2, 300.0f) == LE_OK);
  CHECK(le_engine_set_click_output(e2, 0x1) == LE_OK);
  CHECK(le_engine_set_count_in(e2, 1) == LE_OK);
  double energy2[1] = {0};
  CHECK(le_engine_record(e2, 0) == LE_OK);
  ck_run(e2, 1, 1, energy2, NULL); /* drain the RECORD command */
  le_engine_get_snapshot(e2, &s);
  CHECK(s.counting_in == 1); /* the schedule still runs */
  ck_run(e2, CK_BAR - 2, 1, energy2, NULL);
  le_engine_get_snapshot(e2, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY); /* one frame short */
  CHECK(energy2[0] == 0.0);                   /* and silent throughout */
  ck_run(e2, 1, 1, energy2, NULL);            /* the downbeat frame */
  le_engine_get_snapshot(e2, &s);
  CHECK(s.counting_in == 0);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING); /* landed exactly on time */
  CHECK(energy2[0] == 0.0);

  le_engine_destroy(e2);
}

/* trigger_click's downbeat-vs-beat boolean (1500/1000 Hz) is computed
 * independently at THREE call sites: the count-in scheduler (click_frame),
 * the loop-locked scheduler (grid_beat_frame), and the free-running
 * scheduler (click_frame, no-master-yet / sync-off). Code-review fix
 * (MEDIUM): only the count-in site had a frequency assertion — flipping the
 * boolean at either of the other two would have passed all pre-existing
 * tests. The three tests below cover the three sites independently. */

static void test_click_count_in_downbeat_vs_beat_frequency(void) {
  printf("test_click_count_in_downbeat_vs_beat_frequency\n");
  le_engine* e = ck_make_engine(1);

  CHECK(le_engine_set_tempo(e, 300.0f) == LE_OK);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_REC) == LE_OK);
  CHECK(le_engine_set_click_output(e, 0x1) == LE_OK);
  CHECK(le_engine_set_count_in(e, 1) == LE_OK);
  ck_run(e, 1, 1, NULL, NULL);

  /* Count in one 4/4 bar. Beat 0 is the bar downbeat: 1500 Hz — ~45 cycles
   * over the 30 ms burst, ~90 sign flips. Beat 1 is a plain beat: 1000 Hz —
   * ~30 cycles, ~60 flips. The counts separate cleanly at 75. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  const int down = ck_crossings(e, CK_CLICK_FRAMES, 1, 0);
  CHECK(down > 75 && down < 105);
  ck_run(e, CK_FPB - CK_CLICK_FRAMES, 1, NULL, NULL);
  const int beat = ck_crossings(e, CK_CLICK_FRAMES, 1, 0);
  CHECK(beat > 45 && beat < 75);

  le_engine_destroy(e);
}

static void test_click_free_running_downbeat_vs_beat_frequency(void) {
  printf("test_click_free_running_downbeat_vs_beat_frequency\n");
  le_engine* e = ck_make_engine(1);

  CHECK(le_engine_set_tempo(e, 300.0f) == LE_OK);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_REC) == LE_OK);
  CHECK(le_engine_set_click_output(e, 0x1) == LE_OK);
  ck_run(e, 1, 1, NULL, NULL);

  /* The DEFINING recording free-runs the click off the nominal grid (no
   * master yet, clock.length == 0) — click_frame's free-run branch, the
   * trigger_click call site distinct from both the count-in scheduler above
   * and the loop-locked one below. Same downbeat/beat frequency split. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  const int down = ck_crossings(e, CK_CLICK_FRAMES, 1, 0);
  CHECK(down > 75 && down < 105);
  ck_run(e, CK_FPB - CK_CLICK_FRAMES, 1, NULL, NULL);
  const int beat = ck_crossings(e, CK_CLICK_FRAMES, 1, 0);
  CHECK(beat > 45 && beat < 75);

  le_engine_destroy(e);
}

static void test_click_loop_locked_downbeat_vs_beat_frequency(void) {
  printf("test_click_loop_locked_downbeat_vs_beat_frequency\n");
  le_engine* e = ck_make_engine(1);
  le_snapshot s;

  CHECK(le_engine_set_tempo(e, 300.0f) == LE_OK);
  CHECK(le_engine_set_click_output(e, 0x1) == LE_OK);
  ck_run(e, 1, 1, NULL, NULL);

  /* Finalize a one-bar defining loop with the click off, then enable it —
   * grid_beat_frame's loop-locked branch drives beats hereon, via the
   * NATURAL per-frame beat-transition trigger (not the pos==0 gate-rise
   * special case: the click is enabled mid-loop, at whatever arbitrary
   * position the finalize flush left it, and this test waits for the loop
   * to wrap around to 0 on its own before asserting anything). */
  CHECK(le_engine_record(e, 0) == LE_OK);
  ck_run(e, CK_BAR, 1, NULL, NULL);
  CHECK(le_engine_record(e, 0) == LE_OK);
  ck_run(e, CK_SR / 100 + 64, 1, NULL, NULL);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_PLAY_REC) == LE_OK);

  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == CK_BAR);
  const int32_t to_top = (CK_BAR - s.master_position_frames) % CK_BAR;
  ck_run(e, to_top, 1, NULL, NULL);

  const int down = ck_crossings(e, CK_CLICK_FRAMES, 1, 0);
  CHECK(down > 75 && down < 105); /* the wrap to beat 0: 1500 Hz downbeat */
  ck_run(e, CK_FPB - CK_CLICK_FRAMES, 1, NULL, NULL);
  const int beat = ck_crossings(e, CK_CLICK_FRAMES, 1, 0);
  CHECK(beat > 45 && beat < 75); /* beat 1: 1000 Hz */

  le_engine_destroy(e);
}

static void test_count_in_delays_defining_record(void) {
  printf("test_count_in_delays_defining_record\n");
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK); /* 500 frames per beat */
  CHECK(le_engine_set_count_in(e, 2) == LE_OK);   /* 2 bars * 4 * 500 = 4000 */
  tg_advance(e, 1);

  CHECK(le_engine_record(e, 0) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 1);
  CHECK(s.count_in_beats_left == 8); /* all 8 beats ahead (beat 0 sounding) */
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);

  /* One frame short of the full count-in: still counting, still empty. */
  tg_advance(e, 3998);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 1);
  CHECK(s.count_in_beats_left == 1);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);

  /* The next frame is the downbeat: the DEFINING record starts, delayed by
   * exactly bars * ts_num * frames_per_beat frames. */
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 0);
  CHECK(s.count_in_beats_left == 0);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING);

  /* And not a frame earlier: 800 captured frames finalize to an 800-frame
   * loop — had capture started during the count-in, the length would show
   * it. */
  tg_advance(e, 800);
  CHECK(le_engine_record(e, 0) == LE_OK);
  tg_advance(e, 1000 / 100); /* seam-xfade deferral at sr 1000 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 800);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);

  le_engine_destroy(e);
}

static void test_count_in_record_press_cancels(void) {
  printf("test_count_in_record_press_cancels\n");
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
  CHECK(le_engine_set_count_in(e, 1) == LE_OK);
  tg_advance(e, 1);
  CHECK(le_engine_record(e, 0) == LE_OK);
  tg_advance(e, 500);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 1);

  /* A record press mid-count CANCELS: back to idle, nothing records. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 0);
  CHECK(s.count_in_beats_left == 0);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);

  /* Well past where the count-in would have committed: still idle — the
   * cancel killed the deferred record, not just the clicks. */
  tg_advance(e, 4000);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.master_length_frames == 0);

  /* A fresh press after a cancel starts a fresh count-in. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 1);

  le_engine_destroy(e);
}

static void test_count_in_stop_and_disable_cancel(void) {
  printf("test_count_in_stop_and_disable_cancel\n");
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
  CHECK(le_engine_set_count_in(e, 1) == LE_OK);
  tg_advance(e, 1);

  /* Stop cancels (D9). */
  CHECK(le_engine_record(e, 0) == LE_OK);
  tg_advance(e, 500);
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 0);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  tg_advance(e, 3000);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 0);

  /* Disabling count-in mid-count cancels too. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  tg_advance(e, 500);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 1);
  CHECK(le_engine_set_count_in(e, 0) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 0);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  tg_advance(e, 3000);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 0);

  le_engine_destroy(e);
}

static void test_count_in_bars_change_mid_count_cancels(void) {
  printf("test_count_in_bars_change_mid_count_cancels\n");
  /* Code-review fix (MEDIUM): LE_CMD_SET_COUNT_IN used to reset the running
   * countdown only when the NEW value was 0; any other nonzero value
   * republished a_count_in_bars but left the frozen count_in_total/
   * count_in_beats/count_in_fpb (set at le_count_in_begin from the OLD
   * value) untouched, so the published setting and the actually-running
   * countdown would silently diverge until the stale count-in ended. ANY
   * mid-count-in change now cancels, matching the existing ->0 precedent. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK); /* 500 frames/beat */
  CHECK(le_engine_set_count_in(e, 2) == LE_OK);   /* 2 bars = 4000 frames */
  tg_advance(e, 1);

  CHECK(le_engine_record(e, 0) == LE_OK);
  tg_advance(e, 500);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 1);

  /* Changing to a DIFFERENT nonzero value mid-count cancels outright. */
  CHECK(le_engine_set_count_in(e, 4) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 0);
  CHECK(s.count_in_beats_left == 0);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.count_in_bars == 4); /* the new setting IS published */

  /* Well past where the OLD (2-bar) count-in would have committed: still
   * idle — the cancel killed the deferred record, not just the beat count. */
  tg_advance(e, 4000);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.master_length_frames == 0);

  /* A fresh press counts in cleanly against the NEW value (4 bars = 8000
   * frames), with no residual state from the cancelled one. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  tg_advance(e, 7999);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 1);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 0);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING);

  le_engine_destroy(e);
}

static void test_tempo_lock_during_count_in(void) {
  printf("test_tempo_lock_during_count_in\n");
  /* Code-review fix (MEDIUM): D6's tempo lock gated on "does any track have
   * content", which is false during an active count-in (the defining track
   * is still EMPTY — it only becomes RECORDING at le_count_in_commit). A
   * tempo/signature change was therefore accepted mid-count-in even though
   * the count-in's click schedule (count_in_fpb etc.) was already frozen
   * from the OLD tempo: the audible click kept counting the old rate while
   * the eventually-finalized grid would silently follow the new one.
   * le_tempo_locked now also locks while count_in_total > 0. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK); /* 500 frames/beat */
  CHECK(le_engine_set_count_in(e, 1) == LE_OK);   /* 1 bar = 2000 frames */
  tg_advance(e, 1);

  CHECK(le_engine_record(e, 0) == LE_OK); /* begins counting in */
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 1);

  /* Attempted mid-count-in changes are rejected outright, exactly like D6's
   * content lock. */
  CHECK(le_engine_set_tempo(e, 90.0f) == LE_OK); /* posts; audio-thread no-ops it */
  CHECK(le_engine_set_time_signature(e, 3, 4) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f);
  CHECK(s.ts_num == 4);
  CHECK(s.ts_den == 4);
  CHECK(s.counting_in == 1); /* still counting, unaffected either way */

  /* Let the count-in run to completion (2000 frames total; 2 already
   * elapsed above). */
  tg_advance(e, 2000 - 2);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 0);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING);
  /* The tempo/signature that survived is the ORIGINAL, locked-through one —
   * not the rejected 90 bpm / 3-4. */
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f);
  CHECK(s.ts_num == 4);
  CHECK(s.ts_den == 4);

  /* Finalize a clean one-bar take (2000 frames at 120 bpm/4-4, sr 1000) and
   * confirm the finalized GRID matches the original tempo too. */
  tg_advance(e, 2000);
  CHECK(le_engine_record(e, 0) == LE_OK);
  tg_advance(e, e->sample_rate / 100);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 2000);
  CHECK(s.loop_bars == 1);
  CHECK(fabsf(s.tempo_bpm - 120.0f) < 0.01f);

  le_engine_destroy(e);
}

static void test_count_in_cancel_race_across_block_boundary(void) {
  printf("test_count_in_cancel_race_across_block_boundary\n");
  /* Code-review fix (HIGH): le_count_in_commit can complete the count-in
   * MID-block via the per-frame countdown, but commands only drain once at
   * block-top (le_engine_process). A cancel press posted just after the
   * commit's block has already drained arrives one block too late to see
   * count_in_total > 0 in handle_record's guard — before the fix, it would
   * fall through to the RECORDING-finalize branch and mint a near-zero-
   * length defining loop instead of the cancel it meant. Constructed
   * directly with le_engine_process (not the tg_advance/ck_run helpers) for
   * exact control of block boundaries: one call spans past the count-in's
   * completion (the commit fires mid-call); the cancel press is posted only
   * AFTER that call returns, so it can only drain in the NEXT call. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK); /* 500 frames/beat */
  CHECK(le_engine_set_count_in(e, 1) == LE_OK);   /* 1 bar = 2000 frames */
  tg_advance(e, 1);

  CHECK(le_engine_record(e, 0) == LE_OK); /* begins counting in */

  /* Block N: one call spanning past frame 2000 — the commit lands mid-call,
   * inside this same block. */
  {
    const int n = 2050;
    float* in = calloc((size_t)n, sizeof(float));
    float* out = calloc((size_t)n, sizeof(float));
    CHECK(in != NULL && out != NULL);
    le_engine_process(e, out, in, (uint32_t)n);
    free(in);
    free(out);
  }
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 0);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING); /* the commit landed */

  /* The cancel-intent press is posted only NOW — after block N (and its
   * commit) already happened. It can only drain at the top of block N+1. */
  CHECK(le_engine_record(e, 0) == LE_OK);

  /* Block N+1: a tiny call is enough to drain it. */
  tg_advance(e, 4);

  /* The grace window recognized the race: aborted back to EMPTY, not
   * finalized into a near-zero-length defining loop. */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.master_length_frames == 0);
  CHECK(s.counting_in == 0);

  /* A fresh press afterward behaves normally — no residual grace/limbo. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  tg_advance(e, 4);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 1); /* counts in again, cleanly */

  le_engine_destroy(e);
}

static void test_count_in_without_tempo_records_immediately(void) {
  printf("test_count_in_without_tempo_records_immediately\n");
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  /* Count-in enabled but NO tempo set: nothing to click against — the press
   * records immediately, exactly as without count-in. */
  CHECK(le_engine_set_count_in(e, 1) == LE_OK);
  tg_advance(e, 1);
  CHECK(le_engine_record(e, 0) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 0);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING);

  le_engine_destroy(e);
}

static void test_count_in_never_fires_with_content(void) {
  printf("test_count_in_never_fires_with_content\n");
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
  tg_advance(e, 1);
  tg_record_defining_loop(e, 2000); /* track 0 defines and plays a bar */
  CHECK(le_engine_set_count_in(e, 1) == LE_OK);
  tg_advance(e, 1);

  /* With the loop playing, a press on an empty sibling records immediately
   * (phase-locked, as always) — count-in is for the DEFINING take only. */
  CHECK(le_engine_record(e, 1) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 0);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);

  le_engine_destroy(e);
}

static void test_count_in_auto_record_mutual_exclusion(void) {
  printf("test_count_in_auto_record_mutual_exclusion\n");
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
  tg_advance(e, 1);

  /* Direction 1: enabling count-in while a track waits on the input
   * threshold clears BOTH the auto-record mode and the pending arm (D9). */
  CHECK(le_engine_set_auto_record(e, 1) == LE_OK);
  CHECK(le_engine_record(e, 0) == LE_OK); /* arms the input-level trigger */
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].pending == 1);
  CHECK(le_engine_set_count_in(e, 1) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].pending == 0); /* threshold arm cancelled */
  CHECK(e->auto_record == 0);      /* mode cleared (white-box) */
  CHECK(s.count_in_bars == 1);

  /* A press now counts in — auto-record is gone. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 1);
  CHECK(le_engine_record(e, 0) == LE_OK); /* cancel; back to idle */
  tg_advance(e, 1);

  /* Direction 2: enabling auto-record clears the count-in setting; a press
   * then threshold-arms instead of counting in. */
  CHECK(le_engine_set_auto_record(e, 1) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.count_in_bars == 0);
  CHECK(e->count_in_bars == 0);
  CHECK(le_engine_record(e, 0) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 0);
  CHECK(s.tracks[0].pending == 1);
  CHECK(le_engine_record(e, 0) == LE_OK); /* disarm again */
  tg_advance(e, 1);

  /* Direction 2, mid-count: enabling auto-record during an active count-in
   * cancels the counting as well (its SET_COUNT_IN(0) cancels in flight). */
  CHECK(le_engine_set_count_in(e, 1) == LE_OK); /* clears auto-record again */
  CHECK(le_engine_record(e, 0) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 1);
  CHECK(le_engine_set_auto_record(e, 1) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 0);
  CHECK(s.count_in_bars == 0);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);

  le_engine_destroy(e);
}

static void test_count_in_click_absent_from_perf_capture(void) {
  printf("test_count_in_click_absent_from_perf_capture\n");
  le_engine* e = ck_make_engine(1);

  CHECK(le_engine_set_tempo(e, 300.0f) == LE_OK);
  CHECK(le_engine_set_click_mode(e, LE_CLICK_PLAY_REC) == LE_OK);
  /* Route the click to output 0 — the very channel the perf tap captures.
   * If the click were summed before the tap this test would light up. */
  CHECK(le_engine_set_click_output(e, 0x1) == LE_OK);
  CHECK(le_engine_set_count_in(e, 1) == LE_OK);
  ck_run(e, 1, 1, NULL, NULL);

  char path[600];
  snprintf(path, sizeof(path), "%s/master.pcm", perf_test_dir());
  remove(path); /* clear any stale capture from a prior test */
  CHECK(le_perf_arm(e, perf_test_dir()) == LE_OK);
  drain(e);

  /* Count in a full bar (audible on output 0), then record a little. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  double energy[1] = {0};
  ck_run(e, CK_BAR, 1, energy, NULL);
  CHECK(energy[0] > 0.5); /* the count-in clicked on the captured output */
  ck_run(e, 1000, 1, NULL, NULL);
  CHECK(atomic_load_explicit(&e->a_perf_overruns, memory_order_relaxed) ==
        0u); /* nothing dropped: the capture spans the whole count-in */
  CHECK(le_perf_disarm(e) == LE_OK); /* blocks: final flush + join */

  /* The captured master must be pure silence: the click sums AFTER the perf
   * tap, so a performance capture (and every export built from it) never
   * contains it — by construction, not by filtering. */
  static float pcm[262144];
  FILE* f = fopen(path, "rb");
  CHECK(f != NULL);
  if (f != NULL) {
    const size_t n = fread(pcm, sizeof(float), 262144, f);
    fclose(f);
    CHECK(n >= (size_t)CK_BAR); /* the count-in window is all there */
    float max_mag = 0.0f;
    for (size_t i = 0; i < n; ++i) {
      if (fabsf(pcm[i]) > max_mag) max_mag = fabsf(pcm[i]);
    }
    CHECK(max_mag == 0.0f);
  }

  le_engine_destroy(e);
}

/* ---- long-loop (> LE_LAYER_QUANTUM) audit coverage — #227 ----
 *
 * Nearly every looper test runs at LOOP_N = 4 frames, far below
 * LE_LAYER_QUANTUM: any buffer sized in quanta is silently big enough there,
 * so a sizing bug whose computed size happens to round up to one quantum is
 * invisible (#218's shadow-slot overflow ran green through the whole suite).
 * These variants drive the paths that size, copy, or index by loop length
 * with a loop LONGER than one quantum, so a one-quantum buffer is short and
 * the bug is loud — especially under the ASAN CI job added with this issue. */

/* Interleaved-stereo pump for a two-lane track: lane 0 records input 0
 * (value a), lane 1 records input 1 (value b). When cap is non-NULL, output
 * channel 0 is appended per frame, advancing *capn (mirrors feed_const). */
static void pump_two_lane(le_engine* e, float a, float b, int frames,
                          float* cap, int* capn) {
  float in[128];
  float out[128];
  while (frames > 0) {
    const int n = frames > 64 ? 64 : frames;
    for (int i = 0; i < n; ++i) {
      in[i * 2 + 0] = a;
      in[i * 2 + 1] = b;
    }
    le_engine_process(e, out, in, (uint32_t)n);
    if (cap != NULL) {
      for (int i = 0; i < n; ++i) cap[(*capn)++] = out[i * 2 + 0];
    }
    frames -= n;
  }
}

/* Frames of buf[0..n) within 1e-3 of want. The punch declick fade (~480
 * frames per edge at 48k) keeps a long-loop capture from being exactly
 * constant, so these tests assert "almost everywhere at the level, never
 * above it" where the short tests assert exact equality. */
static int count_near(const float* buf, int n, float want) {
  int hits = 0;
  for (int i = 0; i < n; ++i) {
    if (fabsf(buf[i] - want) < 1e-3f) hits++;
  }
  return hits;
}

/* Records a defining base loop of exactly `len` frames of `value` (mono).
 * At real lengths the finalize defers ~10 ms for the seam crossfade, so the
 * overlap must keep being fed after the second press — this helper owns that
 * timing dance once (the long-loop siblings of record_base_loop). */
static void record_long_base_loop(le_engine* e, float value, int32_t len) {
  le_snapshot s;
  le_engine_record(e, 0);
  pump_frames(e, value, len);
  le_engine_record(e, 0);
  drain(e);
  pump_frames(e, value, 600); /* > seam overlap (480 @ 48k) */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].length_frames == len);
}

/* Multi-lane dub capture + layer save/load slot mapping at > 1 quantum: both
 * lanes' dub shadows and restored slots must cover the full loop, and
 * finalize_layers' slot mapping must survive a teardown/rebuild with
 * multi-quantum buffers. Short sibling: test_layer_multi_lane_roundtrip. */
static void test_multi_lane_long_loop_dub_roundtrip(void) {
  printf("test_multi_lane_long_loop_dub_roundtrip\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 200000);
  le_engine_set_lane_count(e, 0, 2);
  le_engine_set_lane_input(e, 0, 0, 0);
  le_engine_set_lane_input(e, 0, 1, 1);
  le_engine_set_lane_output(e, 0, 0, 0x1);
  le_engine_set_lane_output(e, 0, 1, 0x1);
  drain(e);
  le_snapshot s;

  /* Defining record; at this length the finalize defers ~10 ms for the seam
   * crossfade — keep feeding through the overlap. */
  const int32_t len = LE_LAYER_QUANTUM + 2000;
  le_engine_record(e, 0);
  pump_two_lane(e, 1.0f, 2.0f, len, NULL, NULL);
  le_engine_record(e, 0);
  drain(e);
  pump_two_lane(e, 1.0f, 2.0f, 600, NULL, NULL);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].length_frames == len);

  /* One full dub pass into both lanes. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  pump_two_lane(e, 0.5f, 0.25f, len, NULL, NULL);
  le_engine_record(e, 0); /* punch out */
  drain(e);
  pump_two_lane(e, 0.0f, 0.0f, 600, NULL, NULL); /* fade tail */
  drain(e);
  settle_layers(e);
  le_engine_get_snapshot(e, &s);
  const int32_t depth = s.tracks[0].undo_depth;
  CHECK(depth >= 1); /* the pass (+ a punch-tail sliver at this size) */

  /* Live playback sums both dubbed lanes: (1+0.5) + (2+0.25) = 3.75 almost
   * everywhere — including the seam band: the equal-gain (linear) seam
   * crossfade (#256) has weights summing to exactly 1.0, so fully correlated
   * DC content passes at unity and the legitimate ceiling is 3.75. A seam-band
   * DOUBLE-application of the dub layer (the #218 bug class) would reach
   * 3.0 + 2*0.75 = 4.5, and a regression to equal-power sin/cos weights would
   * reach 3.0*sqrt(2) + 0.75 = 4.99 — keep the bound between the legitimate
   * 3.75 and the nearest failure mode at 4.5 to catch both. */
  float* play = malloc((size_t)len * sizeof(float));
  CHECK(play != NULL);
  if (play == NULL) { /* CHECK doesn't halt — avoid the NULL capture */
    le_engine_destroy(e);
    return;
  }
  int got = 0;
  pump_two_lane(e, 0.0f, 0.0f, len, play, &got);
  CHECK(got == len);
  CHECK(count_near(play, len, 3.75f) > (len * 9) / 10);
  for (int i = 0; i < len; ++i) CHECK(play[i] < 4.1f);

  /* Export every image of both lanes (ordinal 0 = oldest undo … depth = live),
   * tear down, rebuild, and demand byte-identical re-exports: the strongest
   * phase-independent proof the slot mapping survived at this size. */
  const int images = depth + 1;
  CHECK(images <= 4);
  if (images > 4) { /* CHECK doesn't halt — bail before overflowing l0/l1 */
    free(play);
    le_engine_destroy(e);
    return;
  }
  float* l0[4] = {0};
  float* l1[4] = {0};
  for (int o = 0; o < images; ++o) {
    l0[o] = malloc((size_t)len * sizeof(float));
    l1[o] = malloc((size_t)len * sizeof(float));
    CHECK(l0[o] != NULL && l1[o] != NULL);
    if (l0[o] == NULL || l1[o] == NULL) return;
    CHECK(le_engine_export_layer(e, 0, 0, o, l0[o], len) == len);
    CHECK(le_engine_export_layer(e, 0, 1, o, l1[o], len) == len);
  }

  /* Loop-indexed tail pin: the playback capture above is phase-shifted, so
   * only exports can address the [quantum, len) region specifically — the
   * 4% tail a whole-loop histogram can never catch on its own (a dub that
   * silently stopped at one quantum would still clear the 90% bar). The
   * punch/seam fade bands (~1500 frames, wherever the phase put them) are
   * allowed to miss the exact level. */
  const int tail = len - LE_LAYER_QUANTUM;
  CHECK(count_near(l0[depth] + LE_LAYER_QUANTUM, tail, 1.5f) > tail - 1500);
  CHECK(count_near(l1[depth] + LE_LAYER_QUANTUM, tail, 2.25f) > tail - 1500);

  le_engine_clear(e, 0);
  drain(e);
  for (int o = 0; o < images; ++o) {
    CHECK(le_engine_import_layer(e, 0, 0, o, l0[o], len) == LE_OK);
    CHECK(le_engine_import_layer(e, 0, 1, o, l1[o], len) == LE_OK);
  }
  CHECK(le_engine_finalize_layers(e, 0, depth, 0) == LE_OK);
  CHECK(le_engine_commit_session(e, len) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].lane_count == 2);
  CHECK(s.tracks[0].undo_depth == depth);

  float* back = malloc((size_t)len * sizeof(float));
  CHECK(back != NULL);
  for (int o = 0; o < images; ++o) {
    CHECK(le_engine_export_layer(e, 0, 0, o, back, len) == len);
    CHECK(memcmp(back, l0[o], (size_t)len * sizeof(float)) == 0);
    CHECK(le_engine_export_layer(e, 0, 1, o, back, len) == len);
    CHECK(memcmp(back, l1[o], (size_t)len * sizeof(float)) == 0);
  }

  /* The rebuilt track still plays the dubbed sum and undoes to the base. */
  got = 0;
  pump_two_lane(e, 0.0f, 0.0f, len, play, &got);
  CHECK(count_near(play, len, 3.75f) > (len * 9) / 10);
  for (int32_t k = 0; k < depth; ++k) CHECK(le_engine_undo(e, 0) == LE_OK);
  got = 0;
  pump_two_lane(e, 0.0f, 0.0f, len, play, &got);
  CHECK(count_near(play, len, 3.0f) > (len * 9) / 10);

  free(back);
  for (int o = 0; o < images; ++o) {
    free(l0[o]);
    free(l1[o]);
  }
  free(play);
  le_engine_destroy(e);
}

/* Pool eviction with multi-quantum slots: exhausting the pool with 2-quantum
 * layers must evict the oldest and keep running, and the survivors' buffers
 * must still cover the whole loop. Short sibling: test_undo_pool_eviction. */
static void test_undo_pool_eviction_long_loop(void) {
  printf("test_undo_pool_eviction_long_loop\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 200000);
  le_snapshot s;

  const int32_t len = LE_LAYER_QUANTUM + 2000;
  record_long_base_loop(e, 1.0f, len);

  /* One continuous overdub held for more wraps than the pool holds; the poll
   * tick between passes collects retires and replenishes spares. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  const int passes = LE_POOL_SLOTS + 10;
  for (int pass = 0; pass < passes; ++pass) {
    pump_frames(e, 0.5f, len);
    le_engine_get_snapshot(e, &s);
  }
  le_engine_record(e, 0); /* punch out */
  drain(e);
  pump_frames(e, 0.0f, 600);
  drain(e);
  settle_layers(e);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth >= LE_POOL_SLOTS - 6);
  CHECK(s.tracks[0].undo_depth <= LE_POOL_SLOTS - 1);

  /* Content sits at the additive top almost everywhere (the punch tail may
   * carry one extra fading pass), and undo still swaps in a full-size slot. */
  const float top = 1.0f + 0.5f * (float)passes;
  float* pcm = malloc((size_t)len * sizeof(float));
  CHECK(pcm != NULL);
  if (pcm == NULL) {
    le_engine_destroy(e);
    return;
  }
  CHECK(le_engine_export_track(e, 0, pcm, len) == len);
  CHECK(count_near(pcm, len, top) > (len * 9) / 10);
  for (int i = 0; i < len; ++i) CHECK(pcm[i] < top + 0.5f + 1e-3f);
  /* Loop-indexed tail pin (export addresses loop frame 0..len): the 4% tail
   * past the quantum must carry every pass too, not just clear a whole-loop
   * histogram; fade bands (~1500 frames) may miss the exact level. */
  const int tail = len - LE_LAYER_QUANTUM;
  CHECK(count_near(pcm + LE_LAYER_QUANTUM, tail, top) > tail - 1500);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  CHECK(le_engine_lane_slot_cap_for_test(e, 0, 0, -1) >= len);
  free(pcm);
  le_engine_destroy(e);
}

/* Record-offset compensation writing beyond the first quantum: an impulse
 * overdubbed deep in the second quantum (write index ~ quantum + 1000, past
 * where a one-quantum shadow would end) lands exactly once. Short sibling:
 * test_latency_compensation (10-frame loop). */
static void test_record_offset_long_loop(void) {
  printf("test_record_offset_long_loop\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 200000);
  le_snapshot s;

  const int32_t len = LE_LAYER_QUANTUM + 2000;
  record_long_base_loop(e, 0.0f, len);

  CHECK(le_engine_set_record_offset(e, 3) == LE_OK);
  drain(e);

  /* Punch in, run past the punch-in declick fade AND the quantum boundary,
   * then a single hot frame; finish the pass in silence. */
  le_engine_record(e, 0);
  pump_frames(e, 0.0f, LE_LAYER_QUANTUM + 1000);
  pump_frames(e, 1.0f, 1);
  pump_frames(e, 0.0f, len - LE_LAYER_QUANTUM - 1001);
  le_engine_record(e, 0); /* punch out */
  drain(e);
  pump_frames(e, 0.0f, 600);
  drain(e);
  settle_layers(e);

  /* Exactly one hot frame landed; nothing else lit up or clipped. */
  float* pcm = malloc((size_t)len * sizeof(float));
  CHECK(pcm != NULL);
  if (pcm == NULL) {
    le_engine_destroy(e);
    return;
  }
  CHECK(le_engine_export_track(e, 0, pcm, len) == len);
  int hot = 0;
  for (int i = 0; i < len; ++i) {
    if (fabsf(pcm[i]) > 0.5f) hot++;
    CHECK(fabsf(pcm[i]) < 1.0f + 1e-3f);
  }
  CHECK(hot == 1);
  free(pcm);
  le_engine_destroy(e);
}

/* Overdub feedback decaying a multi-quantum layer: the scale-and-sum pass
 * must walk the full 2-quantum buffer, and undo must restore the undecayed
 * base. Short sibling: test_overdub_feedback_decays_layers. */
static void test_overdub_feedback_long_loop(void) {
  printf("test_overdub_feedback_long_loop\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 1, 1, 200000);
  le_snapshot s;

  const int32_t len = LE_LAYER_QUANTUM + 2000;
  record_long_base_loop(e, 1.0f, len);

  CHECK(le_engine_set_overdub_feedback(e, 0.5f) == LE_OK);
  drain(e);

  /* One silent dub pass: existing content decays to 1.0 * 0.5 everywhere. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  pump_frames(e, 0.0f, len);
  le_engine_record(e, 0); /* punch out */
  drain(e);
  pump_frames(e, 0.0f, 600);
  drain(e);
  settle_layers(e);

  float* pcm = malloc((size_t)len * sizeof(float));
  CHECK(pcm != NULL);
  if (pcm == NULL) {
    le_engine_destroy(e);
    return;
  }
  CHECK(le_engine_export_track(e, 0, pcm, len) == len);
  CHECK(count_near(pcm, len, 0.5f) > (len * 9) / 10);
  for (int i = 0; i < len; ++i) CHECK(pcm[i] < 1.0f + 1e-3f);
  /* Loop-indexed tail pin: a decay pass that silently stopped at one quantum
   * leaves the whole [quantum, len) tail at 1.0 yet still clears the 90%
   * whole-loop bar — pin the tail itself (fade bands may miss). */
  const int tail = len - LE_LAYER_QUANTUM;
  CHECK(count_near(pcm + LE_LAYER_QUANTUM, tail, 0.5f) > tail - 1500);

  /* Undo restores the undecayed base across the whole buffer. */
  le_engine_get_snapshot(e, &s);
  const int32_t depth = s.tracks[0].undo_depth;
  CHECK(depth >= 1);
  for (int32_t k = 0; k < depth; ++k) CHECK(le_engine_undo(e, 0) == LE_OK);
  CHECK(le_engine_export_track(e, 0, pcm, len) == len);
  CHECK(count_near(pcm, len, 1.0f) > (len * 9) / 10);
  free(pcm);
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

/* le_engine_export_track_lane exports any lane, not just lane 0 — asserted
 * against a two-lane track recording two distinct inputs, so each lane's
 * export is independently verifiable. le_engine_export_track (lane 0) stays
 * byte-identical: same settled-buffer memcpy, same return value. */
static void test_export_track_lane_multi_lane(void) {
  printf("test_export_track_lane_multi_lane\n");
  le_engine* e = le_engine_create();
  le_engine_configure(e, 48000, 2, 2, 1000);
  le_engine_set_lane_count(e, 0, 2);
  le_engine_set_lane_input(e, 0, 0, 0); /* lane 0 records input 0 */
  le_engine_set_lane_input(e, 0, 1, 1); /* lane 1 records input 1 */
  drain(e);

  float out[2 * LOOP_N];
  float in[2 * LOOP_N];
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 1.0f;
    in[i * 2 + 1] = 2.0f;
  }
  le_engine_record(e, 0);
  le_engine_process(e, out, in, LOOP_N);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);

  float lane0[64];
  float lane1[64];
  CHECK(le_engine_export_track_lane(e, 0, 0, lane0, 64) == LOOP_N);
  CHECK(le_engine_export_track_lane(e, 0, 1, lane1, 64) == LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(lane0[i] - 1.0f) < 1e-6f);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(lane1[i] - 2.0f) < 1e-6f);

  /* le_engine_export_track (the existing lane-0-only entry point) is
   * byte-identical to exporting lane 0 explicitly. */
  float legacy[64];
  CHECK(le_engine_export_track(e, 0, legacy, 64) == LOOP_N);
  CHECK(memcmp(legacy, lane0, (size_t)LOOP_N * sizeof(float)) == 0);

  /* max_frames clamps identically to the lane-0 entry point. */
  float clamped[2];
  CHECK(le_engine_export_track_lane(e, 0, 0, clamped, 2) == 2);

  /* A valid but never-recorded-into lane (track 1's lane 0, allocated but
   * empty) returns 0 frames, not an error. */
  float empty[64];
  CHECK(le_engine_export_track_lane(e, 1, 0, empty, 64) == 0);

  /* A lane index that's in-range (< LE_MAX_LANES) but was never allocated at
   * all — track 0's lane_count is 2, so lane 2 is a distinct branch from the
   * "allocated but a_len == 0" case above: pool[live] itself is NULL. */
  CHECK(le_engine_export_track_lane(e, 0, 2, empty, 64) == 0);

  /* Invalid channel/lane -> LE_ERR_INVALID, distinct from the 0-frames case
   * above (le_engine_export_track's lane-0-only sibling has no such
   * distinction to make, since it has no `lane` argument to validate). */
  CHECK(le_engine_export_track_lane(e, -1, 0, lane0, 64) == LE_ERR_INVALID);
  CHECK(le_engine_export_track_lane(e, e->track_count, 0, lane0, 64) ==
        LE_ERR_INVALID);
  CHECK(le_engine_export_track_lane(e, 0, -1, lane0, 64) == LE_ERR_INVALID);
  CHECK(le_engine_export_track_lane(e, 0, LE_MAX_LANES, lane0, 64) ==
        LE_ERR_INVALID);
  CHECK(le_engine_export_track_lane(e, 0, 0, lane0, 0) == LE_ERR_INVALID);
  CHECK(le_engine_export_track_lane(e, 0, 0, NULL, 64) == LE_ERR_INVALID);
  CHECK(le_engine_export_track_lane(NULL, 0, 0, lane0, 64) == LE_ERR_INVALID);

  le_engine_destroy(e);
}

/* le_engine_import_track_lane restores a multi-lane track: a two-lane loop is
 * exported per lane, torn down, then reloaded lane-by-lane and committed. Both
 * lanes play back their own content summed on the shared output — the multi-lane
 * counterpart of test_session_export_import_roundtrip (which is lane-0 only).
 * (Uses the two-lane helpers defined just below in the multi-lane section.) */
static le_engine* make_two_lane_engine(void);
static void record_two_lane(le_engine* e, float a, float b);
static void test_import_track_lane_multi_lane_roundtrip(void) {
  printf("test_import_track_lane_multi_lane_roundtrip\n");
  le_engine* e = make_two_lane_engine(); /* both lanes route to out 0 */
  float out[2 * LOOP_N];
  le_snapshot s;

  record_two_lane(e, 1.0f, 2.0f); /* lane 0 = 1.0, lane 1 = 2.0 */

  float lane0[64];
  float lane1[64];
  CHECK(le_engine_export_track_lane(e, 0, 0, lane0, 64) == LOOP_N);
  CHECK(le_engine_export_track_lane(e, 0, 1, lane1, 64) == LOOP_N);

  /* Tear the track down to EMPTY (which also collapses lane_count back to 1). */
  le_engine_clear(e, 0);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);

  /* Reload both lanes: lane 0 primary, lane 1 grows lane_count and fills. */
  CHECK(le_engine_import_track_lane(e, 0, 0, lane0, LOOP_N) == LE_OK);
  CHECK(le_engine_import_track_lane(e, 0, 1, lane1, LOOP_N) == LE_OK);
  CHECK(le_engine_commit_session(e, LOOP_N) == LE_OK);
  drain(e);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].lane_count == 2);

  /* Both lanes reproduce their content, summed (not merged) on out 0: 1+2 == 3. */
  float zin[2 * LOOP_N] = {0};
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i * 2 + 0] - 3.0f) < 1e-6f);

  /* Importing into a non-empty (now PLAYING) track is rejected on any lane. */
  CHECK(le_engine_import_track_lane(e, 0, 0, lane0, LOOP_N) == LE_ERR_INVALID);
  CHECK(le_engine_import_track_lane(e, 0, 1, lane1, LOOP_N) == LE_ERR_INVALID);

  /* Argument validation mirrors the export sibling. */
  le_engine_clear(e, 0);
  drain(e);
  CHECK(le_engine_import_track_lane(e, 0, 0, lane0, 0) == LE_ERR_INVALID);
  CHECK(le_engine_import_track_lane(e, 0, -1, lane0, LOOP_N) == LE_ERR_INVALID);
  CHECK(le_engine_import_track_lane(e, 0, LE_MAX_LANES, lane0, LOOP_N) ==
        LE_ERR_INVALID);
  CHECK(le_engine_import_track_lane(e, -1, 0, lane0, LOOP_N) == LE_ERR_INVALID);
  CHECK(le_engine_import_track_lane(e, 0, 0, NULL, LOOP_N) == LE_ERR_INVALID);
  CHECK(le_engine_import_track_lane(NULL, 0, 0, lane0, LOOP_N) == LE_ERR_INVALID);

  le_engine_destroy(e);
}

/* ---- overdub-layer (undo/redo) persistence ---- */

/* Full timeline round-trip: two overdub passes then one undo leaves an undo
 * layer, a live buffer, and a redo layer; export all three, tear down, rebuild
 * via import_layer + finalize_layers + commit, and assert the live playback AND
 * the reconstructed undo/redo replay all reproduce the original takes. */
static void test_layer_export_import_roundtrip(void) {
  printf("test_layer_export_import_roundtrip\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  /* Base 1.0, then two +0.5 overdubs: live 1.0 -> 1.5 -> 2.0. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);
  for (int layer = 0; layer < 2; ++layer) {
    le_engine_record(e, 0);
    process_const(e, 0.5f, LOOP_N, out);
    le_engine_record(e, 0);
    drain(e);
  }
  settle_layers(e); /* punch envelope quiet before undo/export */

  /* Undo once so there is both undo (1) and redo (1) history to persist. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 1);
  CHECK(s.tracks[0].redo_depth == 1);

  /* Export the whole timeline: ordinal 0 = 1.0 (undo), 1 = 1.5 (live),
   * 2 = 2.0 (redo). */
  float layers[3][64];
  for (int o = 0; o < 3; ++o) {
    CHECK(le_engine_export_layer(e, 0, 0, o, layers[o], 64) == LOOP_N);
  }
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(layers[0][i] - 1.0f) < 1e-6f);
    CHECK(fabsf(layers[1][i] - 1.5f) < 1e-6f);
    CHECK(fabsf(layers[2][i] - 2.0f) < 1e-6f);
  }
  /* A past-the-end ordinal is rejected, distinct from an empty layer. */
  CHECK(le_engine_export_layer(e, 0, 0, 3, layers[0], 64) == LE_ERR_INVALID);

  /* Tear down to EMPTY, then rebuild from the exported layers. */
  le_engine_clear(e, 0);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);

  for (int o = 0; o < 3; ++o) {
    CHECK(le_engine_import_layer(e, 0, 0, o, layers[o], LOOP_N) == LE_OK);
  }
  CHECK(le_engine_finalize_layers(e, 0, 1, 1) == LE_OK);
  CHECK(le_engine_commit_session(e, LOOP_N) == LE_OK);
  drain(e);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].undo_depth == 1);
  CHECK(s.tracks[0].redo_depth == 1);

  /* Live plays 1.5; undo -> 1.0 (redo now 2); redo twice -> 1.5 -> 2.0. */
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.5f) < 1e-6f);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.0f) < 1e-6f);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 0);
  CHECK(s.tracks[0].redo_depth == 2);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.5f) < 1e-6f);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 2.0f) < 1e-6f);

  le_engine_destroy(e);
}

/* import_layer / finalize_layers reject bad reconstructions rather than
 * publishing a torn track: past-cap ordinals, over-cap layer counts, an
 * unstaged track, and a partial (missing-slot) reconstruction. */
static void test_layer_import_rejects_bad_reconstruction(void) {
  printf("test_layer_import_rejects_bad_reconstruction\n");
  le_engine* e = make_configured_engine();
  float pcm[LOOP_N] = {0.5f, 0.5f, 0.5f, 0.5f};

  /* An ordinal past the pool cap is rejected. */
  CHECK(le_engine_import_layer(e, 0, 0, LE_POOL_SLOTS, pcm, LOOP_N) ==
        LE_ERR_INVALID);
  /* A layer count past the pool cap is rejected. */
  CHECK(le_engine_finalize_layers(e, 0, LE_POOL_SLOTS, 0) == LE_ERR_INVALID);
  /* Finalizing a track with nothing staged (a_len 0) is rejected. */
  CHECK(le_engine_finalize_layers(e, 0, 0, 0) == LE_ERR_INVALID);

  /* Stage one layer, then a finalize claiming a missing second slot fails. */
  CHECK(le_engine_import_layer(e, 0, 0, 0, pcm, LOOP_N) == LE_OK);
  CHECK(le_engine_finalize_layers(e, 0, 1, 0) == LE_ERR_INVALID); /* slot 1 gone */
  /* The matching finalize (one live layer, no undo/redo) succeeds. */
  CHECK(le_engine_finalize_layers(e, 0, 0, 0) == LE_OK);

  le_engine_destroy(e);
}

/* Layers persist per lane and undo in lockstep across lanes: a two-lane track
 * with one overdub pass exports both layers of both lanes, rebuilds, and both
 * lanes undo together back to their pre-overdub content. */
static void test_layer_multi_lane_roundtrip(void) {
  printf("test_layer_multi_lane_roundtrip\n");
  le_engine* e = make_two_lane_engine(); /* both lanes route to out 0 */
  float out[2 * LOOP_N];
  float in[2 * LOOP_N];
  le_snapshot s;

  record_two_lane(e, 1.0f, 2.0f); /* lane 0 = 1.0, lane 1 = 2.0 */
  /* One overdub pass: +0.5 into lane 0, +0.25 into lane 1. */
  for (int i = 0; i < LOOP_N; ++i) {
    in[i * 2 + 0] = 0.5f;
    in[i * 2 + 1] = 0.25f;
  }
  le_engine_record(e, 0);
  le_engine_process(e, out, in, LOOP_N);
  le_engine_record(e, 0);
  drain(e);
  settle_layers(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 1);

  /* Export both layers (ordinal 0 = pre-overdub, 1 = live) of each lane. */
  float l0[2][64];
  float l1[2][64];
  for (int o = 0; o < 2; ++o) {
    CHECK(le_engine_export_layer(e, 0, 0, o, l0[o], 64) == LOOP_N);
    CHECK(le_engine_export_layer(e, 0, 1, o, l1[o], 64) == LOOP_N);
  }
  for (int i = 0; i < LOOP_N; ++i) {
    CHECK(fabsf(l0[0][i] - 1.0f) < 1e-6f);
    CHECK(fabsf(l0[1][i] - 1.5f) < 1e-6f);
    CHECK(fabsf(l1[0][i] - 2.0f) < 1e-6f);
    CHECK(fabsf(l1[1][i] - 2.25f) < 1e-6f);
  }

  le_engine_clear(e, 0);
  drain(e);

  /* Rebuild: 2 lanes x 2 layers (undo 1, redo 0). */
  for (int o = 0; o < 2; ++o) {
    CHECK(le_engine_import_layer(e, 0, 0, o, l0[o], LOOP_N) == LE_OK);
    CHECK(le_engine_import_layer(e, 0, 1, o, l1[o], LOOP_N) == LE_OK);
  }
  CHECK(le_engine_finalize_layers(e, 0, 1, 0) == LE_OK);
  CHECK(le_engine_commit_session(e, LOOP_N) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].lane_count == 2);
  CHECK(s.tracks[0].undo_depth == 1);

  /* Live: lane0 (1.5) + lane1 (2.25) summed on out 0 = 3.75. */
  float zin[2 * LOOP_N] = {0};
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i * 2 + 0] - 3.75f) < 1e-6f);
  /* Undo peels both lanes in lockstep: 1.0 + 2.0 = 3.0. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  le_engine_process(e, out, zin, LOOP_N);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i * 2 + 0] - 3.0f) < 1e-6f);

  le_engine_destroy(e);
}

/* Overdubbing AFTER a reconstruction must not corrupt the restored layers: the
 * preceding clear pre-arms dub shadow slots, and a multi-layer rebuild then
 * occupies low pool slots — if a stale shadow collides with a restored slot,
 * the next overdub would write a pre-pass image over a restored layer. Rebuild
 * (undo 1, redo 1), commit, punch a fresh overdub, and assert undo peels back
 * through the new layer to the restored ones intact. */
static void test_layer_overdub_after_reload_no_corruption(void) {
  printf("test_layer_overdub_after_reload_no_corruption\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  /* Base 1.0, two +0.5 overdubs -> live 2.0 (undo 2); undo once -> 1.5. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);
  for (int layer = 0; layer < 2; ++layer) {
    le_engine_record(e, 0);
    process_const(e, 0.5f, LOOP_N, out);
    le_engine_record(e, 0);
    drain(e);
  }
  settle_layers(e);
  CHECK(le_engine_undo(e, 0) == LE_OK);

  float layers[3][64];
  for (int o = 0; o < 3; ++o) {
    CHECK(le_engine_export_layer(e, 0, 0, o, layers[o], 64) == LOOP_N);
  }

  le_engine_clear(e, 0);
  drain(e);
  for (int o = 0; o < 3; ++o) {
    CHECK(le_engine_import_layer(e, 0, 0, o, layers[o], LOOP_N) == LE_OK);
  }
  CHECK(le_engine_finalize_layers(e, 0, 1, 1) == LE_OK);
  CHECK(le_engine_commit_session(e, LOOP_N) == LE_OK);
  drain(e);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.5f) < 1e-6f);

  /* Punch a fresh +0.25 overdub over the reloaded track -> live 1.75. */
  le_engine_record(e, 0);
  process_const(e, 0.25f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);
  settle_layers(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 2); /* restored undo + the new pass */
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.75f) < 1e-6f);

  /* Undo the new pass -> the reconstructed live (1.5), NOT a corrupted layer. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.5f) < 1e-6f);
  /* Undo again -> the original restored undo layer (1.0). */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.0f) < 1e-6f);

  le_engine_destroy(e);
}

/* Reconstruct a track with TWO redo layers, exercising finalize's redo-stack
 * formula (redo_stack[k] = undo_count + redo_count - k) at redo_count == 2 —
 * the single-redo round-trip only covers redo_stack[0] = undo_count + 1. */
static void test_layer_reconstruct_two_redo(void) {
  printf("test_layer_reconstruct_two_redo\n");
  le_engine* e = make_configured_engine();
  float out[64];
  le_snapshot s;

  /* Base 1.0, three +0.5 overdubs -> 2.5 (undo 3); undo twice -> live 1.5,
   * redo 2. */
  le_engine_record(e, 0);
  process_const(e, 1.0f, LOOP_N, out);
  le_engine_record(e, 0);
  drain(e);
  for (int layer = 0; layer < 3; ++layer) {
    le_engine_record(e, 0);
    process_const(e, 0.5f, LOOP_N, out);
    le_engine_record(e, 0);
    drain(e);
  }
  settle_layers(e);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  CHECK(le_engine_undo(e, 0) == LE_OK);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].undo_depth == 1);
  CHECK(s.tracks[0].redo_depth == 2);

  /* Export 4 layers: 1.0 (undo), 1.5 (live), 2.0 then 2.5 (redo, oldest→new). */
  float layers[4][64];
  for (int o = 0; o < 4; ++o) {
    CHECK(le_engine_export_layer(e, 0, 0, o, layers[o], 64) == LOOP_N);
  }
  CHECK(fabsf(layers[2][0] - 2.0f) < 1e-6f);
  CHECK(fabsf(layers[3][0] - 2.5f) < 1e-6f);

  le_engine_clear(e, 0);
  drain(e);
  for (int o = 0; o < 4; ++o) {
    CHECK(le_engine_import_layer(e, 0, 0, o, layers[o], LOOP_N) == LE_OK);
  }
  CHECK(le_engine_finalize_layers(e, 0, 1, 2) == LE_OK);
  CHECK(le_engine_commit_session(e, LOOP_N) == LE_OK);
  drain(e);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].redo_depth == 2);
  /* Redo twice climbs the stack in the right order: 1.5 -> 2.0 -> 2.5. */
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.5f) < 1e-6f);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 2.0f) < 1e-6f);
  CHECK(le_engine_redo(e, 0) == LE_OK);
  process_const(e, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 2.5f) < 1e-6f);

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

/* ---- json_read: the minimal JSON parser (part 7) ----
 *
 * Direct unit tests for the parser itself, isolated from the full
 * performance.json schema every perf_render_* test below exercises it
 * through — malformed input, arena exhaustion, and nesting are all easy to
 * get wrong in a hand-rolled parser and deserve their own coverage. */

static void test_json_read_parses_nested_objects_and_arrays(void) {
  printf("test_json_read_parses_nested_objects_and_arrays\n");
  static le_json_value nodes[64];
  le_json_arena arena = {.nodes = nodes, .capacity = 64, .used = 0};
  const char* text =
      "{\"a\": 1, \"b\": true, \"c\": null, \"d\": \"hi\", "
      "\"e\": {\"f\": [1, 2, 3]}}";
  le_json_value* root = le_json_parse(text, &arena);
  CHECK(root != NULL);
  CHECK(le_json_number(le_json_get(root, "a"), -1) == 1.0);
  CHECK(le_json_bool(le_json_get(root, "b"), 0) == 1);
  CHECK(le_json_get(root, "c") != NULL);
  CHECK(le_json_get(root, "c")->type == LE_JSON_NULL);
  char s[8];
  CHECK(le_json_string(le_json_get(root, "d"), s, sizeof(s)));
  CHECK(strcmp(s, "hi") == 0);
  const le_json_value* e = le_json_get(root, "e");
  CHECK(e != NULL);
  const le_json_value* f = le_json_get(e, "f");
  CHECK(le_json_length(f) == 3);
  CHECK(le_json_number(le_json_at(f, 0), -1) == 1.0);
  CHECK(le_json_number(le_json_at(f, 2), -1) == 3.0);
  CHECK(le_json_at(f, 3) == NULL); /* out of range */
}

static void test_json_read_rejects_malformed_input(void) {
  printf("test_json_read_rejects_malformed_input\n");
  static le_json_value nodes[16];
  le_json_arena arena = {.nodes = nodes, .capacity = 16, .used = 0};
  CHECK(le_json_parse("{\"a\": }", &arena) == NULL);
  CHECK(le_json_parse("{\"a\": 1", &arena) == NULL); /* unterminated */
  CHECK(le_json_parse("[1, 2,]", &arena) == NULL);   /* trailing comma */
  CHECK(le_json_parse("not json", &arena) == NULL);
  CHECK(le_json_parse("", &arena) == NULL);
  CHECK(le_json_parse(NULL, &arena) == NULL);
}

static void test_json_read_arena_exhaustion_fails_cleanly(void) {
  printf("test_json_read_arena_exhaustion_fails_cleanly\n");
  /* Exactly 2 nodes' worth of capacity for a document that needs 3 (the
   * object plus two array elements) — parsing must fail, not overrun the
   * array or return a partially-built tree. */
  static le_json_value nodes[2];
  le_json_arena arena = {.nodes = nodes, .capacity = 2, .used = 0};
  CHECK(le_json_parse("[1, 2]", &arena) == NULL);
}

static void test_json_read_get_and_length_reject_non_objects(void) {
  printf("test_json_read_get_and_length_reject_non_objects\n");
  static le_json_value nodes[8];
  le_json_arena arena = {.nodes = nodes, .capacity = 8, .used = 0};
  le_json_value* array = le_json_parse("[1, 2, 3]", &arena);
  CHECK(array != NULL);
  CHECK(le_json_get(array, "x") == NULL); /* not an object */
  CHECK(le_json_length(array) == 3);      /* length still works on arrays */
  CHECK(le_json_at(array, 0) != NULL);
  CHECK(le_json_get(NULL, "x") == NULL);
  CHECK(le_json_length(NULL) == 0);
  CHECK(le_json_at(NULL, 0) == NULL);
}

/* ---- perf_render: the offline renderer (part 7) ----
 *
 * A native-only test cannot drive the full production pipeline (part 6's
 * armSnapshot/disarmSnapshot, the loops directory .wav files, and
 * finalized:true are all written by Dart's performance_repository, never by
 * this engine directly) — so these tests hand-construct a capture
 * directory's contents directly, mirroring exactly what that pipeline
 * produces (docs/design/performance-manifest-
 * format.md, docs/design/performance-event-log-format.md), then invoke the
 * renderer against the fixture and assert on its output stems. */

#if defined(_WIN32)
#include <direct.h> /* _mkdir */
#else
#include <sys/stat.h> /* mkdir */
#endif

static void test_render_mkdir(const char* path) {
#if defined(_WIN32)
  _mkdir(path);
#else
  mkdir(path, 0755);
#endif
}

static const char* render_test_dir(const char* name) {
  static char dir[600];
  snprintf(dir, sizeof(dir), "%s/render_%s_%d", perf_test_dir(), name,
          (int)test_getpid());
  test_render_mkdir(dir);
  return dir;
}

/* Writes `samples` as a 32-bit float mono WAV — the same fixed format
 * wav_codec/perf_render.c's own reader expects. */
static void test_write_wav_mono(const char* path, const float* samples,
                                int32_t count, int32_t sample_rate) {
  FILE* f = fopen(path, "wb");
  CHECK(f != NULL);
  if (f == NULL) return;
  unsigned char header[44] = {0};
  memcpy(header + 0, "RIFF", 4);
  const uint32_t data_bytes = (uint32_t)count * (uint32_t)sizeof(float);
  const uint32_t riff_size = 36 + data_bytes;
  memcpy(header + 4, &riff_size, 4);
  memcpy(header + 8, "WAVE", 4);
  memcpy(header + 12, "fmt ", 4);
  const uint32_t fmt_size = 16;
  memcpy(header + 16, &fmt_size, 4);
  const uint16_t format_code = 3;
  memcpy(header + 20, &format_code, 2);
  const uint16_t channels = 1;
  memcpy(header + 22, &channels, 2);
  const uint32_t sr = (uint32_t)sample_rate;
  memcpy(header + 24, &sr, 4);
  const uint32_t byte_rate = sr * (uint32_t)sizeof(float);
  memcpy(header + 28, &byte_rate, 4);
  const uint16_t block_align = (uint16_t)sizeof(float);
  memcpy(header + 32, &block_align, 2);
  const uint16_t bits = 32;
  memcpy(header + 34, &bits, 2);
  memcpy(header + 36, "data", 4);
  memcpy(header + 40, &data_bytes, 4);
  fwrite(header, 1, sizeof(header), f);
  fwrite(samples, sizeof(float), (size_t)count, f);
  fclose(f);
}

static void test_write_raw_pcm_mono(const char* path, const float* samples,
                                    int32_t count) {
  FILE* f = fopen(path, "wb");
  CHECK(f != NULL);
  if (f == NULL) return;
  fwrite(samples, sizeof(float), (size_t)count, f);
  fclose(f);
}

static void test_write_log_header(FILE* f, int32_t sample_rate) {
  fwrite("PLEV", 1, 4, f);
  const uint32_t version = 1;
  fwrite(&version, 4, 1, f);
  fwrite(&sample_rate, 4, 1, f);
}

/* Writes one 28-byte events.log entry, matching perf_drain.c's own encoding
 * exactly (frame, code, then the union's 16-byte payload region). */
static void test_write_log_entry(FILE* f, uint64_t frame, le_command cmd) {
  fwrite(&frame, 8, 1, f);
  fwrite(&cmd.code, 4, 1, f);
  fwrite(((unsigned char*)&cmd) + 4, 16, 1, f);
}

static void test_write_manifest(const char* dir, const char* body) {
  char path[700];
  snprintf(path, sizeof(path), "%s/performance.json", dir);
  FILE* f = fopen(path, "wb");
  CHECK(f != NULL);
  if (f == NULL) return;
  fwrite(body, 1, strlen(body), f);
  fclose(f);
}

/* Shared fixed-format WAV reader backing test_read_stem/test_read_wet_stem/
 * test_read_master_stem below: reads a 44-byte canonical WAV header written
 * by le_pr_write_wav_mono, then up to `out_cap` float samples, returning the
 * frame count actually read (0 if the file is missing/unreadable). */
static int32_t test_read_wav_fixed(const char* path, float* out, int32_t out_cap) {
  FILE* f = fopen(path, "rb");
  if (f == NULL) return 0;
  unsigned char header[44];
  if (fread(header, 1, sizeof(header), f) != sizeof(header)) {
    fclose(f);
    return 0;
  }
  uint32_t data_bytes;
  memcpy(&data_bytes, header + 40, 4);
  const int32_t frames = (int32_t)(data_bytes / sizeof(float));
  const int32_t n = frames < out_cap ? frames : out_cap;
  const size_t got = fread(out, sizeof(float), (size_t)n, f);
  fclose(f);
  return (int32_t)got;
}

/* Reads track `channel`'s rendered dry stem and returns its frame count (0 if
 * the file is missing/unreadable), filling `out` (caller-sized) with its
 * samples. */
static int32_t test_read_stem(const char* dir, int32_t channel, float* out,
                              int32_t out_cap) {
  char path[700];
  snprintf(path, sizeof(path), "%s/stems/dry/track%d.wav", dir, channel);
  return test_read_wav_fixed(path, out, out_cap);
}

/* Polls until the render finishes or `max_polls` is exceeded (each poll ~1ms
 * apart) — a real worker thread, not a synchronous call. */
static void test_wait_for_render(le_engine* e, int max_polls) {
  for (int i = 0; i < max_polls; ++i) {
    int32_t done = 0;
    le_perf_render_poll(e, &done, NULL, NULL);
    if (done) return;
    test_sleep_ms(1);
  }
}

/* Acceptance: a scripted log (record -> play -> mute -> volume ride -> stop)
 * renders a dry stem whose boundaries land at the exact logged frames. The
 * non-content events (mute/volume/stop) must not corrupt the timeline — the
 * dry stem is unity-gain loop content only (volume/mute are automation for
 * the .als generator, parts 9-10, not baked into stem audio). */
static void test_perf_render_scripted_log_boundaries(void) {
  printf("test_perf_render_scripted_log_boundaries\n");
  const char* dir = render_test_dir("scripted");
  const int32_t sr = 4800;
  const int32_t loop_len = 4;
  const uint64_t capture_frames = 20;

  char loops_dir[700];
  snprintf(loops_dir, sizeof(loops_dir), "%s/loops", dir);
  test_render_mkdir(loops_dir);

  const float base[4] = {1.0f, 1.0f, 1.0f, 1.0f};
  char wav_path[700];
  snprintf(wav_path, sizeof(wav_path), "%s/track0-lane0.wav", loops_dir);
  test_write_wav_mono(wav_path, base, loop_len, sr);

  char manifest[2048];
  snprintf(manifest, sizeof(manifest),
          "{\"sample_rate\": %d, \"capture_frames\": %llu, "
          "\"armSnapshot\": {\"tracks\": [{\"channel\": 0, \"lanes\": "
          "[{\"lane\": 0, \"deferred\": false, \"pcmRef\": "
          "\"loops/track0-lane0.wav\"}]}]}, "
          "\"disarmSnapshot\": {\"tracks\": []}, \"layers\": []}",
          sr, (unsigned long long)capture_frames);
  test_write_manifest(dir, manifest);

  char log_path[700];
  snprintf(log_path, sizeof(log_path), "%s/events.log", dir);
  FILE* lf = fopen(log_path, "wb");
  CHECK(lf != NULL);
  if (lf != NULL) {
    test_write_log_header(lf, sr);
    test_write_log_entry(
        lf, 2, (le_command){.code = LE_CMD_PLAY, .arg_i = 0, .arg_f = 0});
    test_write_log_entry(
        lf, 8, (le_command){.code = LE_CMD_SET_MUTE, .arg_i = 0, .arg_f = 1});
    test_write_log_entry(lf, 12,
                        (le_command){.code = LE_CMD_SET_VOLUME,
                                    .arg_i = 0,
                                    .arg_f = 0.3f});
    test_write_log_entry(
        lf, 18, (le_command){.code = LE_CMD_STOP, .arg_i = 0, .arg_f = 0});
    fclose(lf);
  }

  le_engine* e = le_engine_create();
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 2000);

  int32_t done = 0, progress = 0, track_count = 0;
  CHECK(le_perf_render_poll(e, &done, &progress, &track_count) == LE_OK);
  CHECK(done == 1);
  CHECK(progress == 100);
  CHECK(track_count == 1);
  int32_t channel = -1, succeeded = 0;
  CHECK(le_perf_render_track_status(e, 0, &channel, &succeeded) == LE_OK);
  CHECK(channel == 0);
  CHECK(succeeded == 1);

  float stem[20];
  const int32_t got = test_read_stem(dir, 0, stem, 20);
  CHECK(got == (int32_t)capture_frames);
  /* Unity-gain, looped base content for the WHOLE capture window — mute/
   * volume/stop never touch the stem's samples. */
  for (int32_t i = 0; i < got; ++i) {
    CHECK(fabsf(stem[i] - 1.0f) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* Shared body for the overdub-pass stitching contract, parameterized by loop
 * length (#227 runs it beyond one quantum) and the arm-time loop phase
 * (`clock_frame`, armSnapshot.clockFrame — #255 runs it nonzero). Track
 * settled at arm with a base RAMP image; one retired-layer ramp (offset by
 * +2) activates at `retire_frame` — not one loop cycle earlier: a punch-out
 * mid-cycle retires via an async, chunked drain that can land arbitrarily
 * later than "punch-in + one cycle", so the logged retire frame itself is
 * the only value this capture can trust. Frames before it play the pre-pass
 * image; frames from it onward play the retired layer — both PHASE-LOCKED
 * (#255): a layer image is loop-position-indexed and the loop phase is one
 * continuous counter across the capture, so every frame plays
 * image[(clock_frame + f) % loop_len], exactly what the performer heard.
 * Ramps (not constants) so a renderer that indexes an image modulo the
 * wrong length (e.g. one quantum) or from the wrong phase (segment-relative
 * index 0, the pre-#255 bug) reads a DIFFERENT sample and fails loudly — a
 * constant fill would return the right value from the wrong index. Ramp
 * steps are exact in float32 (the fixture wav is format-3 float), so
 * comparisons stay bitwise against the very buffers the fixtures were
 * written from. */
static void run_perf_render_stitching_case(const char* name, int32_t sr,
                                           int32_t loop_len,
                                           uint64_t capture_frames,
                                           uint64_t retire_frame,
                                           uint64_t clock_frame,
                                           int wait_polls) {
  const char* dir = render_test_dir(name);
  char loops_dir[700];
  snprintf(loops_dir, sizeof(loops_dir), "%s/loops", dir);
  test_render_mkdir(loops_dir);

  float* pre = malloc((size_t)loop_len * sizeof(float));
  float* post = malloc((size_t)loop_len * sizeof(float));
  float* stem = malloc((size_t)capture_frames * sizeof(float));
  CHECK(pre != NULL && post != NULL && stem != NULL);
  if (pre == NULL || post == NULL || stem == NULL) {
    free(pre);
    free(post);
    free(stem);
    return;
  }
  for (int32_t i = 0; i < loop_len; ++i) {
    pre[i] = 0.25f + (float)(i & 1023) * (1.0f / 2048.0f); /* [0.25, 0.75) */
    post[i] = 2.0f + (float)(i & 1023) * (1.0f / 2048.0f); /* [2.0, 2.5) */
  }

  char wav_path[700];
  snprintf(wav_path, sizeof(wav_path), "%s/track0-lane0.wav", loops_dir);
  test_write_wav_mono(wav_path, pre, loop_len, sr);

  char layer_name[64];
  snprintf(layer_name, sizeof(layer_name), "layer-%s.pcm", name);
  char layer_path[700];
  snprintf(layer_path, sizeof(layer_path), "%s/%s", dir, layer_name);
  test_write_raw_pcm_mono(layer_path, post, loop_len);

  char manifest[2048];
  snprintf(manifest, sizeof(manifest),
           "{\"sample_rate\": %d, \"capture_frames\": %llu, "
           "\"armSnapshot\": {\"clockFrame\": %llu, \"tracks\": "
           "[{\"channel\": 0, \"lanes\": "
           "[{\"lane\": 0, \"deferred\": false, \"pcmRef\": "
           "\"loops/track0-lane0.wav\"}]}]}, "
           "\"disarmSnapshot\": {\"tracks\": []}, "
           "\"layers\": [{\"channel\": 0, \"slot\": 1, \"generation\": 0, "
           "\"frame\": %llu, \"frame_count\": %d, \"lane_count\": 1, "
           "\"filename\": \"%s\"}]}",
           sr, (unsigned long long)capture_frames,
           (unsigned long long)clock_frame,
           (unsigned long long)retire_frame, loop_len, layer_name);
  test_write_manifest(dir, manifest);

  char log_path[700];
  snprintf(log_path, sizeof(log_path), "%s/events.log", dir);
  FILE* lf = fopen(log_path, "wb");
  CHECK(lf != NULL);
  if (lf != NULL) {
    test_write_log_header(lf, sr);
    test_write_log_entry(
        lf, retire_frame,
        (le_command){.code = LE_PLOG_LAYER_RETIRED,
                     .evt = {.channel = 0, .slot = 1, .generation = 0}});
    fclose(lf);
  }

  le_engine* e = le_engine_create();
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, wait_polls);

  const int32_t got = test_read_stem(dir, 0, stem, (int32_t)capture_frames);
  CHECK(got == (int32_t)capture_frames);
  /* Phase-locked segment semantics (#255, le_pr_append_segment / the stitch
   * loop in perf_render.c): every segment plays its loop-position-indexed
   * image from the phase live playback had actually reached — the arm image
   * from `clock_frame` at capture frame 0, and the retired layer from the
   * phase the loop was at when the retire activated — so every frame is
   * image[(clock_frame + f) % loop_len], exactly what the performer heard.
   * The pre-#255 renderer instead restarted each segment at its own index 0
   * (`pos = (f - start) % image_len`), rotating every mid-cycle retire by
   * the retire phase; the ramp fill fails loudly on both that rotation and
   * a modulo-one-quantum indexing wrap. */
  int bad = 0;
  for (uint64_t f = 0; f < retire_frame && f < capture_frames; ++f) {
    if (stem[f] != pre[(clock_frame + f) % (uint64_t)loop_len]) {
      bad++; /* pre-pass image, phase-locked to the arm clock */
    }
  }
  for (uint64_t f = retire_frame; f < capture_frames; ++f) {
    if (stem[f] != post[(clock_frame + f) % (uint64_t)loop_len]) {
      bad++; /* retired layer, phase-locked continuation */
    }
  }
  CHECK(bad == 0);

  free(pre);
  free(post);
  free(stem);
  le_engine_destroy(e);
}

static void test_perf_render_overdub_stitching(void) {
  printf("test_perf_render_overdub_stitching\n");
  /* retire_frame 10 is deliberately mid-cycle (10 % 4 == 2, phase 2): a
   * boundary retire (phase 0) could not tell phase-locked stitching from
   * the pre-#255 segment-relative rotation. Armed at phase 0. */
  run_perf_render_stitching_case("stitch", 4800, 4, 16, 10, 0, 2000);
}

/* The same contract at a loop longer than one quantum (#227): the pre-pass
 * image, the retired layer, and the stem writer all size and index by the
 * real loop length — a one-quantum image buffer would truncate (loud under
 * ASAN), and the ramp fill catches a modulo-one-quantum indexing wrap that
 * stays in bounds. The retire lands mid-cycle (phase 1234), so this also
 * exercises the #255 phase lock beyond one quantum. */
static void test_perf_render_stitching_long_loop(void) {
  printf("test_perf_render_stitching_long_loop\n");
  const int32_t loop_len = LE_LAYER_QUANTUM + 2000;
  run_perf_render_stitching_case("stitch_long", 48000, loop_len,
                                 (uint64_t)loop_len * 2,
                                 (uint64_t)loop_len + 1234, 0, 20000);
}

/* The #255 sibling gap: a capture armed MID-LOOP against an already-playing
 * track (armSnapshot.clockFrame != 0). The arm image must play from
 * clockFrame at capture frame 0 — pre[(6 + f) % 4], i.e. arm phase 2 — and
 * the mid-cycle retire at frame 9 must inherit the chained phase
 * ((6 + 9) % 4 == 3), locking the whole stem to the live phase counter. */
static void test_perf_render_stitching_mid_loop_arm(void) {
  printf("test_perf_render_stitching_mid_loop_arm\n");
  run_perf_render_stitching_case("stitch_armphase", 4800, 4, 16, 9, 6, 2000);
}

/* Acceptance: a track recorded fresh while armed (absent from armSnapshot,
 * present only in disarmSnapshot) renders silence up to its logged
 * RECORD_END frame, then the disarm-snapshot content, looped. */
static void test_perf_render_fresh_recorded_while_armed(void) {
  printf("test_perf_render_fresh_recorded_while_armed\n");
  const char* dir = render_test_dir("fresh");
  const int32_t sr = 4800;
  const int32_t loop_len = 4;
  const uint64_t capture_frames = 12;
  const uint64_t record_end = 4;

  char loops_dir[700];
  snprintf(loops_dir, sizeof(loops_dir), "%s/loops", dir);
  test_render_mkdir(loops_dir);

  const float content[4] = {0.5f, 0.5f, 0.5f, 0.5f};
  char wav_path[700];
  snprintf(wav_path, sizeof(wav_path), "%s/track1-lane0.wav", loops_dir);
  test_write_wav_mono(wav_path, content, loop_len, sr);

  char manifest[2048];
  snprintf(manifest, sizeof(manifest),
          "{\"sample_rate\": %d, \"capture_frames\": %llu, "
          "\"armSnapshot\": {\"tracks\": []}, "
          "\"disarmSnapshot\": {\"tracks\": [{\"channel\": 1, \"lanes\": "
          "[{\"lane\": 0, \"deferred\": false, \"pcmRef\": "
          "\"loops/track1-lane0.wav\"}]}]}, \"layers\": []}",
          sr, (unsigned long long)capture_frames);
  test_write_manifest(dir, manifest);

  char log_path[700];
  snprintf(log_path, sizeof(log_path), "%s/events.log", dir);
  FILE* lf = fopen(log_path, "wb");
  CHECK(lf != NULL);
  if (lf != NULL) {
    test_write_log_header(lf, sr);
    test_write_log_entry(
        lf, record_end,
        (le_command){.code = LE_PLOG_RECORD_END, .arg_i = 1, .arg_f = 0});
    fclose(lf);
  }

  le_engine* e = le_engine_create();
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 2000);

  float stem[12];
  const int32_t got = test_read_stem(dir, 1, stem, 12);
  CHECK(got == (int32_t)capture_frames);
  for (uint64_t f = 0; f < record_end; ++f) {
    CHECK(fabsf(stem[f]) < 1e-6f); /* silent while recording */
  }
  for (uint64_t f = record_end; f < capture_frames; ++f) {
    CHECK(fabsf(stem[f] - 0.5f) < 1e-6f); /* disarm-snapshot content, looped */
  }

  le_engine_destroy(e);
}

/* Acceptance: progress is monotonic 0-100 and reaches done; cancel stops the
 * worker within one work chunk (join returns promptly) and leaves no partial
 * stem file for whichever track was in flight. */
static void test_perf_render_progress_and_cancel(void) {
  printf("test_perf_render_progress_and_cancel\n");
  const char* dir = render_test_dir("progress");
  const int32_t sr = 4800;
  const int32_t loop_len = 4;

  char loops_dir[700];
  snprintf(loops_dir, sizeof(loops_dir), "%s/loops", dir);
  test_render_mkdir(loops_dir);

  const float content[4] = {0.25f, 0.25f, 0.25f, 0.25f};
  char manifest_tracks[4096];
  int off = 0;
  for (int ch = 0; ch < 4; ++ch) {
    char wav_path[700];
    snprintf(wav_path, sizeof(wav_path), "%s/track%d-lane0.wav", loops_dir, ch);
    test_write_wav_mono(wav_path, content, loop_len, sr);
    off += snprintf(manifest_tracks + off, sizeof(manifest_tracks) - (size_t)off,
                   "%s{\"channel\": %d, \"lanes\": [{\"lane\": 0, "
                   "\"deferred\": false, \"pcmRef\": "
                   "\"loops/track%d-lane0.wav\"}]}",
                   ch == 0 ? "" : ", ", ch, ch);
  }

  char manifest[8192];
  snprintf(manifest, sizeof(manifest),
          "{\"sample_rate\": %d, \"capture_frames\": %d, "
          "\"armSnapshot\": {\"tracks\": [%s]}, "
          "\"disarmSnapshot\": {\"tracks\": []}, \"layers\": []}",
          sr, loop_len, manifest_tracks);
  test_write_manifest(dir, manifest);

  char log_path[700];
  snprintf(log_path, sizeof(log_path), "%s/events.log", dir);
  FILE* lf = fopen(log_path, "wb");
  CHECK(lf != NULL);
  if (lf != NULL) {
    test_write_log_header(lf, sr);
    fclose(lf);
  }

  /* Run 1: let it run to completion, sampling progress along the way. */
  le_engine* e1 = le_engine_create();
  CHECK(le_perf_render_begin(e1, dir) == LE_OK);
  int32_t last_progress = -1;
  int32_t done = 0;
  for (int i = 0; i < 2000 && !done; ++i) {
    int32_t p = 0;
    le_perf_render_poll(e1, &done, &p, NULL);
    CHECK(p >= last_progress); /* monotonic */
    last_progress = p;
    if (!done) test_sleep_ms(1);
  }
  CHECK(done == 1);
  CHECK(last_progress == 100);
  le_engine_destroy(e1);

  /* Run 2: cancel immediately; the worker must stop and join without
   * hanging, and le_perf_render_begin on a fresh engine (a fresh capture
   * dir's worth of state, same fixture) must still work afterward — this
   * only proves cancel's join is well-behaved, not a specific partial-file
   * guarantee (which would need pausing the worker mid-chunk, not exercised
   * here). */
  le_engine* e2 = le_engine_create();
  CHECK(le_perf_render_begin(e2, dir) == LE_OK);
  CHECK(le_perf_render_cancel(e2) == LE_OK);
  int32_t done2 = 0;
  le_perf_render_poll(e2, &done2, NULL, NULL);
  CHECK(done2 == 1); /* no render active: poll reports done */
  le_engine_destroy(e2);
}

/* Acceptance: a render runs correctly while the SAME engine keeps processing
 * live audio — no interaction (the render thread never touches live engine
 * state; the audio thread never touches the render handle). */
static void test_perf_render_concurrent_with_live_engine(void) {
  printf("test_perf_render_concurrent_with_live_engine\n");
  const char* dir = render_test_dir("concurrent");
  const int32_t sr = 4800;
  const int32_t loop_len = 4;

  char loops_dir[700];
  snprintf(loops_dir, sizeof(loops_dir), "%s/loops", dir);
  test_render_mkdir(loops_dir);
  const float content[4] = {1.0f, 1.0f, 1.0f, 1.0f};
  char wav_path[700];
  snprintf(wav_path, sizeof(wav_path), "%s/track0-lane0.wav", loops_dir);
  test_write_wav_mono(wav_path, content, loop_len, sr);

  char manifest[2048];
  snprintf(manifest, sizeof(manifest),
          "{\"sample_rate\": %d, \"capture_frames\": %d, "
          "\"armSnapshot\": {\"tracks\": [{\"channel\": 0, \"lanes\": "
          "[{\"lane\": 0, \"deferred\": false, \"pcmRef\": "
          "\"loops/track0-lane0.wav\"}]}]}, "
          "\"disarmSnapshot\": {\"tracks\": []}, \"layers\": []}",
          sr, loop_len);
  test_write_manifest(dir, manifest);
  char log_path[700];
  snprintf(log_path, sizeof(log_path), "%s/events.log", dir);
  FILE* lf = fopen(log_path, "wb");
  CHECK(lf != NULL);
  if (lf != NULL) {
    test_write_log_header(lf, sr);
    fclose(lf);
  }

  le_engine* live = make_configured_engine();
  record_base_loop(live, 1.0f);
  le_snapshot before;
  le_engine_get_snapshot(live, &before);

  le_engine* renderer = le_engine_create();
  CHECK(le_perf_render_begin(renderer, dir) == LE_OK);

  float out[LOOP_N];
  process_const(live, 0.0f, LOOP_N, out);
  for (int i = 0; i < LOOP_N; ++i) CHECK(fabsf(out[i] - 1.0f) < 1e-6f);

  test_wait_for_render(renderer, 2000);
  int32_t done = 0;
  le_perf_render_poll(renderer, &done, NULL, NULL);
  CHECK(done == 1);

  le_snapshot after;
  le_engine_get_snapshot(live, &after);
  CHECK(after.tracks[0].state == before.tracks[0].state);
  CHECK(after.tracks[0].length_frames == before.tracks[0].length_frames);

  le_engine_destroy(live);
  le_engine_destroy(renderer);
}

/* Acceptance: a per-stem failure (an unreadable pcmRef) yields partial
 * success — the render still completes, reporting that one track failed
 * while the other succeeded, rather than aborting the whole render. */
static void test_perf_render_partial_success(void) {
  printf("test_perf_render_partial_success\n");
  const char* dir = render_test_dir("partial");
  const int32_t sr = 4800;
  const int32_t loop_len = 4;

  char loops_dir[700];
  snprintf(loops_dir, sizeof(loops_dir), "%s/loops", dir);
  test_render_mkdir(loops_dir);
  const float content[4] = {1.0f, 1.0f, 1.0f, 1.0f};
  char wav_path[700];
  snprintf(wav_path, sizeof(wav_path), "%s/track0-lane0.wav", loops_dir);
  test_write_wav_mono(wav_path, content, loop_len, sr);
  /* track1's pcmRef deliberately points at a file that does not exist. */

  char manifest[2048];
  snprintf(manifest, sizeof(manifest),
          "{\"sample_rate\": %d, \"capture_frames\": %d, "
          "\"armSnapshot\": {\"tracks\": ["
          "{\"channel\": 0, \"lanes\": [{\"lane\": 0, \"deferred\": false, "
          "\"pcmRef\": \"loops/track0-lane0.wav\"}]}, "
          "{\"channel\": 1, \"lanes\": [{\"lane\": 0, \"deferred\": false, "
          "\"pcmRef\": \"loops/track1-lane0.wav\"}]}]}, "
          "\"disarmSnapshot\": {\"tracks\": []}, \"layers\": []}",
          sr, loop_len);
  test_write_manifest(dir, manifest);
  char log_path[700];
  snprintf(log_path, sizeof(log_path), "%s/events.log", dir);
  FILE* lf = fopen(log_path, "wb");
  CHECK(lf != NULL);
  if (lf != NULL) {
    test_write_log_header(lf, sr);
    fclose(lf);
  }

  le_engine* e = le_engine_create();
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 2000);

  int32_t done = 0, track_count = 0;
  le_perf_render_poll(e, &done, NULL, &track_count);
  CHECK(done == 1);
  CHECK(track_count == 2);

  int good = 0, bad = 0;
  for (int i = 0; i < track_count; ++i) {
    int32_t channel = -1, succeeded = -1;
    CHECK(le_perf_render_track_status(e, i, &channel, &succeeded) == LE_OK);
    if (channel == 0) {
      CHECK(succeeded == 1);
      good++;
    } else if (channel == 1) {
      CHECK(succeeded == 0);
      bad++;
    }
  }
  CHECK(good == 1);
  CHECK(bad == 1);
  CHECK(test_read_stem(dir, 0, (float[4]){0}, 4) == loop_len);

  le_engine_destroy(e);
}

/* Acceptance (robustness): pointing a render at a directory with no
 * performance.json (or, separately, a corrupt one) must not hang or crash —
 * the worker should reach `done` with zero tracks, matching a render that
 * legitimately has nothing to do. */
static void test_perf_render_missing_or_corrupt_manifest(void) {
  printf("test_perf_render_missing_or_corrupt_manifest\n");

  const char* missing_dir = render_test_dir("missing-manifest");
  le_engine* e1 = le_engine_create();
  CHECK(le_perf_render_begin(e1, missing_dir) == LE_OK);
  test_wait_for_render(e1, 2000);
  int32_t done = 0, track_count = -1;
  CHECK(le_perf_render_poll(e1, &done, NULL, &track_count) == LE_OK);
  CHECK(done == 1);
  CHECK(track_count == 0);
  le_engine_destroy(e1);

  const char* corrupt_dir = render_test_dir("corrupt-manifest");
  test_write_manifest(corrupt_dir, "{not valid json");
  le_engine* e2 = le_engine_create();
  CHECK(le_perf_render_begin(e2, corrupt_dir) == LE_OK);
  test_wait_for_render(e2, 2000);
  done = 0;
  track_count = -1;
  CHECK(le_perf_render_poll(e2, &done, NULL, &track_count) == LE_OK);
  CHECK(done == 1);
  CHECK(track_count == 0);
  le_engine_destroy(e2);
}

/* ---- perf_render: the wet pass + master reconstruction (part 8) ---- */

/* Reads track `channel`'s rendered WET stem (as opposed to test_read_stem's
 * dry stem), same fixed-format WAV reader convention. */
static int32_t test_read_wet_stem(const char* dir, int32_t channel, float* out,
                                  int32_t out_cap) {
  char path[700];
  snprintf(path, sizeof(path), "%s/stems/wet/track%d.wav", dir, channel);
  return test_read_wav_fixed(path, out, out_cap);
}

/* Reads the reconstructed master (stems/wet/master.wav), same fixed-format
 * WAV reader convention as test_read_wet_stem. */
static int32_t test_read_master_stem(const char* dir, float* out,
                                     int32_t out_cap) {
  char path[700];
  snprintf(path, sizeof(path), "%s/stems/wet/master.wav", dir);
  return test_read_wav_fixed(path, out, out_cap);
}

/* Acceptance: a chain with a mid-performance param sweep renders the sweep
 * at the logged frames. DRIVE (stateless: tanhf(x*drive)*level, no memory
 * across samples) is chosen deliberately so the expected output at every
 * frame is a pure, hand-computable function of that frame's own params —
 * no DSP internals to approximate. armSnapshot seeds the chain already
 * engaged (so the arm-time param values apply to the FIRST few frames, not
 * defaults); one LE_PLOG_SET_LANE_FX_PARAM sweeps `drive` mid-capture. */
static void test_perf_render_wet_fx_sweep(void) {
  printf("test_perf_render_wet_fx_sweep\n");
  const char* dir = render_test_dir("wet-sweep");
  const int32_t sr = 4800;
  const int32_t loop_len = 4;
  const uint64_t capture_frames = 12;
  const uint64_t sweep_frame = 6;
  const float dry_value = 0.5f;
  const float drive0 = 0.2f, level0 = 0.6f;
  const float drive1 = 0.9f, level1 = 0.6f;

  char loops_dir[700];
  snprintf(loops_dir, sizeof(loops_dir), "%s/loops", dir);
  test_render_mkdir(loops_dir);
  const float base[4] = {dry_value, dry_value, dry_value, dry_value};
  char wav_path[700];
  snprintf(wav_path, sizeof(wav_path), "%s/track0-lane0.wav", loops_dir);
  test_write_wav_mono(wav_path, base, loop_len, sr);

  char manifest[2048];
  snprintf(manifest, sizeof(manifest),
          "{\"sample_rate\": %d, \"capture_frames\": %llu, "
          "\"armSnapshot\": {\"masterGain\": 1.0, \"limiterOn\": false, "
          "\"limiterCeiling\": 0.99, \"tracks\": [{\"channel\": 0, "
          "\"volume\": 1.0, \"muted\": false, \"lanes\": [{\"lane\": 0, "
          "\"deferred\": false, \"pcmRef\": \"loops/track0-lane0.wav\", "
          "\"effects\": [{\"type\": 1, \"params\": [%f, %f, 0.0, 0.0]}]}]}]}, "
          "\"disarmSnapshot\": {\"tracks\": []}, \"layers\": []}",
          sr, (unsigned long long)capture_frames, (double)drive0,
          (double)level0);
  test_write_manifest(dir, manifest);

  char log_path[700];
  snprintf(log_path, sizeof(log_path), "%s/events.log", dir);
  FILE* lf = fopen(log_path, "wb");
  CHECK(lf != NULL);
  if (lf != NULL) {
    test_write_log_header(lf, sr);
    /* fx.index packs (slot << 8 | param); fx.type carries the float value
     * bit-cast to int32 (LE_PLOG_SET_LANE_FX_PARAM, perf_log_ring.h). */
    uint32_t drive_bits;
    memcpy(&drive_bits, &drive1, sizeof(drive_bits));
    test_write_log_entry(
        lf, sweep_frame,
        (le_command){.code = LE_PLOG_SET_LANE_FX_PARAM,
                    .fx = {0, 0, LE_PLOG_FX_PARAM_PACK(0, 0),
                            (int32_t)drive_bits}});
    fclose(lf);
  }

  le_engine* e = le_engine_create();
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 2000);
  int32_t done = 0;
  CHECK(le_perf_render_poll(e, &done, NULL, NULL) == LE_OK);
  CHECK(done == 1);

  float wet[16];
  const int32_t got = test_read_wet_stem(dir, 0, wet, 16);
  CHECK(got == (int32_t)capture_frames);
  for (int32_t i = 0; i < got; ++i) {
    const float drive = (uint64_t)i < sweep_frame ? drive0 : drive1;
    const float level = (uint64_t)i < sweep_frame ? level0 : level1;
    const float expected = tanhf(dry_value * (1.0f + drive * 29.0f)) * level;
    CHECK(fabsf(wet[i] - expected) < 1e-5f);
  }

  le_engine_destroy(e);
}

/* Regression: a dry-stem write failure must exclude that channel's wet
 * content from master.wav even when the wet write for the SAME channel
 * succeeds. Before this fix, the master-accumulation gate in
 * le_pr_worker_main checked `wet_ok` alone, so a dry-write failure paired
 * with a wet-write success still baked that channel's audio into
 * master.wav despite le_perf_render_track_status correctly reporting the
 * channel as failed — violating the "check every track's status before
 * trusting master.wav" contract the surrounding code documents. Forcing
 * only the dry write to fail (le_perf_render_force_dry_write_failure_for_test)
 * leaves the wet write's real filesystem I/O untouched, reproducing that
 * exact scenario deterministically. */
static void test_perf_render_dry_write_fail_excludes_from_master(void) {
  printf("test_perf_render_dry_write_fail_excludes_from_master\n");
  const char* dir = render_test_dir("dry-fail-master");
  const int32_t sr = 4800;
  const int32_t loop_len = 4;
  const uint64_t capture_frames = 4;

  char loops_dir[700];
  snprintf(loops_dir, sizeof(loops_dir), "%s/loops", dir);
  test_render_mkdir(loops_dir);
  const float content[4] = {0.5f, 0.5f, 0.5f, 0.5f};
  char wav_path[700];
  snprintf(wav_path, sizeof(wav_path), "%s/track0-lane0.wav", loops_dir);
  test_write_wav_mono(wav_path, content, loop_len, sr);

  char manifest[1200];
  snprintf(manifest, sizeof(manifest),
          "{\"sample_rate\": %d, \"capture_frames\": %llu, "
          "\"armSnapshot\": {\"masterGain\": 1.0, \"limiterOn\": false, "
          "\"limiterCeiling\": 0.99, \"tracks\": [{\"channel\": 0, "
          "\"volume\": 1.0, \"muted\": false, \"lanes\": [{\"lane\": 0, "
          "\"deferred\": false, \"pcmRef\": \"loops/track0-lane0.wav\", "
          "\"effects\": []}]}]}, "
          "\"disarmSnapshot\": {\"tracks\": []}, \"layers\": []}",
          sr, (unsigned long long)capture_frames);
  test_write_manifest(dir, manifest);

  char log_path[700];
  snprintf(log_path, sizeof(log_path), "%s/events.log", dir);
  FILE* lf = fopen(log_path, "wb");
  CHECK(lf != NULL);
  if (lf != NULL) {
    test_write_log_header(lf, sr);
    fclose(lf);
  }

  le_perf_render_force_dry_write_failure_for_test(0); /* fail channel 0's dry write */

  le_engine* e = le_engine_create();
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 2000);

  le_perf_render_force_dry_write_failure_for_test(-1); /* reset before other tests run */

  int32_t done = 0, track_count = 0;
  CHECK(le_perf_render_poll(e, &done, NULL, &track_count) == LE_OK);
  CHECK(done == 1);
  CHECK(track_count == 1);

  int32_t channel = -1, succeeded = -1;
  CHECK(le_perf_render_track_status(e, 0, &channel, &succeeded) == LE_OK);
  CHECK(channel == 0);
  CHECK(succeeded == 0); /* the dry write was forced to fail */

  /* The wet stem write itself is unaffected by the forced dry failure and
   * still lands on disk with real content. */
  float wet[4];
  const int32_t wet_got = test_read_wet_stem(dir, 0, wet, 4);
  CHECK(wet_got == (int32_t)capture_frames);
  for (int32_t i = 0; i < wet_got; ++i) {
    CHECK(fabsf(wet[i] - 0.5f) < 1e-5f);
  }

  /* ...but master.wav must NOT contain it: this channel's `ok` is 0 (the
   * dry write failed), so the fixed gate (`if (ok && ...)`) must exclude it
   * from the master sum even though wet_ok was 1. Before the fix (gating on
   * `wet_ok` alone) this would have been 0.5f, not 0.0f. */
  float master[4];
  const int32_t master_got =
      test_read_master_stem(dir, master, (int32_t)capture_frames);
  CHECK(master_got == (int32_t)capture_frames);
  for (int32_t i = 0; i < master_got; ++i) {
    CHECK(master[i] == 0.0f);
  }

  le_engine_destroy(e);
}

/* Regression (isolation): in a MULTI-channel render, forcing one channel's
 * dry write to fail must exclude only that channel from master.wav — a
 * second, healthy channel rendered in the same pass must still succeed and
 * still land correctly in master.wav. This is the channel-selective
 * counterpart to test_perf_render_dry_write_fail_excludes_from_master (which
 * only proves the single-channel case): the earlier single-channel test
 * cannot distinguish a per-channel gate from a process-wide one, since
 * failing "every channel" and failing "the only channel" look identical. */
static void test_perf_render_multi_channel_dry_fail_isolated(void) {
  printf("test_perf_render_multi_channel_dry_fail_isolated\n");
  const char* dir = render_test_dir("dry-fail-multi");
  const int32_t sr = 4800;
  const int32_t loop_len = 4;
  const uint64_t capture_frames = 4;
  const float healthy_value = 0.4f;
  const float failing_value = 0.3f;

  char loops_dir[700];
  snprintf(loops_dir, sizeof(loops_dir), "%s/loops", dir);
  test_render_mkdir(loops_dir);
  const float content0[4] = {healthy_value, healthy_value, healthy_value,
                             healthy_value};
  char wav_path0[700];
  snprintf(wav_path0, sizeof(wav_path0), "%s/track0-lane0.wav", loops_dir);
  test_write_wav_mono(wav_path0, content0, loop_len, sr);
  const float content1[4] = {failing_value, failing_value, failing_value,
                             failing_value};
  char wav_path1[700];
  snprintf(wav_path1, sizeof(wav_path1), "%s/track1-lane0.wav", loops_dir);
  test_write_wav_mono(wav_path1, content1, loop_len, sr);

  char manifest[1500];
  snprintf(manifest, sizeof(manifest),
          "{\"sample_rate\": %d, \"capture_frames\": %llu, "
          "\"armSnapshot\": {\"masterGain\": 1.0, \"limiterOn\": false, "
          "\"limiterCeiling\": 0.99, \"tracks\": ["
          "{\"channel\": 0, \"volume\": 1.0, \"muted\": false, "
          "\"lanes\": [{\"lane\": 0, \"deferred\": false, "
          "\"pcmRef\": \"loops/track0-lane0.wav\", \"effects\": []}]}, "
          "{\"channel\": 1, \"volume\": 1.0, \"muted\": false, "
          "\"lanes\": [{\"lane\": 0, \"deferred\": false, "
          "\"pcmRef\": \"loops/track1-lane0.wav\", \"effects\": []}]}]}, "
          "\"disarmSnapshot\": {\"tracks\": []}, \"layers\": []}",
          sr, (unsigned long long)capture_frames);
  test_write_manifest(dir, manifest);

  char log_path[700];
  snprintf(log_path, sizeof(log_path), "%s/events.log", dir);
  FILE* lf = fopen(log_path, "wb");
  CHECK(lf != NULL);
  if (lf != NULL) {
    test_write_log_header(lf, sr);
    fclose(lf);
  }

  le_perf_render_force_dry_write_failure_for_test(1); /* only channel 1 */

  le_engine* e = le_engine_create();
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 2000);

  le_perf_render_force_dry_write_failure_for_test(-1); /* reset before other tests run */

  int32_t done = 0, track_count = 0;
  CHECK(le_perf_render_poll(e, &done, NULL, &track_count) == LE_OK);
  CHECK(done == 1);
  CHECK(track_count == 2);

  int good = 0, bad = 0;
  for (int i = 0; i < track_count; ++i) {
    int32_t channel = -1, succeeded = -1;
    CHECK(le_perf_render_track_status(e, i, &channel, &succeeded) == LE_OK);
    if (channel == 0) {
      CHECK(succeeded == 1); /* channel 0's dry write was untouched */
      good++;
    } else if (channel == 1) {
      CHECK(succeeded == 0); /* channel 1's dry write was forced to fail */
      bad++;
    }
  }
  CHECK(good == 1);
  CHECK(bad == 1);

  /* Both channels' wet stems land on disk with real content regardless of
   * status — the forced failure only ever touches channel 1's dry write. */
  float wet0[4];
  CHECK(test_read_wet_stem(dir, 0, wet0, 4) == (int32_t)capture_frames);
  for (int32_t i = 0; i < (int32_t)capture_frames; ++i) {
    CHECK(fabsf(wet0[i] - healthy_value) < 1e-5f);
  }
  float wet1[4];
  CHECK(test_read_wet_stem(dir, 1, wet1, 4) == (int32_t)capture_frames);
  for (int32_t i = 0; i < (int32_t)capture_frames; ++i) {
    CHECK(fabsf(wet1[i] - failing_value) < 1e-5f);
  }

  /* master.wav must contain channel 0's healthy content and nothing from
   * channel 1: if it were 0.7f (healthy_value + failing_value), the gate
   * would be leaking the failed channel in; if it were 0.0f, the gate would
   * be over-excluding the healthy channel too (e.g. a process-wide flag
   * instead of a per-channel one). */
  float master[4];
  CHECK(test_read_master_stem(dir, master, (int32_t)capture_frames) ==
       (int32_t)capture_frames);
  for (int32_t i = 0; i < (int32_t)capture_frames; ++i) {
    CHECK(fabsf(master[i] - healthy_value) < 1e-5f);
  }

  le_engine_destroy(e);
}

/* Acceptance (coverage): a chain with TWO concurrently active slots (both
 * stateless DRIVE, so the series composition is still hand-computable) runs
 * both in order, and a mid-performance LE_CMD_SET_LANE_FX_COUNT shrink
 * disables the second slot from its logged frame onward without touching
 * its retained type/params (matching the live engine: count only gates how
 * many chain entries fx_apply_chain iterates, it never clears a slot beyond
 * the new count). */
static void test_perf_render_wet_multi_slot_and_count_shrink(void) {
  printf("test_perf_render_wet_multi_slot_and_count_shrink\n");
  const char* dir = render_test_dir("wet-multi-slot");
  const int32_t sr = 4800;
  const int32_t loop_len = 4;
  const uint64_t capture_frames = 8;
  const uint64_t shrink_frame = 4;
  const float dry_value = 0.5f;
  const float d0 = 0.3f, l0 = 0.7f;
  const float d1 = 0.6f, l1 = 0.5f;

  char loops_dir[700];
  snprintf(loops_dir, sizeof(loops_dir), "%s/loops", dir);
  test_render_mkdir(loops_dir);
  const float base[4] = {dry_value, dry_value, dry_value, dry_value};
  char wav_path[700];
  snprintf(wav_path, sizeof(wav_path), "%s/track0-lane0.wav", loops_dir);
  test_write_wav_mono(wav_path, base, loop_len, sr);

  char manifest[2048];
  snprintf(manifest, sizeof(manifest),
          "{\"sample_rate\": %d, \"capture_frames\": %llu, "
          "\"armSnapshot\": {\"tracks\": [{\"channel\": 0, \"volume\": 1.0, "
          "\"muted\": false, \"lanes\": [{\"lane\": 0, \"deferred\": false, "
          "\"pcmRef\": \"loops/track0-lane0.wav\", \"effects\": "
          "[{\"type\": 1, \"params\": [%f, %f, 0.0, 0.0]}, "
          "{\"type\": 1, \"params\": [%f, %f, 0.0, 0.0]}]}]}]}, "
          "\"disarmSnapshot\": {\"tracks\": []}, \"layers\": []}",
          sr, (unsigned long long)capture_frames, (double)d0, (double)l0,
          (double)d1, (double)l1);
  test_write_manifest(dir, manifest);

  char log_path[700];
  snprintf(log_path, sizeof(log_path), "%s/events.log", dir);
  FILE* lf = fopen(log_path, "wb");
  CHECK(lf != NULL);
  if (lf != NULL) {
    test_write_log_header(lf, sr);
    test_write_log_entry(
        lf, shrink_frame,
        (le_command){.code = LE_CMD_SET_LANE_FX_COUNT,
                    .fxcount = {0, 0, 1}});
    fclose(lf);
  }

  le_engine* e = le_engine_create();
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 2000);
  int32_t done = 0;
  CHECK(le_perf_render_poll(e, &done, NULL, NULL) == LE_OK);
  CHECK(done == 1);

  float wet[16];
  const int32_t got = test_read_wet_stem(dir, 0, wet, 16);
  CHECK(got == (int32_t)capture_frames);
  for (int32_t i = 0; i < got; ++i) {
    const float stage0 = tanhf(dry_value * (1.0f + d0 * 29.0f)) * l0;
    const float expected = (uint64_t)i < shrink_frame
                               ? tanhf(stage0 * (1.0f + d1 * 29.0f)) * l1
                               : stage0;
    CHECK(fabsf(wet[i] - expected) < 1e-5f);
  }

  le_engine_destroy(e);
}

/* Acceptance: a hosted plugin slot renders as dry passthrough in the wet
 * pass (D-RENDER, umbrella plan) — the render's fresh le_fx_state never
 * publishes a live plugin instance, so fx_apply_chain's own documented NULL
 * behavior (fx_plugin_process) already produces this with no special-casing
 * in perf_render.c; this proves that end-to-end against the real renderer. */
static void test_perf_render_wet_plugin_passthrough(void) {
  printf("test_perf_render_wet_plugin_passthrough\n");
  const char* dir = render_test_dir("wet-plugin");
  const int32_t sr = 4800;
  const int32_t loop_len = 4;
  const uint64_t capture_frames = 8;

  char loops_dir[700];
  snprintf(loops_dir, sizeof(loops_dir), "%s/loops", dir);
  test_render_mkdir(loops_dir);
  const float base[4] = {0.3f, -0.4f, 0.7f, -0.2f};
  char wav_path[700];
  snprintf(wav_path, sizeof(wav_path), "%s/track0-lane0.wav", loops_dir);
  test_write_wav_mono(wav_path, base, loop_len, sr);

  char manifest[2048];
  snprintf(manifest, sizeof(manifest),
          "{\"sample_rate\": %d, \"capture_frames\": %llu, "
          "\"armSnapshot\": {\"tracks\": [{\"channel\": 0, \"volume\": 1.0, "
          "\"muted\": false, \"lanes\": [{\"lane\": 0, \"deferred\": false, "
          "\"pcmRef\": \"loops/track0-lane0.wav\", \"effects\": "
          "[{\"type\": 8, \"plugin\": {\"uid\": \"test.plugin\"}}]}]}]}, "
          "\"disarmSnapshot\": {\"tracks\": []}, \"layers\": []}",
          sr, (unsigned long long)capture_frames);
  test_write_manifest(dir, manifest);

  le_engine* e = le_engine_create();
  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 2000);
  int32_t done = 0;
  CHECK(le_perf_render_poll(e, &done, NULL, NULL) == LE_OK);
  CHECK(done == 1);

  float dry[16];
  const int32_t dry_got = test_read_stem(dir, 0, dry, 16);
  float wet[16];
  const int32_t wet_got = test_read_wet_stem(dir, 0, wet, 16);
  CHECK(dry_got == (int32_t)capture_frames);
  CHECK(wet_got == (int32_t)capture_frames);
  for (int32_t i = 0; i < dry_got && i < wet_got; ++i) {
    CHECK(fabsf(wet[i] - dry[i]) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* #255 review follow-up (PR #260 finding 1): a track recorded FRESH while
 * the master already runs finalizes via finalize_new_track
 * (engine_process.c), which does NOT reset the loop clock — its buffer was
 * written phase-locked to the RUNNING master (record_pos seeds to
 * clock.position at record start), so its image is loop-position-indexed
 * against that clock, and anchoring its RECORD_END segment at phase 0 would
 * rotate the stem. Drives a REAL engine: track 0 defines a 4-frame master
 * (finalize -> clock reset at capture frame 4, LOOP_LENGTH_LOCKED logged
 * there); track 1 then records fresh with the press at master position 1
 * and the finalize press at position 3. The rendered dry stem for track 1
 * must match live playback sample-exactly — image[(f - 4) % 4], the master
 * phase — and the offline master must hold parity with the live-captured
 * master.pcm, the same criterion as the golden gate below. */
static void test_perf_render_fresh_midloop_second_track_phase(void) {
  printf("test_perf_render_fresh_midloop_second_track_phase\n");
  const char* dir = render_test_dir("midloop2nd");
  const int32_t sr = 4800;
  const int32_t loop_len = 4;
  float out[64];

  le_engine* e = le_engine_create();
  le_engine_configure(e, sr, 1, 1, 1000);
  CHECK(le_perf_arm(e, dir) == LE_OK);
  drain(e);

  /* Track 0 defines the master: frames 0-3 record 0.6, finalize applies at
   * capture frame 4 (le_loop_clock_set_length resets the master phase to 0
   * there, and finalize_master logs LOOP_LENGTH_LOCKED + RECORD_END at that
   * same frame). */
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, 0.6f, loop_len, out);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);

  /* Play to master position 1: frames 4-8 (positions 0,1,2,3,0) — the next
   * buffer starts at capture frame 9, master position 1. */
  process_const(e, 0.0f, 4, out);
  process_const(e, 0.0f, 1, out);

  /* Track 1 records FRESH mid-loop: the press lands at frame 9 (master
   * position 1), two frames captured (buffer indices 1,2 — writes are
   * phase-locked to the running master), and the finalize press lands at
   * frame 11 (position 3): finalize_new_track -> k=1, len 4, NO clock
   * reset. */
  CHECK(le_engine_record(e, 1) == LE_OK);
  process_const(e, 0.3f, 2, out);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e); /* RECORD_END for channel 1 logged at capture frame 11 */

  /* Both tracks play together: frames 11-18. */
  process_const(e, 0.0f, 8, out);

  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  const uint64_t capture_frames = (uint64_t)snap.perf_frames;
  CHECK(capture_frames == 19);

  /* Export both settled lanes for the disarm snapshot — bit-identical to
   * the engine's own buffers, exactly what performance_repository's real
   * _captureSettledLanes does at disarm. Track 1's image is loop-position-
   * indexed against the running master: [0, 0.3, 0.3, 0]. */
  float lane0[8] = {0};
  float lane1[8] = {0};
  CHECK(le_engine_export_track_lane(e, 0, 0, lane0, 8) == loop_len);
  CHECK(le_engine_export_track_lane(e, 1, 0, lane1, 8) == loop_len);
  CHECK(fabsf(lane1[0]) < 1e-6f);
  CHECK(fabsf(lane1[1] - 0.3f) < 1e-6f);
  CHECK(fabsf(lane1[2] - 0.3f) < 1e-6f);
  CHECK(fabsf(lane1[3]) < 1e-6f);

  char wav_path[700];
  snprintf(wav_path, sizeof(wav_path), "%s/track0-lane0.wav", dir);
  test_write_wav_mono(wav_path, lane0, loop_len, sr);
  snprintf(wav_path, sizeof(wav_path), "%s/track1-lane0.wav", dir);
  test_write_wav_mono(wav_path, lane1, loop_len, sr);

  CHECK(le_perf_disarm(e) == LE_OK);

  char manifest[1600];
  snprintf(manifest, sizeof(manifest),
           "{\"sample_rate\": %d, \"capture_frames\": %llu, "
           "\"armSnapshot\": {\"masterGain\": 1.0, \"limiterOn\": false, "
           "\"limiterCeiling\": 0.99, \"tracks\": []}, "
           "\"disarmSnapshot\": {\"tracks\": ["
           "{\"channel\": 0, \"volume\": 1.0, \"muted\": false, \"lanes\": "
           "[{\"lane\": 0, \"deferred\": false, \"pcmRef\": "
           "\"track0-lane0.wav\", \"effects\": []}]}, "
           "{\"channel\": 1, \"volume\": 1.0, \"muted\": false, \"lanes\": "
           "[{\"lane\": 0, \"deferred\": false, \"pcmRef\": "
           "\"track1-lane0.wav\", \"effects\": []}]}]}, "
           "\"layers\": []}",
           sr, (unsigned long long)capture_frames);
  test_write_manifest(dir, manifest);

  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 5000);

  /* Track 1's dry stem: silence until its RECORD_END at frame 11, then the
   * image at the MASTER phase — lane1[(f - 4) % 4], what the performer
   * heard — not the phase-0-anchored lane1[(f - 11) % 4]. */
  float stem1[32] = {0};
  CHECK(test_read_stem(dir, 1, stem1, 32) == (int32_t)capture_frames);
  for (uint64_t f = 0; f < 11; ++f) {
    CHECK(fabsf(stem1[f]) < 1e-6f);
  }
  for (uint64_t f = 11; f < capture_frames; ++f) {
    CHECK(fabsf(stem1[f] - lane1[(f - 4) % 4]) < 1e-6f);
  }

  /* Master parity, the golden gate's own criterion. */
  char pcm_path[700];
  snprintf(pcm_path, sizeof(pcm_path), "%s/master.pcm", dir);
  FILE* pf = fopen(pcm_path, "rb");
  CHECK(pf != NULL);
  float live[32] = {0};
  size_t live_n = 0;
  if (pf != NULL) {
    live_n = fread(live, sizeof(float), (size_t)capture_frames, pf);
    fclose(pf);
  }
  CHECK(live_n == capture_frames);

  float offline[32] = {0};
  CHECK(test_read_master_stem(dir, offline, 32) == (int32_t)capture_frames);
  if (live_n == capture_frames) {
    for (uint64_t f = 0; f < capture_frames; ++f) {
      CHECK(fabsf(offline[f] - live[f]) < 1e-4f);
    }
  }

  le_engine_destroy(e);
}

/* #255 re-review residual (PR #260): the k > 1 variant of the case above. A
 * fresh take spanning just over one base loop rounds UP to k whole loops
 * (finalize_new_track), and live playback then cycles its k segments
 * relative to the take's OWN start iteration (((loop_iteration - start_iter)
 * % k) * base + pos, engine_process.c) — the TRACK's epoch. Anchoring the
 * RECORD_END segment on the master lock's epoch mod k*base agrees with that
 * only modulo base and rotates the stem by whole base loops whenever
 * start_iter % k != 0. Drives a REAL engine: 4-frame master locked at
 * capture frame 4; track 1 records fresh from frame 9 (iteration 1,
 * position 1) for 6 frames -> k=2 (len 8), start_iter=1, finalize at frame
 * 15. Live playback of track 1 is lane1[(f - 8) % 8]; a lock-epoch anchor
 * would render lane1[(f - 12) % 8] — rotated one base loop. */
static void test_perf_render_fresh_multiloop_second_track_phase(void) {
  printf("test_perf_render_fresh_multiloop_second_track_phase\n");
  const char* dir = render_test_dir("multiloop2nd");
  const int32_t sr = 4800;
  const int32_t loop_len = 4;
  const int32_t track1_len = 8; /* k = 2 after round-up */
  float out[64];

  le_engine* e = le_engine_create();
  le_engine_configure(e, sr, 1, 1, 1000);
  CHECK(le_perf_arm(e, dir) == LE_OK);
  drain(e);

  /* Track 0 defines the 4-frame master; finalize (clock reset + lock)
   * applies at capture frame 4. */
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, 0.6f, loop_len, out);
  CHECK(le_engine_record(e, 0) == LE_OK);
  drain(e);

  /* Play to master position 1 / iteration 1 (frames 4-8): the next buffer
   * starts at capture frame 9, position 1, one full loop crossed. */
  process_const(e, 0.0f, 4, out);
  process_const(e, 0.0f, 1, out);

  /* Track 1 records fresh mid-loop for SIX frames (9-14): record_pos seeds
   * to 1 and runs to 7, spanning the loop top -> finalize_new_track rounds
   * up to k=2 (len 8) with start_iter=1; the finalize press applies at
   * capture frame 15, master position 3, iteration 2. Buffer indices 1-6
   * hold 0.3; indices 0 and 7 stay silent. */
  CHECK(le_engine_record(e, 1) == LE_OK);
  process_const(e, 0.3f, 6, out);
  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e); /* RECORD_END for channel 1 logged at capture frame 15 */

  /* Both tracks play together: frames 15-22. */
  process_const(e, 0.0f, 8, out);

  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  const uint64_t capture_frames = (uint64_t)snap.perf_frames;
  CHECK(capture_frames == 23);

  float lane0[8] = {0};
  float lane1[16] = {0};
  CHECK(le_engine_export_track_lane(e, 0, 0, lane0, 8) == loop_len);
  CHECK(le_engine_export_track_lane(e, 1, 0, lane1, 16) == track1_len);
  CHECK(fabsf(lane1[0]) < 1e-6f);
  for (int i = 1; i <= 6; ++i) {
    CHECK(fabsf(lane1[i] - 0.3f) < 1e-6f);
  }
  CHECK(fabsf(lane1[7]) < 1e-6f);

  char wav_path[700];
  snprintf(wav_path, sizeof(wav_path), "%s/track0-lane0.wav", dir);
  test_write_wav_mono(wav_path, lane0, loop_len, sr);
  snprintf(wav_path, sizeof(wav_path), "%s/track1-lane0.wav", dir);
  test_write_wav_mono(wav_path, lane1, track1_len, sr);

  CHECK(le_perf_disarm(e) == LE_OK);

  char manifest[1600];
  snprintf(manifest, sizeof(manifest),
           "{\"sample_rate\": %d, \"capture_frames\": %llu, "
           "\"armSnapshot\": {\"masterGain\": 1.0, \"limiterOn\": false, "
           "\"limiterCeiling\": 0.99, \"tracks\": []}, "
           "\"disarmSnapshot\": {\"tracks\": ["
           "{\"channel\": 0, \"volume\": 1.0, \"muted\": false, \"lanes\": "
           "[{\"lane\": 0, \"deferred\": false, \"pcmRef\": "
           "\"track0-lane0.wav\", \"effects\": []}]}, "
           "{\"channel\": 1, \"volume\": 1.0, \"muted\": false, \"lanes\": "
           "[{\"lane\": 0, \"deferred\": false, \"pcmRef\": "
           "\"track1-lane0.wav\", \"effects\": []}]}]}, "
           "\"layers\": []}",
           sr, (unsigned long long)capture_frames);
  test_write_manifest(dir, manifest);

  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 5000);

  /* Track 1's dry stem: silence until its RECORD_END at frame 15, then the
   * image at the TRACK's epoch — lane1[(f - 8) % 8], what the performer
   * heard — not the lock-epoch lane1[(f - 12) % 8]. */
  float stem1[32] = {0};
  CHECK(test_read_stem(dir, 1, stem1, 32) == (int32_t)capture_frames);
  for (uint64_t f = 0; f < 15; ++f) {
    CHECK(fabsf(stem1[f]) < 1e-6f);
  }
  for (uint64_t f = 15; f < capture_frames; ++f) {
    CHECK(fabsf(stem1[f] - lane1[(f - 8) % 8]) < 1e-6f);
  }

  /* Master parity, the golden gate's own criterion. */
  char pcm_path[700];
  snprintf(pcm_path, sizeof(pcm_path), "%s/master.pcm", dir);
  FILE* pf = fopen(pcm_path, "rb");
  CHECK(pf != NULL);
  float live[32] = {0};
  size_t live_n = 0;
  if (pf != NULL) {
    live_n = fread(live, sizeof(float), (size_t)capture_frames, pf);
    fclose(pf);
  }
  CHECK(live_n == capture_frames);

  float offline[32] = {0};
  CHECK(test_read_master_stem(dir, offline, 32) == (int32_t)capture_frames);
  if (live_n == capture_frames) {
    for (uint64_t f = 0; f < capture_frames; ++f) {
      CHECK(fabsf(offline[f] - live[f]) < 1e-4f);
    }
  }

  le_engine_destroy(e);
}

/* Acceptance (the hard gate): drives a REAL engine through a scripted
 * performance under the fixed golden-parity protocol — arm from silence, no
 * monitor inputs, no plugin slots — with overdubbing intentionally absent
 * (arm-image phase alignment against an already-playing track is now
 * phase-locked via armSnapshot.clockFrame, #255, and unit-covered by the
 * stitching cases above; this golden protocol still arms from silence per
 * the plan's own fixed protocol) but real FX engagement/sweep, a volume
 * ride, a mute/unmute, a master-gain change, and the limiter, all via the
 * actual public API so events.log holds genuine engine-emitted entries
 * rather than a hand-typed approximation. Compares the offline-reconstructed
 * master (stems/wet/master.wav) against the live-captured master
 * (master.pcm) sample-by-sample. */
static void test_perf_render_golden_master_parity(void) {
  printf("test_perf_render_golden_master_parity\n");
  const char* dir = render_test_dir("golden");
  const int32_t sr = 4800;
  const int32_t loop_len = 4;

  le_engine* e = le_engine_create();
  le_engine_configure(e, sr, 1, 1, 1000);

  /* Arm from silence: nothing recorded yet, no master loop defined. */
  CHECK(le_perf_arm(e, dir) == LE_OK);
  drain(e);

  /* Record fresh while armed, then finalize to PLAYING — le_loop_clock_set_
   * length (loop_clock.c) resets the master phase to 0 exactly at this
   * finalize frame, so the fresh content is phase-aligned by construction
   * (no arm-image / clockFrame concern here at all). */
  float out[64];
  CHECK(le_engine_record(e, 0) == LE_OK);
  process_const(e, 0.6f, loop_len, out);
  CHECK(le_engine_record(e, 0) == LE_OK); /* finalize -> PLAYING */
  drain(e);
  process_const(e, 0.6f, loop_len, out);
  process_const(e, 0.6f, loop_len, out);

  /* Scripted performance: FX engage + sweep, volume ride, mute/unmute,
   * master gain, limiter — every command below is real, applied to the
   * live engine, not a hand-authored log fixture. */
  CHECK(le_engine_set_lane_fx(e, 0, 0, 0, LE_FX_DRIVE) == LE_OK);
  CHECK(le_engine_set_lane_fx_count(e, 0, 0, 1) == LE_OK);
  process_const(e, 0.6f, loop_len, out);

  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 0, 0.9f) == LE_OK);
  CHECK(le_engine_set_lane_fx_param(e, 0, 0, 0, 1, 0.8f) == LE_OK);
  process_const(e, 0.6f, loop_len, out);

  CHECK(le_engine_set_lane_volume(e, 0, 0, 0.5f) == LE_OK);
  process_const(e, 0.6f, loop_len, out);

  CHECK(le_engine_set_lane_mute(e, 0, 0, 1) == LE_OK);
  process_const(e, 0.6f, loop_len, out);
  CHECK(le_engine_set_lane_mute(e, 0, 0, 0) == LE_OK);
  process_const(e, 0.6f, loop_len, out);

  CHECK(le_engine_set_master_gain(e, 0.7f) == LE_OK);
  process_const(e, 0.6f, loop_len, out);

  CHECK(le_engine_set_limiter(e, 1, 0.4f) == LE_OK);
  process_const(e, 0.6f, loop_len, out);
  process_const(e, 0.6f, loop_len, out);

  le_snapshot snap;
  le_engine_get_snapshot(e, &snap);
  const uint64_t capture_frames = (uint64_t)snap.perf_frames;
  CHECK(capture_frames > 0);

  /* Export the settled lane for the disarm-snapshot's pcmRef — bit-identical
   * to what the engine actually holds, exactly what performance_repository's
   * real _captureSettledLanes does at disarm. */
  float exported[8];
  const int32_t exported_n = le_engine_export_track_lane(e, 0, 0, exported, 8);
  CHECK(exported_n == loop_len);
  char wav_path[700];
  snprintf(wav_path, sizeof(wav_path), "%s/track0-lane0.wav", dir);
  test_write_wav_mono(wav_path, exported, loop_len, sr);

  CHECK(le_perf_disarm(e) == LE_OK); /* blocks until the final flush + close */

  char manifest[1200];
  snprintf(manifest, sizeof(manifest),
          "{\"sample_rate\": %d, \"capture_frames\": %llu, "
          "\"armSnapshot\": {\"masterGain\": 1.0, \"limiterOn\": false, "
          "\"limiterCeiling\": 0.99, \"tracks\": []}, "
          "\"disarmSnapshot\": {\"tracks\": [{\"channel\": 0, \"volume\": "
          "1.0, \"muted\": false, \"lanes\": [{\"lane\": 0, \"deferred\": "
          "false, \"pcmRef\": \"track0-lane0.wav\", \"effects\": []}]}]}, "
          "\"layers\": []}",
          sr, (unsigned long long)capture_frames);
  test_write_manifest(dir, manifest);

  CHECK(le_perf_render_begin(e, dir) == LE_OK);
  test_wait_for_render(e, 5000);

  int32_t done = 0, track_count = 0;
  CHECK(le_perf_render_poll(e, &done, NULL, &track_count) == LE_OK);
  CHECK(done == 1);
  CHECK(track_count == 1);
  int32_t channel = -1, succeeded = 0;
  CHECK(le_perf_render_track_status(e, 0, &channel, &succeeded) == LE_OK);
  CHECK(channel == 0);
  CHECK(succeeded == 1);

  char master_pcm_path[700];
  snprintf(master_pcm_path, sizeof(master_pcm_path), "%s/master.pcm", dir);
  FILE* mf = fopen(master_pcm_path, "rb");
  CHECK(mf != NULL);
  float* live = (float*)malloc((size_t)capture_frames * sizeof(float));
  size_t live_n = 0;
  if (mf != NULL) {
    live_n = fread(live, sizeof(float), (size_t)capture_frames, mf);
    fclose(mf);
  }
  CHECK(live_n == capture_frames);

  char master_wav_path[700];
  snprintf(master_wav_path, sizeof(master_wav_path), "%s/stems/wet/master.wav",
          dir);
  FILE* wf = fopen(master_wav_path, "rb");
  CHECK(wf != NULL);
  float* offline = (float*)malloc((size_t)capture_frames * sizeof(float));
  size_t offline_n = 0;
  if (wf != NULL) {
    unsigned char header[44];
    if (fread(header, 1, sizeof(header), wf) == sizeof(header)) {
      offline_n = fread(offline, sizeof(float), (size_t)capture_frames, wf);
    }
    fclose(wf);
  }
  CHECK(offline_n == capture_frames);

  if (live_n == capture_frames && offline_n == capture_frames) {
    for (uint64_t f = 0; f < capture_frames; ++f) {
      CHECK(fabsf(offline[f] - live[f]) < 1e-4f);
    }
  }

  free(live);
  free(offline);
  le_engine_destroy(e);
}

/* Code-review fix (A3 follow-up): a quantized record-END round-down
 * TRUNCATION (D8 -- capture ends behind the press, drop the tail) used to
 * tag finalize_new_track's LE_PLOG_RECORD_END with the raw, buffer-start-
 * approximate `frame` passed to apply_command -- not the `behind`-frames-
 * earlier boundary the audio was actually truncated to (le_truncate_capture_
 * tail). Live playback reads clock.position directly and was never
 * affected; but perf_render.c's le_pr_record_end_phase folds the logged
 * end_frame straight into the finalized segment's start_frame AND its
 * `(end_frame - start_frame)` phase span, so an export render of a
 * round-down-truncated take used to start its segment `behind` frames late.
 *
 * This asserts the fix DIRECTLY, at its own source of truth: the logged
 * LE_PLOG_RECORD_END frame tag in events.log (the file the drain thread
 * writes during a live perf-armed session -- read here as raw bytes, the
 * SAME 28-byte-per-entry format test_write_log_entry hand-authors for the
 * OTHER perf_render tests' fixtures). Two reasons this beats an offline-
 * render/stem comparison for THIS specific bug:
 *   - Once the render has switched to the new segment, le_pr_record_end_
 *     phase's own math makes the tagged end_frame cancel out algebraically
 *     (index(f) = (start_pos - start_frame_record + f) % image_len) -- a
 *     wrong tag is only OBSERVABLE within the disputed window itself
 *     [true end_frame, buggy end_frame), and since that window is exactly
 *     the truncated-away tail, the new take's own content there is silence
 *     either way. Making it observable needs the channel to have had real
 *     (non-silent) content at ARM time -- but le_pr_render_track only
 *     honors a channel's RECORD_END at all when `!build.has_content`
 *     (i.e. the channel was EMPTY at arm), so an arm-image and a fresh
 *     RECORD_END are mutually exclusive in the render's own model. There is
 *     no render-observable way to exercise this fix through that pipeline.
 *   - The live master-tap ring (master.pcm) is sized for LE_PERF_CAPTURE_
 *     SECONDS of REAL wall-clock audio; a synchronous, no-sleep native test
 *     that blasts through thousands of frames in microseconds starves the
 *     background drain thread of real time to keep it drained and silently
 *     overruns it (a_perf_overruns) -- an environment artifact, not a
 *     symptom of this bug.
 *
 * Every "true" timing value below is read straight from the live engine's
 * own snapshots (never hand-derived arithmetic reproducing the engine's own
 * math): `raw_before_finalize` / `pos_before_finalize` are perf_frames and
 * master_position_frames snapshotted immediately before the finalize press
 * -- pos_before_finalize (1684) and the already-CHECKed content boundary
 * (1500) give `behind` (184) as plain arithmetic on two asserted facts, not
 * a re-derivation of le_truncate_capture_tail's own math. `raw_before_
 * finalize` equals the ARM command's OWN apply-time perf_frame_base: the
 * finalize press (le_engine_record) is a pure control-thread ring push (no
 * frames processed), and the drain(e) that follows is a ZERO-frame
 * le_engine_process call, so perf_frame_base for THAT call -- read before
 * any of ITS OWN frames are added -- is unchanged from this snapshot. */
static void test_perf_render_quantized_round_down_truncation_log_frame(void) {
  printf("test_perf_render_quantized_round_down_truncation_log_frame\n");
  const char* dir = render_test_dir("qdown-log");
  const int32_t sr = 1000;
  const int32_t loop_len = 3000; /* 2 loop-locked bars, as in qa_make_grid_engine */

  le_engine* e = le_engine_create();
  le_engine_configure(e, sr, 1, 1, 20000);
  CHECK(le_perf_arm(e, dir) == LE_OK); /* arm from silence, nothing recorded yet */
  drain(e);

  /* Track 0 defines a SILENT 3000-frame master (tg_record_defining_loop always
   * records silence); irrelevant to this test beyond establishing the grid. */
  le_engine_set_tempo(e, 120.0f);
  tg_advance(e, 1);
  tg_record_defining_loop(e, loop_len); /* master position 1 on return */
  le_engine_set_quantize(e, 1);

  /* Exactly test_quantize_div_record_end_rounds_down's scripted press
   * sequence: arm a quarter-quantized start (fires at loop-locked position
   * 375), record 2.0 for 1309 frames (position 1684), then press finalize --
   * behind=184 < ahead=191, so the capture truncates back to the boundary at
   * 1500 and finalizes NOW, not at the next boundary. */
  CHECK(le_engine_set_quantize_div(e, LE_GRID_DIV_QUARTER) == LE_OK);
  qa_advance_to(e, 0.0f, 1);
  le_engine_record(e, 1); /* arm the start */
  drain(e);
  qa_advance_to(e, 0.0f, 375); /* fire: capture begins at 375 */
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);

  qa_advance_to(e, 2.0f, 375 + 1309);
  le_engine_get_snapshot(e, &s);
  const uint64_t raw_before_finalize = (uint64_t)s.perf_frames;
  const int32_t pos_before_finalize = s.master_position_frames;
  CHECK(pos_before_finalize == 1684);

  le_engine_record(e, 1); /* finalize press: round-down truncation */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING); /* truncated, finalized now */
  CHECK(s.tracks[1].length_frames == loop_len);

  /* The finalized take's own content proves where le_truncate_capture_tail
   * actually cut: 2.0 up to (not including) 1500, silence from 1500. */
  float* lane1 = (float*)calloc((size_t)loop_len, sizeof(float));
  CHECK(le_engine_export_track_lane(e, 1, 0, lane1, loop_len) == loop_len);
  CHECK(fabsf(lane1[1499] - 2.0f) < 1e-6f);
  const int32_t content_boundary = 1500;
  CHECK(fabsf(lane1[content_boundary]) < 1e-6f);
  free(lane1);

  /* The truncated boundary, in plain arithmetic on two already-asserted
   * facts (never a re-derivation of le_truncate_capture_tail's own math):
   * the press landed `behind` frames past the boundary it truncates BACK
   * to. */
  const int32_t behind = pos_before_finalize - content_boundary;
  CHECK(behind == 184);
  const uint64_t end_frame_true = raw_before_finalize - (uint64_t)behind;

  CHECK(le_perf_disarm(e) == LE_OK); /* flushes events.log fully before this returns */

  /* Read events.log directly: 12-byte header ("PLEV" + version + sample_rate),
   * then 28-byte entries (frame:8, code:4, arg_i:4, arg_f:4, 8 bytes unused --
   * the generic {arg_i, arg_f} union arm LE_PLOG_RECORD_END uses, matching
   * test_write_log_entry's own encoding and le_pd_write_log_entry's on-disk
   * layout exactly). Finds channel 1's RECORD_END frame tag. */
  char log_path[700];
  snprintf(log_path, sizeof(log_path), "%s/events.log", dir);
  FILE* lf = fopen(log_path, "rb");
  CHECK(lf != NULL);
  int64_t record_end_ch1_frame = -1;
  if (lf != NULL) {
    unsigned char header[12];
    CHECK(fread(header, 1, sizeof(header), lf) == sizeof(header));
    unsigned char entry[28];
    while (fread(entry, 1, sizeof(entry), lf) == sizeof(entry)) {
      int64_t frame;
      int32_t code, arg_i;
      memcpy(&frame, entry + 0, 8);
      memcpy(&code, entry + 8, 4);
      memcpy(&arg_i, entry + 12, 4);
      if (code == LE_PLOG_RECORD_END && arg_i == 1) {
        record_end_ch1_frame = frame;
      }
    }
    fclose(lf);
  }
  CHECK(record_end_ch1_frame >= 0);

  /* The core assertion: channel 1's logged finalize frame is the TRUNCATED
   * boundary's own sample-accurate position -- `end_frame_true`, `behind`
   * frames earlier than the raw press -- not the buffer-start-approximate
   * press frame (`raw_before_finalize`) itself. A regression back to the
   * raw `frame` would make record_end_ch1_frame equal raw_before_finalize,
   * `behind` (184) frames later than this check requires. */
  CHECK(record_end_ch1_frame == (int64_t)end_frame_true);
  CHECK(record_end_ch1_frame != (int64_t)raw_before_finalize);

  le_engine_destroy(e);
}

/* ---- looper mode (B2a, D4) ----
 * The five-mode field + its content-lock gate. No Sync/Song/Band/Free
 * SEMANTICS exist yet (that's B2b onward) — these tests cover only the field
 * itself and le_looper_mode_locked (engine_process.c). */

static void test_looper_mode_defaults_and_persistence(void) {
  printf("test_looper_mode_defaults_and_persistence\n");
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  /* Grid-off-style default: MULTI (0) on a fresh engine, same as every other
   * tempo-grid-era setting's untouched value. */
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_MULTI);

  /* Settings persist across a reconfigure (the 2f0513a pattern, same as
   * tempo/click): seeded once in le_engine_create, never reset by
   * configure. */
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_SYNC);

  le_engine_configure(e, 1000, 1, 1, 20000);
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_SYNC); /* survived the reconfigure */

  le_engine_destroy(e);
}

static void test_looper_mode_setter_validates_args(void) {
  printf("test_looper_mode_setter_validates_args\n");
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  /* Out-of-range values are rejected by the control-thread wrapper and never
   * posted — the published mode is untouched. */
  CHECK(le_engine_set_looper_mode(e, -1) == LE_ERR_INVALID);
  CHECK(le_engine_set_looper_mode(e, 5) == LE_ERR_INVALID);
  CHECK(le_engine_set_looper_mode(e, 99) == LE_ERR_INVALID);
  CHECK(le_engine_set_looper_mode(NULL, LE_LOOPER_MODE_SYNC) == LE_ERR_INVALID);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_MULTI);

  le_engine_destroy(e);
}

static void test_looper_mode_switch_accepted_when_empty(void) {
  printf("test_looper_mode_switch_accepted_when_empty\n");
  /* Every one of the 5 values round-trips through the command while every
   * track is EMPTY -- no other validation at this stage (B2a is the field +
   * gate only; Sync/Song/Band/Free semantics are not implemented yet). */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  const int32_t modes[] = {
      LE_LOOPER_MODE_MULTI, LE_LOOPER_MODE_SYNC, LE_LOOPER_MODE_SONG,
      LE_LOOPER_MODE_BAND,  LE_LOOPER_MODE_FREE,  LE_LOOPER_MODE_MULTI,
  };
  for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); ++i) {
    CHECK(le_engine_set_looper_mode(e, modes[i]) == LE_OK);
    tg_advance(e, 1);
    le_engine_get_snapshot(e, &s);
    CHECK(s.looper_mode == modes[i]);
  }

  le_engine_destroy(e);
}

static void test_looper_mode_locked_with_content(void) {
  printf("test_looper_mode_locked_with_content\n");
  /* D4: while any track has content, a mode switch is a no-op; clearing
   * every track releases the lock and the switch applies immediately. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  tg_record_defining_loop(e, 4000); /* track 0 defines the master */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state != LE_TRACK_EMPTY);

  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK); /* accepted
    by the wrapper (control-thread validation only); dropped by the audio
    thread */
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_MULTI); /* unchanged: locked */

  le_engine_clear(e, 0);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);

  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_SYNC); /* unlocked: applies */

  le_engine_destroy(e);
}

static void test_looper_mode_locked_by_non_zero_track_content(void) {
  printf("test_looper_mode_locked_by_non_zero_track_content\n");
  /* The D4 gate checks EVERY track, not just track 0 / a "selected" one:
   * content on track 2 alone -- tracks 0, 1, and everything past 2 stay
   * EMPTY -- still locks a mode switch. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  le_engine_record(e, 2); /* track 2 defines the master directly */
  tg_advance(e, 4000);
  le_engine_record(e, 2); /* queue finalize (seam crossfade) */
  tg_advance(e, e->sample_rate / 100);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[2].state != LE_TRACK_EMPTY);

  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_BAND) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_MULTI); /* still locked by track 2 */

  le_engine_clear(e, 2);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[2].state == LE_TRACK_EMPTY);

  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_BAND) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_BAND); /* every track empty: applies */

  le_engine_destroy(e);
}

/* ---- Free mode per-track clocks (B2b) ----
 *
 * Each le_track gains its own le_loop_clock (free_clock), engaged only when
 * a_looper_mode == LE_LOOPER_MODE_FREE. "Dormant outside Free mode" is
 * proven by every OTHER test in this file (400+) passing UNCHANGED with the
 * default MULTI mode -- see the full-suite run this PR's verification
 * quotes. These tests cover Free mode's own semantics: independent
 * per-track lengths under staggered/un-synced starts, the one-capturer
 * hand-off finalizing to each track's OWN clock (not the master, not the
 * interrupting track), per-track viz, and that no residual Multi-mode
 * master-clock state can leak into a fresh Free-mode recording. */

/* Records a defining/first take on channel [ch] for [len] silent frames and
 * lets the seam-crossfade deferral (sr/100 extra frames) land -- mirrors
 * tg_record_defining_loop but parameterized by channel, because every
 * Free-mode track's first take goes through the EXACT SAME defining/xfade-
 * deferred path as Multi mode's track 0 (e->clock.length == 0 is the sole
 * discriminator handle_record/finalize use, and it never becomes nonzero in
 * Free mode -- see finalize_master's free_mode branch). */
static void fm_record_track(le_engine* e, int32_t ch, int32_t len) {
  le_engine_record(e, ch);
  tg_advance(e, len);
  le_engine_record(e, ch); /* queue finalize (defers for the seam crossfade) */
  tg_advance(e, e->sample_rate / 100);
}

/* Like fm_record_track but feeds a constant [value] instead of silence, so
 * the recorded content is trivially distinguishable per track (viz tests). */
static void fm_advance_value(le_engine* e, float value, int total) {
  float in[64];
  float out[64];
  for (int i = 0; i < 64; ++i) in[i] = value;
  while (total > 0) {
    const int n = total > 64 ? 64 : total;
    le_engine_process(e, out, in, (uint32_t)n);
    total -= n;
  }
}
static void fm_record_track_value(le_engine* e, int32_t ch, int32_t len,
                                  float value) {
  le_engine_record(e, ch);
  fm_advance_value(e, value, len);
  le_engine_record(e, ch);
  fm_advance_value(e, value, e->sample_rate / 100);
}

/* A fresh engine, switched into Free mode (every track starts empty, so the
 * D4 gate accepts it immediately). */
static le_engine* fm_make_free_engine(int sr) {
  le_engine* e = tg_make_engine(sr);
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_FREE) == LE_OK);
  tg_advance(e, 1);
  return e;
}

static void test_free_mode_defining_recording_sets_own_clock_not_master(void) {
  printf("test_free_mode_defining_recording_sets_own_clock_not_master\n");
  le_engine* e = fm_make_free_engine(1000);
  le_snapshot s;

  fm_record_track(e, 0, 1500);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].length_frames == 1500);
  CHECK(s.tracks[0].multiple == 1);

  /* The shared master never moves -- the whole point of Free mode: each
   * track's defining recording sets ITS OWN clock, not e->clock. */
  CHECK(s.master_length_frames == 0);
  CHECK(e->clock.length == 0);
  CHECK(load_i32(&e->a_master_len) == 0);
  CHECK(e->loop_iteration == 0);

  /* This track's OWN clock IS established. */
  CHECK(e->tracks[0].free_clock.length == 1500);
  CHECK(e->tracks[0].free_clock.position == 0);
  CHECK(e->tracks[0].free_iteration == 0);

  le_engine_destroy(e);
}

static void test_free_mode_independent_lengths_prime_wraps(void) {
  printf("test_free_mode_independent_lengths_prime_wraps\n");
  le_engine* e = fm_make_free_engine(1000);
  le_snapshot s;

  /* 8 mutually prime lengths -- distinct primes are trivially coprime, so no
   * accidental shared period can mask cross-track interference between any
   * pair. Recorded sequentially (one-capturer): by the time the last track
   * finalizes, every earlier track has already been PLAYING (and ticking
   * its own clock) for a different, staggered span -- exactly the
   * un-synced Free-mode workflow. */
  const int32_t len[LE_MAX_TRACKS] = {991, 997, 1009, 1013,
                                      1019, 1021, 1031, 1033};
  for (int32_t ch = 0; ch < LE_MAX_TRACKS; ++ch) {
    fm_record_track(e, ch, len[ch]);
  }

  le_engine_get_snapshot(e, &s);
  for (int32_t ch = 0; ch < LE_MAX_TRACKS; ++ch) {
    CHECK(s.tracks[ch].state == LE_TRACK_PLAYING);
    CHECK(s.tracks[ch].length_frames == len[ch]);
    CHECK(e->tracks[ch].free_clock.length == len[ch]);
  }
  /* The shared master stayed dormant through all 8 defining takes. */
  CHECK(load_i32(&e->a_master_len) == 0);
  CHECK(e->clock.length == 0);

  /* Snapshot each track's current (already-staggered) position/iteration as
   * the baseline for one shared batch advance -- every track is PLAYING now,
   * so this single tg_advance ticks all 8 clocks in lockstep with the SAME
   * frame count, letting position/iteration be verified against a closed-
   * form formula instead of a loose bound. */
  int32_t base_pos[LE_MAX_TRACKS];
  uint64_t base_iter[LE_MAX_TRACKS];
  for (int32_t ch = 0; ch < LE_MAX_TRACKS; ++ch) {
    base_pos[ch] = e->tracks[ch].free_clock.position;
    base_iter[ch] = e->tracks[ch].free_iteration;
  }

  /* Long enough for several wrap cycles on both the shortest (991) and the
   * longest (1033) track. */
  const int N = 5000;
  tg_advance(e, N);

  for (int32_t ch = 0; ch < LE_MAX_TRACKS; ++ch) {
    const int64_t total = (int64_t)base_pos[ch] + N;
    const int32_t expect_pos = (int32_t)(total % len[ch]);
    const uint64_t expect_iter = base_iter[ch] + (uint64_t)(total / len[ch]);
    CHECK(e->tracks[ch].free_clock.position == expect_pos);
    CHECK(e->tracks[ch].free_iteration == expect_iter);
    CHECK(expect_iter >= base_iter[ch] + 3); /* several wraps happened */
  }

  /* The shared master / loop_iteration never moved across the whole run. */
  CHECK(load_i32(&e->a_master_len) == 0);
  CHECK(e->clock.length == 0);
  CHECK(e->loop_iteration == 0);

  le_engine_destroy(e);
}

static void test_free_mode_one_capturer_handoff_finalizes_to_own_length(void) {
  printf("test_free_mode_one_capturer_handoff_finalizes_to_own_length\n");
  le_engine* e = fm_make_free_engine(1000);
  le_snapshot s;

  /* Track 0 already has its own established length from an earlier take. */
  fm_record_track(e, 0, 2000);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].length_frames == 2000);
  const int32_t track0_len_before = e->tracks[0].free_clock.length;

  /* Track 1 starts its OWN defining recording -- left in flight (not
   * finalized). */
  le_engine_record(e, 1);
  tg_advance(e, 400);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);

  /* Track 0 (already established) starts an overdub punch-in: the
   * one-capturer hand-off (close_active_capture -- unconditional and mode-
   * agnostic, the same "single input stream" invariant Multi mode relies
   * on) finalizes track 1's in-flight recording RIGHT HERE, to ITS OWN
   * clock -- not track 0's length, not any shared master. */
  le_engine_record(e, 0);
  tg_advance(e, 1);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].length_frames == 400);
  CHECK(e->tracks[1].free_clock.length == 400);
  CHECK(e->tracks[1].free_clock.length != track0_len_before);

  /* Track 0's own clock is untouched by the hand-off: it moved to
   * OVERDUBBING, not a re-finalize. */
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);
  CHECK(e->tracks[0].free_clock.length == track0_len_before);

  /* The shared master never existed and still doesn't. */
  CHECK(load_i32(&e->a_master_len) == 0);
  CHECK(e->clock.length == 0);

  le_engine_destroy(e);
}

static void test_free_mode_no_residual_multi_mode_state(void) {
  printf("test_free_mode_no_residual_multi_mode_state\n");
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  /* Establish real Multi-mode master-clock state first. */
  tg_record_defining_loop(e, 2000);
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_MULTI);
  CHECK(s.master_length_frames == 2000);
  CHECK(e->clock.length == 2000);

  /* Clear back to all-empty -- the only way to release the D4 lock -- via
   * the existing, unmodified handle_clear all-empty reset. */
  le_engine_clear(e, 0);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.master_length_frames == 0);
  CHECK(e->clock.length == 0);

  /* Switch into Free mode (only possible now that everything is empty). */
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_FREE) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_FREE);

  /* A fresh Free-mode defining recording, at a DIFFERENT length than the
   * old Multi-mode master -- if any stale master-clock state leaked in, this
   * would either misread the old 2000-frame grid or corrupt the new take. */
  fm_record_track(e, 0, 1500);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].length_frames == 1500);
  CHECK(e->tracks[0].free_clock.length == 1500);
  CHECK(e->tracks[0].free_clock.position == 0);
  CHECK(e->tracks[0].free_iteration == 0);
  CHECK(load_i32(&e->a_master_len) == 0); /* never re-established */
  CHECK(e->clock.length == 0);
  CHECK(e->loop_iteration == 0);

  le_engine_destroy(e);
}

static void test_free_mode_overdub_writes_own_position(void) {
  printf("test_free_mode_overdub_writes_own_position\n");
  /* Regression pin for the mix_tracks_frame fix: before it, an overdub
   * write's target index (wdub) defaulted to 0 whenever the shared master
   * was dormant (e->clock.length == 0, i.e. always in Free mode) instead of
   * this track's own comp_pos(trk_pos, offset, trk_len) -- corrupting frame
   * 0 every sample instead of writing at the punched-in position. Feeds a
   * LOUD, distinguishable overdub value (not silence) so a stray write at
   * the wrong index is actually detectable, not masked by "0 * gain == 0". */
  le_engine* e = fm_make_free_engine(1000);
  le_snapshot s;

  fm_record_track_value(e, 0, 900, 0.5f);
  /* Run the loop around a few times so the write head is nowhere near frame
   * 0 when the punch-in below lands. */
  tg_advance(e, 2200); /* several full loops past position 0 */

  le_engine_record(e, 0); /* punch-in: PLAYING -> OVERDUBBING */
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);
  const int32_t punch_pos = e->tracks[0].free_clock.position;
  CHECK(punch_pos > 0 && punch_pos < 900); /* not sitting at the loop top */

  /* Overdub a loud constant for a short, bounded span (long enough for the
   * ~10-frame punch-in fade to fully ramp), then punch back out. */
  fm_advance_value(e, 1.0f, 50);
  le_engine_record(e, 0); /* OVERDUBBING -> PLAYING */
  fm_advance_value(e, 0.0f, e->sample_rate / 100 + 5); /* let the fade settle */

  const int32_t live = load_i32(&e->tracks[0].lanes[0].a_live);
  const float* buf = e->tracks[0].lanes[0].pool[live];
  CHECK(buf != NULL);

  /* The overdub landed at THIS track's own punched-in position (fully
   * ramped by now: original 0.5f loop content + 1.0f * unity overdub gain),
   * not at index 0. classic additive overdub (overdub_fb == 1.0 default). */
  const int32_t mid = (punch_pos + 20) % 900; /* deep in the fully-ramped window */
  CHECK(buf[mid] > 1.3f);
  CHECK(buf[mid] < 1.7f);

  /* Frame 0 (and every frame far from the punch window) must be untouched
   * -- still exactly the original 0.5f recording, not corrupted by writes
   * that used to land unconditionally at index 0. */
  CHECK(fabsf(buf[0] - 0.5f) < 1e-6f);
  CHECK(fabsf(buf[10] - 0.5f) < 1e-6f);
  CHECK(fabsf(buf[899] - 0.5f) < 1e-6f);

  le_engine_destroy(e);
}

static void test_free_mode_per_track_viz_independent(void) {
  printf("test_free_mode_per_track_viz_independent\n");
  le_engine* e = fm_make_free_engine(1000);

  /* Two tracks, distinct lengths and distinct constant content so their
   * waveforms are trivially distinguishable. */
  fm_record_track_value(e, 0, 900, 0.8f);
  fm_record_track_value(e, 1, 1100, 0.3f);

  /* Both tracks are now PLAYING; run long enough for each to sweep its own
   * full length (publishing every viz bucket at least once). */
  tg_advance(e, 2500);

  float tviz0[LE_VIZ_POINTS];
  float tviz1[LE_VIZ_POINTS];
  CHECK(le_engine_read_track_visual(e, 0, tviz0, LE_VIZ_POINTS) == LE_VIZ_POINTS);
  CHECK(le_engine_read_track_visual(e, 1, tviz1, LE_VIZ_POINTS) == LE_VIZ_POINTS);

  /* Each track's own waveform captured ITS OWN content level -- bucketed
   * against its OWN clock (free_track_viz_tap_frame), not the master's
   * (which would never publish anything: e->clock.length stays 0). */
  CHECK(max_of(tviz0, LE_VIZ_POINTS) > 0.79f);
  CHECK(max_of(tviz0, LE_VIZ_POINTS) < 0.81f);
  CHECK(max_of(tviz1, LE_VIZ_POINTS) > 0.29f);
  CHECK(max_of(tviz1, LE_VIZ_POINTS) < 0.31f);

  /* The MASTER waveform is never touched in Free mode -- there is no single
   * shared loop to visualize (viz_tap_frame's own e->clock.length > 0 gate
   * stays false for the whole run). */
  float loopviz[LE_VIZ_POINTS];
  le_engine_read_visual(e, loopviz, LE_VIZ_POINTS);
  CHECK(max_of(loopviz, LE_VIZ_POINTS) < 1e-6f);

  le_engine_destroy(e);
}

/* ---- Free mode (B2b): adversarial-review follow-up fixes + coverage ----
 *
 * A 13-agent five-lens adversarial review of the original B2b commit found
 * two real defects (BUG 1, BUG 2 below) -- the same bug class as the wdub/
 * od_fade_on fix above (a sibling function reading the permanently-dormant
 * e->clock instead of a Free-mode track's own free_clock), just in code the
 * first pass didn't touch -- plus several already-correct-by-inspection
 * paths that had zero direct test coverage. This section fixes both real
 * bugs and closes every coverage gap the review flagged. */

static void test_free_mode_dub_layer_retires_not_stuck(void) {
  printf("test_free_mode_dub_layer_retires_not_stuck\n");
  /* Regression pin for BUG 1 (adversarial review, empirically proven with a
   * throwaway repro): le_dub_block_update used to read `base` ONCE from the
   * permanently-dormant e->clock.length instead of the track's own
   * free_clock.length, so the post-punch-out drain guards (base > 0) could
   * never pass for a Free-mode track -- a_layer_in_flight got stuck at 1
   * forever: the undo layer never retires (permanently un-undoable) and its
   * dub_slot never returns to the shared bounded pool (a real-time-thread
   * resource leak that eventually starves future overdub captures). */
  le_engine* e = fm_make_free_engine(1000);
  le_snapshot s;

  fm_record_track(e, 0, 900);

  /* Punch in, overdub LESS than a full lap (a partially-covered shadow --
   * exactly the path le_dub_block_update's drain exists for), punch out. */
  le_engine_record(e, 0); /* PLAYING -> OVERDUBBING */
  fm_advance_value(e, 0.3f, 50);
  le_engine_record(e, 0); /* OVERDUBBING -> PLAYING */

  /* Let the punch-out fade tail fully decay (od_gain -> 0) so the block
   * update's "still writing" guard clears and the drain can proceed. */
  tg_advance(e, e->sample_rate / 100 + 5);

  settle_layers(e); /* the reviewer's exact repro shape */

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].layer_in_flight == 0); /* was stuck at 1 before the fix */
  CHECK(e->tracks[0].dub_slot == -1);      /* the shadow slot returned to the pool */
  CHECK(e->tracks[0].dub_retire_slot == -1);

  le_engine_destroy(e);
}

static void test_free_mode_commit_session_rejected_leaves_master_dormant(void) {
  printf("test_free_mode_commit_session_rejected_leaves_master_dormant\n");
  /* Regression pin for BUG 2 (adversarial review): le_engine_commit_session
   * used to post LE_CMD_COMMIT_SESSION unconditionally, which would set
   * e->clock/a_master_len to a nonzero value even while a_looper_mode ==
   * FREE -- violating the invariant every other Free-mode code path in this
   * file depends on staying dormant. Covers BOTH layers of the fix: the
   * control-thread wrapper's synchronous rejection, and the audio-thread
   * handler's own defensive guard (for a raw ring push that bypasses the
   * wrapper entirely -- the real escape hatch, le_engine_post_command,
   * additionally requires a_running, i.e. a live device, so it cannot be
   * exercised in this device-free harness; le_push is the same "post
   * straight onto the ring" primitive minus that requirement, gated only on
   * a_configured like every other control-thread wrapper here, and is
   * exactly what le_engine_commit_session itself calls once past the new
   * guard). */
  le_engine* e = fm_make_free_engine(1000);

  /* Layer 1: the normal wrapper rejects synchronously, before posting. */
  CHECK(le_engine_commit_session(e, 2000) == LE_ERR_INVALID);
  tg_advance(e, 1);
  CHECK(e->clock.length == 0);
  CHECK(load_i32(&e->a_master_len) == 0);

  /* Layer 2: even a raw post (bypassing the wrapper) is declined audio-side. */
  CHECK(le_push(e, LE_CMD_COMMIT_SESSION, 2000, 0.0f) == LE_OK);
  tg_advance(e, 1);
  CHECK(e->clock.length == 0);
  CHECK(load_i32(&e->a_master_len) == 0);

  le_engine_destroy(e);
}

static void test_free_mode_stopped_track_freezes_phase(void) {
  printf("test_free_mode_stopped_track_freezes_phase\n");
  /* GAP 3: advance_track_clock_frame's state gate (only ticks while PLAYING
   * or OVERDUBBING, explicitly excluding STOPPED) had zero direct coverage. */
  le_engine* e = fm_make_free_engine(1000);
  le_snapshot s;

  fm_record_track(e, 0, 900);
  tg_advance(e, 250); /* move well off position 0 */

  const int32_t pos_before_stop = e->tracks[0].free_clock.position;
  const uint64_t iter_before_stop = e->tracks[0].free_iteration;
  CHECK(pos_before_stop > 0);

  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  /* Advance substantially while stopped -- the track's own clock must NOT
   * tick during any of this. */
  tg_advance(e, 5000);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(e->tracks[0].free_clock.position == pos_before_stop);
  CHECK(e->tracks[0].free_iteration == iter_before_stop);

  /* Resume: playback picks up from EXACTLY where it paused, not advanced by
   * the stopped duration. */
  CHECK(le_engine_play(e, 0) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(e->tracks[0].free_clock.position == (pos_before_stop + 1) % 900);

  le_engine_destroy(e);
}

/* GAP 4: the defensive free_clock/free_iteration/track_viz_bucket resets in
 * handle_clear / LE_CMD_UNDO_TO_EMPTY / LE_CMD_REDO_FROM_EMPTY /
 * LE_CMD_RESTORE_CLEAR were correct by code-tracing but had zero direct
 * coverage. Four small tests, each with two Free-mode tracks (distinct
 * lengths, both advanced off position 0): drive one lifecycle path on track
 * 0, assert it resets/restores correctly AND track 1 is byte-for-byte
 * unaffected (catches both over-reset and under-reset). */

static void test_free_mode_clear_resets_targeted_track_only(void) {
  printf("test_free_mode_clear_resets_targeted_track_only\n");
  le_engine* e = fm_make_free_engine(1000);
  le_snapshot s;

  fm_record_track(e, 0, 991);
  fm_record_track(e, 1, 997);
  tg_advance(e, 300);

  const int32_t sib_pos = e->tracks[1].free_clock.position;
  const uint64_t sib_iter = e->tracks[1].free_iteration;
  const int32_t sib_len = e->tracks[1].free_clock.length;
  CHECK(sib_pos > 0);

  CHECK(le_engine_clear(e, 0) == LE_OK);
  tg_advance(e, 1); /* the clear lands, and the sibling ticks once more */

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(e->tracks[0].free_clock.length == 0);
  CHECK(e->tracks[0].free_clock.position == 0);
  CHECK(e->tracks[0].free_iteration == 0);
  CHECK(e->track_viz_bucket[0] == -1);

  /* Sibling is byte-for-byte unaffected, aside from its own natural tick. */
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(e->tracks[1].free_clock.length == sib_len);
  CHECK(e->tracks[1].free_clock.position == sib_pos + 1);
  CHECK(e->tracks[1].free_iteration == sib_iter);

  le_engine_destroy(e);
}

static void test_free_mode_undo_to_empty_resets_targeted_track_only(void) {
  printf("test_free_mode_undo_to_empty_resets_targeted_track_only\n");
  le_engine* e = fm_make_free_engine(1000);
  le_snapshot s;

  fm_record_track(e, 0, 991);
  fm_record_track(e, 1, 997);
  tg_advance(e, 300);

  const int32_t sib_pos = e->tracks[1].free_clock.position;
  const uint64_t sib_iter = e->tracks[1].free_iteration;
  const int32_t sib_len = e->tracks[1].free_clock.length;

  /* Track 0 has no overdub layers -- undoing the base recording itself
   * empties it (le_engine_undo's undo_count == 0 path -> LE_CMD_UNDO_TO_EMPTY). */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  tg_advance(e, 1);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(e->tracks[0].free_clock.length == 0);
  CHECK(e->tracks[0].free_clock.position == 0);
  CHECK(e->tracks[0].free_iteration == 0);
  CHECK(e->track_viz_bucket[0] == -1);

  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(e->tracks[1].free_clock.length == sib_len);
  CHECK(e->tracks[1].free_clock.position == sib_pos + 1);
  CHECK(e->tracks[1].free_iteration == sib_iter);

  le_engine_destroy(e);
}

static void test_free_mode_redo_from_empty_restores_targeted_track_only(void) {
  printf("test_free_mode_redo_from_empty_restores_targeted_track_only\n");
  le_engine* e = fm_make_free_engine(1000);
  le_snapshot s;

  fm_record_track(e, 0, 991);
  fm_record_track(e, 1, 997);
  tg_advance(e, 300);

  const int32_t sib_pos_before = e->tracks[1].free_clock.position;
  const uint64_t sib_iter_before = e->tracks[1].free_iteration;
  const int32_t sib_len = e->tracks[1].free_clock.length;

  CHECK(le_engine_undo(e, 0) == LE_OK); /* -> EMPTY, redo stack holds the base take */
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);

  CHECK(le_engine_redo(e, 0) == LE_OK); /* -> LE_CMD_REDO_FROM_EMPTY */
  tg_advance(e, 1);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].length_frames == 991);
  /* THIS track's own clock is freshly re-established at its original length
   * -- not left dormant, and not resurrecting whatever position/iteration
   * it happened to be at before the undo (fresh position 0, one tick having
   * landed by the frame the redo applies). */
  CHECK(e->tracks[0].free_clock.length == 991);
  CHECK(e->tracks[0].free_clock.position == 1);
  CHECK(e->tracks[0].free_iteration == 0);

  /* Sibling: two more of its own ticks landed (the undo's block, the redo's
   * block) -- completely unaffected by track 0's whole undo/redo round trip. */
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(e->tracks[1].free_clock.length == sib_len);
  CHECK(e->tracks[1].free_clock.position == sib_pos_before + 2);
  CHECK(e->tracks[1].free_iteration == sib_iter_before);

  le_engine_destroy(e);
}

static void test_free_mode_restore_clear_restores_targeted_track_only(void) {
  printf("test_free_mode_restore_clear_restores_targeted_track_only\n");
  le_engine* e = fm_make_free_engine(1000);
  le_snapshot s;

  fm_record_track(e, 0, 991);
  fm_record_track(e, 1, 997);
  tg_advance(e, 300);

  const int32_t sib_pos_before = e->tracks[1].free_clock.position;
  const uint64_t sib_iter_before = e->tracks[1].free_iteration;
  const int32_t sib_len = e->tracks[1].free_clock.length;

  CHECK(le_engine_clear_undoable(e, 0) == LE_OK); /* -> EMPTY, restore point stacked */
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(e->tracks[0].free_clock.length == 0); /* handle_clear's reset, proven above */

  CHECK(le_engine_undo(e, 0) == LE_OK); /* history is cleared -> LE_CMD_RESTORE_CLEAR */
  tg_advance(e, 1);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].length_frames == 991);
  CHECK(e->tracks[0].free_clock.length == 991);
  CHECK(e->tracks[0].free_iteration == 0);

  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(e->tracks[1].free_clock.length == sib_len);
  CHECK(e->tracks[1].free_clock.position == sib_pos_before + 2);
  CHECK(e->tracks[1].free_iteration == sib_iter_before);

  le_engine_destroy(e);
}

static void test_free_mode_playback_output_scans_own_position(void) {
  printf("test_free_mode_playback_output_scans_own_position\n");
  /* GAP 5: pins the mix_tracks_frame READ side specifically (loopsample =
   * lbuf[seg_base[t] + trk_pos[t]]) via the AUDIBLE OUTPUT (out[]), not just
   * the raw write buffer the earlier overdub test checks -- a revert of
   * just that one read line (leaving the write side correct) would silently
   * stick Free-mode playback at position-0 content forever, and nothing
   * else in this suite would catch it. */
  le_engine* e = fm_make_free_engine(1000);

  /* Two distinguishable halves of an 800-frame loop. The seam-crossfade
   * deferral (finalize press, below) is fed the SAME value as the head
   * (0.2f) so the equal-gain blend of "continuation" into "head" over the
   * first few frames stays a clean 0.2f rather than smearing toward
   * whatever the deferral window happened to capture. */
  le_engine_record(e, 0);
  fm_advance_value(e, 0.2f, 400); /* first half: buf[0..399] */
  fm_advance_value(e, 0.9f, 400); /* second half: buf[400..799] */
  le_engine_record(e, 0);         /* finalize (defers for the seam crossfade) */
  fm_advance_value(e, 0.2f, e->sample_rate / 100);

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].length_frames == 800);

  float in[1] = {0.0f};
  float out[1];

  /* Rewind to the loop top (a whole number of laps) so the next frame reads
   * index 0 of the first half. */
  const int32_t pos_now = e->tracks[0].free_clock.position;
  tg_advance(e, (800 - pos_now) % 800);
  CHECK(e->tracks[0].free_clock.position == 0);

  le_engine_process(e, out, in, 1); /* reads index 0: first half */
  CHECK(fabsf(out[0] - 0.2f) < 1e-5f);

  /* Advance to the middle of the loop (index 400: second half) and sample
   * the output there too -- proves the read position actually moved. */
  tg_advance(e, 399); /* one frame already consumed by the process() above */
  CHECK(e->tracks[0].free_clock.position == 400);
  le_engine_process(e, out, in, 1);
  CHECK(fabsf(out[0] - 0.9f) < 1e-5f);

  le_engine_destroy(e);
}

static void test_free_mode_punch_in_ramps_not_hard_cuts(void) {
  printf("test_free_mode_punch_in_ramps_not_hard_cuts\n");
  /* GAP 6: pins that od_fade_on's per-track fix (trk_len[t] instead of the
   * master's always-0 length) actually keeps the punch fade RAMPING in Free
   * mode rather than hard-cutting -- sampled at the punch edge itself
   * (the FIRST overdubbed frame), where a missing ramp (od_gain snapping
   * straight to the 1.0 target) is indistinguishable from a correct one by
   * the time content is read deep into the window, as the existing test
   * does. */
  le_engine* e = fm_make_free_engine(1000);

  fm_record_track_value(e, 0, 900, 0.5f);
  tg_advance(e, 100); /* off position 0, not near the loop top */

  le_engine_record(e, 0);       /* PLAYING -> OVERDUBBING */
  fm_advance_value(e, 1.0f, 1); /* exactly the FIRST overdubbed frame */

  const int32_t live = load_i32(&e->tracks[0].lanes[0].a_live);
  const float* buf = e->tracks[0].lanes[0].pool[live];
  CHECK(buf != NULL);

  /* At the very first punched-in frame, od_gain has ramped only ONE step
   * (od_step = 1 / od_fade_frames = 0.1 at this sample rate): a hard cut
   * would already read ~1.5 (0.5 + 1.0*1.0) here; a missing gate would read
   * exactly 0.5 (no overdub at all); a correct ramp reads ~0.6. */
  const int32_t punch_idx = 100; /* position was 100 when the punch landed */
  CHECK(buf[punch_idx] > 0.5f);
  CHECK(buf[punch_idx] < 0.7f);

  le_engine_destroy(e);
}

/* ---- Song mode per-track clocks (B4) ----
 *
 * Song mode's transport ("independent lengths, no primary, no shared grid
 * obligation" — song-mode-spec.md §2) is structurally identical to Free's,
 * so B4 reuses B2b's per-track free_clock machinery outright: every gate
 * above that used to read `mode == FREE` now reads `mode == FREE || mode ==
 * SONG`, and nothing else changed. These tests are deliberately NOT a
 * wholesale re-run of every Free-mode test above — they exist to prove the
 * gate-broadening itself is correct at each of the sites B4 touched
 * (finalize_master, le_dub_block_update, LE_CMD_REDO_FROM_EMPTY,
 * LE_CMD_RESTORE_CLEAR, the viz taps, mix_tracks_frame's trk_pos/trk_len
 * seeding, and the NEW commit-session guard), not to re-prove Free-mode
 * math the code path is byte-for-byte shared with. fm_record_track /
 * fm_record_track_value / fm_advance_value above are mode-agnostic (they
 * only call le_engine_record / tg_advance) and are reused verbatim. */

/* A fresh engine, switched into Song mode (every track starts empty, so the
 * D4 gate accepts it immediately). */
static le_engine* sm_make_song_engine(int sr) {
  le_engine* e = tg_make_engine(sr);
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SONG) == LE_OK);
  tg_advance(e, 1);
  return e;
}

static void test_song_mode_defining_recording_sets_own_clock_not_master(
    void) {
  printf("test_song_mode_defining_recording_sets_own_clock_not_master\n");
  le_engine* e = sm_make_song_engine(1000);
  le_snapshot s;

  fm_record_track(e, 0, 1500);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].length_frames == 1500);
  CHECK(s.tracks[0].multiple == 1);

  /* The shared master never moves -- Song mode's sections are simply tracks
   * with no shared grid (song-mode-spec.md §1). */
  CHECK(s.master_length_frames == 0);
  CHECK(e->clock.length == 0);
  CHECK(load_i32(&e->a_master_len) == 0);
  CHECK(e->loop_iteration == 0);

  CHECK(e->tracks[0].free_clock.length == 1500);
  CHECK(e->tracks[0].free_clock.position == 0);
  CHECK(e->tracks[0].free_iteration == 0);

  le_engine_destroy(e);
}

static void test_song_mode_independent_lengths_wraps(void) {
  printf("test_song_mode_independent_lengths_wraps\n");
  le_engine* e = sm_make_song_engine(1000);
  le_snapshot s;

  /* 4 mutually prime lengths (a section per track): enough to prove no
   * shared-grid interference between sections without wholesale duplicating
   * Free's own 8-track proof of the same underlying clock math. */
  const int32_t len[4] = {97, 101, 103, 107};
  for (int32_t ch = 0; ch < 4; ++ch) {
    fm_record_track(e, ch, len[ch]);
  }

  le_engine_get_snapshot(e, &s);
  for (int32_t ch = 0; ch < 4; ++ch) {
    CHECK(s.tracks[ch].state == LE_TRACK_PLAYING);
    CHECK(s.tracks[ch].length_frames == len[ch]);
    CHECK(e->tracks[ch].free_clock.length == len[ch]);
  }
  CHECK(load_i32(&e->a_master_len) == 0);
  CHECK(e->clock.length == 0);

  int32_t base_pos[4];
  uint64_t base_iter[4];
  for (int32_t ch = 0; ch < 4; ++ch) {
    base_pos[ch] = e->tracks[ch].free_clock.position;
    base_iter[ch] = e->tracks[ch].free_iteration;
  }

  const int N = 1500; /* several wraps on every section, even the longest */
  tg_advance(e, N);

  for (int32_t ch = 0; ch < 4; ++ch) {
    const int64_t total = (int64_t)base_pos[ch] + N;
    const int32_t expect_pos = (int32_t)(total % len[ch]);
    const uint64_t expect_iter = base_iter[ch] + (uint64_t)(total / len[ch]);
    CHECK(e->tracks[ch].free_clock.position == expect_pos);
    CHECK(e->tracks[ch].free_iteration == expect_iter);
    CHECK(expect_iter >= base_iter[ch] + 3);
  }

  CHECK(load_i32(&e->a_master_len) == 0);
  CHECK(e->clock.length == 0);
  CHECK(e->loop_iteration == 0);

  le_engine_destroy(e);
}

static void test_song_mode_one_capturer_handoff_finalizes_to_own_length(
    void) {
  printf("test_song_mode_one_capturer_handoff_finalizes_to_own_length\n");
  le_engine* e = sm_make_song_engine(1000);
  le_snapshot s;

  /* Section 0 already established. */
  fm_record_track(e, 0, 2000);
  le_engine_get_snapshot(e, &s);
  const int32_t sec0_len_before = e->tracks[0].free_clock.length;

  /* Section 1 starts its own defining recording, left in flight. */
  le_engine_record(e, 1);
  tg_advance(e, 400);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);

  /* Punching in on section 0 hands off the one input stream
   * (close_active_capture -- unconditional and mode-agnostic, unchanged by
   * B4): section 1's in-flight recording finalizes RIGHT HERE, to ITS OWN
   * length -- direct per-track presses, exactly as the spec's "no advance
   * gesture, no special in-flight rule" (song-mode-spec.md §2 Q4) says. */
  le_engine_record(e, 0);
  tg_advance(e, 1);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].length_frames == 400);
  CHECK(e->tracks[1].free_clock.length == 400);
  CHECK(e->tracks[1].free_clock.length != sec0_len_before);

  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);
  CHECK(e->tracks[0].free_clock.length == sec0_len_before);

  CHECK(load_i32(&e->a_master_len) == 0);
  CHECK(e->clock.length == 0);

  le_engine_destroy(e);
}

static void test_song_mode_commit_session_rejected_leaves_master_dormant(
    void) {
  printf("test_song_mode_commit_session_rejected_leaves_master_dormant\n");
  /* NEW guard (B4): session import's single-shared-base COMMIT_SESSION is
   * just as incompatible with Song's independent per-track lengths as it is
   * with Free's -- le_engine_commit_session (engine_session.c) and the
   * audio-thread handler's own defensive copy (engine_process.c) both now
   * reject SONG, mirroring the exact two-layer guard B2b already had for
   * FREE (adversarial-review BUG 2). */
  le_engine* e = sm_make_song_engine(1000);

  /* Layer 1: the normal wrapper rejects synchronously, before posting. */
  CHECK(le_engine_commit_session(e, 2000) == LE_ERR_INVALID);
  tg_advance(e, 1);
  CHECK(e->clock.length == 0);
  CHECK(load_i32(&e->a_master_len) == 0);

  /* Layer 2: even a raw post (bypassing the wrapper) is declined audio-side. */
  CHECK(le_push(e, LE_CMD_COMMIT_SESSION, 2000, 0.0f) == LE_OK);
  tg_advance(e, 1);
  CHECK(e->clock.length == 0);
  CHECK(load_i32(&e->a_master_len) == 0);

  le_engine_destroy(e);
}

static void test_song_mode_dub_layer_retires_not_stuck(void) {
  printf("test_song_mode_dub_layer_retires_not_stuck\n");
  /* Regression pin for the SAME bug class B2b's adversarial review found and
   * fixed for Free (le_dub_block_update's `base` must read the TRACK's own
   * free_clock.length, not the permanently-dormant e->clock.length) --
   * proves B4's gate-broadening covers this site too. Without it, a Song-
   * mode partially-covered overdub shadow would never drain: a_layer_in_
   * flight stuck at 1 forever, the shadow slot never returned to the
   * shared bounded pool. */
  le_engine* e = sm_make_song_engine(1000);
  le_snapshot s;

  fm_record_track(e, 0, 900);

  le_engine_record(e, 0); /* PLAYING -> OVERDUBBING */
  fm_advance_value(e, 0.3f, 50); /* less than a full lap */
  le_engine_record(e, 0); /* OVERDUBBING -> PLAYING */

  tg_advance(e, e->sample_rate / 100 + 5); /* let the punch-out fade decay */

  settle_layers(e);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].layer_in_flight == 0);
  CHECK(e->tracks[0].dub_slot == -1);
  CHECK(e->tracks[0].dub_retire_slot == -1);

  le_engine_destroy(e);
}

/* GAP-style coverage (mirroring the Free-mode section's own four
 * lifecycle-path tests): the defensive free_clock/free_iteration/
 * track_viz_bucket resets in handle_clear / LE_CMD_UNDO_TO_EMPTY /
 * LE_CMD_REDO_FROM_EMPTY / LE_CMD_RESTORE_CLEAR are exercised in Song mode
 * specifically because REDO_FROM_EMPTY and RESTORE_CLEAR are sites B4
 * actually changed (broadened from a FREE-only check) -- handle_clear and
 * UNDO_TO_EMPTY's resets are unconditional (mode-agnostic already) and are
 * included here mainly for symmetry / a complete lifecycle picture. */

static void test_song_mode_clear_resets_targeted_track_only(void) {
  printf("test_song_mode_clear_resets_targeted_track_only\n");
  le_engine* e = sm_make_song_engine(1000);
  le_snapshot s;

  fm_record_track(e, 0, 811);
  fm_record_track(e, 1, 823);
  tg_advance(e, 300);

  const int32_t sib_pos = e->tracks[1].free_clock.position;
  const uint64_t sib_iter = e->tracks[1].free_iteration;
  const int32_t sib_len = e->tracks[1].free_clock.length;
  CHECK(sib_pos > 0);

  CHECK(le_engine_clear(e, 0) == LE_OK);
  tg_advance(e, 1);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(e->tracks[0].free_clock.length == 0);
  CHECK(e->tracks[0].free_clock.position == 0);
  CHECK(e->tracks[0].free_iteration == 0);
  CHECK(e->track_viz_bucket[0] == -1);

  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(e->tracks[1].free_clock.length == sib_len);
  CHECK(e->tracks[1].free_clock.position == sib_pos + 1);
  CHECK(e->tracks[1].free_iteration == sib_iter);

  le_engine_destroy(e);
}

static void test_song_mode_undo_to_empty_resets_targeted_track_only(void) {
  printf("test_song_mode_undo_to_empty_resets_targeted_track_only\n");
  le_engine* e = sm_make_song_engine(1000);
  le_snapshot s;

  fm_record_track(e, 0, 811);
  fm_record_track(e, 1, 823);
  tg_advance(e, 300);

  const int32_t sib_pos = e->tracks[1].free_clock.position;
  const uint64_t sib_iter = e->tracks[1].free_iteration;
  const int32_t sib_len = e->tracks[1].free_clock.length;

  CHECK(le_engine_undo(e, 0) == LE_OK); /* no layers -> UNDO_TO_EMPTY */
  tg_advance(e, 1);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(e->tracks[0].free_clock.length == 0);
  CHECK(e->tracks[0].free_clock.position == 0);
  CHECK(e->tracks[0].free_iteration == 0);
  CHECK(e->track_viz_bucket[0] == -1);

  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(e->tracks[1].free_clock.length == sib_len);
  CHECK(e->tracks[1].free_clock.position == sib_pos + 1);
  CHECK(e->tracks[1].free_iteration == sib_iter);

  le_engine_destroy(e);
}

static void test_song_mode_redo_from_empty_restores_targeted_track_only(
    void) {
  printf("test_song_mode_redo_from_empty_restores_targeted_track_only\n");
  /* B4-touched site: before this PR, LE_CMD_REDO_FROM_EMPTY's mode check
   * only matched FREE, so a Song-mode redo would have fallen into the
   * ELSE branch (le_restore_multiple_or_divisor against e->clock.length,
   * always 0 in Song) instead of restoring this track's OWN free_clock --
   * silently corrupting the restored section's playback position. */
  le_engine* e = sm_make_song_engine(1000);
  le_snapshot s;

  fm_record_track(e, 0, 811);
  fm_record_track(e, 1, 823);
  tg_advance(e, 300);

  const int32_t sib_pos_before = e->tracks[1].free_clock.position;
  const uint64_t sib_iter_before = e->tracks[1].free_iteration;
  const int32_t sib_len = e->tracks[1].free_clock.length;

  CHECK(le_engine_undo(e, 0) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);

  CHECK(le_engine_redo(e, 0) == LE_OK); /* -> LE_CMD_REDO_FROM_EMPTY */
  tg_advance(e, 1);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].length_frames == 811);
  CHECK(e->tracks[0].free_clock.length == 811);
  CHECK(e->tracks[0].free_clock.position == 1);
  CHECK(e->tracks[0].free_iteration == 0);

  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(e->tracks[1].free_clock.length == sib_len);
  CHECK(e->tracks[1].free_clock.position == sib_pos_before + 2);
  CHECK(e->tracks[1].free_iteration == sib_iter_before);

  le_engine_destroy(e);
}

static void test_song_mode_restore_clear_restores_targeted_track_only(void) {
  printf("test_song_mode_restore_clear_restores_targeted_track_only\n");
  /* B4-touched site: the LE_CMD_RESTORE_CLEAR twin of the redo test above. */
  le_engine* e = sm_make_song_engine(1000);
  le_snapshot s;

  fm_record_track(e, 0, 811);
  fm_record_track(e, 1, 823);
  tg_advance(e, 300);

  const int32_t sib_pos_before = e->tracks[1].free_clock.position;
  const uint64_t sib_iter_before = e->tracks[1].free_iteration;
  const int32_t sib_len = e->tracks[1].free_clock.length;

  CHECK(le_engine_clear_undoable(e, 0) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(e->tracks[0].free_clock.length == 0);

  CHECK(le_engine_undo(e, 0) == LE_OK); /* history is cleared -> RESTORE_CLEAR */
  tg_advance(e, 1);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].length_frames == 811);
  CHECK(e->tracks[0].free_clock.length == 811);
  CHECK(e->tracks[0].free_iteration == 0);

  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(e->tracks[1].free_clock.length == sib_len);
  CHECK(e->tracks[1].free_clock.position == sib_pos_before + 2);
  CHECK(e->tracks[1].free_iteration == sib_iter_before);

  le_engine_destroy(e);
}

static void test_song_mode_per_track_viz_independent(void) {
  printf("test_song_mode_per_track_viz_independent\n");
  le_engine* e = sm_make_song_engine(1000);

  fm_record_track_value(e, 0, 900, 0.8f);
  fm_record_track_value(e, 1, 1100, 0.3f);

  tg_advance(e, 2500);

  float tviz0[LE_VIZ_POINTS];
  float tviz1[LE_VIZ_POINTS];
  CHECK(le_engine_read_track_visual(e, 0, tviz0, LE_VIZ_POINTS) == LE_VIZ_POINTS);
  CHECK(le_engine_read_track_visual(e, 1, tviz1, LE_VIZ_POINTS) == LE_VIZ_POINTS);

  CHECK(max_of(tviz0, LE_VIZ_POINTS) > 0.79f);
  CHECK(max_of(tviz0, LE_VIZ_POINTS) < 0.81f);
  CHECK(max_of(tviz1, LE_VIZ_POINTS) > 0.29f);
  CHECK(max_of(tviz1, LE_VIZ_POINTS) < 0.31f);

  /* The MASTER waveform is never touched in Song mode either. */
  float loopviz[LE_VIZ_POINTS];
  le_engine_read_visual(e, loopviz, LE_VIZ_POINTS);
  CHECK(max_of(loopviz, LE_VIZ_POINTS) < 1e-6f);

  le_engine_destroy(e);
}

static void test_song_mode_playback_output_scans_own_position(void) {
  printf("test_song_mode_playback_output_scans_own_position\n");
  /* B4 GAP 5 (Song twin of test_free_mode_playback_output_scans_own_position,
   * above): pins mix_tracks_frame's READ side specifically (loopsample =
   * lbuf[seg_base[t] + trk_pos[t]]) via the AUDIBLE OUTPUT (out[]) for SONG
   * mode -- adversarial review found that test_song_mode_per_track_viz_
   * independent, above, records a CONSTANT value across the whole loop, so
   * it cannot distinguish "reads this track's own live position" from
   * "stuck reading position 0 forever": both read the same constant. Two
   * DISTINGUISHABLE halves, sampled through REAL le_engine_process() output
   * at two different loop positions (mirroring the Free-mode GAP 5 test
   * exactly), close that gap: a revert of just mix_tracks_frame's Free/Song
   * position-seeding guard (engine_process.c, the free_track_positions_frame
   * call) would leave Song-mode playback stuck at position-0 content
   * forever, and this is the test that catches it directly rather than as
   * an incidental side effect of unrelated overdub bookkeeping. */
  le_engine* e = sm_make_song_engine(1000);

  /* Two distinguishable halves of an 800-frame section. The seam-crossfade
   * deferral (finalize press, below) is fed the SAME value as the head
   * (0.2f) so the equal-gain blend of "continuation" into "head" over the
   * first few frames stays a clean 0.2f rather than smearing toward
   * whatever the deferral window happened to capture. */
  le_engine_record(e, 0);
  fm_advance_value(e, 0.2f, 400); /* first half: buf[0..399] */
  fm_advance_value(e, 0.9f, 400); /* second half: buf[400..799] */
  le_engine_record(e, 0);         /* finalize (defers for the seam crossfade) */
  fm_advance_value(e, 0.2f, e->sample_rate / 100);

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].length_frames == 800);

  float in[1] = {0.0f};
  float out[1];

  /* Rewind to the loop top (a whole number of laps) so the next frame reads
   * index 0 of the first half. */
  const int32_t pos_now = e->tracks[0].free_clock.position;
  tg_advance(e, (800 - pos_now) % 800);
  CHECK(e->tracks[0].free_clock.position == 0);

  le_engine_process(e, out, in, 1); /* reads index 0: first half */
  CHECK(fabsf(out[0] - 0.2f) < 1e-5f);

  /* Advance to the middle of the loop (index 400: second half) and sample
   * the output there too -- proves the read position actually moved. */
  tg_advance(e, 399); /* one frame already consumed by the process() above */
  CHECK(e->tracks[0].free_clock.position == 400);
  le_engine_process(e, out, in, 1);
  CHECK(fabsf(out[0] - 0.9f) < 1e-5f);

  le_engine_destroy(e);
}

/* Regression: B2a's D4 content-lock gate (le_looper_mode_locked) is
 * UNCHANGED by B4 -- it never became mode-specific, and reusing Free's
 * gates for Song didn't touch it. Chains Multi -> Song (locked, then
 * unlocked) and Song -> Free (locked, then unlocked), the two transitions
 * the task explicitly calls out. */
static void test_looper_mode_switch_multi_song_free_locked_with_content(
    void) {
  printf("test_looper_mode_switch_multi_song_free_locked_with_content\n");
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  tg_record_defining_loop(e, 2000); /* Multi-mode content on track 0 */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state != LE_TRACK_EMPTY);

  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SONG) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_MULTI); /* still locked */

  le_engine_clear(e, 0);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);

  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SONG) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_SONG); /* unlocked: applies */

  /* Song-mode content locks switching AWAY too -- reusing Free's gates
   * didn't quietly weaken Song's own D4 lock. */
  fm_record_track(e, 0, 500);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state != LE_TRACK_EMPTY);

  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_FREE) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_SONG); /* still locked */

  le_engine_clear(e, 0);
  tg_advance(e, 1);
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_FREE) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_FREE); /* unlocked: applies */

  le_engine_destroy(e);
}

/* ---- One Shot (B4, Sheeran manual §5.9.4) ----
 *
 * A per-track "plays just once and then stops" flag (LE_CMD_SET_ONE_SHOT).
 * Settable in any mode (mirrors a_primary_track's D18 persistence pattern),
 * but only behaviorally active in Free/Song -- the only two modes with a
 * per-track transport-wrap event to hook (advance_track_clock_frame's
 * free_clock wrap). Dormant elsewhere: proven below in Multi mode. */

static void test_one_shot_default_off(void) {
  printf("test_one_shot_default_off\n");
  le_engine* e = make_configured_engine();
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].one_shot == 0);
  le_engine_destroy(e);
}

static void test_one_shot_setter_rejects_invalid_channel(void) {
  printf("test_one_shot_setter_rejects_invalid_channel\n");
  le_engine* e = make_configured_engine();
  CHECK(le_engine_set_one_shot(e, -1, 1) == LE_ERR_INVALID);
  CHECK(le_engine_set_one_shot(e, 999, 1) == LE_ERR_INVALID);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].one_shot == 0); /* untouched by the rejected calls */
  le_engine_destroy(e);
}

static void test_one_shot_setter_accepted_in_any_mode(void) {
  printf("test_one_shot_setter_accepted_in_any_mode\n");
  le_engine* e = make_configured_engine();
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_MULTI);
  CHECK(le_engine_set_one_shot(e, 1, 1) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].one_shot == 1);
  le_engine_destroy(e);
}

static void test_one_shot_persists_through_clear_reset_by_configure(void) {
  printf("test_one_shot_persists_through_clear_reset_by_configure\n");
  le_engine* e = sm_make_song_engine(1000);
  CHECK(le_engine_set_one_shot(e, 0, 1) == LE_OK);
  drain(e);
  fm_record_track(e, 0, 500);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].one_shot == 1);

  /* A SETTING, not content: clear does not reset it -- like
   * a_length_preset_bars, a re-recorded track keeps its flag. */
  CHECK(le_engine_clear(e, 0) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[0].one_shot == 1);

  /* A full reconfigure DOES reset it, exactly like a_length_preset_bars /
   * target_multiple / track_quantize -- the "fresh engine" boundary. */
  CHECK(le_engine_configure(e, 1000, 1, 1, 20000) == LE_OK);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].one_shot == 0);

  le_engine_destroy(e);
}

static void test_one_shot_stops_track_at_wrap_in_song_mode(void) {
  printf("test_one_shot_stops_track_at_wrap_in_song_mode\n");
  le_engine* e = sm_make_song_engine(1000);
  le_snapshot s;

  CHECK(le_engine_set_one_shot(e, 0, 1) == LE_OK);
  drain(e);

  fm_record_track(e, 0, 300);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(e->tracks[0].free_clock.position == 0);

  /* Just short of one full lap: still playing normally. */
  tg_advance(e, 299);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);

  /* The 300th frame completes the lap: One Shot fires instead of wrapping
   * into a second pass. */
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  const int32_t pos_at_stop = e->tracks[0].free_clock.position;
  const uint64_t iter_at_stop = e->tracks[0].free_iteration;
  CHECK(pos_at_stop == 0); /* the wrap itself completed */
  CHECK(iter_at_stop == 1);

  /* A STOPPED track's clock never ticks, one-shot or not (mirrors
   * test_free_mode_stopped_track_freezes_phase). */
  tg_advance(e, 500);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);
  CHECK(e->tracks[0].free_clock.position == pos_at_stop);
  CHECK(e->tracks[0].free_iteration == iter_at_stop);

  le_engine_destroy(e);
}

static void test_one_shot_off_track_keeps_looping_in_song_mode(void) {
  printf("test_one_shot_off_track_keeps_looping_in_song_mode\n");
  /* Control for the test above: the SAME section, WITHOUT the flag, keeps
   * looping past several laps -- proves the stop is the flag's doing, not
   * some other Song-mode side effect. */
  le_engine* e = sm_make_song_engine(1000);
  le_snapshot s;

  fm_record_track(e, 0, 300);

  tg_advance(e, 300); /* exactly one full lap */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(e->tracks[0].free_clock.position == 0);
  CHECK(e->tracks[0].free_iteration == 1);

  tg_advance(e, 350); /* well into a second lap */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(e->tracks[0].free_iteration >= 2);

  le_engine_destroy(e);
}

static void test_one_shot_dormant_in_multi_mode(void) {
  printf("test_one_shot_dormant_in_multi_mode\n");
  /* B4 design decision: One Shot only has a wrap event to hook in Free/
   * Song (advance_track_clock_frame's free_clock check) -- in Multi/Sync/
   * Band a track's own "lap" is a derived point on the ONE shared master
   * clock, not an independent per-track event. The flag is still settable
   * and published here (test_one_shot_setter_accepted_in_any_mode), but
   * this proves it has ZERO effect on playback in Multi: several full
   * master-loop laps with the flag set, still PLAYING throughout. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_MULTI);

  CHECK(le_engine_set_one_shot(e, 0, 1) == LE_OK);
  drain(e);

  tg_record_defining_loop(e, 300);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].one_shot == 1); /* published, but... */

  tg_advance(e, 300 * 4); /* several master-loop laps */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING); /* dormant: never stopped */
  CHECK(e->loop_iteration >= 3);

  le_engine_destroy(e);
}

static void test_one_shot_overdubbing_track_stops_cleanly_at_wrap(void) {
  printf("test_one_shot_overdubbing_track_stops_cleanly_at_wrap\n");
  /* One Shot's stop reuses handle_stop's exact PLAYING/OVERDUBBING ->
   * STOPPED transition (le_consume_pending_mutes lands the same way) --
   * pins that a One-Shot fire mid-overdub ends the capture cleanly: the
   * in-flight layer still drains and retires through the ordinary post-
   * punch-out path, exactly as a manual Stop press mid-overdub would leave
   * it (no stuck a_layer_in_flight / dub_slot). */
  le_engine* e = sm_make_song_engine(1000);
  le_snapshot s;

  CHECK(le_engine_set_one_shot(e, 0, 1) == LE_OK);
  drain(e);
  fm_record_track(e, 0, 300);

  tg_advance(e, 100);
  le_engine_record(e, 0); /* PLAYING -> OVERDUBBING, punch in */
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_OVERDUBBING);

  /* Cross the loop top while still overdubbing. */
  tg_advance(e, 300);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED); /* fired mid-overdub */

  settle_layers(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].layer_in_flight == 0);
  CHECK(e->tracks[0].dub_slot == -1);
  CHECK(e->tracks[0].dub_retire_slot == -1);

  le_engine_destroy(e);
}

static void test_one_shot_persists_across_mode_switch_fires_on_first_wrap(
    void) {
  printf("test_one_shot_persists_across_mode_switch_fires_on_first_wrap\n");
  /* Adversarial review (B4): the "settable in any mode" design (LE_CMD_SET_
   * ONE_SHOT's doc, loopy_engine_api.h; a_one_shot's doc, engine_private.h)
   * is deliberate -- mirrors LE_CMD_CROWN_PRIMARY's D18 persistent-
   * designation pattern -- but no existing test exercised the actual
   * cross-mode path: set while in Multi (where test_one_shot_dormant_in_
   * multi_mode, above, already proves it inert), clear (D4 needs an empty
   * rig), switch to Song, then record fresh content. handle_clear does NOT
   * reset a_one_shot (only le_engine_configure does -- see test_one_shot_
   * persists_through_clear_reset_by_configure, above, for the same-mode
   * case), so the flag survives all the way from Multi into Song with no
   * re-arm, and fires on the very first Song-mode wrap. This is TODAY'S
   * actual, intentional engine behavior, pinned so a future change to it
   * (e.g. B5c deciding to reset One Shot on mode switch as a UX guard) is a
   * deliberate, visible edit to this test -- not a silent regression. */
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_MULTI);

  /* Record real content in Multi mode, then flag it one-shot -- settable and
   * (per test_one_shot_dormant_in_multi_mode) INERT here. */
  tg_record_defining_loop(e, 300);
  CHECK(le_engine_set_one_shot(e, 0, 1) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].one_shot == 1);

  /* D4 needs an empty rig to switch mode -- clear (handle_clear does NOT
   * touch a_one_shot). */
  CHECK(le_engine_clear(e, 0) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[0].one_shot == 1); /* survives the clear */

  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SONG) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_SONG);
  CHECK(s.tracks[0].one_shot == 1); /* survives the mode switch too */

  /* Record a brand-new section in Song mode -- the flag was never re-set
   * since Multi mode, two steps ago. */
  fm_record_track(e, 0, 300);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[0].one_shot == 1);

  /* Just short of the first lap: still playing normally. */
  tg_advance(e, 299);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_PLAYING);

  /* The very first Song-mode wrap fires the flag that was set back in
   * Multi -- no separate LE_CMD_SET_ONE_SHOT was ever posted in Song. */
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_STOPPED);

  le_engine_destroy(e);
}

/* ---- B3: primary track (D18), Sync mode (D16) ----
 *
 * D18: a_primary_track (-1 = none) persists through a crowned track's
 * clear/undo-to-empty; only an explicit re-crown changes it. D16: Sync's
 * non-primary tracks snap their DEFINING recording to the nearest of
 * {1/4, 1/2, 1, 2, 4} times the primary's length once a primary is crowned
 * AND established (has content, exactly one base loop); with no primary
 * yet, Sync behaves exactly like Multi (AUTO round-up). Band shares this
 * SAME primary/multiple-division machinery (le_sync_quantize_active checks
 * BAND too), but its ADDITIONAL independently start/stoppable section
 * tracks are a follow-on part (B3b) — see the B3 PR notes. */

/* Writes one distinct value per frame from [values] (n <= 64, matching every
 * other small-loop test helper's implicit bound). */
static void process_seq(le_engine* e, const float* values, int n, float* out) {
  float in[64];
  for (int i = 0; i < n; ++i) in[i] = values[i];
  le_engine_process(e, out, in, (uint32_t)n);
}

#define SB_BASE 16 /* primary loop length for every B3 test below */

static void test_primary_track_default_none(void) {
  printf("test_primary_track_default_none\n");
  le_engine* e = make_configured_engine();
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.primary_track == -1);
  le_engine_destroy(e);
}

static void test_crown_primary_rejects_invalid_channel(void) {
  printf("test_crown_primary_rejects_invalid_channel\n");
  le_engine* e = make_configured_engine();
  CHECK(le_engine_crown_primary(e, -1) == LE_ERR_INVALID);
  CHECK(le_engine_crown_primary(e, 999) == LE_ERR_INVALID);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.primary_track == -1); /* untouched by the rejected calls */
  le_engine_destroy(e);
}

static void test_crown_primary_sets_field(void) {
  printf("test_crown_primary_sets_field\n");
  le_engine* e = make_configured_engine();
  CHECK(le_engine_crown_primary(e, 2) == LE_OK);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.primary_track == 2);
  le_engine_destroy(e);
}

static void test_crown_primary_accepted_in_any_mode(void) {
  printf("test_crown_primary_accepted_in_any_mode\n");
  /* D18: the crown is a persistent designation, independent of mode --
   * accepted (and published) here in the default MULTI mode, even though
   * it has no effect there (le_sync_quantize_active). */
  le_engine* e = make_configured_engine();
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_MULTI);
  CHECK(le_engine_crown_primary(e, 1) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.primary_track == 1);
  le_engine_destroy(e);
}

static void test_crown_primary_persists_through_clear(void) {
  printf("test_crown_primary_persists_through_clear\n");
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_crown_primary(e, 0) == LE_OK);
  drain(e);
  le_engine_record(e, 0);
  process_const(e, 1.0f, SB_BASE, out);
  le_engine_record(e, 0); /* finalize -> PLAYING */
  drain(e);

  CHECK(le_engine_clear(e, 0) == LE_OK);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.primary_track == 0); /* D18: survives the clear */

  le_engine_destroy(e);
}

static void test_crown_primary_persists_through_undo_to_empty(void) {
  printf("test_crown_primary_persists_through_undo_to_empty\n");
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_crown_primary(e, 0) == LE_OK);
  drain(e);
  le_engine_record(e, 0);
  process_const(e, 1.0f, SB_BASE, out);
  le_engine_record(e, 0);
  drain(e);

  /* No overdub layers yet, so the very first undo goes past the base layer
   * (UNDO_TO_EMPTY), not a layer peel. */
  CHECK(le_engine_undo(e, 0) == LE_OK);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.primary_track == 0); /* D18: survives undo-to-empty too */

  le_engine_destroy(e);
}

static void test_crown_primary_re_crown_changes_it(void) {
  printf("test_crown_primary_re_crown_changes_it\n");
  le_engine* e = make_configured_engine();
  CHECK(le_engine_crown_primary(e, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_crown_primary(e, 3) == LE_OK);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.primary_track == 3); /* only an explicit re-crown moves it */
  le_engine_destroy(e);
}

/* D16 fallback, inert-outside-Sync/Band leg: in MULTI mode a crowned
 * primary has NO effect on another track's finalize -- it keeps today's
 * AUTO round-up, never the nearest-ratio snap (which would behave
 * differently here: 1.5 base loops rounds DOWN to 1 under nearest-log2
 * matching, but Multi's AUTO always rounds UP to 2). */
static void test_crown_primary_inert_outside_sync_band(void) {
  printf("test_crown_primary_inert_outside_sync_band\n");
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_crown_primary(e, 0) == LE_OK);
  drain(e);

  le_engine_record(e, 0);
  process_const(e, 1.0f, SB_BASE, out);
  le_engine_record(e, 0); /* finalize -> defines the base loop, multiple 1 */
  drain(e);

  le_engine_record(e, 1);
  process_const(e, 2.0f, SB_BASE + SB_BASE / 2, out); /* 1.5x base */
  le_engine_record(e, 1); /* finalize */
  drain(e);

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.looper_mode == LE_LOOPER_MODE_MULTI);
  CHECK(s.tracks[1].multiple == 2);          /* AUTO round-up, unaffected */
  CHECK(s.tracks[1].sync_divisor == 0);
  CHECK(s.tracks[1].length_frames == 2 * SB_BASE);

  le_engine_destroy(e);
}

/* D16 fallback: Sync mode with NO primary yet (or an un-established one)
 * behaves exactly like Multi's AUTO round-up -- proven the same
 * discriminating way as the inert-outside-Sync/Band test above (a
 * nearest-ratio snap of 1.5x would round DOWN to 1; AUTO round-up gives 2). */
static void test_sync_no_primary_behaves_like_multi(void) {
  printf("test_sync_no_primary_behaves_like_multi\n");
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  drain(e);
  /* No crown at all. */

  le_engine_record(e, 0);
  process_const(e, 1.0f, SB_BASE, out);
  le_engine_record(e, 0);
  drain(e);

  le_engine_record(e, 1);
  process_const(e, 2.0f, SB_BASE + SB_BASE / 2, out); /* 1.5x base */
  le_engine_record(e, 1);
  drain(e);

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].multiple == 2); /* AUTO round-up fallback, not nearest */
  CHECK(s.tracks[1].sync_divisor == 0);

  le_engine_destroy(e);
}

/* Presses record on [ch] in a mode where le_sync_quantize_active holds for
 * it: the press force-arms (D16) instead of recording immediately, so the
 * caller must advance to the next primary-track loop top for it to
 * actually start. Leaves the track RECORDING with record_pos freshly
 * seeded at exactly 0 -- the phase-lock precondition every test below
 * relies on. */
static void sb_arm_and_start(le_engine* e, int32_t ch) {
  CHECK(le_engine_record(e, ch) == LE_OK);
  drain(e); /* applies the ARM (pending_record = 1); does not fire it */
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[ch].pending == 1);
  tg_advance(e, s.master_length_frames - s.master_position_frames);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[ch].state == LE_TRACK_RECORDING);
  CHECK(s.master_position_frames == 0); /* fired exactly at the loop top */
}

/* Crowns + records track 0 as an established primary (SB_BASE frames of
 * [value]) in whichever mode is already set (SYNC or BAND). Leaves the
 * master clock at position 0. */
static void sb_make_primary(le_engine* e, float value) {
  float out[64];
  CHECK(le_engine_crown_primary(e, 0) == LE_OK);
  drain(e);
  le_engine_record(e, 0);
  process_const(e, value, SB_BASE, out);
  le_engine_record(e, 0);
  drain(e);
}

/* Generalizes sb_make_primary to an arbitrary channel and base length --
 * used by the GAP-1 tests below, which deliberately need a primary length
 * that ISN'T SB_BASE (16, which divides both 2 and 4 cleanly and would
 * mask BUG 2 entirely). */
static void sb_make_primary_ex(le_engine* e, int32_t ch, int32_t base_len,
                               float value) {
  float out[64];
  CHECK(le_engine_crown_primary(e, ch) == LE_OK);
  drain(e);
  le_engine_record(e, ch);
  process_const(e, value, base_len, out);
  le_engine_record(e, ch);
  drain(e);
}

/* Nearest-log2-match, DOWNWARD leg: 20 frames (1.25x SB_BASE) is closer to
 * 1x than 2x on the log2 grid (log2(1.25) ~= 0.32, nearer 0 than 1) -- the
 * take is TRUNCATED to exactly one base loop, discriminating this from
 * Multi's AUTO, which would round UP to 2 for anything over 1x. */
static void test_sync_nonprimary_snaps_down_to_nearest_multiple(void) {
  printf("test_sync_nonprimary_snaps_down_to_nearest_multiple\n");
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  drain(e);
  sb_make_primary(e, 1.0f);

  sb_arm_and_start(e, 1);
  process_const(e, 2.0f, 20, out); /* 1.25x SB_BASE */
  le_engine_record(e, 1);          /* immediate finalize */
  drain(e);

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].sync_divisor == 0);
  CHECK(s.tracks[1].multiple == 1); /* snapped DOWN, not rounded up to 2 */
  CHECK(s.tracks[1].length_frames == SB_BASE);

  /* The truncated content is exactly the first SB_BASE frames of 2.0 (the
   * captured tail past that point is discarded, never played). */
  float pcm[SB_BASE];
  CHECK(le_engine_export_track(e, 1, pcm, SB_BASE) == SB_BASE);
  for (int i = 0; i < SB_BASE; ++i) CHECK(fabsf(pcm[i] - 2.0f) < 1e-6f);

  le_engine_destroy(e);
}

/* THE core division-playback test (D16, the trickiest math in this PR):
 * an exact 1/2-ratio capture (8 frames, log2(0.5) == -1 exactly) becomes a
 * division track whose own 8-frame buffer holds 8 DISTINCT values, so
 * phase can be read back unambiguously. Verifies, over TWO full primary
 * cycles (32 frames): the division completes exactly 4 of its own loops
 * (2 per primary cycle) and re-aligns to its own frame 0 at EVERY primary
 * loop top (frame 0 and frame 16), not just the first -- out[i] must equal
 * pattern[i % 8] for the entire 32-frame span. */
static void test_sync_nonprimary_division_half_phase_correct_two_cycles(void) {
  printf("test_sync_nonprimary_division_half_phase_correct_two_cycles\n");
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  drain(e);
  sb_make_primary(e, 0.0f); /* silent primary -- isolates track 1 below */

  sb_arm_and_start(e, 1);
  const float pattern[8] = {1, 2, 3, 4, 5, 6, 7, 8};
  process_seq(e, pattern, 8, out); /* exactly SB_BASE/2 frames */
  le_engine_record(e, 1);          /* immediate finalize */
  drain(e);

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].sync_divisor == 2);
  CHECK(s.tracks[1].multiple == 1); /* inert alongside the divisor */
  CHECK(s.tracks[1].length_frames == SB_BASE / 2);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);

  /* Realign to a clean primary loop top before sampling (position is
   * already 0 here in practice -- SB_BASE frames captured from a position-0
   * start wraps exactly back to 0 -- but this is not load-bearing on that
   * coincidence). */
  le_engine_get_snapshot(e, &s);
  tg_advance(e, (SB_BASE - s.master_position_frames) % SB_BASE);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == 0);

  process_const(e, 0.0f, 2 * SB_BASE, out); /* two full primary cycles */
  for (int i = 0; i < 2 * SB_BASE; ++i) {
    CHECK(fabsf(out[i] - pattern[i % 8]) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* The 1/4-division leg of the same D16 formula: 4 frames (log2(0.25) == -2
 * exactly) over one full primary cycle -- the 4-value pattern must repeat
 * exactly 4 times. */
static void test_sync_nonprimary_division_quarter(void) {
  printf("test_sync_nonprimary_division_quarter\n");
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  drain(e);
  sb_make_primary(e, 0.0f);

  sb_arm_and_start(e, 1);
  const float pattern[4] = {10, 20, 30, 40};
  process_seq(e, pattern, 4, out);
  le_engine_record(e, 1);
  drain(e);

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].sync_divisor == 4);
  CHECK(s.tracks[1].length_frames == SB_BASE / 4);

  tg_advance(e, (SB_BASE - s.master_position_frames) % SB_BASE);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == 0);

  /* GAP 6: two full primary cycles (like the half-division sibling test),
   * not one -- proves re-alignment at the SECOND boundary too, not just
   * the first. */
  process_const(e, 0.0f, 2 * SB_BASE, out);
  for (int i = 0; i < 2 * SB_BASE; ++i) {
    CHECK(fabsf(out[i] - pattern[i % 4]) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* ---- adversarial-review fixes (post-bd77289): BUG 1-4, GAP 1-6 ---- */

/* GAP 2 (happy-path leg): the Sync-active round-UP finalize (nearest-ratio
 * p >= 0, k = 2 or 4) had ZERO test coverage before this fix -- which is
 * exactly how BUG 1 (the missing max_loop_frames clamp) shipped
 * undetected. Default (generous) capacity: a capture that snaps to k=2
 * finalizes with the correct multiple and the full, unclamped length. */
static void test_sync_nonprimary_snaps_up_to_nearest_multiple(void) {
  printf("test_sync_nonprimary_snaps_up_to_nearest_multiple\n");
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  drain(e);
  sb_make_primary(e, 1.0f);

  sb_arm_and_start(e, 1);
  process_const(e, 2.0f, 2 * SB_BASE, out); /* exactly 2x -> k=2 */
  le_engine_record(e, 1);
  drain(e);

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].sync_divisor == 0);
  CHECK(s.tracks[1].multiple == 2);
  CHECK(s.tracks[1].length_frames == 2 * SB_BASE);

  float pcm[2 * SB_BASE];
  CHECK(le_engine_export_track(e, 1, pcm, 2 * SB_BASE) == 2 * SB_BASE);
  for (int i = 0; i < 2 * SB_BASE; ++i) CHECK(fabsf(pcm[i] - 2.0f) < 1e-6f);

  le_engine_destroy(e);
}

/* BUG 1 fix, GAP 2 (capacity leg): constrains max_loop_frames so that k=2
 * -- what the capture naturally snaps to -- would need MORE frames than
 * are actually allocated. Before the fix, le_track_set_len(t, k * base)
 * had no clamp here (unlike the ordinary auto-round-up path a few lines
 * below it in finalize_new_track), so a_len was published larger than the
 * lane's actual pool capacity -- mix_tracks_frame's playback read then
 * goes out of bounds on the audio thread. Proves the SAME clamp the
 * ordinary path already had now also applies to the Sync-active leg. */
static void test_sync_round_up_finalize_respects_max_loop_frames(void) {
  printf("test_sync_round_up_finalize_respects_max_loop_frames\n");
  /* Parameters are deliberately spread out, not just "base=SB_BASE
   * scaled": the capture length (44) must (a) log2-round to k=2 relative
   * to base (44/30 ~= 1.47, nearest to 2^1), (b) stay STRICTLY UNDER
   * max_frames so the pre-existing "record_pos >= max_loop_frames"
   * capacity safety valve (advance_transport_frame) never auto-finalizes
   * DURING the capture -- that path finalizes into OVERDUBBING and arms a
   * punch-in undo session, an unrelated interaction that would corrupt
   * this test's content if the two thresholds collided -- and (c) stay
   * <= 64 (process_const's own fixed-size stack buffer). max_frames (50)
   * sits strictly between the capture length and 2*base (60), so maxk =
   * max_frames/base = 1 clamps k down from the naturally-chosen 2. */
  const int32_t base = 30;
  const int32_t max_frames = 50;
  const int32_t capture = 44;
  le_engine* e = tg_make_engine_cap(48000, max_frames);
  float out[64];
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  drain(e);
  sb_make_primary_ex(e, 0, base, 0.0f); /* silent primary: isolates track 1 */

  sb_arm_and_start(e, 1);
  process_const(e, 2.0f, capture, out); /* ~1.47x base -> nearest-ratio k=2 */
  le_engine_record(e, 1);
  drain(e);

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].sync_divisor == 0);
  /* Without BUG 1's fix this would read 2 (== 2 * base == 60 frames,
   * beyond the 50-frame allocated capacity -- an OOB read on playback).
   * The clamp forces the largest multiple that still fits. */
  CHECK(s.tracks[1].multiple == 1);
  CHECK(s.tracks[1].length_frames == base);
  CHECK(s.tracks[1].length_frames <= max_frames);

  /* Playback must stay well-defined (in-bounds) at every position of the
   * clamped loop -- the concrete proof this is safe, not just "the
   * metadata looks right". */
  process_const(e, 0.0f, base, out);
  for (int i = 0; i < base; ++i) CHECK(fabsf(out[i] - 2.0f) < 1e-6f);

  le_engine_destroy(e);
}

/* BUG 2 fix, GAP 1: an ODD primary length (17) can never tile a division
 * exactly (17 % 2 != 0, let alone % 4) -- le_sync_choose_ratio must fall
 * all the way back to an ordinary 1x multiple rather than ever publish a
 * stuttering division. Captures ~1/4 of the base, which would otherwise
 * request a division. */
static void test_sync_division_falls_back_on_indivisible_base(void) {
  printf("test_sync_division_falls_back_on_indivisible_base\n");
  const int32_t base = 17;
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  drain(e);
  sb_make_primary_ex(e, 0, base, 1.0f);

  sb_arm_and_start(e, 1);
  process_const(e, 2.0f, 4, out); /* ~1/4 of 17 -> would request n=4 */
  le_engine_record(e, 1);
  drain(e);

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].sync_divisor == 0); /* no unsafe division was created */
  CHECK(s.tracks[1].multiple == 1);     /* falls back to 1x, always exact */
  CHECK(s.tracks[1].length_frames == base);

  le_engine_destroy(e);
}

/* BUG 2 fix, GAP 1 (the discriminating case): base=18 is EVEN but not a
 * multiple of 4 -- a request that naturally lands on n=4 (nearest-log2 to
 * a ~1/4 capture) must step DOWN to n=2 (18 % 2 == 0, 18 % 4 != 0) rather
 * than publish an inexact 4-way division. Verifies EXACT tiling with no
 * repeated or skipped index across 2 full primary cycles by comparing
 * playback against the division's OWN exported buffer (ground truth,
 * including whatever unwritten tail the short capture left) rather than a
 * hand-computed pattern. SB_BASE (16) divides both 2 and 4 cleanly and
 * would mask this bug entirely -- this is why GAP 1 called out a
 * non-16 base specifically. */
static void
test_sync_nonprimary_division_even_not_multiple_of_four_tiles_exactly(void) {
  printf(
      "test_sync_nonprimary_division_even_not_multiple_of_four_tiles_exactly\n");
  const int32_t base = 18;
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  drain(e);
  sb_make_primary_ex(e, 0, base, 0.0f); /* silent primary: isolates track 1 */

  sb_arm_and_start(e, 1);
  const float pattern[5] = {1, 2, 3, 4, 5}; /* ~1/4 of 18 -> requests n=4 */
  process_seq(e, pattern, 5, out);
  le_engine_record(e, 1);
  drain(e);

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].sync_divisor == 2);         /* stepped DOWN from 4 */
  CHECK(s.tracks[1].length_frames == base / 2); /* 9, exact */

  float buf[9];
  CHECK(le_engine_export_track(e, 1, buf, 9) == 9);

  tg_advance(e, (base - s.master_position_frames) % base);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == 0);

  process_const(e, 0.0f, 2 * base, out); /* two full primary cycles */
  for (int i = 0; i < 2 * base; ++i) {
    CHECK(fabsf(out[i] - buf[i % 9]) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* BUG 3 fix (adversarial review): crowning a track that is ITSELF a Sync
 * division of another primary must not let downstream tracks treat its
 * fractional length as if it were a full primary reference -- track 1
 * (crowned second) holds only an 8-frame division of track 0's 16-frame
 * primary; le_sync_quantize_active must read this as "not established"
 * for any OTHER track (the D16 no-primary fallback), not corrupt the math
 * with an 8-frame "base". */
static void
test_crown_division_track_does_not_corrupt_downstream_quantize(void) {
  printf("test_crown_division_track_does_not_corrupt_downstream_quantize\n");
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  drain(e);
  sb_make_primary(e, 1.0f); /* track 0: 16-frame primary */

  sb_arm_and_start(e, 1);
  process_const(e, 2.0f, SB_BASE / 2, out); /* exact half -> divisor 2 */
  le_engine_record(e, 1);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].sync_divisor == 2);
  CHECK(s.tracks[1].length_frames == SB_BASE / 2);

  /* Crown track 1 (the division) as the new primary. */
  CHECK(le_engine_crown_primary(e, 1) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.primary_track == 1);

  /* Track 2's recording must NOT quantize against track 1's fractional
   * (8-frame) length -- it falls back to ordinary Multi-style behavior,
   * exactly the D16 no-primary-established discriminator used elsewhere
   * in this file: a 1.25x-the-REAL-base take rounds UP to multiple 2
   * under AUTO, never snaps DOWN to 1 the way an active Sync quantize
   * would (and could never even compute a sane ratio against an 8-frame
   * "base" without corrupting the math). */
  le_engine_record(e, 2);
  process_const(e, 3.0f, SB_BASE + SB_BASE / 4, out); /* 1.25x REAL base */
  le_engine_record(e, 2);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[2].sync_divisor == 0);
  CHECK(s.tracks[2].multiple == 2); /* AUTO round-up fallback, not corrupted */

  le_engine_destroy(e);
}

/* BUG 4 fix (adversarial review): clearing the primary while a dependent
 * Sync track survives keeps e->clock alive (handle_clear only resets it
 * when EVERY track is empty) -- and a_primary_track itself persists too
 * (D18). Re-recording the primary must NOT auto-round like an ordinary
 * track (which would silently un-establish it as "the reference" for
 * every future Sync recording, a_multiple != 1, with no user-visible
 * signal) -- it must always re-finalize as exactly one base loop, per
 * D18's "the primary is a deliberate, persistent designation". */
static void test_primary_re_record_after_clear_forces_one_base_loop(void) {
  printf("test_primary_re_record_after_clear_forces_one_base_loop\n");
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  drain(e);
  sb_make_primary(e, 1.0f); /* track 0: 16-frame primary */

  /* A dependent Sync track that will keep e->clock alive once the primary
   * is cleared. */
  sb_arm_and_start(e, 1);
  process_const(e, 2.0f, SB_BASE, out); /* exact 1x */
  le_engine_record(e, 1);
  drain(e);

  CHECK(le_engine_clear(e, 0) == LE_OK); /* the primary, not the dependent */
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.primary_track == 0);              /* D18: crown survives */
  CHECK(s.master_length_frames == SB_BASE); /* e->clock kept alive by track 1 */

  /* Re-record the primary with a take that would round UP under ordinary
   * AUTO (1.5x base) -- without the fix this lands a_multiple at 2. */
  le_engine_record(e, 0);
  process_const(e, 5.0f, SB_BASE + SB_BASE / 2, out); /* 1.5x base */
  le_engine_record(e, 0);
  drain(e);

  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].sync_divisor == 0);
  CHECK(s.tracks[0].multiple == 1); /* forced, not auto-rounded to 2 */
  CHECK(s.tracks[0].length_frames == SB_BASE);
  CHECK(s.master_length_frames == SB_BASE); /* e->clock itself untouched */

  /* The primary is genuinely re-established: a fresh dependent recording
   * still gets Sync-quantized (proves le_sync_quantize_active's
   * a_multiple == 1 check now passes again). */
  sb_arm_and_start(e, 2);
  process_const(e, 9.0f, SB_BASE / 2, out); /* exact half */
  le_engine_record(e, 2);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[2].sync_divisor == 2);
  CHECK(s.tracks[2].length_frames == SB_BASE / 2);

  le_engine_destroy(e);
}

/* GAP 3: force-arm-to-primary-loop-top was only ever tested from position
 * 0 (a degenerate full-cycle wait, sb_arm_and_start's own precondition).
 * Presses record mid-cycle and asserts the take starts at EXACTLY the
 * next boundary frame -- not one frame early, not one frame late. */
static void test_sync_force_arm_from_mid_cycle_fires_at_exact_boundary(void) {
  printf("test_sync_force_arm_from_mid_cycle_fires_at_exact_boundary\n");
  le_engine* e = make_configured_engine();
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  drain(e);
  sb_make_primary(e, 1.0f);

  tg_advance(e, 5); /* mid-cycle, not the loop top */
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == 5);

  CHECK(le_engine_record(e, 1) == LE_OK);
  drain(e); /* applies the ARM; does not fire it */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[1].pending == 1);

  /* One frame short of the boundary: still not fired. */
  tg_advance(e, SB_BASE - 5 - 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == SB_BASE - 1);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[1].pending == 1);

  /* The single frame that crosses the loop top fires it, exactly. */
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == 0);
  CHECK(s.tracks[1].state == LE_TRACK_RECORDING);
  CHECK(s.tracks[1].pending == 0);

  le_engine_destroy(e);
}

/* GAP 4: no B3 test cleared/undid the primary while a dependent Sync
 * track was alive and PLAYING. The dependent must keep playing correctly
 * (it reads e->clock.length + its own a_sync_divisor, never the primary
 * track's own state), and a later third-track recording must fall back
 * sanely (D16 no-primary-established) since the primary is now EMPTY. */
static void
test_primary_cleared_dependent_track_keeps_playing_correctly(void) {
  printf("test_primary_cleared_dependent_track_keeps_playing_correctly\n");
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  drain(e);
  sb_make_primary(e, 0.0f); /* silent primary: isolates track 1's playback */

  sb_arm_and_start(e, 1);
  const float pattern[8] = {1, 2, 3, 4, 5, 6, 7, 8};
  process_seq(e, pattern, 8, out); /* exact half -> divisor 2 */
  le_engine_record(e, 1);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].sync_divisor == 2);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);

  CHECK(le_engine_clear(e, 0) == LE_OK); /* clear the primary */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING); /* untouched */
  CHECK(s.master_length_frames == SB_BASE);     /* kept alive by track 1 */

  /* Realign and verify track 1's playback is still phase-correct. */
  tg_advance(e, (SB_BASE - s.master_position_frames) % SB_BASE);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == 0);
  process_const(e, 0.0f, 2 * SB_BASE, out);
  for (int i = 0; i < 2 * SB_BASE; ++i) {
    CHECK(fabsf(out[i] - pattern[i % 8]) < 1e-6f);
  }

  /* A third track now falls back to ordinary Multi behavior: the primary
   * is EMPTY, so le_sync_quantize_active reads "not established". */
  le_engine_record(e, 2);
  process_const(e, 3.0f, SB_BASE + SB_BASE / 2, out); /* 1.5x -> AUTO k=2 */
  le_engine_record(e, 2);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[2].sync_divisor == 0);
  CHECK(s.tracks[2].multiple == 2);

  le_engine_destroy(e);
}

/* GAP 5: le_restore_multiple_or_divisor's division-reconstruction branch
 * (undo-to-empty -> redo-from-empty of a track holding an active divisor)
 * had zero coverage. Round-trips a half-division track through exactly
 * that path and confirms the divisor (and the live content) come back
 * unchanged. */
static void
test_division_track_undo_to_empty_redo_round_trips_divisor(void) {
  printf("test_division_track_undo_to_empty_redo_round_trips_divisor\n");
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  drain(e);
  sb_make_primary(e, 0.0f);

  sb_arm_and_start(e, 1);
  const float pattern[8] = {11, 22, 33, 44, 55, 66, 77, 88};
  process_seq(e, pattern, 8, out);
  le_engine_record(e, 1);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].sync_divisor == 2);
  CHECK(s.tracks[1].length_frames == SB_BASE / 2);

  /* No overdub layers yet: the first undo goes straight past the base
   * layer (UNDO_TO_EMPTY), resetting a_sync_divisor to 0. */
  CHECK(le_engine_undo(e, 1) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_EMPTY);
  CHECK(s.tracks[1].sync_divisor == 0);

  /* Redo reinstates it via le_restore_multiple_or_divisor. */
  CHECK(le_engine_redo(e, 1) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].sync_divisor == 2); /* recovered exactly, not guessed */
  CHECK(s.tracks[1].length_frames == SB_BASE / 2);

  float pcm[SB_BASE / 2];
  CHECK(le_engine_export_track(e, 1, pcm, SB_BASE / 2) == SB_BASE / 2);
  for (int i = 0; i < SB_BASE / 2; ++i) {
    CHECK(fabsf(pcm[i] - pattern[i]) < 1e-6f);
  }

  le_engine_destroy(e);
}

/* ---- B3b: Band section transport ---- */

static void test_band_section_toggle_rejected_outside_band_mode(void) {
  printf("test_band_section_toggle_rejected_outside_band_mode\n");
  le_engine* e = make_configured_engine();
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_SYNC) == LE_OK);
  drain(e);
  CHECK(le_engine_crown_primary(e, 0) == LE_OK);
  drain(e);
  CHECK(le_engine_toggle_section(e, 1) == LE_ERR_INVALID);
  le_engine_destroy(e);
}

static void test_band_section_toggle_rejected_for_primary(void) {
  printf("test_band_section_toggle_rejected_for_primary\n");
  le_engine* e = make_configured_engine();
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_BAND) == LE_OK);
  drain(e);
  sb_make_primary(e, 1.0f);
  CHECK(le_engine_toggle_section(e, 0) == LE_ERR_INVALID); /* is the primary */
  le_engine_destroy(e);
}

static void test_band_section_toggle_rejected_for_empty_track(void) {
  printf("test_band_section_toggle_rejected_for_empty_track\n");
  le_engine* e = make_configured_engine();
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_BAND) == LE_OK);
  drain(e);
  sb_make_primary(e, 1.0f);
  CHECK(le_engine_toggle_section(e, 1) == LE_ERR_INVALID); /* still EMPTY */
  le_engine_destroy(e);
}

/* THE core Band arming test: a section-transport press at a NON-boundary
 * position must NOT take effect immediately -- it must fire exactly at the
 * next primary-track loop top (song-mode-spec.md §2 Q3 / §3's STOP-pedal
 * table), neither before nor (observably) after. */
static void test_band_section_start_stop_quantized_to_primary_top(void) {
  printf("test_band_section_start_stop_quantized_to_primary_top\n");
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_BAND) == LE_OK);
  drain(e);
  sb_make_primary(e, 1.0f);

  /* Track 1: a full-multiple section (k = 1), PLAYING immediately after its
   * own (sync-quantized) defining recording finalizes. */
  sb_arm_and_start(e, 1);
  process_const(e, 2.0f, SB_BASE, out);
  le_engine_record(e, 1);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.master_position_frames == 0); /* exactly one base loop captured */

  /* Move to a clearly non-boundary position before arming the toggle. */
  tg_advance(e, 5);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == 5);

  CHECK(le_engine_toggle_section(e, 1) == LE_OK);
  drain(e); /* applies the ARM; does not fire it */
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].pending == 1);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING); /* NOT immediate */

  /* One frame short of the boundary: still armed, still playing. */
  const int32_t remaining = s.master_length_frames - s.master_position_frames;
  CHECK(remaining > 1); /* the press landed clearly mid-loop */
  tg_advance(e, remaining - 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.tracks[1].pending == 1);

  /* The single frame that crosses the primary's loop top fires it. */
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == 0);
  CHECK(s.tracks[1].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[1].pending == 0);

  /* A second toggle (STOPPED -> armed -> PLAYING) proves the toggle
   * direction is read fresh each time from the track's current state, not
   * latched at arm time. */
  tg_advance(e, 5);
  CHECK(le_engine_toggle_section(e, 1) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_STOPPED); /* still not immediate */
  tg_advance(e, SB_BASE - 5);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);

  le_engine_destroy(e);
}

/* ---- code-review fixes (post-b264920): BUG 1-2, GAP 1-2 ---- */

/* B3b BUG 1 (adversarial review): the crowned primary hasn't recorded yet
 * (D16 fallback: whoever records first defines e->clock) -- a non-primary
 * track (channel 1) records and finalizes FIRST, becoming the track that
 * defines the master. le_engine_toggle_section must reject: without an
 * established primary, "the primary's loop top" is meaningless, and
 * arming against e->clock here would actually be arming against channel
 * 1's OWN clock (the very track being toggled), directly contradicting
 * this function's documented guarantee. */
static void test_band_section_toggle_rejected_when_primary_not_established(
    void) {
  printf("test_band_section_toggle_rejected_when_primary_not_established\n");
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_BAND) == LE_OK);
  drain(e);
  CHECK(le_engine_crown_primary(e, 0) == LE_OK); /* crowned... */
  drain(e);
  /* ...but NOT recorded. Channel 1 records first instead (D16 fallback:
   * ordinary immediate defining recording, since le_sync_quantize_active
   * is false with no established primary). */
  le_engine_record(e, 1);
  process_const(e, 1.0f, SB_BASE, out);
  le_engine_record(e, 1);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);   /* the crowned primary */
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING); /* defines e->clock instead */
  CHECK(s.primary_track == 0);

  CHECK(le_engine_toggle_section(e, 1) == LE_ERR_INVALID);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].pending == 0); /* nothing armed */

  le_engine_destroy(e);
}

/* B3b BUG 2(a) (adversarial review): a pending toggle-section arm (trigger
 * 2) must not be silently cancelled by a Record press on the SAME channel
 * (le_engine_record's own quantize-arm path, trigger 0) -- the two
 * commands' arms must never be treated as interchangeable. Asserts the
 * Record press is rejected and the ORIGINAL toggle arm survives
 * untouched, then still fires correctly. */
static void test_band_section_pending_toggle_survives_record_press(void) {
  printf("test_band_section_pending_toggle_survives_record_press\n");
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_BAND) == LE_OK);
  drain(e);
  sb_make_primary(e, 1.0f);

  /* Track 1's OWN content-establishing recording happens with quantize
   * still off (its D16 force-arm is unaffected either way, but its
   * FINALIZE press must not itself get quantize-armed by the global
   * setting -- that's a different interaction than the one under test
   * here). Global quantize turns on only afterward, for the punch-in-arm
   * collision below: a Record press on a content-bearing track then tries
   * to arm a punch-in overdub (trigger 0) instead of going immediate. */
  sb_arm_and_start(e, 1);
  process_const(e, 2.0f, SB_BASE, out);
  le_engine_record(e, 1);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);

  CHECK(le_engine_set_quantize(e, 1) == LE_OK);
  drain(e);

  tg_advance(e, 5); /* mid-cycle */
  CHECK(le_engine_toggle_section(e, 1) == LE_OK); /* arms trigger 2 */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].pending == 1);

  /* Channel 1 is already armed with a DIFFERENT trigger -- rejected, not
   * silently swallowed. */
  CHECK(le_engine_record(e, 1) == LE_ERR_INVALID);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].pending == 1);             /* the toggle arm survives */
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING); /* untouched */

  /* The original toggle still fires correctly at the primary's loop top. */
  tg_advance(e, SB_BASE - 5);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[1].pending == 0);

  le_engine_destroy(e);
}

/* B3b BUG 2(b) (adversarial review): the reverse of (a) -- a pending
 * RECORD quantize-arm (trigger 0) on a section track must not be silently
 * cancelled by a toggle-section press on the SAME channel. */
static void test_band_section_pending_record_survives_toggle_press(void) {
  printf("test_band_section_pending_record_survives_toggle_press\n");
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_BAND) == LE_OK);
  drain(e);
  sb_make_primary(e, 1.0f);

  /* See test_band_section_pending_toggle_survives_record_press for why
   * quantize turns on only AFTER track 1's own content-establishing
   * finalize, not before. */
  sb_arm_and_start(e, 1);
  process_const(e, 2.0f, SB_BASE, out);
  le_engine_record(e, 1);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);

  CHECK(le_engine_set_quantize(e, 1) == LE_OK);
  drain(e);

  tg_advance(e, 5); /* mid-cycle */
  CHECK(le_engine_record(e, 1) == LE_OK); /* arms a punch-in, trigger 0 */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].pending == 1);

  /* A toggle-section press on the SAME channel must be rejected, not
   * silently disarm the pending record. */
  CHECK(le_engine_toggle_section(e, 1) == LE_ERR_INVALID);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].pending == 1);             /* the record arm survives */
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING); /* untouched */

  /* The original record arm still fires correctly (punch-in at the
   * boundary -> OVERDUBBING). */
  tg_advance(e, SB_BASE - 5);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_OVERDUBBING);
  CHECK(s.tracks[1].pending == 0);

  le_engine_destroy(e);
}

/* B3b BUG 2(c) (adversarial review): the quantize-OFF case is the worse
 * variant -- le_engine_record's Immediate path pushes LE_CMD_RECORD
 * directly, which unconditionally zeroes pending_record/a_pending on the
 * audio thread with no way to tell whose arm it was clearing. Without the
 * fix this would silently kill the pending toggle with no error to
 * either caller and leave a stale armed[]==1 behind. Global quantize
 * stays OFF (the default) for this test. */
static void
test_band_section_pending_toggle_survives_immediate_record_press(void) {
  printf(
      "test_band_section_pending_toggle_survives_immediate_record_press\n");
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_BAND) == LE_OK);
  drain(e);
  sb_make_primary(e, 1.0f); /* quantize stays OFF (default) */

  sb_arm_and_start(e, 1);
  process_const(e, 2.0f, SB_BASE, out);
  le_engine_record(e, 1);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);

  tg_advance(e, 5);
  CHECK(le_engine_toggle_section(e, 1) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].pending == 1);

  /* Quantize is OFF: an ordinary Record press on channel 1 reaches the
   * Immediate path directly (no arm-vs-arm branch at all) and, before the
   * fix, silently pushed LE_CMD_RECORD -- killing the pending toggle with
   * zero error to either caller. */
  CHECK(le_engine_record(e, 1) == LE_ERR_INVALID);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].pending == 1);              /* survives, not stale-cleared */
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING); /* untouched */

  /* And it still fires correctly. */
  tg_advance(e, SB_BASE - 5);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[1].pending == 0);

  le_engine_destroy(e);
}

/* GAP 1 (mutation-survivable, adversarial review): a mutant swapping
 * `if (wrapped)` for `if (boundary)` in advance_transport_frame's Band
 * section-transport fire block would fire trigger 2 at a live musical-
 * quantize SUBDIVISION boundary too, not just the primary's true loop
 * top. `boundary` and `wrapped` only diverge when some OTHER track has a
 * pending trigger-0 arm (has_pending) -- track 2 here exists purely to
 * make that divergence observable: it force-arms (D16 sync-quantize) the
 * instant it's pressed, giving has_pending a true value straight through
 * the subdivision midpoint. Needs a REAL tempo grid: every other B3/B3b
 * test's SB_BASE=16-frame loop is far too short for any tempo in 30-300
 * BPM to derive a whole-bar grid over, so this uses sr=1000, 120 BPM,
 * 4/4, and a 2000-frame (exactly 1-bar) primary -- frames-per-beat 500,
 * so a HALF-note division boundary sits at the exact midpoint, frame
 * 1000. */
static void test_band_section_toggle_ignores_subdivision_boundary(void) {
  printf("test_band_section_toggle_ignores_subdivision_boundary\n");
  le_engine* e = tg_make_engine(1000);
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_BAND) == LE_OK);
  drain(e);
  CHECK(le_engine_set_tempo(e, 120.0f) == LE_OK);
  drain(e);
  CHECK(le_engine_crown_primary(e, 0) == LE_OK);
  drain(e);

  le_engine_record(e, 0);
  tg_advance(e, 2000);
  le_engine_record(e, 0); /* queue finalize (defers for the seam crossfade) */
  tg_advance(e, e->sample_rate / 100);

  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_length_frames == 2000);
  CHECK(s.loop_bars == 1);

  CHECK(le_engine_set_quantize_div(e, LE_GRID_DIV_HALF) == LE_OK);
  drain(e);

  /* Track 1: the section under test. */
  sb_arm_and_start(e, 1);
  tg_advance(e, 2000); /* one full base loop of content */
  le_engine_record(e, 1); /* immediate finalize (non-defining) */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.master_position_frames == 0);

  /* Track 2: EMPTY, force-arms trigger 0 on this press and stays pending
   * -- its sole purpose is to make has_pending (and therefore `boundary`)
   * diverge from `wrapped` at the subdivision midpoint below. */
  CHECK(le_engine_record(e, 2) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[2].pending == 1);

  /* Arm the toggle on track 1. */
  CHECK(le_engine_toggle_section(e, 1) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].pending == 1);

  /* Advance to (but not past) the HALF-note subdivision midpoint, frame
   * 1000 -- `boundary` (not `wrapped`) goes true there. Track 1 must NOT
   * fire. */
  tg_advance(e, 1000);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == 1000);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING); /* unchanged */
  CHECK(s.tracks[1].pending == 1);              /* still armed */

  /* The remaining 1000 frames cross the TRUE primary loop top -- NOW it
   * fires. */
  tg_advance(e, 1000);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == 0);
  CHECK(s.tracks[1].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[1].pending == 0);

  le_engine_destroy(e);
}

/* GAP 2 (mutation-survivable, adversarial review): a mutant that caches
 * the fire direction at ARM time (e.g. always PLAYING -> STOPPED) instead
 * of reading the track's state FRESH when the primary wraps would produce
 * identical output for every other test here, since none of them change
 * state between arming and firing. Arms while PLAYING, independently
 * stops the SAME track via a direct LE_CMD_STOP (le_engine_stop_track --
 * a completely separate command from the toggle, and one that never
 * touches pending_record/armed[]) before the primary wraps, and asserts
 * the fire toggles the OTHER way (STOPPED -> PLAYING) -- proof the fire
 * logic reads state fresh at FIRE time, not the stale PLAYING it was
 * armed against. */
static void
test_band_section_toggle_reacts_to_state_at_fire_time_not_arm_time(void) {
  printf(
      "test_band_section_toggle_reacts_to_state_at_fire_time_not_arm_time\n");
  le_engine* e = make_configured_engine();
  float out[64];
  CHECK(le_engine_set_looper_mode(e, LE_LOOPER_MODE_BAND) == LE_OK);
  drain(e);
  sb_make_primary(e, 1.0f);

  sb_arm_and_start(e, 1);
  process_const(e, 2.0f, SB_BASE, out);
  le_engine_record(e, 1);
  drain(e);
  le_snapshot s;
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);
  CHECK(s.master_position_frames == 0);

  tg_advance(e, 5); /* mid-cycle */
  CHECK(le_engine_toggle_section(e, 1) == LE_OK); /* armed while PLAYING */
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].pending == 1);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING);

  /* Independently stop the SAME track via a direct command -- the arm is
   * still pending; this is not a toggle cancel, it's an unrelated
   * command. */
  CHECK(le_engine_stop_track(e, 1) == LE_OK);
  drain(e);
  le_engine_get_snapshot(e, &s);
  CHECK(s.tracks[1].state == LE_TRACK_STOPPED);
  CHECK(s.tracks[1].pending == 1); /* the toggle arm survives */

  /* Cross the primary's loop top -- fire must read the CURRENT (STOPPED)
   * state, not the PLAYING it was armed against, so it toggles the OTHER
   * way this time. */
  tg_advance(e, SB_BASE - 5);
  le_engine_get_snapshot(e, &s);
  CHECK(s.master_position_frames == 0);
  CHECK(s.tracks[1].state == LE_TRACK_PLAYING); /* STOPPED -> PLAYING */
  CHECK(s.tracks[1].pending == 0);

  le_engine_destroy(e);
}

/* ---- MIDI clock send (C1, D15) --------------------------------------------
 *
 * Engine-level wiring: the tri-state a_clock_mode field/command, the
 * Multi/Sync/Band-only gate (le_clock_send_gate_open), and real Start timing
 * against a genuine count-in. The pure tick/Start/Stop decision logic itself
 * (jitter bound, 24*beats between Starts, no double-counting) is unit-tested
 * directly against le_midi_clock_advance in test_midi_core.c -- these tests
 * only prove engine_process.c wires that logic to the right engine state.
 */

/* Pops up to `max` pending MIDI clock bytes (e->midi_clock_ring, C1) into
 * `out`, returning the count popped. Direct ring access, not a public API --
 * this test TU already includes engine_private.h for the tempo-grid section
 * above. */
static int32_t clock_drain(le_engine* e, uint8_t* out, int32_t max) {
  int32_t n = 0;
  le_command cmd;
  while (n < max && le_ring_pop(&e->midi_clock_ring, &cmd)) {
    out[n++] = (uint8_t)cmd.code;
  }
  return n;
}

static void test_clock_mode_defaults_and_persistence(void) {
  printf("test_clock_mode_defaults_and_persistence\n");
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  /* Grid-off-style default: OFF (0) on a fresh engine. */
  le_engine_get_snapshot(e, &s);
  CHECK(s.clock_mode == LE_CLOCK_OFF);

  /* Settings persist across a reconfigure, same pattern as looper_mode /
   * primary_track: seeded once in le_engine_create, never reset by
   * configure. */
  CHECK(le_engine_set_clock_mode(e, LE_CLOCK_SEND) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.clock_mode == LE_CLOCK_SEND);

  le_engine_configure(e, 1000, 1, 1, 20000);
  le_engine_get_snapshot(e, &s);
  CHECK(s.clock_mode == LE_CLOCK_SEND); /* survived the reconfigure */

  le_engine_destroy(e);
}

static void test_clock_mode_setter_validates_args(void) {
  printf("test_clock_mode_setter_validates_args\n");
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  /* RECEIVE is a real enum value (Phase E) but explicitly stubbed as
   * rejected in this part -- and everything outside the enum is rejected
   * too. Nothing is posted; the published mode stays OFF. */
  CHECK(le_engine_set_clock_mode(e, LE_CLOCK_RECEIVE) == LE_ERR_INVALID);
  CHECK(le_engine_set_clock_mode(e, -1) == LE_ERR_INVALID);
  CHECK(le_engine_set_clock_mode(e, 3) == LE_ERR_INVALID);
  CHECK(le_engine_set_clock_mode(e, 99) == LE_ERR_INVALID);
  CHECK(le_engine_set_clock_mode(NULL, LE_CLOCK_SEND) == LE_ERR_INVALID);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.clock_mode == LE_CLOCK_OFF);

  /* OFF and SEND both round-trip. */
  CHECK(le_engine_set_clock_mode(e, LE_CLOCK_SEND) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.clock_mode == LE_CLOCK_SEND);
  CHECK(le_engine_set_clock_mode(e, LE_CLOCK_OFF) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.clock_mode == LE_CLOCK_OFF);

  le_engine_destroy(e);
}

/* A raw LE_CMD_SET_CLOCK_MODE post (bypassing the exported wrapper's
 * validation entirely) must still be re-validated on the audio thread --
 * mirrors every other setter's "re-validated here" defense (LE_CMD_SET_
 * LOOPER_MODE, LE_CMD_SET_TIME_SIGNATURE, ...). */
static void test_clock_mode_raw_command_revalidates(void) {
  printf("test_clock_mode_raw_command_revalidates\n");
  le_engine* e = tg_make_engine(1000);
  le_snapshot s;

  CHECK(le_push(e, LE_CMD_SET_CLOCK_MODE, LE_CLOCK_RECEIVE, 0.0f) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.clock_mode == LE_CLOCK_OFF); /* dropped, not applied */

  CHECK(le_push(e, LE_CMD_SET_CLOCK_MODE, 99, 0.0f) == LE_OK);
  tg_advance(e, 1);
  le_engine_get_snapshot(e, &s);
  CHECK(s.clock_mode == LE_CLOCK_OFF);

  le_engine_destroy(e);
}

static void test_clock_off_emits_nothing_even_when_active(void) {
  printf("test_clock_off_emits_nothing_even_when_active\n");
  /* clock_mode stays at its OFF default throughout: a fully active Multi-
   * mode transport with a tempo set produces zero clock bytes. */
  le_engine* e = tg_make_engine_cap(1000, 100000);
  le_engine_set_tempo(e, 120.0f);
  tg_advance(e, 1);

  tg_record_defining_loop(e, 4000);
  tg_advance(e, 4000); /* a couple more loop cycles of playback */

  uint8_t bytes[256];
  CHECK(clock_drain(e, bytes, 256) == 0);

  le_engine_destroy(e);
}

static void test_clock_silent_in_song_and_free_modes(void) {
  printf("test_clock_silent_in_song_and_free_modes\n");
  /* Manual-verified (D15, song-mode-spec.md): send is active ONLY in Multi/
   * Sync/Band -- Song and Free stay silent no matter what clock_mode says. */
  const int32_t modes[] = {LE_LOOPER_MODE_SONG, LE_LOOPER_MODE_FREE};
  for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); ++i) {
    le_engine* e = tg_make_engine_cap(1000, 100000);
    CHECK(le_engine_set_looper_mode(e, modes[i]) == LE_OK);
    CHECK(le_engine_set_clock_mode(e, LE_CLOCK_SEND) == LE_OK);
    le_engine_set_tempo(e, 120.0f);
    tg_advance(e, 1);

    tg_record_defining_loop(e, 4000);
    tg_advance(e, 4000);

    uint8_t bytes[256];
    CHECK(clock_drain(e, bytes, 256) == 0);

    le_engine_destroy(e);
  }
}

/* Records a defining loop of `len` frames on channel 0 with clock send
 * active, then drains and returns the emitted byte sequence's length,
 * writing it into `out` (capacity `cap`). Shared by the Multi/Sync/Band gate
 * test below -- the three modes are expected to behave identically here
 * (none of B3/B4's primary-relative machinery changes whether the transport
 * itself is "active", which is all the clock gate reads). */
static int32_t clock_record_and_drain(int32_t mode, int32_t len, uint8_t* out,
                                      int32_t cap) {
  le_engine* e = tg_make_engine_cap(1000, 100000);
  CHECK(le_engine_set_looper_mode(e, mode) == LE_OK);
  CHECK(le_engine_set_clock_mode(e, LE_CLOCK_SEND) == LE_OK);
  le_engine_set_tempo(e, 120.0f); /* 500 fpb, 1000 fp-quarter -> 41.67 fp-tick */
  tg_advance(e, 1);

  tg_record_defining_loop(e, len);
  tg_advance(e, len); /* one more full loop of playback */
  CHECK(le_engine_stop_track(e, 0) == LE_OK);
  tg_advance(e, 1);

  const int32_t n = clock_drain(e, out, cap);
  le_engine_destroy(e);
  return n;
}

static void test_clock_multi_sync_band_emit_start_ticks_stop(void) {
  printf("test_clock_multi_sync_band_emit_start_ticks_stop\n");
  const int32_t modes[] = {LE_LOOPER_MODE_MULTI, LE_LOOPER_MODE_SYNC,
                           LE_LOOPER_MODE_BAND};
  for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); ++i) {
    uint8_t bytes[4096];
    const int32_t n = clock_record_and_drain(modes[i], 4000, bytes, 4096);
    CHECK(n >= 2); /* at least a Start and a Stop */
    CHECK(bytes[0] == LE_MIDI_CLOCK_START);
    CHECK(bytes[n - 1] == LE_MIDI_CLOCK_STOP);
    /* Exactly one Start and one Stop across one continuous active run. */
    int starts = 0, stops = 0, ticks = 0;
    for (int32_t b = 0; b < n; ++b) {
      if (bytes[b] == LE_MIDI_CLOCK_START) starts++;
      else if (bytes[b] == LE_MIDI_CLOCK_STOP) stops++;
      else if (bytes[b] == LE_MIDI_CLOCK_TICK) ticks++;
    }
    CHECK(starts == 1);
    CHECK(stops == 1);
    CHECK(ticks > 0); /* some clock ticks actually fired */
  }
}

static void test_clock_start_not_at_count_in_start(void) {
  printf("test_clock_start_not_at_count_in_start\n");
  /* D15: Start is sent at the loop downbeat (end of count-in), never at
   * count-in start. Mirrors test_length_preset_n_bars_click_on_arms_
   * through_count_in's count-in drive pattern above. */
  le_engine* e = tg_make_engine_cap(1000, 100000);
  le_snapshot s;

  le_engine_set_tempo(e, 120.0f); /* 500 frames/beat, 2000 frames/bar (4/4) */
  CHECK(le_engine_set_count_in(e, 1) == LE_OK); /* 1 bar = 2000 frames */
  CHECK(le_engine_set_clock_mode(e, LE_CLOCK_SEND) == LE_OK);
  tg_advance(e, 1);

  le_engine_record(e, 0); /* enters the count-in, not RECORDING yet */
  tg_advance(e, 1999);
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 1);
  CHECK(s.tracks[0].state == LE_TRACK_EMPTY);

  /* Nothing on the clock ring while counting in -- no premature Start. */
  uint8_t bytes[64];
  CHECK(clock_drain(e, bytes, 64) == 0);

  tg_advance(e, 1); /* the 2000th frame: count-in commits, recording begins */
  le_engine_get_snapshot(e, &s);
  CHECK(s.counting_in == 0);
  CHECK(s.tracks[0].state == LE_TRACK_RECORDING);

  /* Exactly the downbeat's Start appears now -- not before. */
  const int32_t n = clock_drain(e, bytes, 64);
  CHECK(n >= 1);
  CHECK(bytes[0] == LE_MIDI_CLOCK_START);
  for (int32_t b = 1; b < n; ++b) CHECK(bytes[b] != LE_MIDI_CLOCK_START);

  le_engine_destroy(e);
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
  test_export_track_lane_multi_lane();
  test_import_track_lane_multi_lane_roundtrip();
  test_layer_export_import_roundtrip();
  test_layer_import_rejects_bad_reconstruction();
  test_layer_multi_lane_roundtrip();
  test_layer_reconstruct_two_redo();
  test_layer_overdub_after_reload_no_corruption();
  test_target_multiple_forces_length();
  test_default_multiple_applies_to_inheriting_tracks();
  test_fixed_multiple_auto_finalizes();
  test_rec_dub_continues_into_overdub();
  test_new_track_autofinish_overdubs_with_rec_dub_off();
  test_rec_dub_first_wrap_is_undoable_layer();
  test_new_track_first_wrap_is_undoable_layer();
  test_first_wrap_layer_shrinks_to_quantum();
  test_deferred_arm_first_wrap_shadow_fits_loop();
  test_click_defaults_and_validation();
  test_click_masked_channels_and_volume();
  test_click_bypasses_master_bus();
  test_click_respects_output_enabled_gate();
  test_click_mode_rec_semantics();
  test_click_punch_in_overdub_no_off_grid_click();
  test_click_mode_rec_first_semantics();
  test_click_mode_rec_first_second_track_silent();
  test_click_mode_play_rec_semantics();
  test_click_mode_off_stays_silent();
  test_click_count_in_downbeat_vs_beat_frequency();
  test_click_free_running_downbeat_vs_beat_frequency();
  test_click_loop_locked_downbeat_vs_beat_frequency();
  test_count_in_delays_defining_record();
  test_count_in_record_press_cancels();
  test_count_in_stop_and_disable_cancel();
  test_count_in_bars_change_mid_count_cancels();
  test_tempo_lock_during_count_in();
  test_count_in_cancel_race_across_block_boundary();
  test_count_in_without_tempo_records_immediately();
  test_count_in_never_fires_with_content();
  test_count_in_auto_record_mutual_exclusion();
  test_count_in_click_absent_from_perf_capture();
  test_first_wrap_prearm_footprint_bounded();
  test_rec_dub_long_loop_first_wrap_undo();
  test_multi_lane_long_loop_dub_roundtrip();
  test_undo_pool_eviction_long_loop();
  test_record_offset_long_loop();
  test_overdub_feedback_long_loop();
  test_auto_record_starts_on_signal();
  test_quantize_track_override_forces_on();
  test_quantize_track_override_forces_off();
  test_quantize_track_override_inherits();
  test_monitor_single_chain();
  test_monitor_volume();
  test_monitor_mute();
  test_latency_restores_monitoring();
  test_latency_keeps_monitor_enabled_set_mid_measurement();
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
  test_perf_layer_persists_through_pool_eviction();
  test_perf_layer_persists_through_clear_during_dub();
  test_perf_layer_persists_through_redo_invalidation();
  test_perf_layer_hand_off_ordering_on_write_failure();
  test_perf_layer_no_staging_when_unarmed();
  test_layer_staging_ring_overflow_returns_zero();
  test_perf_layer_persists_burst_of_two_in_one_drain();
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
  test_clear_undoable_restores_take_and_layers();
  test_clear_undoable_redo_reclears();
  test_clear_undoable_restores_master_grid();
  test_clear_undoable_restores_state_and_mutes();
  test_record_after_undoable_clear_drops_restore_point();
  test_plain_clear_leaves_no_restore_point();
  test_undoable_clear_of_empty_track_is_plain();
  test_cleared_sibling_does_not_hold_grid();
  test_record_over_cleared_track_drops_restore_point_grid_held();
  test_redo_stack_bounded_with_restore_point();
  test_empty_track_never_reports_undo_depth();
  test_undo_restores_clear_query();
  test_undo_restores_clear_query_false_after_record();
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
  test_tempo_grid_math();
  test_tempo_grid_next_boundary();
  test_tempo_grid_signature_validation();
  test_tempo_grid_derive_bpm();
  test_tempo_grid_bpm_for_length();
  test_tempo_grid_defaults_and_persistence();
  test_tempo_set_and_clamp();
  test_tap_tempo();
  test_manual_vs_tap_last_writer();
  test_time_signature_validation();
  test_quantize_div_setter();
  test_loop_syncs_tempo();
  test_loop_rounds_to_bar_keeps_tempo();
  test_sync_off_keeps_free_form();
  test_loop_derives_tempo_from_none();
  test_derive_only_from_none();
  test_length_preset_auto_click_off_unchanged();
  test_length_preset_auto_click_on_derives_bars_only();
  test_length_preset_auto_click_on_no_tempo_falls_back();
  test_length_preset_n_bars_click_off_derives_tempo();
  test_length_preset_n_bars_click_on_auto_finalizes();
  test_length_preset_n_bars_click_on_arms_through_count_in();
  test_length_preset_n_bars_click_on_early_press_disarms();
  test_length_preset_n_bars_click_on_handoff_before_target();
  test_length_preset_n_bars_click_on_handoff_during_crossfade();
  test_length_preset_n_bars_click_on_no_tempo_fallback();
  test_length_preset_signature_drift_after_set_degrades_cleanly();
  test_length_preset_setter_validates_args();
  test_length_preset_allocation_capacity();
  test_length_preset_allocation_capacity_exact_fit();
  test_length_preset_inert_until_rerecord();
  test_length_preset_dormant_with_sync_off();
  test_loop_drives_beat_counter();
  test_beat_counter_generic_signature();
  test_tempo_lock_with_content();
  test_dead_tempo_survives_source_clear();
  test_clear_undo_restores_grid();
  test_surviving_grid_regrid_on_tempo_change();
  test_commit_session_resets_stale_grid();
  test_tap_pair_dies_with_clear();
  test_lock_engages_with_sync_off_content();
  test_beat_division_locks_to_loop();
  test_beat_boundary_on_block_edge();
  test_loop_subdiv_ratio_and_boundaries();
  test_quantize_div_start_fires_on_loop_locked_grid();
  test_quantize_div_record_end_rounds_down();
  test_quantize_div_record_end_rounds_up();
  test_quantize_div_record_end_min_one_unit();
  test_quantize_div_overdub_start_quantized_end_layer();
  test_quantize_div_granularity_change_reevaluates();
  test_quantize_div_off_reverts_pending_to_loop_top();
  test_quantize_div_min_one_unit_reevaluates_on_granularity_change();
  test_quantize_div_disarm_wins_at_boundary_block();
  test_quantize_div_handoff_clears_pending_end();
  test_quantize_boolean_handoff_clears_pending_end();
  test_quantize_div_requires_boolean_quantize();
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

  test_json_read_parses_nested_objects_and_arrays();
  test_json_read_rejects_malformed_input();
  test_json_read_arena_exhaustion_fails_cleanly();
  test_json_read_get_and_length_reject_non_objects();

  test_perf_render_scripted_log_boundaries();
  test_perf_render_overdub_stitching();
  test_perf_render_stitching_long_loop();
  test_perf_render_stitching_mid_loop_arm();
  test_perf_render_fresh_recorded_while_armed();
  test_perf_render_progress_and_cancel();
  test_perf_render_concurrent_with_live_engine();
  test_perf_render_partial_success();
  test_perf_render_missing_or_corrupt_manifest();
  test_perf_render_wet_fx_sweep();
  test_perf_render_dry_write_fail_excludes_from_master();
  test_perf_render_multi_channel_dry_fail_isolated();
  test_perf_render_wet_multi_slot_and_count_shrink();
  test_perf_render_wet_plugin_passthrough();
  test_perf_render_fresh_midloop_second_track_phase();
  test_perf_render_fresh_multiloop_second_track_phase();
  test_perf_render_golden_master_parity();
  test_perf_render_quantized_round_down_truncation_log_frame();
  test_looper_mode_defaults_and_persistence();
  test_looper_mode_setter_validates_args();
  test_looper_mode_switch_accepted_when_empty();
  test_looper_mode_locked_with_content();
  test_looper_mode_locked_by_non_zero_track_content();
  test_free_mode_defining_recording_sets_own_clock_not_master();
  test_free_mode_independent_lengths_prime_wraps();
  test_free_mode_one_capturer_handoff_finalizes_to_own_length();
  test_free_mode_no_residual_multi_mode_state();
  test_free_mode_overdub_writes_own_position();
  test_free_mode_per_track_viz_independent();
  test_free_mode_dub_layer_retires_not_stuck();
  test_free_mode_commit_session_rejected_leaves_master_dormant();
  test_free_mode_stopped_track_freezes_phase();
  test_free_mode_clear_resets_targeted_track_only();
  test_free_mode_undo_to_empty_resets_targeted_track_only();
  test_free_mode_redo_from_empty_restores_targeted_track_only();
  test_free_mode_restore_clear_restores_targeted_track_only();
  test_free_mode_playback_output_scans_own_position();
  test_free_mode_punch_in_ramps_not_hard_cuts();

  test_song_mode_defining_recording_sets_own_clock_not_master();
  test_song_mode_independent_lengths_wraps();
  test_song_mode_one_capturer_handoff_finalizes_to_own_length();
  test_song_mode_commit_session_rejected_leaves_master_dormant();
  test_song_mode_dub_layer_retires_not_stuck();
  test_song_mode_clear_resets_targeted_track_only();
  test_song_mode_undo_to_empty_resets_targeted_track_only();
  test_song_mode_redo_from_empty_restores_targeted_track_only();
  test_song_mode_restore_clear_restores_targeted_track_only();
  test_song_mode_per_track_viz_independent();
  test_song_mode_playback_output_scans_own_position();
  test_looper_mode_switch_multi_song_free_locked_with_content();

  test_one_shot_default_off();
  test_one_shot_setter_rejects_invalid_channel();
  test_one_shot_setter_accepted_in_any_mode();
  test_one_shot_persists_through_clear_reset_by_configure();
  test_one_shot_stops_track_at_wrap_in_song_mode();
  test_one_shot_off_track_keeps_looping_in_song_mode();
  test_one_shot_dormant_in_multi_mode();
  test_one_shot_overdubbing_track_stops_cleanly_at_wrap();
  test_one_shot_persists_across_mode_switch_fires_on_first_wrap();

  test_primary_track_default_none();
  test_crown_primary_rejects_invalid_channel();
  test_crown_primary_sets_field();
  test_crown_primary_accepted_in_any_mode();
  test_crown_primary_persists_through_clear();
  test_crown_primary_persists_through_undo_to_empty();
  test_crown_primary_re_crown_changes_it();
  test_crown_primary_inert_outside_sync_band();
  test_sync_no_primary_behaves_like_multi();
  test_sync_nonprimary_snaps_down_to_nearest_multiple();
  test_sync_nonprimary_division_half_phase_correct_two_cycles();
  test_sync_nonprimary_division_quarter();
  test_sync_nonprimary_snaps_up_to_nearest_multiple();
  test_sync_round_up_finalize_respects_max_loop_frames();
  test_sync_division_falls_back_on_indivisible_base();
  test_sync_nonprimary_division_even_not_multiple_of_four_tiles_exactly();
  test_crown_division_track_does_not_corrupt_downstream_quantize();
  test_primary_re_record_after_clear_forces_one_base_loop();
  test_sync_force_arm_from_mid_cycle_fires_at_exact_boundary();
  test_primary_cleared_dependent_track_keeps_playing_correctly();
  test_division_track_undo_to_empty_redo_round_trips_divisor();
  test_band_section_toggle_rejected_outside_band_mode();
  test_band_section_toggle_rejected_for_primary();
  test_band_section_toggle_rejected_for_empty_track();
  test_band_section_start_stop_quantized_to_primary_top();
  test_band_section_toggle_rejected_when_primary_not_established();
  test_band_section_pending_toggle_survives_record_press();
  test_band_section_pending_record_survives_toggle_press();
  test_band_section_pending_toggle_survives_immediate_record_press();
  test_band_section_toggle_ignores_subdivision_boundary();
  test_band_section_toggle_reacts_to_state_at_fire_time_not_arm_time();

  test_clock_mode_defaults_and_persistence();
  test_clock_mode_setter_validates_args();
  test_clock_mode_raw_command_revalidates();
  test_clock_off_emits_nothing_even_when_active();
  test_clock_silent_in_song_and_free_modes();
  test_clock_multi_sync_band_emit_start_ticks_stop();
  test_clock_start_not_at_count_in_start();

  if (g_failures == 0) {
    printf("ALL PASSED\n");
    return 0;
  }
  printf("%d CHECK(S) FAILED\n", g_failures);
  return 1;
}
