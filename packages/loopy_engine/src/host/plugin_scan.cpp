// Plugin scanning — the le_plugin_scan_* C ABI and its dedicated scan thread.
//
// Real implementation, compiled only in a LOOPY_ENABLE_PLUGINS build (macOS
// today). Non-plugin builds link core/plugin_scan_disabled.c instead, which
// provides the same symbols as a "no plugins" stub so FFI always resolves.
//
// Threading model (umbrella D-SCAN): le_plugin_scan_begin launches ONE detached-
// lifetime worker thread that walks the VST3/CLAP install locations and loads
// each candidate; the audio callback is never touched, so a scan is safe while
// the engine runs. Dart polls progress and reads finished entries. Only one
// scan runs at a time; results are buffered under a mutex for le_plugin_scan_get.

#if defined(LOOPY_ENABLE_PLUGINS)

#include <atomic>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

#include "../core/loopy_engine_api.h"
#include "plugin_host.h"

namespace {

// Copies a std::string into a fixed-size C char buffer, NUL-terminated and
// truncated to fit (one byte reserved for the terminator).
template <size_t N>
void copyField(char (&dst)[N], const std::string& src) {
  const size_t n = src.size() < N - 1 ? src.size() : N - 1;
  std::memcpy(dst, src.data(), n);
  dst[n] = '\0';
}

// The single process-wide scan session. There is exactly one engine and one
// scan at a time in the app, so a Meyers singleton keyed by nothing is enough;
// the le_engine* arg is validated for the ABI contract but not used as a key.
class ScanSession final : public loopy::ScanSink {
 public:
  static ScanSession& instance() {
    static ScanSession session;
    return session;
  }

  int32_t begin() {
    if (!done_.load()) return LE_ERR_ALREADY_RUNNING;
    join();  // reap a previously-finished worker
    {
      std::lock_guard<std::mutex> lock(mutex_);
      results_.clear();
    }
    found_.store(0);
    scanned_.store(0);
    total_.store(0);
    cancel_.store(false);
    done_.store(false);
    worker_ = std::thread([this] {
      loopy::scanVst3(*this);
      loopy::scanClap(*this);
      done_.store(true);
    });
    return LE_OK;
  }

  void poll(int32_t* done, int32_t* found, int32_t* scanned, int32_t* total) {
    if (done) *done = done_.load() ? 1 : 0;
    if (found) *found = found_.load();
    if (scanned) *scanned = scanned_.load();
    if (total) *total = total_.load();
  }

  int32_t get(int32_t index, le_plugin_desc* out) {
    if (index < 0 || !out) return LE_ERR_INVALID;
    std::lock_guard<std::mutex> lock(mutex_);
    if (static_cast<size_t>(index) >= results_.size()) return LE_ERR_INVALID;
    *out = results_[static_cast<size_t>(index)];
    return LE_OK;
  }

  void cancel() {
    cancel_.store(true);
    join();
  }

  // Looks up a discovered descriptor by its (non-empty) id. Returns false if no
  // match — including failed entries, whose id is empty.
  bool find(const std::string& id, loopy::PluginDescriptor& out) {
    if (id.empty()) return false;
    std::lock_guard<std::mutex> lock(mutex_);
    for (const le_plugin_desc& d : results_) {
      if (id == d.id) {
        out.id = d.id;
        out.name = d.name;
        out.vendor = d.vendor;
        out.path = d.path;
        out.format = static_cast<loopy::PluginFormat>(d.format);
        out.version = d.version;
        return true;
      }
    }
    return false;
  }

  // --- loopy::ScanSink ---
  void add(const loopy::PluginDescriptor& d) override {
    le_plugin_desc desc;
    std::memset(&desc, 0, sizeof(desc));
    copyField(desc.id, d.id);
    copyField(desc.name, d.name);
    copyField(desc.vendor, d.vendor);
    copyField(desc.path, d.path);
    desc.format = static_cast<int32_t>(d.format);
    desc.version = d.version;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      results_.push_back(desc);
    }
    found_.fetch_add(1);
  }

  void candidateDiscovered() override { total_.fetch_add(1); }
  void candidateScanned() override { scanned_.fetch_add(1); }
  bool cancelled() const override { return cancel_.load(); }

 private:
  ScanSession() { done_.store(true); }
  // ScanSink's destructor is intentionally non-virtual (it is never deleted
  // through a base pointer), so this is not an override.
  ~ScanSession() { join(); }

  void join() {
    if (worker_.joinable()) worker_.join();
  }

  std::thread worker_;
  std::mutex mutex_;  // guards results_
  std::vector<le_plugin_desc> results_;
  std::atomic<int32_t> found_{0};
  std::atomic<int32_t> scanned_{0};
  std::atomic<int32_t> total_{0};
  std::atomic<bool> done_{true};
  std::atomic<bool> cancel_{false};
};

}  // namespace

namespace loopy {

uint32_t parseVersion(const std::string& version) {
  uint32_t parts[3] = {0, 0, 0};
  int field = 0;
  uint32_t cur = 0;
  bool any = false;
  for (char c : version) {
    if (c >= '0' && c <= '9') {
      cur = cur * 10 + static_cast<uint32_t>(c - '0');
      any = true;
    } else if (c == '.') {
      if (field < 3) parts[field] = cur > 255 ? 255 : cur;
      cur = 0;
      if (++field >= 3) break;
    } else {
      break;  // stop at the first non-numeric, non-dot char (e.g. "1.0-beta")
    }
  }
  if (field < 3) parts[field] = cur > 255 ? 255 : cur;
  if (!any) return 0;
  return (parts[0] << 16) | (parts[1] << 8) | parts[2];
}

bool findScannedPlugin(const std::string& id, PluginDescriptor& out) {
  return ScanSession::instance().find(id, out);
}

}  // namespace loopy

extern "C" {

int32_t le_plugin_scan_begin(le_engine* engine, int32_t rescan) {
  (void)rescan;  // native caching is not used in this slice (Dart caches)
  if (!engine) return LE_ERR_INVALID;
  return ScanSession::instance().begin();
}

int32_t le_plugin_scan_poll(le_engine* engine, int32_t* done, int32_t* found,
                            int32_t* scanned, int32_t* total) {
  if (!engine) return LE_ERR_INVALID;
  ScanSession::instance().poll(done, found, scanned, total);
  return LE_OK;
}

int32_t le_plugin_scan_get(le_engine* engine, int32_t index,
                           le_plugin_desc* out) {
  if (!engine) return LE_ERR_INVALID;
  return ScanSession::instance().get(index, out);
}

int32_t le_plugin_scan_cancel(le_engine* engine) {
  if (!engine) return LE_ERR_INVALID;
  ScanSession::instance().cancel();
  return LE_OK;
}

}  // extern "C"

#endif  // LOOPY_ENABLE_PLUGINS
