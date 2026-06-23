// Native stress harness for loopy's VST3 host (Vst3Host in host_vst3.cpp).
//
// Hammers the real host through every lifecycle path — load / process / param
// flood / state get-set / editor open-close / unload — sequentially, in an
// editor open-close storm (the path that exercises the new HostMessage /
// HostAttributeList objects hardest), and concurrently across threads. Reports
// per-phase counts, RSS deltas (leak signal), and attributes any crash to the
// exact plugin + op via a live "current op" breadcrumb.
//
// Build: ./build.sh stress [asan]   (see README.md). Links the actual host TUs.

#import <Cocoa/Cocoa.h>

#include <mach/mach.h>

#include <atomic>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "plugin_host.h"

using loopy::IPluginHost;
using loopy::LoadStatus;
using loopy::PluginDescriptor;
using loopy::PluginParamInfo;

// scanVst3 references loopy::parseVersion (normally defined in plugin_scan.cpp,
// which we don't link — it pulls the whole C ABI). Provide a local definition.
namespace loopy {
uint32_t parseVersion(const std::string& v) {
  uint32_t parts[3] = {0, 0, 0};
  int field = 0;
  uint32_t cur = 0;
  bool any = false;
  for (char c : v) {
    if (c >= '0' && c <= '9') {
      cur = cur * 10 + uint32_t(c - '0');
      any = true;
    } else if (c == '.') {
      if (field < 3) parts[field] = cur > 255 ? 255 : cur;
      cur = 0;
      if (++field >= 3) break;
    } else {
      break;
    }
  }
  if (field < 3) parts[field] = cur > 255 ? 255 : cur;
  if (!any) return 0;
  return (parts[0] << 16) | (parts[1] << 8) | parts[2];
}
}  // namespace loopy

namespace {

constexpr double kSampleRate = 48000.0;
constexpr int kMaxBlock = 512;

// A breadcrumb the signal handler prints so a crash names the offending plugin.
std::atomic<const char*> g_op{"idle"};
std::atomic<const char*> g_plugin{"(none)"};  // descriptor name, atomically swapped
void setOp(const char* op) { g_op.store(op, std::memory_order_relaxed); }
void setPlugin(const std::string& s) {
  // Leak a stable C string per name; cheap and crash-safe to read from a handler.
  g_plugin.store(strdup(s.c_str()), std::memory_order_relaxed);
}

void crashHandler(int sig) {
  const char* op = g_op.load(std::memory_order_relaxed);
  const char* pl = g_plugin.load(std::memory_order_relaxed);
  // async-signal-safe-ish: write() the breadcrumb to stderr (fd 2).
  const char* a = "\n*** CRASH (signal ";
  write(2, a, strlen(a));
  char num[8];
  int n = snprintf(num, sizeof(num), "%d", sig);
  write(2, num, n);
  const char* b = ") during op='";
  write(2, b, strlen(b));
  if (op) write(2, op, strlen(op));
  const char* c = "' plugin='";
  write(2, c, strlen(c));
  if (pl) write(2, pl, strlen(pl));
  const char* d = "' ***\n";
  write(2, d, strlen(d));
  signal(sig, SIG_DFL);
  raise(sig);
}

size_t rssBytes() {
  mach_task_basic_info info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) {
    return 0;
  }
  return info.resident_size;
}
double mb(size_t b) { return double(b) / (1024.0 * 1024.0); }

struct CollectSink final : loopy::ScanSink {
  std::vector<PluginDescriptor> plugins;
  void add(const PluginDescriptor& d) override {
    if (!d.id.empty()) plugins.push_back(d);  // skip failed-candidate entries
  }
  void candidateDiscovered() override {}
  void candidateScanned() override {}
  bool cancelled() const override { return false; }
};

// Pump the AppKit run loop for `ms` so windows actually map / plugins lay out
// and any deferred main-queue frees drain. Main thread only.
void pump(double ms) {
  NSDate* until = [NSDate dateWithTimeIntervalSinceNow:ms / 1000.0];
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:until];
}

// Drive one full audio-ish session on an already-loaded host: flood params and
// process `blocks` blocks of noise. Single-threaded per host (the contract).
void runAudio(IPluginHost* h, int blocks, std::mt19937& rng) {
  std::vector<PluginParamInfo> params;
  const int pc = h->paramCount();
  for (int i = 0; i < pc; ++i) {
    PluginParamInfo info;
    if (h->paramInfoAt(i, info)) params.push_back(info);
  }
  std::vector<float> l(kMaxBlock), r(kMaxBlock);
  std::uniform_real_distribution<float> noise(-1.0f, 1.0f);
  for (int b = 0; b < blocks; ++b) {
    // Flood param changes — sometimes more than the host's pending cap (64) to
    // exercise the drop path; values span the plugin's real plain range.
    if (!params.empty()) {
      const int floods = (b % 7 == 0) ? 80 : 5;
      for (int k = 0; k < floods; ++k) {
        const PluginParamInfo& p = params[rng() % params.size()];
        std::uniform_real_distribution<double> val(p.min, p.max);
        h->queueParam(p.id, val(rng));
      }
    }
    for (int i = 0; i < kMaxBlock; ++i) {
      l[i] = noise(rng);
      r[i] = noise(rng);
    }
    setOp("process");
    h->process(l.data(), r.data(), kMaxBlock);
  }
  // Read back param text for a few — exercises the value->string path.
  for (size_t i = 0; i < params.size() && i < 8; ++i) {
    std::string txt;
    setOp("paramValueText");
    h->paramValueText(params[i].id, h->paramGet(params[i].id), txt);
  }
}

struct Counts {
  std::atomic<int> ok{0}, topo{0}, failed{0}, editors{0}, states{0};
};

// One load→audio→state→unload cycle. Returns false if load failed (expected for
// instruments / multi-bus plugins — not an error).
bool oneCycle(const PluginDescriptor& d, int blocks, std::mt19937& rng,
              Counts& c, bool doState) {
  IPluginHost* h = loopy::createVst3Host();
  if (!h) return false;
  setOp("load");
  const LoadStatus st = h->load(d, kSampleRate, kMaxBlock);
  if (st != LoadStatus::ok) {
    if (st == LoadStatus::unsupportedTopology) {
      c.topo.fetch_add(1);
    } else {
      c.failed.fetch_add(1);
    }
    delete h;  // teardown of a non-ok host must be clean too
    return false;
  }
  c.ok.fetch_add(1);
  runAudio(h, blocks, rng);
  if (doState) {
    std::vector<uint8_t> blob;
    setOp("stateGet");
    if (h->stateGet(blob) && !blob.empty()) {
      setOp("stateSet");
      if (h->stateSet(blob.data(), int(blob.size()))) c.states.fetch_add(1);
      // process again after a state restore — restored params must be live.
      runAudio(h, 8, rng);
    }
  }
  setOp("unload");
  delete h;  // ~Vst3Host runs unload(): editor close, deactivate, release chain
  return true;
}

}  // namespace

int main(int argc, char** argv) {
  @autoreleasepool {
    setvbuf(stdout, nullptr, _IOLBF, 0);  // live progress even when piped to a file
    signal(SIGSEGV, crashHandler);
    signal(SIGABRT, crashHandler);
    signal(SIGBUS, crashHandler);
    const int scale = argc > 1 ? atoi(argv[1]) : 1;  // multiplies iteration counts
    std::printf("== loopy VST3 host stress (scale=%d) ==\n", scale);

    // AppKit must exist before any window/editor work; accessory policy keeps it
    // off the Dock and lets windows map without a full app bundle.
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    CollectSink sink;
    setOp("scan");
    loopy::scanVst3(sink);
    std::printf("scanned %zu VST3 audio-effect classes\n", sink.plugins.size());
    if (sink.plugins.empty()) {
      std::printf("no plugins found — nothing to stress\n");
      return 0;
    }
    for (const auto& p : sink.plugins) {
      std::printf("  - %-28s v%u  %s\n", p.name.c_str(), p.version,
                  p.id.c_str());
    }

    std::mt19937 rng(0xC0FFEE);
    const size_t rssStart = rssBytes();
    std::printf("\nRSS start: %.1f MB\n", mb(rssStart));

    // ---- Phase 1: sequential full-lifecycle churn over every plugin ----
    const int seqIters = 20 * scale;
    std::printf("\n[Phase 1] sequential lifecycle churn: %d iters x %zu plugins\n",
                seqIters, sink.plugins.size());
    Counts c1;
    for (int it = 0; it < seqIters; ++it) {
      for (const auto& d : sink.plugins) {
        setPlugin(d.name);
        oneCycle(d, /*blocks=*/16, rng, c1, /*doState=*/true);
      }
      if ((it + 1) % 5 == 0) {
        std::printf("  iter %3d/%d  ok=%d topo=%d failed=%d states=%d  RSS=%.1f MB\n",
                    it + 1, seqIters, c1.ok.load(), c1.topo.load(),
                    c1.failed.load(), c1.states.load(), mb(rssBytes()));
      }
    }
    const size_t rssAfter1 = rssBytes();
    std::printf("[Phase 1] done. ok=%d topo=%d failed=%d states=%d  RSS=%.1f MB (+%.1f)\n",
                c1.ok.load(), c1.topo.load(), c1.failed.load(), c1.states.load(),
                mb(rssAfter1), mb(rssAfter1 - rssStart));

    // ---- Phase 2: editor open/close STORM (the new-code hot path) ----
    // First discover which plugins actually expose an editor, then churn them.
    std::printf("\n[Phase 2] editor open/close storm (HostMessage path)\n");
    std::vector<PluginDescriptor> editable;
    for (const auto& d : sink.plugins) {
      IPluginHost* h = loopy::createVst3Host();
      setPlugin(d.name);
      setOp("load(probe)");
      if (h->load(d, kSampleRate, kMaxBlock) == LoadStatus::ok) {
        setOp("editorOpen(probe)");
        if (h->editorOpen()) {
          editable.push_back(d);
          setOp("editorClose(probe)");
          h->editorClose();
        }
      }
      delete h;
    }
    std::printf("  %zu plugins expose an editor\n", editable.size());
    const int edIters = 15 * scale;
    Counts c2;
    for (const auto& d : editable) {
      setPlugin(d.name);
      IPluginHost* h = loopy::createVst3Host();
      if (h->load(d, kSampleRate, kMaxBlock) != LoadStatus::ok) {
        delete h;
        continue;
      }
      // Open/close many times on ONE loaded instance: each open makes DPF mint a
      // fresh batch of IMessage/IAttributeList through our createInstance.
      for (int k = 0; k < edIters; ++k) {
        setOp("editorOpen");
        const bool opened = h->editorOpen();
        pump(4);
        // Interleave audio while the editor is open — params + messages in flight.
        runAudio(h, 2, rng);
        setOp("editorClose");
        h->editorClose();
        pump(1);
        if (opened) c2.editors.fetch_add(1);
      }
      // Also churn full load+open+close so window + plugin teardown repeats.
      for (int k = 0; k < edIters / 4; ++k) {
        IPluginHost* h2 = loopy::createVst3Host();
        if (h2->load(d, kSampleRate, kMaxBlock) == LoadStatus::ok) {
          setOp("editorOpen(reload)");
          if (h2->editorOpen()) {
            pump(2);
            c2.editors.fetch_add(1);
          }
          setOp("editorClose(reload)");
          h2->editorClose();
        }
        delete h2;
      }
      delete h;
      std::printf("  %-28s editor cycles done  RSS=%.1f MB\n", d.name.c_str(),
                  mb(rssBytes()));
    }
    const size_t rssAfter2 = rssBytes();
    std::printf("[Phase 2] done. editor opens=%d  RSS=%.1f MB (+%.1f since p1)\n",
                c2.editors.load(), mb(rssAfter2), mb(rssAfter2 - rssAfter1));

    // ---- Phase 3: concurrent load/process/unload churn (no editors) ----
    setOp("idle");
    const int threads = 8;
    const int perThread = 60 * scale;
    std::printf("\n[Phase 3] concurrent churn: %d threads x %d cycles\n", threads,
                perThread);
    Counts c3;
    std::atomic<int> done{0};
    std::vector<std::thread> pool;
    for (int t = 0; t < threads; ++t) {
      pool.emplace_back([&, t] {
        std::mt19937 trng(0xABCD + t);
        for (int k = 0; k < perThread; ++k) {
          const auto& d = sink.plugins[trng() % sink.plugins.size()];
          oneCycle(d, /*blocks=*/8, trng, c3, /*doState=*/(k % 3 == 0));
          done.fetch_add(1);
        }
      });
    }
    for (auto& th : pool) th.join();
    const size_t rssAfter3 = rssBytes();
    std::printf("[Phase 3] done. cycles=%d ok=%d topo=%d failed=%d states=%d  RSS=%.1f MB (+%.1f since p2)\n",
                done.load(), c3.ok.load(), c3.topo.load(), c3.failed.load(),
                c3.states.load(), mb(rssAfter3), mb(rssAfter3 - rssAfter2));

    std::printf("\n== SUMMARY ==\n");
    std::printf("total loads ok: %d   topology-rejected: %d   load-failed: %d\n",
                c1.ok.load() + c3.ok.load(), c1.topo.load() + c3.topo.load(),
                c1.failed.load() + c3.failed.load());
    std::printf("editor opens:   %d\n", c2.editors.load());
    std::printf("state restores: %d\n", c1.states.load() + c3.states.load());
    std::printf("RSS: start %.1f MB -> end %.1f MB (net +%.1f MB)\n",
                mb(rssStart), mb(rssAfter3), mb(rssAfter3 - rssStart));
    std::printf("DONE — no crash.\n");
    return 0;
  }
}
