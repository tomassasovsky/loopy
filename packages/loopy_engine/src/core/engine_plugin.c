/*
 * engine_plugin.c — control-thread plugin-slot lifecycle (umbrella D-LIFE).
 *
 * Loading and unloading a hosted plugin into a lane / monitor FX chain slot
 * happens entirely here, on the control thread: the audio thread only ever
 * reads the atomically-published slot pointer + "ready" flag (fx_plugin_process
 * in engine_fx.c). The heavy work — le_plugin_slot_create (instancing,
 * activation, buffer allocation, in host/slot.cpp) and le_plugin_slot_destroy —
 * never touches the audio callback.
 *
 * Teardown uses a published-quiescent handshake: retract `ready` (so the audio
 * thread renders dry even if it still dispatches the entry), mark the chain
 * entry LE_FX_NONE (so it stops dispatching), wait until the audio thread has
 * cycled past two buffers (so it has snapshotted NONE and no longer reads the
 * slot pointer), and only THEN null the pointer and destroy the host. This is
 * always compiled; on a non-LOOPY_ENABLE_PLUGINS build le_plugin_slot_create
 * returns NULL (stubs in plugin_disabled.c) so a load simply fails.
 *
 * PRECONDITION: these entry points are the control thread's alone — they must
 * not be called concurrently with each other (the FFI layer drives them from a
 * single isolate). The audio thread never calls them; it only reads what they
 * publish.
 */
#include <stdatomic.h>

#include "../host/plugin_slot.h"
#include "engine_private.h"

#if defined(_WIN32)
#include <windows.h>
static void control_sleep_ms(int ms) { Sleep((DWORD)ms); }
#else
#include <time.h>
static void control_sleep_ms(int ms) {
  struct timespec t = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&t, NULL);
}
#endif

/* Resolves a lane's effect state + the published type cell for chain entry
 * [index], or returns NULL on an out-of-range address. */
static le_fx_state* lane_fx(le_engine* e, int32_t channel, int32_t lane,
                            int32_t index, _Atomic int32_t** out_type) {
  if (!e || channel < 0 || channel >= e->track_count) return NULL;
  if (lane < 0 || lane >= LE_MAX_LANES) return NULL;
  if (index < 0 || index >= LE_FX_MAX) return NULL;
  le_lane* ln = &e->tracks[channel].lanes[lane];
  *out_type = &ln->a_fx_type[index];
  return &ln->fx;
}

static le_fx_state* monitor_fx(le_engine* e, int32_t input, int32_t index,
                               _Atomic int32_t** out_type) {
  if (!e || input < 0 || input >= LE_MAX_INPUTS) return NULL;
  if (index < 0 || index >= LE_FX_MAX) return NULL;
  le_monitor_input* m = &e->monitors[input];
  *out_type = &m->a_fx_type[index];
  return &m->fx;
}

/* The handshake budget: two processed-buffer boundaries prove the audio thread
 * snapshotted LE_FX_NONE and no longer reads the slot; the 1 ms-per-spin cap
 * bounds teardown so it can never hang on a stalled device. */
#define LE_PLUGIN_QUIESCE_BOUNDARIES 2
#define LE_PLUGIN_QUIESCE_MAX_SPINS 200

/* Tears down whatever plugin occupies fx->plugin[index] via the quiescent
 * handshake, leaving the entry empty (LE_FX_NONE). Returns 1 if the slot was
 * actually reclaimed (or was already empty), 0 if the audio thread could not be
 * confirmed quiescent within the budget — the latter happens only when the
 * device callback is STALLED (e.g. inside a hung plugin), in which case the slot
 * is deliberately NOT freed (that would be a use-after-free): it is left
 * retracted + LE_FX_NONE, so the audio thread never dispatches it again, and it
 * is reclaimed at le_engine_destroy (after the device is closed) or by a later
 * successful clear once the callback recovers. */
static int clear_slot(le_engine* e, le_fx_state* fx, _Atomic int32_t* type,
                      int32_t index) {
  le_plugin_slot* slot =
      atomic_load_explicit(&fx->plugin[index], memory_order_acquire);
  if (!slot) return 1;

  /* 1. Retract ready — the audio thread now renders dry for this entry even if
   *    it still dispatches it, so the host's process() is never called again. */
  le_plugin_slot_set_ready(slot, 0);
  /* 2. Stop the audio thread dispatching the entry at all (release-ordered so
   *    the retract above is visible no later than the NONE the audio reads). */
  atomic_store_explicit(type, LE_FX_NONE, memory_order_release);
  /* 3. Confirm the audio thread cycled past two buffer boundaries (a_frames
   *    advances once per processed buffer), so it has snapshotted NONE. Only
   *    meaningful while the device runs. */
  if (load_i32(&e->a_running)) {
    uint64_t last = atomic_load_explicit(&e->a_frames, memory_order_acquire);
    int boundaries = 0;
    for (int spins = 0;
         spins < LE_PLUGIN_QUIESCE_MAX_SPINS &&
         boundaries < LE_PLUGIN_QUIESCE_BOUNDARIES;
         ++spins) {
      control_sleep_ms(1);
      uint64_t now = atomic_load_explicit(&e->a_frames, memory_order_acquire);
      if (now != last) {
        ++boundaries;
        last = now;
      }
    }
    if (boundaries < LE_PLUGIN_QUIESCE_BOUNDARIES) {
      /* The callback is stalled — do NOT free (a possible in-flight process()
       * would be a use-after-free). Leave the slot retracted + NONE; teardown
       * reclaims it. */
      return 0;
    }
  }
  /* 4. No audio-thread reference remains: null the pointer and destroy. */
  atomic_store_explicit(&fx->plugin[index], NULL, memory_order_release);
  le_plugin_slot_destroy(slot);
  return 1;
}

/* Creates + publishes a plugin into an (already-resolved) slot. Replaces any
 * existing plugin in the same entry first. */
static int32_t install(le_engine* e, le_fx_state* fx, _Atomic int32_t* type,
                       int32_t index, const char* plugin_id,
                       le_plugin_slot** out_slot) {
  /* Replace any existing plugin first. If the old one cannot be safely cleared
   * (a stalled callback), refuse rather than overwrite + leak its pointer. */
  if (!clear_slot(e, fx, type, index)) return LE_ERR_DEVICE;

  double sr = (double)load_i32(&e->a_sample_rate);
  if (sr <= 0.0) sr = e->sample_rate > 0 ? (double)e->sample_rate : 48000.0;

  /* The reason distinguishes a topology rejection (LE_ERR_UNSUPPORTED, D-BUS)
   * from an unknown id / generic load failure, so the UI can localize it. */
  int32_t reason = LE_ERR_DEVICE;
  le_plugin_slot* slot = le_plugin_slot_create(plugin_id, sr, &reason);
  if (!slot) return reason;

  /* Publish the pointer and mark ready BEFORE marking the entry LE_FX_PLUGIN, so
   * the first time the audio thread dispatches it the slot is live. Ordering is
   * not load-bearing for safety: a weak observer that sees PLUGIN before the
   * pointer loads NULL and renders one dry sample — never a crash. */
  atomic_store_explicit(&fx->plugin[index], slot, memory_order_release);
  le_plugin_slot_set_ready(slot, 1);
  atomic_store_explicit(type, LE_FX_PLUGIN, memory_order_release);
  if (out_slot) *out_slot = slot;
  return LE_OK;
}

int32_t le_engine_set_lane_plugin(le_engine* engine, int32_t channel,
                                  int32_t lane, int32_t index,
                                  const char* plugin_id,
                                  le_plugin_slot** out_slot) {
  _Atomic int32_t* type = NULL;
  le_fx_state* fx = lane_fx(engine, channel, lane, index, &type);
  if (!fx || !plugin_id) return LE_ERR_INVALID;
  return install(engine, fx, type, index, plugin_id, out_slot);
}

int32_t le_engine_set_monitor_plugin(le_engine* engine, int32_t input,
                                     int32_t index, const char* plugin_id,
                                     le_plugin_slot** out_slot) {
  _Atomic int32_t* type = NULL;
  le_fx_state* fx = monitor_fx(engine, input, index, &type);
  if (!fx || !plugin_id) return LE_ERR_INVALID;
  return install(engine, fx, type, index, plugin_id, out_slot);
}

int32_t le_engine_clear_lane_plugin(le_engine* engine, int32_t channel,
                                    int32_t lane, int32_t index) {
  _Atomic int32_t* type = NULL;
  le_fx_state* fx = lane_fx(engine, channel, lane, index, &type);
  if (!fx) return LE_ERR_INVALID;
  /* The slot is always retracted + emptied; a deferred reclaim (stalled
   * callback) is still a successful clear from the caller's view. */
  (void)clear_slot(engine, fx, type, index);
  return LE_OK;
}

int32_t le_engine_clear_monitor_plugin(le_engine* engine, int32_t input,
                                       int32_t index) {
  _Atomic int32_t* type = NULL;
  le_fx_state* fx = monitor_fx(engine, input, index, &type);
  if (!fx) return LE_ERR_INVALID;
  (void)clear_slot(engine, fx, type, index);
  return LE_OK;
}
