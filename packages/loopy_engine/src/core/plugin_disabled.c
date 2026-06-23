/*
 * plugin_disabled.c — le_plugin_* stubs for non-LOOPY_ENABLE_PLUGINS builds.
 *
 * Plugin hosting is sequenced macOS-first; the Windows/Linux engine is built
 * without LOOPY_ENABLE_PLUGINS until the ports (parts 8–9). The Dart FFI layer
 * and the engine still bind these symbols, so this stub provides them: scanning
 * reports zero plugins, and the slot interface is a no-op that never creates a
 * host (so le_engine_set_*_plugin simply fails). The real implementations live
 * in host/plugin_scan.cpp and host/slot.cpp, compiled instead when
 * LOOPY_ENABLE_PLUGINS is on.
 */
#ifndef LOOPY_ENABLE_PLUGINS

#include <stddef.h> /* NULL */

#include "../host/plugin_slot.h"
#include "loopy_engine_api.h"

/* ---- Scanning ---- */

int32_t le_plugin_scan_begin(le_engine* engine, int32_t rescan) {
  (void)rescan;
  return engine ? LE_OK : LE_ERR_INVALID;
}

int32_t le_plugin_scan_poll(le_engine* engine, int32_t* done, int32_t* found,
                            int32_t* scanned, int32_t* total) {
  if (!engine) return LE_ERR_INVALID;
  if (done) *done = 1; /* nothing to scan — finished immediately */
  if (found) *found = 0;
  if (scanned) *scanned = 0;
  if (total) *total = 0;
  return LE_OK;
}

int32_t le_plugin_scan_get(le_engine* engine, int32_t index,
                           le_plugin_desc* out) {
  (void)engine;
  (void)index;
  (void)out;
  return LE_ERR_INVALID; /* no entries on a disabled build */
}

int32_t le_plugin_scan_cancel(le_engine* engine) {
  return engine ? LE_OK : LE_ERR_INVALID;
}

/* ---- Plugin slots (host/slot.cpp on a plugin build) ---- */

void le_plugin_slot_process(le_plugin_slot* slot, float* l, float* r) {
  (void)slot;
  (void)l;
  (void)r; /* dry passthrough — leaves the sample untouched */
}

le_plugin_slot* le_plugin_slot_create(const char* plugin_id, double sample_rate) {
  (void)plugin_id;
  (void)sample_rate;
  return NULL; /* no host can be created on a disabled build */
}

le_plugin_slot* le_plugin_slot_create_stub(int32_t mode, double sample_rate) {
  (void)mode;
  (void)sample_rate;
  return NULL;
}

void le_plugin_slot_set_ready(le_plugin_slot* slot, int32_t ready) {
  (void)slot;
  (void)ready;
}

void le_plugin_slot_destroy(le_plugin_slot* slot) { (void)slot; }

#endif /* !LOOPY_ENABLE_PLUGINS */
