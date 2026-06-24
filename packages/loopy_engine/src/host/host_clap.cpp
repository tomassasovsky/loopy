// CLAP host backend — loads + drives one CLAP plugin as an IPluginHost.
//
// Part 3 hosts at the plugin's DEFAULT state: no parameters, no events. The
// adapter (slot.cpp) calls process() with a fixed block on the audio thread;
// everything else runs on the control thread.

#if defined(LOOPY_ENABLE_PLUGINS) && defined(__APPLE__)

#include <CoreFoundation/CoreFoundation.h>

#include <cstring>
#include <string>
#include <vector>

#include <clap/clap.h>

#include "native_window_controller.h"
#include "plugin_host.h"

namespace {

// The CLAP gui host extension (defined after ClapHost, which its callbacks
// dispatch to). Advertised from hostGetExtension so a plugin can request an
// editor resize.
extern const clap_host_gui_t kHostGui;

// Host vtable: we advertise the gui extension (for plugin-requested resizes);
// everything else is unsupported in this slice.
const void* CLAP_ABI hostGetExtension(const clap_host*, const char* id) {
  if (id && std::strcmp(id, CLAP_EXT_GUI) == 0) return &kHostGui;
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

// State streams (D-P1): the output stream appends to a vector; the input stream
// reads from a fixed blob.
int64_t CLAP_ABI clapOStreamWrite(const clap_ostream_t* s, const void* buffer,
                                  uint64_t size) {
  auto* out = static_cast<std::vector<uint8_t>*>(s->ctx);
  const auto* b = static_cast<const uint8_t*>(buffer);
  out->insert(out->end(), b, b + size);
  return static_cast<int64_t>(size);
}
struct ClapReadCtx {
  const uint8_t* data;
  uint64_t size;
  uint64_t pos;
};
int64_t CLAP_ABI clapIStreamRead(const clap_istream_t* s, void* buffer,
                                 uint64_t size) {
  auto* ctx = static_cast<ClapReadCtx*>(s->ctx);
  const uint64_t avail = ctx->size - ctx->pos;
  const uint64_t n = size < avail ? size : avail;
  if (n) std::memcpy(buffer, ctx->data + ctx->pos, n);
  ctx->pos += n;
  return static_cast<int64_t>(n);
}

class ClapHost final : public loopy::IPluginHost {
 public:
  ~ClapHost() override { unload(); }

  loopy::LoadStatus load(const loopy::PluginDescriptor& desc, double sampleRate,
                         int maxBlock) override {
    using loopy::LoadStatus;
    name_ = desc.name;  // for the editor window title
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
    gui_ = static_cast<const clap_plugin_gui_t*>(
        plugin_->get_extension(plugin_, CLAP_EXT_GUI));

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

  bool paramValueText(uint32_t id, double value, std::string& out) override {
    if (!params_ || !params_->value_to_text) return false;
    char buf[128] = {};
    // CLAP values are already plain — pass through directly.
    if (!params_->value_to_text(plugin_, id, value, buf, sizeof(buf))) {
      return false;
    }
    out = buf;
    return true;
  }

  // --- Native editor (main thread; D-WIN) ---

  bool editorOpen() override {
    if (editorOpen_) return true;  // idempotent
    if (!gui_ || !plugin_) return false;
    if (!gui_->is_api_supported(plugin_, CLAP_WINDOW_API_COCOA, false)) {
      return false;
    }
    if (!gui_->create(plugin_, CLAP_WINDOW_API_COCOA, false)) return false;
    uint32_t w = 400;
    uint32_t h = 300;
    if (gui_->get_size) gui_->get_size(plugin_, &w, &h);
    window_ = lpw_window_open(static_cast<int>(w), static_cast<int>(h),
                              name_.empty() ? "Plugin Editor" : name_.c_str(),
                              &ClapHost::onWindowClosedThunk, this);
    if (!window_) {
      gui_->destroy(plugin_);
      return false;
    }
    clap_window_t cw{};
    cw.api = CLAP_WINDOW_API_COCOA;
    cw.cocoa = lpw_window_content_view(window_);
    if (!gui_->set_parent(plugin_, &cw)) {
      gui_->destroy(plugin_);
      lpw_window_close(window_);
      window_ = nullptr;
      return false;
    }
    if (gui_->show) gui_->show(plugin_);
    editorOpen_ = true;
    return true;
  }

  void editorClose() override {
    destroyGui();
    if (window_) {
      lpw_window_close(window_);  // host-driven; delegate callback suppressed
      window_ = nullptr;
    }
  }

  bool editorIsOpen() const override { return editorOpen_; }

  // --- Opaque state (main thread; D-P1) ---

  bool stateGet(std::vector<uint8_t>& out) override {
    if (!plugin_) return false;
    auto* state = static_cast<const clap_plugin_state_t*>(
        plugin_->get_extension(plugin_, CLAP_EXT_STATE));
    if (!state || !state->save) return false;
    clap_ostream_t os{};
    os.ctx = &out;
    os.write = clapOStreamWrite;
    return state->save(plugin_, &os);
  }

  bool stateSet(const uint8_t* data, int size) override {
    if (!plugin_ || !data || size <= 0) return false;
    auto* state = static_cast<const clap_plugin_state_t*>(
        plugin_->get_extension(plugin_, CLAP_EXT_STATE));
    if (!state || !state->load) return false;
    ClapReadCtx ctx{data, static_cast<uint64_t>(size), 0};
    clap_istream_t is{};
    is.ctx = &ctx;
    is.read = clapIStreamRead;
    return state->load(plugin_, &is);
  }

  // Resizes the host window to a plugin-requested content size (clap_host_gui
  // request_resize). Returns true — we always honour the request.
  bool onPluginResize(uint32_t w, uint32_t h) {
    if (!window_) return false;
    lpw_window_resize(window_, static_cast<int>(w), static_cast<int>(h));
    return true;
  }

  // Fired from windowWillClose when the USER closes the window: tear down the
  // plugin GUI; the window handle frees itself (deferred) in the shim.
  static void onWindowClosedThunk(void* ctx) {
    static_cast<ClapHost*>(ctx)->onWindowClosed();
  }
  void onWindowClosed() {
    destroyGui();
    window_ = nullptr;  // the shim owns the deferred free
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
  // Tears down the plugin GUI (idempotent). Shared by editorClose (host-driven)
  // and the user-close callback.
  void destroyGui() {
    if (editorOpen_ && gui_ && plugin_) {
      if (gui_->hide) gui_->hide(plugin_);
      gui_->destroy(plugin_);
    }
    editorOpen_ = false;
  }

  void unload() {
    editorClose();  // D-WIN: never leak the editor window past the plugin
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
  const clap_plugin_gui_t* gui_ = nullptr;
  ClapEventBuffer events_;  // queued param-value events for the next process()
  std::vector<float> outL_, outR_;
  int64_t steady_ = 0;
  int channels_ = 2;  // negotiated channel count (1 = mono-adapted, 2 = stereo)
  bool editorOpen_ = false;
  std::string name_;  // plugin display name, for the editor window title
  lpw_window* window_ = nullptr;
};

// CLAP gui host extension — dispatches to the owning ClapHost via host_data.
void CLAP_ABI hostGuiResizeHintsChanged(const clap_host_t*) {}
bool CLAP_ABI hostGuiRequestResize(const clap_host_t* host, uint32_t w,
                                   uint32_t h) {
  auto* self = static_cast<ClapHost*>(host->host_data);
  return self && self->onPluginResize(w, h);
}
bool CLAP_ABI hostGuiRequestShow(const clap_host_t*) { return false; }
bool CLAP_ABI hostGuiRequestHide(const clap_host_t*) { return false; }
void CLAP_ABI hostGuiClosed(const clap_host_t* host, bool was_destroyed) {
  (void)was_destroyed;
  auto* self = static_cast<ClapHost*>(host->host_data);
  // The plugin (not the user) closed the editor, so there is no NSWindow
  // windowWillClose to drive the shim's deferred free. Use the host-driven
  // editorClose(), which tears down the GUI AND closes+frees the window handle.
  // Calling the bare onWindowClosed() here would null window_ without ever
  // closing it — leaking the NSWindow + handle and orphaning a visible window.
  if (self) self->editorClose();
}

const clap_host_gui_t kHostGui = {
    hostGuiResizeHintsChanged, hostGuiRequestResize, hostGuiRequestShow,
    hostGuiRequestHide,        hostGuiClosed,
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
