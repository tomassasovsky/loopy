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

le_plugin_slot* le_plugin_slot_create(const char* plugin_id, double sample_rate,
                                      int32_t* out_reason) {
  (void)plugin_id;
  (void)sample_rate;
  if (out_reason) *out_reason = LE_ERR_INVALID;
  return NULL; /* no host can be created on a disabled build */
}

le_plugin_slot* le_plugin_slot_create_stub(int32_t mode, double sample_rate,
                                           int32_t* out_reason) {
  (void)mode;
  (void)sample_rate;
  if (out_reason) *out_reason = LE_ERR_INVALID;
  return NULL;
}

void le_plugin_slot_set_ready(le_plugin_slot* slot, int32_t ready) {
  (void)slot;
  (void)ready;
}

void le_plugin_slot_destroy(le_plugin_slot* slot) { (void)slot; }

/* ---- Plugin parameters ---- */

int32_t le_plugin_param_count(le_plugin_slot* slot, int32_t* count) {
  (void)slot;
  if (count) *count = 0;
  return LE_ERR_INVALID;
}

int32_t le_plugin_param_info_at(le_plugin_slot* slot, int32_t index,
                                le_plugin_param_info* out) {
  (void)slot;
  (void)index;
  (void)out;
  return LE_ERR_INVALID;
}

int32_t le_plugin_param_get(le_plugin_slot* slot, uint32_t id, double* plain) {
  (void)slot;
  (void)id;
  if (plain) *plain = 0.0;
  return LE_ERR_INVALID;
}

int32_t le_plugin_param_set(le_plugin_slot* slot, uint32_t id, double value) {
  (void)slot;
  (void)id;
  (void)value;
  return LE_ERR_INVALID;
}

int32_t le_plugin_param_value_text(le_plugin_slot* slot, uint32_t id,
                                   double value, char* out, int32_t out_size) {
  (void)slot;
  (void)id;
  (void)value;
  if (out && out_size > 0) out[0] = '\0';
  return LE_ERR_INVALID;
}

/* ---- Native editor window ---- */

int32_t le_plugin_editor_open(le_plugin_slot* slot) {
  (void)slot;
  return LE_ERR_UNSUPPORTED; /* no editor on a disabled build */
}

int32_t le_plugin_editor_close(le_plugin_slot* slot) {
  (void)slot;
  return LE_OK; /* nothing open to close */
}

int32_t le_plugin_editor_is_open(le_plugin_slot* slot, int32_t* open) {
  (void)slot;
  if (open) *open = 0;
  return LE_ERR_INVALID;
}

/* ---- Opaque plugin state ---- */

int32_t le_plugin_state_size(le_plugin_slot* slot, int32_t* bytes) {
  (void)slot;
  if (bytes) *bytes = 0;
  return LE_ERR_INVALID;
}

int32_t le_plugin_state_get(le_plugin_slot* slot, uint8_t* buf, int32_t cap,
                            int32_t* written) {
  (void)slot;
  (void)buf;
  (void)cap;
  if (written) *written = 0;
  return LE_ERR_INVALID;
}

int32_t le_plugin_state_set(le_plugin_slot* slot, const uint8_t* buf,
                            int32_t bytes) {
  (void)slot;
  (void)buf;
  (void)bytes;
  return LE_ERR_INVALID;
}

#endif /* !LOOPY_ENABLE_PLUGINS */
