// plugin_soak.mm — endurance/soak test for loopy's VST3 host (Vst3Host).
//
// Models a long real session instead of churn: builds N input channels, each a
// chain of K LIVE FX instances (cycling through the loadable plugins for
// variety), and processes audio through every chain continuously for a fixed
// duration across a worker pool. Params are automated periodically; an editor
// is opened/closed every so often on a dedicated instance to exercise the
// HostMessage path over time. RSS + open-fd count are sampled on a schedule so a
// slow leak shows up as a positive slope (MB per instance-audio-hour).
//
// Usage: plugin_soak [channels] [fxPerChannel] [durationSecs] [threads]
//        defaults: 8 4 600 4   (32 live instances, 10 min, 4 audio threads)

#import <Cocoa/Cocoa.h>

#include <libproc.h>
#include <mach/mach.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
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

namespace loopy {
uint32_t parseVersion(const std::string& v) {
  uint32_t parts[3] = {0, 0, 0};
  int field = 0, any = 0;
  uint32_t cur = 0;
  for (char c : v) {
    if (c >= '0' && c <= '9') {
      cur = cur * 10 + uint32_t(c - '0');
      any = 1;
    } else if (c == '.') {
      if (field < 3) parts[field] = cur > 255 ? 255 : cur;
      cur = 0;
      if (++field >= 3) break;
    } else
      break;
  }
  if (field < 3) parts[field] = cur > 255 ? 255 : cur;
  return any ? (parts[0] << 16) | (parts[1] << 8) | parts[2] : 0;
}
}  // namespace loopy

namespace {

constexpr double kSampleRate = 48000.0;
constexpr int kMaxBlock = 512;
using clock_t_ = std::chrono::steady_clock;

struct CollectSink final : loopy::ScanSink {
  std::vector<PluginDescriptor> plugins;
  void add(const PluginDescriptor& d) override {
    if (!d.id.empty()) plugins.push_back(d);
  }
  void candidateDiscovered() override {}
  void candidateScanned() override {}
  bool cancelled() const override { return false; }
};

size_t rssBytes() {
  mach_task_basic_info info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS)
    return 0;
  return info.resident_size;
}
double mb(size_t b) { return double(b) / (1024.0 * 1024.0); }

int openFdCount() {
  const pid_t pid = getpid();
  const int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nullptr, 0);
  if (bytes <= 0) return -1;
  return bytes / int(sizeof(proc_fdinfo));
}

// One live FX chain: K plugin instances processed in series, with its own
// scratch buffers and param tables. Owned by exactly one worker thread.
struct Chain {
  std::vector<IPluginHost*> fx;
  std::vector<std::vector<PluginParamInfo>> params;  // per fx
  std::vector<float> l, r;
  std::mt19937 rng;
  Chain() : l(kMaxBlock), r(kMaxBlock), rng(0x5EED) {}
};

std::atomic<uint64_t> g_blocks{0};  // total process() calls across all instances
std::atomic<bool> g_stop{false};

void processChain(Chain& ch, bool automate) {
  std::uniform_real_distribution<float> noise(-0.5f, 0.5f);
  for (int i = 0; i < kMaxBlock; ++i) {
    ch.l[i] = noise(ch.rng);
    ch.r[i] = noise(ch.rng);
  }
  for (size_t f = 0; f < ch.fx.size(); ++f) {
    if (automate && !ch.params[f].empty()) {
      // A few param moves per block per fx — like live automation.
      for (int k = 0; k < 4; ++k) {
        const PluginParamInfo& p = ch.params[f][ch.rng() % ch.params[f].size()];
        std::uniform_real_distribution<double> val(p.min, p.max);
        ch.fx[f]->queueParam(p.id, val(ch.rng));
      }
    }
    ch.fx[f]->process(ch.l.data(), ch.r.data(), kMaxBlock);
    g_blocks.fetch_add(1, std::memory_order_relaxed);
  }
}

}  // namespace

int main(int argc, char** argv) {
  @autoreleasepool {
    setvbuf(stdout, nullptr, _IOLBF, 0);
    const int channels = argc > 1 ? atoi(argv[1]) : 8;
    const int fxPer = argc > 2 ? atoi(argv[2]) : 4;
    const int durSecs = argc > 3 ? atoi(argv[3]) : 600;
    const int threads = argc > 4 ? atoi(argv[4]) : 4;
    std::printf("== loopy VST3 host SOAK ==\n");
    std::printf("topology: %d channels x %d fx = %d live instances | %d threads | %ds\n",
                channels, fxPer, channels * fxPer, threads, durSecs);

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    CollectSink sink;
    loopy::scanVst3(sink);

    // Filter to plugins that actually load as a stereo/mono effect (drops the
    // multi-bus TDR Nova etc.) so every chain slot is a real live effect.
    std::vector<PluginDescriptor> usable;
    for (const auto& d : sink.plugins) {
      IPluginHost* h = loopy::createVst3Host();
      if (h->load(d, kSampleRate, kMaxBlock) == LoadStatus::ok) usable.push_back(d);
      delete h;
    }
    std::printf("usable effects: %zu / %zu scanned\n", usable.size(),
                sink.plugins.size());
    if (usable.empty()) return 1;

    // Build the session: N chains of K instances, cycling through usable effects.
    std::printf("building session...\n");
    std::vector<Chain> chains(channels);
    int pick = 0, built = 0;
    for (int c = 0; c < channels; ++c) {
      for (int f = 0; f < fxPer; ++f) {
        const PluginDescriptor& d = usable[pick++ % usable.size()];
        IPluginHost* h = loopy::createVst3Host();
        if (h->load(d, kSampleRate, kMaxBlock) != LoadStatus::ok) {
          delete h;
          continue;
        }
        std::vector<PluginParamInfo> ps;
        const int pc = h->paramCount();
        for (int i = 0; i < pc; ++i) {
          PluginParamInfo info;
          if (h->paramInfoAt(i, info)) ps.push_back(info);
        }
        chains[c].fx.push_back(h);
        chains[c].params.push_back(std::move(ps));
        chains[c].rng.seed(0x5EED + c * 131 + f);
        built++;
      }
    }
    // A dedicated instance for the periodic editor open/close (DPF message path),
    // never touched by the audio workers.
    IPluginHost* editorHost = loopy::createVst3Host();
    bool editorOk = editorHost->load(usable[0], kSampleRate, kMaxBlock) == LoadStatus::ok;
    std::printf("built %d live instances + 1 editor instance\n", built);

    const size_t rss0 = rssBytes();
    const int fd0 = openFdCount();
    std::printf("baseline: RSS=%.1f MB  fds=%d\n\n", mb(rss0), fd0);
    std::printf("%8s %8s %10s %12s %8s %10s %8s\n", "wall_s", "RSS_MB",
                "d_RSS_MB", "inst_aud_h", "fds", "Mblocks", "edits");
    std::fflush(stdout);

    // Partition chains across worker threads (disjoint — each instance is touched
    // by exactly one thread, honoring the single-thread-per-host contract).
    std::vector<std::thread> pool;
    std::atomic<int> nextChain{0};
    for (int t = 0; t < threads; ++t) {
      pool.emplace_back([&] {
        // Round-robin claim of channels by index parity of the thread.
        std::vector<int> mine;
        for (int c = 0;; ) {
          c = nextChain.fetch_add(1);
          if (c >= channels) break;
          mine.push_back(c);
        }
        uint64_t local = 0;
        while (!g_stop.load(std::memory_order_relaxed)) {
          for (int c : mine) processChain(chains[c], (local % 64) < 8);
          local++;
        }
      });
    }

    // Main thread: sample metrics on a cadence; periodically exercise the editor.
    const auto start = clock_t_::now();
    int edits = 0;
    int lastEditBucket = -1;
    auto elapsed = [&] {
      return std::chrono::duration<double>(clock_t_::now() - start).count();
    };
    double nextSample = 0.0;
    // Steady baseline captured once warmup is past, so the reported slope
    // reflects sustained behavior, not first-touch DSP/codegen allocation.
    const double warmupSecs = durSecs > 240 ? 60.0 : durSecs / 4.0;
    bool steadySet = false;
    size_t rssSteady = rss0;
    double audHSteady = 0.0;
    while (elapsed() < durSecs) {
      [[NSRunLoop currentRunLoop]
          runMode:NSDefaultRunLoopMode
          beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
      const double e = elapsed();

      // Editor open/close every ~120 s, like a user tweaking a plugin.
      const int bucket = int(e / 120.0);
      if (editorOk && bucket != lastEditBucket) {
        lastEditBucket = bucket;
        if (editorHost->editorOpen()) {
          [[NSRunLoop currentRunLoop]
              runMode:NSDefaultRunLoopMode
              beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
          editorHost->editorClose();
          edits++;
        }
      }

      if (e >= nextSample) {
        nextSample += 15.0;  // sample every 15 s
        const size_t rss = rssBytes();
        const uint64_t blk = g_blocks.load();
        const double instAudH =
            double(blk) * kMaxBlock / kSampleRate / 3600.0;  // instance-audio-hours
        if (!steadySet && e >= warmupSecs) {
          steadySet = true;
          rssSteady = rss;
          audHSteady = instAudH;
        }
        std::printf("%8.0f %8.1f %10.2f %12.3f %8d %10.2f %8d\n", e, mb(rss),
                    mb(rss) - mb(rss0), instAudH, openFdCount(),
                    double(blk) / 1e6, edits);
        std::fflush(stdout);
      }
    }
    g_stop.store(true);
    for (auto& th : pool) th.join();

    const size_t rss1 = rssBytes();
    const int fd1 = openFdCount();
    const uint64_t blk = g_blocks.load();
    const double instAudH = double(blk) * kMaxBlock / kSampleRate / 3600.0;
    const double wallH = elapsed() / 3600.0;
    std::printf("\n== SOAK SUMMARY ==\n");
    std::printf("ran %.1f min wall | %llu blocks | %.2f instance-audio-hours processed\n",
                elapsed() / 60.0, (unsigned long long)blk, instAudH);
    std::printf("editor open/close cycles: %d\n", edits);
    std::printf("RSS: %.1f -> %.1f MB (net %+.1f)\n", mb(rss0), mb(rss1),
                mb(rss1) - mb(rss0));
    std::printf("fds: %d -> %d (net %+d)\n", fd0, fd1, fd1 - fd0);
    std::printf("raw slope (incl warmup): %+.2f MB / instance-audio-hour | %+.1f MB / wall-hour\n",
                instAudH > 0 ? (mb(rss1) - mb(rss0)) / instAudH : 0.0,
                wallH > 0 ? (mb(rss1) - mb(rss0)) / wallH : 0.0);
    // The honest number: growth AFTER warmup, per audio-hour of steady running.
    const double dAudH = instAudH - audHSteady;
    if (steadySet && dAudH > 0) {
      std::printf("STEADY slope (post-%.0fs): %+.3f MB / instance-audio-hour"
                  "  (RSS %.1f->%.1f MB over %.2f inst-aud-h)\n",
                  warmupSecs, (mb(rss1) - mb(rssSteady)) / dAudH, mb(rssSteady),
                  mb(rss1), dAudH);
    }

    // Teardown — every instance released; a clean exit is part of the test.
    for (auto& ch : chains)
      for (auto* h : ch.fx) delete h;
    delete editorHost;
    std::printf("teardown clean. DONE.\n");
    return 0;
  }
}
