/*
 * test_plugin_slot.c — the safety-critical plugin slot path (umbrella D-LIFE /
 * D-RT), driven end-to-end through the real fx_apply_chain with a deterministic
 * stub host. macOS-only (LOOPY_ENABLE_PLUGINS), built by run_native_tests.sh.
 *
 * Covers:
 *   - the sample-to-block adapter (identity host => input delayed by one block);
 *   - dry passthrough for a not-ready slot (no click during load/unload);
 *   - the output sanitize boundary (a NaN/Inf or denormal host cannot poison the
 *     chain — every output sample stays finite and bounded);
 *   - teardown safety (process after retracting ready + after the pointer is
 *     cleared is a harmless no-op).
 *
 * Expects "ALL PASSED".
 */
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../host/plugin_slot.h"
#include "engine_fx.h"
#include "engine_private.h"
#include "loopy_engine_api.h"

static int g_failures = 0;

#define CHECK(cond)                                       \
  do {                                                    \
    if (!(cond)) {                                        \
      printf("  FAIL: %s (line %d)\n", #cond, __LINE__);  \
      g_failures++;                                       \
    }                                                     \
  } while (0)

/* The adapter block size in slot.cpp — kept in sync here for the latency check. */
#define SLOT_BLOCK 128

/* Drives `n` input samples through a one-entry LE_FX_PLUGIN chain on `fx`,
 * writing the wet output into `out`. Runs the real fx_apply_chain per sample. */
static void drive(le_fx_state* fx, const float* in, float* out, int n) {
  int32_t types[LE_FX_MAX];
  float params[LE_FX_MAX][LE_FX_PARAMS];
  memset(types, 0, sizeof(types));
  memset(params, 0, sizeof(params));
  types[0] = LE_FX_PLUGIN;
  for (int i = 0; i < n; ++i) {
    float l = in[i];
    float r = in[i];
    fx_apply_chain(fx, 48000, 48000, &l, &r, 1, types, params);
    out[i] = l;
  }
}

static void test_adapter_latency(void) {
  printf("test_adapter_latency\n");
  le_fx_state fx;
  memset(&fx, 0, sizeof(fx));
  le_plugin_slot* slot = le_plugin_slot_create_stub(LE_PLUGIN_STUB_IDENTITY, 48000, NULL);
  CHECK(slot != NULL);
  atomic_store(&fx.plugin[0], slot);
  le_plugin_slot_set_ready(slot, 1);

  const int n = SLOT_BLOCK * 3;
  float in[SLOT_BLOCK * 3];
  float out[SLOT_BLOCK * 3];
  memset(in, 0, sizeof(in));
  in[0] = 1.0f; /* a unit impulse at sample 0 */
  drive(&fx, in, out, n);

  /* Identity host with one block of latency: the impulse re-appears exactly one
   * block later, and the first block is silent. */
  for (int i = 0; i < SLOT_BLOCK; ++i) CHECK(out[i] == 0.0f);
  CHECK(out[SLOT_BLOCK] == 1.0f);
  for (int i = SLOT_BLOCK + 1; i < n; ++i) CHECK(out[i] == 0.0f);

  atomic_store(&fx.plugin[0], (le_plugin_slot*)NULL);
  le_plugin_slot_destroy(slot);
}

static void test_dry_when_not_ready(void) {
  printf("test_dry_when_not_ready\n");
  le_fx_state fx;
  memset(&fx, 0, sizeof(fx));
  le_plugin_slot* slot = le_plugin_slot_create_stub(LE_PLUGIN_STUB_GAIN, 48000, NULL);
  CHECK(slot != NULL);
  atomic_store(&fx.plugin[0], slot);
  /* NOT ready: the audio thread must pass audio through untouched. */

  const int n = SLOT_BLOCK * 2;
  float in[SLOT_BLOCK * 2];
  float out[SLOT_BLOCK * 2];
  for (int i = 0; i < n; ++i) in[i] = 0.25f;
  drive(&fx, in, out, n);
  for (int i = 0; i < n; ++i) CHECK(out[i] == 0.25f); /* dry, no gain, no latency */

  atomic_store(&fx.plugin[0], (le_plugin_slot*)NULL);
  le_plugin_slot_destroy(slot);
}

/* A NaN/Inf-emitting host: every processed output sample must be sanitized to a
 * finite value before re-entering the chain (D-RT). */
static void test_sanitize_nan(void) {
  printf("test_sanitize_nan\n");
  le_fx_state fx;
  memset(&fx, 0, sizeof(fx));
  le_plugin_slot* slot = le_plugin_slot_create_stub(LE_PLUGIN_STUB_NAN, 48000, NULL);
  CHECK(slot != NULL);
  atomic_store(&fx.plugin[0], slot);
  le_plugin_slot_set_ready(slot, 1);

  const int n = SLOT_BLOCK * 3;
  float in[SLOT_BLOCK * 3];
  float out[SLOT_BLOCK * 3];
  for (int i = 0; i < n; ++i) in[i] = 0.5f;
  drive(&fx, in, out, n);

  for (int i = 0; i < n; ++i) {
    CHECK(isfinite(out[i]));   /* never NaN/Inf downstream */
    CHECK(out[i] == 0.0f);     /* the NaN/Inf block sanitizes to 0 */
  }

  atomic_store(&fx.plugin[0], (le_plugin_slot*)NULL);
  le_plugin_slot_destroy(slot);
}

static void test_sanitize_denormal(void) {
  printf("test_sanitize_denormal\n");
  le_fx_state fx;
  memset(&fx, 0, sizeof(fx));
  le_plugin_slot* slot =
      le_plugin_slot_create_stub(LE_PLUGIN_STUB_DENORMAL, 48000, NULL);
  CHECK(slot != NULL);
  atomic_store(&fx.plugin[0], slot);
  le_plugin_slot_set_ready(slot, 1);

  const int n = SLOT_BLOCK * 3;
  float in[SLOT_BLOCK * 3];
  float out[SLOT_BLOCK * 3];
  for (int i = 0; i < n; ++i) in[i] = 0.5f;
  drive(&fx, in, out, n);
  for (int i = 0; i < n; ++i) CHECK(out[i] == 0.0f); /* denormals flushed */

  atomic_store(&fx.plugin[0], (le_plugin_slot*)NULL);
  le_plugin_slot_destroy(slot);
}

static void test_teardown_is_safe(void) {
  printf("test_teardown_is_safe\n");
  le_fx_state fx;
  memset(&fx, 0, sizeof(fx));
  le_plugin_slot* slot = le_plugin_slot_create_stub(LE_PLUGIN_STUB_GAIN, 48000, NULL);
  CHECK(slot != NULL);
  atomic_store(&fx.plugin[0], slot);
  le_plugin_slot_set_ready(slot, 1);

  float in[SLOT_BLOCK];
  float out[SLOT_BLOCK];
  for (int i = 0; i < SLOT_BLOCK; ++i) in[i] = 0.5f;
  drive(&fx, in, out, SLOT_BLOCK);

  /* Retract ready: further processing is dry (host never called again). */
  le_plugin_slot_set_ready(slot, 0);
  drive(&fx, in, out, SLOT_BLOCK);
  for (int i = 0; i < SLOT_BLOCK; ++i) CHECK(out[i] == 0.5f);

  /* Clear the pointer, then drive: a NULL slot is a harmless dry no-op. */
  atomic_store(&fx.plugin[0], (le_plugin_slot*)NULL);
  drive(&fx, in, out, SLOT_BLOCK);
  for (int i = 0; i < SLOT_BLOCK; ++i) CHECK(out[i] == 0.5f);

  le_plugin_slot_destroy(slot); /* no audio-thread reference remains */
}

/* The control-thread ABI (engine_plugin.c): addressing + error paths. The
 * success + quiescent-handshake path needs a running device callback and is
 * covered by manual/integration testing per the plan. */
static void test_engine_abi_errors(void) {
  printf("test_engine_abi_errors\n");
  le_engine* e = (le_engine*)calloc(1, sizeof(le_engine));
  CHECK(e != NULL);
  if (!e) return;
  e->track_count = 1; /* one addressable track (lane 0) */

  le_plugin_slot* out = NULL;
  /* Unknown plugin id (no scan has run): load fails cleanly, no slot. */
  CHECK(le_engine_set_lane_plugin(e, 0, 0, 0, "no.such.plugin", &out) ==
        LE_ERR_INVALID);
  CHECK(out == NULL);
  CHECK(le_engine_set_monitor_plugin(e, 0, 0, "no.such.plugin", &out) ==
        LE_ERR_INVALID);

  /* Bad addresses / null args are rejected before any load. */
  CHECK(le_engine_set_lane_plugin(NULL, 0, 0, 0, "x", &out) == LE_ERR_INVALID);
  CHECK(le_engine_set_lane_plugin(e, 99, 0, 0, "x", &out) == LE_ERR_INVALID);
  CHECK(le_engine_set_lane_plugin(e, 0, 0, 0, NULL, &out) == LE_ERR_INVALID);
  CHECK(le_engine_set_monitor_plugin(e, 999, 0, "x", &out) == LE_ERR_INVALID);

  /* Clearing an empty slot is OK + idempotent (not running => no handshake). */
  CHECK(le_engine_clear_lane_plugin(e, 0, 0, 0) == LE_OK);
  CHECK(le_engine_clear_lane_plugin(e, 0, 0, 0) == LE_OK);
  CHECK(le_engine_clear_monitor_plugin(e, 0, 0) == LE_OK);
  CHECK(le_engine_clear_lane_plugin(NULL, 0, 0, 0) == LE_ERR_INVALID);

  free(e);
}

/* Topology guard (D-BUS): a host that rejects its bus layout surfaces the
 * distinct LE_ERR_UNSUPPORTED reason; a normal load reports LE_OK. */
static void test_unsupported_topology(void) {
  printf("test_unsupported_topology\n");
  int32_t reason = LE_OK;
  le_plugin_slot* bad =
      le_plugin_slot_create_stub(LE_PLUGIN_STUB_UNSUPPORTED, 48000, &reason);
  CHECK(bad == NULL);
  CHECK(reason == LE_ERR_UNSUPPORTED);

  reason = LE_ERR_DEVICE;
  le_plugin_slot* ok =
      le_plugin_slot_create_stub(LE_PLUGIN_STUB_IDENTITY, 48000, &reason);
  CHECK(ok != NULL);
  CHECK(reason == LE_OK);
  le_plugin_slot_destroy(ok);
}

/* The param ABI + RT queue: enumeration, and a queued set reaching the plugin
 * via the lock-free ring + process (verified through paramGet, ordering = last
 * write wins). The stub exposes 3 automatable params (ids 100/200/300). */
static void test_param_queue(void) {
  printf("test_param_queue\n");
  le_plugin_slot* slot =
      le_plugin_slot_create_stub(LE_PLUGIN_STUB_IDENTITY, 48000, NULL);
  CHECK(slot != NULL);

  int32_t count = -1;
  CHECK(le_plugin_param_count(slot, &count) == LE_OK);
  CHECK(count == 3);
  le_plugin_param_info info;
  CHECK(le_plugin_param_info_at(slot, 0, &info) == LE_OK);
  CHECK(info.id == 100);
  CHECK((info.flags & LE_PARAM_AUTOMATABLE) != 0);
  CHECK(le_plugin_param_info_at(slot, 9, &info) == LE_ERR_INVALID);

  le_fx_state fx;
  memset(&fx, 0, sizeof(fx));
  atomic_store(&fx.plugin[0], slot);
  le_plugin_slot_set_ready(slot, 1);

  /* Queue several sets before any block processes. */
  CHECK(le_plugin_param_set(slot, 100, 0.3) == LE_OK);
  CHECK(le_plugin_param_set(slot, 100, 0.7) == LE_OK); /* later write wins */
  CHECK(le_plugin_param_set(slot, 200, 0.9) == LE_OK);

  double v = -1.0;
  CHECK(le_plugin_param_get(slot, 100, &v) == LE_OK);
  CHECK(v == 0.5); /* still the default until a block applies the queue */

  /* One block: the ring drains into the host, which applies it in order. */
  float in[SLOT_BLOCK];
  float out[SLOT_BLOCK];
  memset(in, 0, sizeof(in));
  drive(&fx, in, out, SLOT_BLOCK);

  CHECK(le_plugin_param_get(slot, 100, &v) == LE_OK);
  CHECK(v == 0.7);
  CHECK(le_plugin_param_get(slot, 200, &v) == LE_OK);
  CHECK(v == 0.9);

  CHECK(le_plugin_param_count(NULL, &count) == LE_ERR_INVALID);
  CHECK(le_plugin_param_set(NULL, 1, 0.5) == LE_ERR_INVALID);

  atomic_store(&fx.plugin[0], (le_plugin_slot*)NULL);
  le_plugin_slot_destroy(slot);
}

/* The editor ABI on a host with no editor (the stub): open reports
 * unsupported, is_open stays 0, close is a no-op success, and null args are
 * rejected. The real NSWindow path (host_vst3 / host_clap) needs a GUI session
 * + a real plugin, so it is exercised manually, not in this harness. */
static void test_editor_abi_no_editor(void) {
  printf("test_editor_abi_no_editor\n");
  le_plugin_slot* slot =
      le_plugin_slot_create_stub(LE_PLUGIN_STUB_IDENTITY, 48000, NULL);
  CHECK(slot != NULL);

  int32_t open = -1;
  CHECK(le_plugin_editor_is_open(slot, &open) == LE_OK);
  CHECK(open == 0);

  /* The stub host exposes no editor → unsupported, and stays closed. */
  CHECK(le_plugin_editor_open(slot) == LE_ERR_UNSUPPORTED);
  CHECK(le_plugin_editor_is_open(slot, &open) == LE_OK);
  CHECK(open == 0);

  /* Closing an unopened editor is a no-op success (idempotent teardown). */
  CHECK(le_plugin_editor_close(slot) == LE_OK);

  /* Null-argument guards. */
  CHECK(le_plugin_editor_open(NULL) == LE_ERR_INVALID);
  CHECK(le_plugin_editor_close(NULL) == LE_ERR_INVALID);
  CHECK(le_plugin_editor_is_open(NULL, &open) == LE_ERR_INVALID);
  CHECK(le_plugin_editor_is_open(slot, NULL) == LE_ERR_INVALID);

  le_plugin_slot_destroy(slot);
}

int main(void) {
  test_adapter_latency();
  test_dry_when_not_ready();
  test_sanitize_nan();
  test_sanitize_denormal();
  test_teardown_is_safe();
  test_engine_abi_errors();
  test_unsupported_topology();
  test_param_queue();
  test_editor_abi_no_editor();
  if (g_failures == 0) {
    printf("ALL PASSED\n");
    return 0;
  }
  printf("%d FAILURE(S)\n", g_failures);
  return 1;
}
