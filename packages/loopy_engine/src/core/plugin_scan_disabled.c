/*
 * plugin_scan_disabled.c — le_plugin_scan_* stub for non-LOOPY_ENABLE_PLUGINS
 * builds.
 *
 * Plugin hosting is sequenced macOS-first; the Windows/Linux engine is built
 * without LOOPY_ENABLE_PLUGINS until the ports (parts 8–9). The Dart FFI layer
 * still binds these symbols, so this stub provides them and reports a scan that
 * completes immediately with zero plugins. The real implementation lives in
 * host/plugin_scan.cpp and is compiled instead when LOOPY_ENABLE_PLUGINS is on.
 */
#ifndef LOOPY_ENABLE_PLUGINS

#include "loopy_engine_api.h"

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

#endif /* !LOOPY_ENABLE_PLUGINS */
