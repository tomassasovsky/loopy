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

// Resolves a scanned descriptor by its stable id (from the most recent scan).
// Returns false if no scan has run or the id is unknown. Defined in
// plugin_scan.cpp, which owns the scan results.
bool findScannedPlugin(const std::string& id, PluginDescriptor& out);

// The outcome of IPluginHost::load — distinguishes a topology rejection (D-BUS)
// from a generic failure so the ABI can return a distinct code the UI localizes.
enum class LoadStatus {
  ok,                  // loaded + activated, ready to process
  failed,              // generic load/activate failure
  unsupportedTopology, // not a stereo (or mono-adaptable) effect: instrument /
                       // multi-bus / sidechain / wrong channel count
};

// Bit flags describing a plugin parameter (mirrors the ABI's
// le_plugin_param_info.flags). The UI shows only automatable, non-hidden params
// as in-app knobs (umbrella D-UI).
enum ParamFlags : uint32_t {
  kParamAutomatable = 1u << 0,
  kParamReadOnly = 1u << 1,
  kParamBypass = 1u << 2,
  kParamHidden = 1u << 3,
  kParamStepped = 1u << 4,
};

// One plugin parameter's metadata (CONTROL thread). Unifies VST3 ParameterInfo
// (normalized; converted to plain via normalizedParamToPlain) and CLAP
// clap_param_info (already plain) into one PLAIN-valued shape.
struct PluginParamInfo {
  uint32_t id = 0;
  std::string name;
  std::string unit;
  double min = 0.0;
  double max = 1.0;
  double def = 0.0;
  int32_t stepCount = 0;  // 0 = continuous; >0 = discrete steps
  uint32_t flags = 0;
};

// One live plugin loaded into a single FX chain slot. The VST3 and CLAP backends
// (host_vst3.cpp / host_clap.cpp) and the test stub (slot.cpp) implement this.
// Every method runs on the CONTROL thread EXCEPT process() and queueParam(),
// which the slot's sample-to-block adapter calls on the AUDIO THREAD.
class IPluginHost {
 public:
  virtual ~IPluginHost() = default;

  // Instantiate + activate the plugin, ready-but-bypassed, at `sampleRate` with
  // a fixed `maxBlock` processing block. On a non-ok status the host is
  // discarded without process() ever being called.
  virtual LoadStatus load(const PluginDescriptor& descriptor, double sampleRate,
                          int maxBlock) = 0;

  // AUDIO THREAD ONLY: process exactly `frames` samples of stereo audio in
  // place (left[frames], right[frames]). Must not allocate, lock, or block.
  // Any params staged by queueParam() since the last call are applied here via
  // the SDK's own event mechanism (D-PARAM: never a direct store).
  virtual void process(float* left, float* right, int frames) = 0;

  // --- Parameters ---

  // CONTROL THREAD: the number of parameters, and metadata / current plain
  // value by index / id. paramInfoAt returns false for an out-of-range index.
  virtual int paramCount() = 0;
  virtual bool paramInfoAt(int index, PluginParamInfo& out) = 0;
  virtual double paramGet(uint32_t id) = 0;

  // AUDIO THREAD: stage a queued param change (drained from the slot's lock-free
  // ring) to apply on the next process(). Stores into an audio-thread-owned
  // pending buffer only — no SDK call here, no allocation.
  virtual void queueParam(uint32_t id, double plain) = 0;
};

// Backend factories. Each returns a not-yet-loaded host (the caller calls
// load()); never null. Implemented in host_vst3.cpp / host_clap.cpp.
IPluginHost* createVst3Host();
IPluginHost* createClapHost();

}  // namespace loopy

#endif  // LOOPY_HOST_PLUGIN_HOST_H
