// editor_probe.mm — attribute the per-editor-open RSS retention seen in the soak.
//
// For each plugin that exposes an editor: load ONE instance, open/close its
// editor N times on that instance (sampling RSS), then unload and sample RSS
// again. Tells us (1) the per-open slope per plugin and (2) whether unloading
// the instance reclaims the accumulated memory. If only GL/DPF GUIs grow while
// VSTGUI/JUCE ones stay flat, the retention is plugin-side, not our host's.

#import <Cocoa/Cocoa.h>

#include <mach/mach.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "plugin_host.h"

using loopy::IPluginHost;
using loopy::LoadStatus;
using loopy::PluginDescriptor;

namespace loopy {
uint32_t parseVersion(const std::string& v) {
  uint32_t p[3] = {0, 0, 0};
  int f = 0, any = 0;
  uint32_t cur = 0;
  for (char c : v) {
    if (c >= '0' && c <= '9') { cur = cur * 10 + uint32_t(c - '0'); any = 1; }
    else if (c == '.') { if (f < 3) p[f] = cur > 255 ? 255 : cur; cur = 0; if (++f >= 3) break; }
    else break;
  }
  if (f < 3) p[f] = cur > 255 ? 255 : cur;
  return any ? (p[0] << 16) | (p[1] << 8) | p[2] : 0;
}
}  // namespace loopy

namespace {
constexpr double kSR = 48000.0;
constexpr int kBlock = 512;
struct Sink final : loopy::ScanSink {
  std::vector<PluginDescriptor> plugins;
  void add(const PluginDescriptor& d) override { if (!d.id.empty()) plugins.push_back(d); }
  void candidateDiscovered() override {}
  void candidateScanned() override {}
  bool cancelled() const override { return false; }
};
double mb(size_t b) { return double(b) / 1048576.0; }
size_t rss() {
  mach_task_basic_info i;
  mach_msg_type_number_t c = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&i, &c) != KERN_SUCCESS) return 0;
  return i.resident_size;
}
void pump(double ms) {
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                           beforeDate:[NSDate dateWithTimeIntervalSinceNow:ms / 1000.0]];
}
}  // namespace

int main() {
  @autoreleasepool {
    setvbuf(stdout, nullptr, _IOLBF, 0);
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    Sink sink;
    loopy::scanVst3(sink);

    const int N = 40;  // opens per plugin
    std::printf("%-26s %8s %8s %9s %10s %10s\n", "plugin", "rss0", "rss_open1",
                "rss_openN", "per_open", "after_unload");
    for (const auto& d : sink.plugins) {
      IPluginHost* h = loopy::createVst3Host();
      if (h->load(d, kSR, kBlock) != LoadStatus::ok) { delete h; continue; }
      // Does it even have an editor?
      if (!h->editorOpen()) { delete h; continue; }
      h->editorClose();

      const size_t r0 = rss();
      size_t r1 = 0;
      for (int k = 0; k < N; ++k) {
        h->editorOpen();
        pump(15);
        h->editorClose();
        pump(3);
        if (k == 0) r1 = rss();
      }
      const size_t rN = rss();
      delete h;          // unload the instance entirely
      pump(30);
      const size_t rU = rss();
      const double perOpen = (mb(rN) - mb(r1)) / (N - 1);
      std::printf("%-26s %8.1f %8.1f %9.1f %10.3f %10.1f\n", d.name.c_str(),
                  mb(r0), mb(r1), mb(rN), perOpen, mb(rU));
    }
    std::printf("\nper_open = MB retained per open (opens 2..N); after_unload = RSS once the instance is freed.\n");
    return 0;
  }
}
