// CLAP host backend — loads + drives one CLAP plugin as an IPluginHost.
//
// Part 3 hosts at the plugin's DEFAULT state: no parameters, no events. The
// adapter (slot.cpp) calls process() with a fixed block on the audio thread;
// everything else runs on the control thread.

#if defined(LOOPY_ENABLE_PLUGINS) && defined(__APPLE__)

#include <CoreFoundation/CoreFoundation.h>

#include <cstring>
#include <vector>

#include <clap/clap.h>

#include "plugin_host.h"

namespace {

// Minimal host vtable — we advertise no host extensions in this slice.
const void* CLAP_ABI hostGetExtension(const clap_host*, const char*) {
  return nullptr;
}
void CLAP_ABI hostNoop(const clap_host*) {}

// Empty event lists: the plugin sees no input events and we drop its output.
uint32_t CLAP_ABI inEventsSize(const clap_input_events*) { return 0; }
const clap_event_header_t* CLAP_ABI inEventsGet(const clap_input_events*,
                                                uint32_t) {
  return nullptr;
}
bool CLAP_ABI outEventsTryPush(const clap_output_events*,
                               const clap_event_header_t*) {
  return true;
}

class ClapHost final : public loopy::IPluginHost {
 public:
  ~ClapHost() override { unload(); }

  bool load(const loopy::PluginDescriptor& desc, double sampleRate,
            int maxBlock) override {
    CFStringRef cfPath = CFStringCreateWithCString(
        kCFAllocatorDefault, desc.path.c_str(), kCFStringEncodingUTF8);
    if (!cfPath) return false;
    CFURLRef url = CFURLCreateWithFileSystemPath(
        kCFAllocatorDefault, cfPath, kCFURLPOSIXPathStyle, true);
    CFRelease(cfPath);
    if (!url) return false;
    bundle_ = CFBundleCreate(kCFAllocatorDefault, url);
    CFRelease(url);
    if (!bundle_) return false;

    entry_ = reinterpret_cast<const clap_plugin_entry_t*>(
        CFBundleGetDataPointerForName(bundle_, CFSTR("clap_entry")));
    if (!entry_ || !entry_->init || !entry_->init(desc.path.c_str())) {
      return false;
    }
    auto factory = reinterpret_cast<const clap_plugin_factory_t*>(
        entry_->get_factory(CLAP_PLUGIN_FACTORY_ID));
    if (!factory || !factory->create_plugin) return false;

    host_.clap_version = CLAP_VERSION;
    host_.host_data = this;
    host_.name = "Loopy";
    host_.vendor = "Loopy";
    host_.url = "";
    host_.version = "0.1.0";
    host_.get_extension = hostGetExtension;
    host_.request_restart = hostNoop;
    host_.request_process = hostNoop;
    host_.request_callback = hostNoop;

    plugin_ = factory->create_plugin(factory, &host_, desc.id.c_str());
    if (!plugin_ || !plugin_->init(plugin_)) return false;
    if (!plugin_->activate(plugin_, sampleRate, 1,
                           static_cast<uint32_t>(maxBlock))) {
      return false;
    }
    if (!plugin_->start_processing(plugin_)) return false;

    outL_.assign(maxBlock, 0.0f);
    outR_.assign(maxBlock, 0.0f);
    inEvents_.ctx = nullptr;
    inEvents_.size = inEventsSize;
    inEvents_.get = inEventsGet;
    outEvents_.ctx = nullptr;
    outEvents_.try_push = outEventsTryPush;
    return true;
  }

  void process(float* l, float* r, int n) override {
    if (!plugin_) return;
    float* inCh[2] = {l, r};
    float* outCh[2] = {outL_.data(), outR_.data()};

    clap_audio_buffer_t in{};
    in.data32 = inCh;
    in.channel_count = 2;
    clap_audio_buffer_t out{};
    out.data32 = outCh;
    out.channel_count = 2;

    clap_process_t proc{};
    proc.steady_time = steady_;
    proc.frames_count = static_cast<uint32_t>(n);
    proc.audio_inputs = &in;
    proc.audio_outputs = &out;
    proc.audio_inputs_count = 1;
    proc.audio_outputs_count = 1;
    proc.in_events = &inEvents_;
    proc.out_events = &outEvents_;
    plugin_->process(plugin_, &proc);
    steady_ += n;

    std::memcpy(l, outL_.data(), sizeof(float) * static_cast<size_t>(n));
    std::memcpy(r, outR_.data(), sizeof(float) * static_cast<size_t>(n));
  }

 private:
  void unload() {
    if (plugin_) {
      plugin_->stop_processing(plugin_);
      plugin_->deactivate(plugin_);
      plugin_->destroy(plugin_);
      plugin_ = nullptr;
    }
    if (entry_ && entry_->deinit) entry_->deinit();
    entry_ = nullptr;
    if (bundle_) {
      CFRelease(bundle_);
      bundle_ = nullptr;
    }
  }

  CFBundleRef bundle_ = nullptr;
  const clap_plugin_entry_t* entry_ = nullptr;
  const clap_plugin_t* plugin_ = nullptr;
  clap_host_t host_{};
  clap_input_events_t inEvents_{};
  clap_output_events_t outEvents_{};
  std::vector<float> outL_, outR_;
  int64_t steady_ = 0;
};

}  // namespace

namespace loopy {
IPluginHost* createClapHost() { return new ClapHost(); }
}  // namespace loopy

#elif defined(LOOPY_ENABLE_PLUGINS)

#include "plugin_host.h"
namespace loopy {
IPluginHost* createClapHost() { return nullptr; }  // ports: parts 8–9
}  // namespace loopy

#endif
