// Plugin hosting — internal C++ surface (part 2 of the VST3/CLAP stack).
//
// This header is the format-agnostic core the C ABI (le_plugin_*) is built on.
// In this slice it is SCAN ONLY: a descriptor type and the two format scan
// backends. The per-instance IPluginHost interface (load / activate / process /
// params / editor / state) lands in part 3 and will be added here alongside
// PluginDescriptor — kept out now to avoid dead, unimplemented virtuals.
//
// Compiled only in a LOOPY_ENABLE_PLUGINS build (see plugin_scan.cpp).

#ifndef LOOPY_HOST_PLUGIN_HOST_H
#define LOOPY_HOST_PLUGIN_HOST_H

#include <cstdint>
#include <string>

namespace loopy {

// The plugin format a descriptor was discovered in. Values mirror the ABI's
// le_plugin_format so the C boundary is a straight cast.
enum class PluginFormat : int32_t {
  vst3 = 0,
  clap = 1,
};

// One discovered plugin class, format-agnostic. The scan backends fill these
// and the ABI copies them into le_plugin_desc. A FAILED candidate (a file that
// could not be loaded or described) is reported with an empty `id` and `name`/
// `path` pointing at the offending file, so one broken plugin does not abort
// the scan (umbrella D-SCAN).
struct PluginDescriptor {
  std::string id;      // VST3 TUID hex / CLAP descriptor id; empty == failed
  std::string name;
  std::string vendor;
  std::string path;    // .vst3 bundle / .clap file
  PluginFormat format = PluginFormat::vst3;
  uint32_t version = 0;  // packed major<<16 | minor<<8 | patch
};

// The sink the scan backends push into. The driver (plugin_scan.cpp) implements
// it to buffer results, advance progress counters, and signal cancellation, so
// the backends stay ignorant of threading and the C ABI.
struct ScanSink {
  // A discovered class (or a failed-candidate entry with an empty id).
  virtual void add(const PluginDescriptor& descriptor) = 0;
  // ++total — a candidate file was discovered (before it is loaded).
  virtual void candidateDiscovered() = 0;
  // ++scanned — a candidate file was processed (loaded or failed).
  virtual void candidateScanned() = 0;
  // Whether the caller asked to stop; backends should bail between candidates.
  virtual bool cancelled() const = 0;

 protected:
  ~ScanSink() = default;
};

// Format scan backends. Each walks its standard install locations, reports
// progress through `sink`, and adds one entry per audio-effect class (or a
// failed entry per unreadable file). Implemented per-platform (macOS first);
// non-Apple builds are empty until the Windows/Linux ports (parts 8–9).
void scanVst3(ScanSink& sink);
void scanClap(ScanSink& sink);

// Packs a dotted version string ("1.2.3", "1.0.0.0") into major<<16|minor<<8|
// patch, clamping each field to a byte. Returns 0 for an unparseable string.
uint32_t parseVersion(const std::string& version);

}  // namespace loopy

#endif  // LOOPY_HOST_PLUGIN_HOST_H
