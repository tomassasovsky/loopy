/*
 * plugin_slot.h — internal interface to a hosted-plugin chain slot.
 *
 * C-compatible (used from the C engine: engine_fx.c calls the per-sample
 * adapter; engine_plugin.c manages the lifecycle). The real implementation is
 * host/slot.cpp (LOOPY_ENABLE_PLUGINS); other builds link the stubs in
 * core/plugin_disabled.c so the symbols always resolve.
 *
 * Threads (umbrella D-LIFE):
 *   - le_plugin_slot_process runs ON THE AUDIO THREAD and only ever reads an
 *     atomically-published "ready" flag — never allocates, locks, or frees.
 *   - every other function runs on the CONTROL thread.
 */
#ifndef LOOPY_HOST_PLUGIN_SLOT_H
#define LOOPY_HOST_PLUGIN_SLOT_H

#include <stdint.h>

#include "loopy_engine_api.h" /* le_plugin_slot */

#ifdef __cplusplus
extern "C" {
#endif

/* AUDIO THREAD: forward one stereo sample through the slot's plugin via the
 * sample-to-block adapter (one block of latency). If the slot is not ready
 * (loading / unloading / failed) it leaves *l,*r unchanged — dry passthrough,
 * no click. Never allocates, locks, or frees. */
void le_plugin_slot_process(le_plugin_slot* slot, float* l, float* r);

/* CONTROL THREAD: create + activate (bypassed) a slot hosting `plugin_id`
 * (resolved from the last scan) at `sample_rate`. The slot is created NOT ready;
 * publish it, then le_plugin_slot_set_ready(slot, 1). Returns NULL on an unknown
 * id, a load/activate failure, or a non-plugin build. */
le_plugin_slot* le_plugin_slot_create(const char* plugin_id, double sample_rate);

/* CONTROL THREAD, TEST ONLY: create a slot backed by a deterministic stub host
 * (le_plugin_stub_mode) so the native harness can exercise the lifecycle +
 * sanitize + adapter without a real plugin install. Created NOT ready. */
le_plugin_slot* le_plugin_slot_create_stub(int32_t mode, double sample_rate);

/* CONTROL THREAD: publish (`ready` != 0) or retract (`ready` == 0) the slot.
 * Retracting makes the audio thread render dry on the next sample; it is the
 * first step of teardown (before the quiescent handshake + destroy). */
void le_plugin_slot_set_ready(le_plugin_slot* slot, int32_t ready);

/* CONTROL THREAD: destroy the host and free the slot. The caller MUST have
 * retracted ready and completed the quiescent handshake first, so the audio
 * thread no longer references the slot. Safe with NULL. */
void le_plugin_slot_destroy(le_plugin_slot* slot);

/* Behaviour modes for le_plugin_slot_create_stub. */
typedef enum le_plugin_stub_mode {
  LE_PLUGIN_STUB_IDENTITY = 0, /* pass audio through unchanged */
  LE_PLUGIN_STUB_GAIN = 1,     /* halve the signal (audible, deterministic) */
  LE_PLUGIN_STUB_NAN = 2,      /* emit NaN/Inf (exercises the sanitize boundary) */
  LE_PLUGIN_STUB_DENORMAL = 3, /* emit denormals (exercises denormal flush) */
  LE_PLUGIN_STUB_SILENCE = 4,  /* emit silence */
} le_plugin_stub_mode;

#ifdef __cplusplus
}
#endif

#endif /* LOOPY_HOST_PLUGIN_SLOT_H */
