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

// Fixed-size buffer of queued param-value events the input-events list serves to
// the plugin during process(). Audio-thread-owned; no allocation.
struct ClapEventBuffer {
  static constexpr uint32_t kMax = 64;
  clap_event_param_value_t events[kMax];
  uint32_t count = 0;
};

// Input events: serve the queued param-value events (ctx points at the buffer).
uint32_t CLAP_ABI inEventsSize(const clap_input_events* list) {
  return static_cast<const ClapEventBuffer*>(list->ctx)->count;
}
const clap_event_header_t* CLAP_ABI inEventsGet(const clap_input_events* list,
                                                uint32_t index) {
  const auto* buf = static_cast<const ClapEventBuffer*>(list->ctx);
  return index < buf->count ? &buf->events[index].header : nullptr;
}
bool CLAP_ABI outEventsTryPush(const clap_output_events*,
                               const clap_event_header_t*) {
  return true;  // we drop the plugin's output events in this slice
}

class ClapHost final : public loopy::IPluginHost {
 public:
  ~ClapHost() override { unload(); }

  loopy::LoadStatus load(const loopy::PluginDescriptor& desc, double sampleRate,
                         int maxBlock) override {
    using loopy::LoadStatus;
    CFStringRef cfPath = CFStringCreateWithCString(
        kCFAllocatorDefault, desc.path.c_str(), kCFStringEncodingUTF8);
    if (!cfPath) return LoadStatus::failed;
    CFURLRef url = CFURLCreateWithFileSystemPath(
        kCFAllocatorDefault, cfPath, kCFURLPOSIXPathStyle, true);
    CFRelease(cfPath);
    if (!url) return LoadStatus::failed;
    bundle_ = CFBundleCreate(kCFAllocatorDefault, url);
    CFRelease(url);
    if (!bundle_) return LoadStatus::failed;

    entry_ = reinterpret_cast<const clap_plugin_entry_t*>(
        CFBundleGetDataPointerForName(bundle_, CFSTR("clap_entry")));
    if (!entry_ || !entry_->init || !entry_->init(desc.path.c_str())) {
      return LoadStatus::failed;
    }
    auto factory = reinterpret_cast<const clap_plugin_factory_t*>(
        entry_->get_factory(CLAP_PLUGIN_FACTORY_ID));
    if (!factory || !factory->create_plugin) return LoadStatus::failed;

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
    if (!plugin_ || !plugin_->init(plugin_)) return LoadStatus::failed;

    // Topology guard (D-BUS): accept only a single mono/stereo audio-in +
    // audio-out port. No input port is an instrument; >1 port is multi-bus /
    // sidechain. A plugin without the audio-ports extension is assumed stereo.
    auto ports = static_cast<const clap_plugin_audio_ports_t*>(
        plugin_->get_extension(plugin_, CLAP_EXT_AUDIO_PORTS));
    if (ports && ports->count) {
      const uint32_t inPorts = ports->count(plugin_, true);
      const uint32_t outPorts = ports->count(plugin_, false);
      if (inPorts < 1 || outPorts < 1) return LoadStatus::unsupportedTopology;
      if (inPorts > 1 || outPorts > 1) return LoadStatus::unsupportedTopology;
      uint32_t chIn = 2;
      uint32_t chOut = 2;
      clap_audio_port_info_t info;
      if (ports->get && ports->get(plugin_, 0, true, &info)) {
        chIn = info.channel_count;
      }
      if (ports->get && ports->get(plugin_, 0, false, &info)) {
        chOut = info.channel_count;
      }
      if (chIn < 1 || chOut < 1 || chIn > 2 || chOut > 2) {
        return LoadStatus::unsupportedTopology;
      }
      channels_ = (chIn >= 2 && chOut >= 2) ? 2 : 1;
    }

    params_ = static_cast<const clap_plugin_params_t*>(
        plugin_->get_extension(plugin_, CLAP_EXT_PARAMS));

    if (!plugin_->activate(plugin_, sampleRate, 1,
                           static_cast<uint32_t>(maxBlock))) {
      return LoadStatus::failed;
    }
    if (!plugin_->start_processing(plugin_)) return LoadStatus::failed;

    outL_.assign(maxBlock, 0.0f);
    outR_.assign(maxBlock, 0.0f);
    inEvents_.ctx = &events_;  // serves the queued param events
    inEvents_.size = inEventsSize;
    inEvents_.get = inEventsGet;
    outEvents_.ctx = nullptr;
    outEvents_.try_push = outEventsTryPush;
    return LoadStatus::ok;
  }

  void process(float* l, float* r, int n) override {
    if (!plugin_) return;
    float* inCh[2] = {l, r};
    float* outCh[2] = {outL_.data(), outR_.data()};

    clap_audio_buffer_t in{};
    in.data32 = inCh;
    in.channel_count = static_cast<uint32_t>(channels_);
    clap_audio_buffer_t out{};
    out.data32 = outCh;
    out.channel_count = static_cast<uint32_t>(channels_);

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
    events_.count = 0;  // param events consumed by this block

    const size_t bytes = sizeof(float) * static_cast<size_t>(n);
    std::memcpy(l, outL_.data(), bytes);
    // Mono -> stereo: duplicate the single processed channel to the right.
    std::memcpy(r, channels_ == 1 ? outL_.data() : outR_.data(), bytes);
  }

  int paramCount() override {
    return params_ ? static_cast<int>(params_->count(plugin_)) : 0;
  }

  bool paramInfoAt(int index, loopy::PluginParamInfo& out) override {
    if (!params_ || index < 0 ||
        index >= static_cast<int>(params_->count(plugin_))) {
      return false;
    }
    clap_param_info_t info;
    if (!params_->get_info(plugin_, static_cast<uint32_t>(index), &info)) {
      return false;
    }
    out = loopy::PluginParamInfo{};
    out.id = info.id;
    out.name = info.name;
    out.min = info.min_value;
    out.max = info.max_value;
    out.def = info.default_value;  // CLAP values are already plain
    uint32_t flags = 0;
    if (info.flags & CLAP_PARAM_IS_AUTOMATABLE) flags |= loopy::kParamAutomatable;
    if (info.flags & CLAP_PARAM_IS_READONLY) flags |= loopy::kParamReadOnly;
    if (info.flags & CLAP_PARAM_IS_BYPASS) flags |= loopy::kParamBypass;
    if (info.flags & CLAP_PARAM_IS_HIDDEN) flags |= loopy::kParamHidden;
    if (info.flags & CLAP_PARAM_IS_STEPPED) {
      flags |= loopy::kParamStepped;
      out.stepCount = static_cast<int32_t>(info.max_value - info.min_value);
    }
    out.flags = flags;
    return true;
  }

  double paramGet(uint32_t id) override {
    double value = 0.0;
    if (params_ && params_->get_value) params_->get_value(plugin_, id, &value);
    return value;
  }

  void queueParam(uint32_t id, double plain) override {
    if (events_.count >= ClapEventBuffer::kMax) return;
    clap_event_param_value_t& e = events_.events[events_.count++];
    e = clap_event_param_value_t{};
    e.header.size = sizeof(e);
    e.header.space_id = CLAP_CORE_EVENT_SPACE_ID;
    e.header.type = CLAP_EVENT_PARAM_VALUE;
    e.param_id = id;
    e.note_id = -1;
    e.port_index = -1;
    e.channel = -1;
    e.key = -1;
    e.value = plain;
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
  const clap_plugin_params_t* params_ = nullptr;
  ClapEventBuffer events_;  // queued param-value events for the next process()
  std::vector<float> outL_, outR_;
  int64_t steady_ = 0;
  int channels_ = 2;  // negotiated channel count (1 = mono-adapted, 2 = stereo)
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
