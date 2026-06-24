// VST3 host backend — loads + drives one VST3 plugin as an IPluginHost.
//
// Hand-rolled against pluginterfaces only (the IComponent / IAudioProcessor
// lifecycle); no base/public.sdk hosting layer is linked — only the vendored
// class IIDs (coreiids.cpp). Part 3 hosts at the plugin's DEFAULT state: stereo
// in/out, no parameter changes, no events. The adapter (slot.cpp) calls
// process() with a fixed block on the audio thread; load/teardown are control
// thread. A richer host context (IHostApplication) is a follow-up — some
// plugins refuse a null context; those simply fail to load here.

#if defined(LOOPY_ENABLE_PLUGINS) && defined(__APPLE__)

#include <CoreFoundation/CoreFoundation.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivsthostapplication.h"
#include "pluginterfaces/vst/ivstmessage.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/vstspeaker.h"
#include "native_window_controller.h"
#include "plugin_host.h"

// stderr tracing for diagnosing real-plugin load/editor failures. On in debug
// builds (where the manual plugin testing happens), silent in release. Force
// either way with -DLOOPY_VST3_TRACE=0/1.
#ifndef LOOPY_VST3_TRACE
#ifdef NDEBUG
#define LOOPY_VST3_TRACE 0
#else
#define LOOPY_VST3_TRACE 1
#endif
#endif
#if LOOPY_VST3_TRACE
#define LPV_LOG(...) std::fprintf(stderr, "[loopy vst3] " __VA_ARGS__)
#else
#define LPV_LOG(...) ((void)0)
#endif

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

typedef bool (*BundleEntryFunc)(CFBundleRef);
typedef bool (*BundleExitFunc)();
typedef IPluginFactory* (*GetFactoryFunc)();

bool iidEq(const TUID a, const TUID& b) { return std::memcmp(a, b, 16) == 0; }

// Converts a VST3 String128 (UTF-16) to a UTF-8 std::string (BMP).
std::string u16ToUtf8(const char16* s) {
  std::string out;
  for (int i = 0; i < 128 && s[i]; ++i) {
    const char16_t c = static_cast<char16_t>(s[i]);
    if (c < 0x80) {
      out.push_back(static_cast<char>(c));
    } else if (c < 0x800) {
      out.push_back(static_cast<char>(0xC0 | (c >> 6)));
      out.push_back(static_cast<char>(0x80 | (c & 0x3F)));
    } else {
      out.push_back(static_cast<char>(0xE0 | (c >> 12)));
      out.push_back(static_cast<char>(0x80 | ((c >> 6) & 0x3F)));
      out.push_back(static_cast<char>(0x80 | (c & 0x3F)));
    }
  }
  return out;
}

// A minimal host-side IParamValueQueue holding a single point — enough to feed
// one queued plain->normalized param change per id into a process() block.
class HostParamQueue : public IParamValueQueue {
 public:
  void reset(ParamID id) {
    id_ = id;
    value_ = 0.0;
    has_ = false;
  }
  ParamID PLUGIN_API getParameterId() override { return id_; }
  int32 PLUGIN_API getPointCount() override { return has_ ? 1 : 0; }
  tresult PLUGIN_API getPoint(int32 index, int32& sampleOffset,
                              ParamValue& value) override {
    if (index != 0 || !has_) return kResultFalse;
    sampleOffset = 0;
    value = value_;
    return kResultOk;
  }
  tresult PLUGIN_API addPoint(int32, ParamValue value, int32& index) override {
    value_ = value;
    has_ = true;
    index = 0;
    return kResultOk;
  }
  tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
    if (iidEq(iid, IParamValueQueue::iid) || iidEq(iid, FUnknown::iid)) {
      *obj = this;
      return kResultOk;
    }
    *obj = nullptr;
    return kNoInterface;
  }
  uint32 PLUGIN_API addRef() override { return 1; }   // stack-owned
  uint32 PLUGIN_API release() override { return 1; }  // stack-owned

 private:
  ParamID id_ = 0;
  ParamValue value_ = 0.0;
  bool has_ = false;
};

// A fixed-capacity host IParameterChanges (no allocation in process()).
class HostParamChanges : public IParameterChanges {
 public:
  void clear() { count_ = 0; }
  int32 PLUGIN_API getParameterCount() override { return count_; }
  IParamValueQueue* PLUGIN_API getParameterData(int32 index) override {
    return (index >= 0 && index < count_) ? &queues_[index] : nullptr;
  }
  IParamValueQueue* PLUGIN_API addParameterData(const ParamID& id,
                                                int32& index) override {
    for (int32 i = 0; i < count_; ++i) {
      if (queues_[i].getParameterId() == id) {
        index = i;
        return &queues_[i];
      }
    }
    if (count_ >= kMax) {
      index = -1;
      return nullptr;
    }
    index = count_;
    queues_[count_].reset(id);
    return &queues_[count_++];
  }
  tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
    if (iidEq(iid, IParameterChanges::iid) || iidEq(iid, FUnknown::iid)) {
      *obj = this;
      return kResultOk;
    }
    *obj = nullptr;
    return kNoInterface;
  }
  uint32 PLUGIN_API addRef() override { return 1; }
  uint32 PLUGIN_API release() override { return 1; }

 private:
  static constexpr int32 kMax = 64;
  HostParamQueue queues_[kMax];
  int32 count_ = 0;
};

// Host-side IPlugFrame: the plugin calls resizeView when it wants its editor a
// different size (e.g. a "show advanced" toggle). We resize the host NSWindow to
// the requested content size, then ack via onSize so the plugin lays out. Stack-
// owned (addRef/release == 1), like the param-queue helpers above.
class HostPlugFrame : public IPlugFrame {
 public:
  lpw_window* window = nullptr;
  tresult PLUGIN_API resizeView(IPlugView* view, ViewRect* newSize) override {
    if (window && newSize) {
      lpw_window_resize(window, newSize->getWidth(), newSize->getHeight());
      if (view) view->onSize(newSize);
    }
    return kResultOk;
  }
  tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
    if (iidEq(iid, IPlugFrame::iid) || iidEq(iid, FUnknown::iid)) {
      *obj = this;
      return kResultOk;
    }
    *obj = nullptr;
    return kNoInterface;
  }
  uint32 PLUGIN_API addRef() override { return 1; }
  uint32 PLUGIN_API release() override { return 1; }
};

bool hexNibble(char c, int& v) {
  if (c >= '0' && c <= '9') {
    v = c - '0';
    return true;
  }
  if (c >= 'A' && c <= 'F') {
    v = c - 'A' + 10;
    return true;
  }
  if (c >= 'a' && c <= 'f') {
    v = c - 'a' + 10;
    return true;
  }
  return false;
}

// Parses a 32-hex-char id (as emitted by the VST3 scan) back into a 16-byte
// TUID class id.
bool parseTuid(const std::string& hex, TUID out) {
  if (hex.size() != 32) return false;
  for (int i = 0; i < 16; ++i) {
    int hi = 0;
    int lo = 0;
    if (!hexNibble(hex[2 * i], hi) || !hexNibble(hex[2 * i + 1], lo)) {
      return false;
    }
    out[i] = static_cast<int8>((hi << 4) | lo);
  }
  return true;
}

// Minimal host context. Real commercial plugins refuse a NULL context in
// initialize(); most only need a non-null IHostApplication to exist. We do not
// implement IMessage marshalling (createInstance fails) — a follow-up if a
// plugin needs component<->controller messaging. Stack-owned.
class HostApplication : public IHostApplication {
 public:
  tresult PLUGIN_API getName(String128 name) override {
    static const char16 kName[] = u"Loopy";
    std::memcpy(name, kName, sizeof(kName));
    return kResultOk;
  }
  tresult PLUGIN_API createInstance(TUID, TUID, void** obj) override {
    if (obj) *obj = nullptr;
    return kResultFalse;
  }
  tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
    if (iidEq(iid, IHostApplication::iid) || iidEq(iid, FUnknown::iid)) {
      *obj = this;
      return kResultOk;
    }
    *obj = nullptr;
    return kNoInterface;
  }
  uint32 PLUGIN_API addRef() override { return 1; }
  uint32 PLUGIN_API release() override { return 1; }
};

// No-op component handler — the controller/editor needs one set, and the editor
// calls beginEdit/performEdit/endEdit as the user moves a control. We mirror
// those via the low-rate editor poll instead (D-SYNC), so these stay no-ops.
// Stack-owned.
class ComponentHandler : public IComponentHandler {
 public:
  tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
  tresult PLUGIN_API performEdit(ParamID, ParamValue) override {
    return kResultOk;
  }
  tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
  tresult PLUGIN_API restartComponent(int32) override { return kResultOk; }
  tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
    if (iidEq(iid, IComponentHandler::iid) || iidEq(iid, FUnknown::iid)) {
      *obj = this;
      return kResultOk;
    }
    *obj = nullptr;
    return kNoInterface;
  }
  uint32 PLUGIN_API addRef() override { return 1; }
  uint32 PLUGIN_API release() override { return 1; }
};

class Vst3Host final : public loopy::IPluginHost {
 public:
  ~Vst3Host() override { unload(); }

  loopy::LoadStatus load(const loopy::PluginDescriptor& desc, double sampleRate,
                         int maxBlock) override {
    using loopy::LoadStatus;
    name_ = desc.name;  // for the editor window title
    LPV_LOG("load '%s' (id %s)\n", desc.path.c_str(), desc.id.c_str());
    if (!openBundle(desc.path)) {
      LPV_LOG("  openBundle failed\n");
      return LoadStatus::failed;
    }

    IPluginFactory* factory = getFactory_();
    if (!factory) return LoadStatus::failed;
    factory_ = factory;

    TUID cid;
    if (!parseTuid(desc.id, cid)) return LoadStatus::failed;

    void* obj = nullptr;
    // createInstance takes FIDString (const char*); a TUID is signed char[16],
    // so reinterpret both the class id and IComponent's iid.
    if (factory_->createInstance(
            reinterpret_cast<FIDString>(cid),
            reinterpret_cast<FIDString>(
                static_cast<const TUID&>(IComponent::iid)),
            &obj) != kResultOk ||
        !obj) {
      LPV_LOG("  createInstance(IComponent) failed\n");
      return LoadStatus::failed;
    }
    component_ = static_cast<IComponent*>(obj);

    // Pass a real host context — commercial plugins reject a null context.
    if (component_->initialize(&hostApp_) != kResultOk) {
      LPV_LOG("  component initialize failed\n");
      return LoadStatus::failed;
    }
    if (component_->queryInterface(IAudioProcessor::iid,
                                   reinterpret_cast<void**>(&processor_)) !=
            kResultOk ||
        !processor_) {
      return LoadStatus::failed;
    }
    if (processor_->canProcessSampleSize(kSample32) != kResultOk) {
      return LoadStatus::failed;
    }

    // Topology guard (D-BUS): accept only a single main audio-in + audio-out
    // bus. Zero audio inputs is an instrument; more than one audio bus is a
    // multi-bus / sidechain plugin — both rejected so no partial slot exists.
    const int32_t numIn = component_->getBusCount(kAudio, kInput);
    const int32_t numOut = component_->getBusCount(kAudio, kOutput);
    if (numIn < 1 || numOut < 1 || numIn > 1 || numOut > 1) {
      LPV_LOG("  unsupported topology: %d audio-in bus(es), %d audio-out\n",
              numIn, numOut);
      return LoadStatus::unsupportedTopology;
    }

    // Request stereo-in/stereo-out; a mono-only effect is adapted (L duplicated
    // to R) in process(). The negotiated arrangement decides the channel count.
    SpeakerArrangement stereo = SpeakerArr::kStereo;
    processor_->setBusArrangements(&stereo, 1, &stereo, 1);
    SpeakerArrangement inArr = SpeakerArr::kStereo;
    SpeakerArrangement outArr = SpeakerArr::kStereo;
    processor_->getBusArrangement(kInput, 0, inArr);
    processor_->getBusArrangement(kOutput, 0, outArr);
    const int32 chIn = SpeakerArr::getChannelCount(inArr);
    const int32 chOut = SpeakerArr::getChannelCount(outArr);
    if (chIn < 1 || chOut < 1 || chIn > 2 || chOut > 2) {
      return LoadStatus::unsupportedTopology;  // not a mono/stereo effect
    }
    channels_ = (chIn >= 2 && chOut >= 2) ? 2 : 1;

    ProcessSetup setup;
    setup.processMode = kRealtime;
    setup.symbolicSampleSize = kSample32;
    setup.maxSamplesPerBlock = maxBlock;
    setup.sampleRate = sampleRate;
    if (processor_->setupProcessing(setup) != kResultOk) {
      return LoadStatus::failed;
    }

    component_->activateBus(kAudio, kInput, 0, true);
    component_->activateBus(kAudio, kOutput, 0, true);
    if (component_->setActive(true) != kResultOk) return LoadStatus::failed;
    processor_->setProcessing(true);  // some plugins return notImplemented

    // Edit controller for parameter metadata + the editor view: the component
    // IS the controller for a single-component effect, otherwise a separate
    // class instantiated from getControllerClassId. Null is tolerated (the
    // plugin simply exposes no in-app params / editor).
    bool separateController = false;
    if (component_->queryInterface(IEditController::iid,
                                   reinterpret_cast<void**>(&controller_)) !=
        kResultOk) {
      controller_ = nullptr;
      TUID ctrlCid;
      void* cobj = nullptr;
      if (component_->getControllerClassId(ctrlCid) == kResultOk &&
          factory_->createInstance(
              reinterpret_cast<FIDString>(ctrlCid),
              reinterpret_cast<FIDString>(
                  static_cast<const TUID&>(IEditController::iid)),
              &cobj) == kResultOk) {
        controller_ = static_cast<IEditController*>(cobj);
        separateController = true;
      }
    }
    if (controller_) {
      // A separate controller must be initialized with the host context and
      // synced to the component's current state, then connected so the two
      // halves talk; the editor needs a component handler set to function.
      if (separateController) {
        controller_->initialize(&hostApp_);
      }
      controller_->setComponentHandler(&componentHandler_);
      connectComponentAndController();
    }
    LPV_LOG("  loaded ok: controller=%p params=%d channels=%d\n",
            static_cast<void*>(controller_),
            controller_ ? controller_->getParameterCount() : -1, channels_);

    outL_.assign(maxBlock, 0.0f);
    outR_.assign(maxBlock, 0.0f);
    return LoadStatus::ok;
  }

  void process(float* l, float* r, int n) override {
    if (!processor_) return;
    // For a mono effect only channel 0 is fed; the output is duplicated L->R
    // below. For stereo both channels are live.
    Sample32* inCh[2] = {l, r};
    Sample32* outCh[2] = {outL_.data(), outR_.data()};

    AudioBusBuffers in;
    in.numChannels = channels_;
    in.silenceFlags = 0;
    in.channelBuffers32 = inCh;
    AudioBusBuffers out;
    out.numChannels = channels_;
    out.silenceFlags = 0;
    out.channelBuffers32 = outCh;

    // Drain the params staged since the last block into the SDK's
    // IParameterChanges (plain -> normalized via the controller). D-PARAM.
    paramChanges_.clear();
    if (controller_) {
      for (int i = 0; i < pending_; ++i) {
        const ParamValue norm =
            controller_->plainParamToNormalized(pendingId_[i], pendingVal_[i]);
        int32 qIdx = 0;
        IParamValueQueue* q = paramChanges_.addParameterData(pendingId_[i], qIdx);
        if (q) {
          int32 pIdx = 0;
          q->addPoint(0, norm, pIdx);
        }
      }
    }
    pending_ = 0;

    ProcessData data;  // default ctor zeroes the optional pointers
    data.processMode = kRealtime;
    data.symbolicSampleSize = kSample32;
    data.numSamples = n;
    data.numInputs = 1;
    data.numOutputs = 1;
    data.inputs = &in;
    data.outputs = &out;
    data.inputParameterChanges = &paramChanges_;
    processor_->process(data);

    const size_t bytes = sizeof(float) * static_cast<size_t>(n);
    std::memcpy(l, outL_.data(), bytes);
    // Mono -> stereo: duplicate the single processed channel to the right.
    std::memcpy(r, channels_ == 1 ? outL_.data() : outR_.data(), bytes);
  }

  int paramCount() override {
    return controller_ ? controller_->getParameterCount() : 0;
  }

  bool paramInfoAt(int index, loopy::PluginParamInfo& out) override {
    if (!controller_ || index < 0 ||
        index >= controller_->getParameterCount()) {
      return false;
    }
    ParameterInfo info;
    if (controller_->getParameterInfo(index, info) != kResultOk) return false;
    out = loopy::PluginParamInfo{};
    out.id = info.id;
    out.name = u16ToUtf8(info.title);
    out.unit = u16ToUtf8(info.units);
    // VST3 params are normalized; report the plain range/default.
    out.min = controller_->normalizedParamToPlain(info.id, 0.0);
    out.max = controller_->normalizedParamToPlain(info.id, 1.0);
    out.def =
        controller_->normalizedParamToPlain(info.id, info.defaultNormalizedValue);
    out.stepCount = info.stepCount;
    uint32_t flags = 0;
    if (info.flags & ParameterInfo::kCanAutomate) {
      flags |= loopy::kParamAutomatable;
    }
    if (info.flags & ParameterInfo::kIsReadOnly) flags |= loopy::kParamReadOnly;
    if (info.flags & ParameterInfo::kIsBypass) flags |= loopy::kParamBypass;
    if (info.flags & ParameterInfo::kIsHidden) flags |= loopy::kParamHidden;
    if (info.stepCount > 0) flags |= loopy::kParamStepped;
    out.flags = flags;
    return true;
  }

  double paramGet(uint32_t id) override {
    if (!controller_) return 0.0;
    return controller_->normalizedParamToPlain(id,
                                               controller_->getParamNormalized(id));
  }

  void queueParam(uint32_t id, double plain) override {
    if (pending_ < kMaxPending) {
      pendingId_[pending_] = id;
      pendingVal_[pending_] = plain;
      ++pending_;
    }
  }

  // --- Native editor (main thread; D-WIN) ---

  bool editorOpen() override {
    if (view_) return true;  // idempotent
    if (!controller_) {
      LPV_LOG("editorOpen: no controller\n");
      return false;  // no controller => no editor
    }
    IPlugView* view = controller_->createView(Vst::ViewType::kEditor);
    if (!view) {
      LPV_LOG("editorOpen: createView returned null (no GUI?)\n");
      return false;
    }
    if (view->isPlatformTypeSupported(kPlatformTypeNSView) != kResultTrue) {
      LPV_LOG("editorOpen: NSView platform type unsupported\n");
      view->release();
      return false;
    }
    ViewRect rect{};
    view->getSize(&rect);
    const int w = rect.getWidth() > 0 ? rect.getWidth() : 400;
    const int h = rect.getHeight() > 0 ? rect.getHeight() : 300;
    window_ = lpw_window_open(w, h,
                              name_.empty() ? "Plugin Editor" : name_.c_str(),
                              &Vst3Host::onWindowClosedThunk, this);
    if (!window_) {
      view->release();
      return false;
    }
    frame_.window = window_;
    view->setFrame(&frame_);
    void* nsView = lpw_window_content_view(window_);
    if (view->attached(nsView, kPlatformTypeNSView) != kResultOk) {
      view->setFrame(nullptr);
      view->release();
      lpw_window_close(window_);
      window_ = nullptr;
      return false;
    }
    view_ = view;
    lpw_window_show(window_);
    LPV_LOG("editorOpen: window shown (%dx%d)\n", w, h);
    return true;
  }

  void editorClose() override {
    detachView();
    if (window_) {
      lpw_window_close(window_);  // host-driven; the delegate callback is
      window_ = nullptr;          // suppressed, so onWindowClosed won't re-run
    }
  }

  bool editorIsOpen() const override { return view_ != nullptr; }

 private:
  // Connects the component and controller via their IConnectionPoints so the
  // two halves of a separated plugin exchange state/notifications. Best-effort:
  // some plugins need the host to proxy IMessage between them (not implemented),
  // but most function with a direct peer connection.
  void connectComponentAndController() {
    if (component_->queryInterface(IConnectionPoint::iid,
                                   reinterpret_cast<void**>(&compCP_)) !=
        kResultOk) {
      compCP_ = nullptr;
    }
    if (controller_->queryInterface(IConnectionPoint::iid,
                                    reinterpret_cast<void**>(&ctrlCP_)) !=
        kResultOk) {
      ctrlCP_ = nullptr;
    }
    if (compCP_ && ctrlCP_) {
      compCP_->connect(ctrlCP_);
      ctrlCP_->connect(compCP_);
    }
  }

  // Detaches + releases the plugin view (no window teardown). Shared by the
  // host-driven close and the user-close callback.
  void detachView() {
    if (view_) {
      view_->setFrame(nullptr);
      view_->removed();
      view_->release();
      view_ = nullptr;
    }
  }

  // Fired from windowWillClose when the USER closes the editor window: detach the
  // plugin view here; the window handle frees itself (deferred) in the shim.
  static void onWindowClosedThunk(void* ctx) {
    static_cast<Vst3Host*>(ctx)->onWindowClosed();
  }
  void onWindowClosed() {
    detachView();
    window_ = nullptr;  // the shim owns the deferred free; just forget it
  }

  bool openBundle(const std::string& path) {
    CFStringRef cfPath = CFStringCreateWithCString(
        kCFAllocatorDefault, path.c_str(), kCFStringEncodingUTF8);
    if (!cfPath) return false;
    CFURLRef url = CFURLCreateWithFileSystemPath(
        kCFAllocatorDefault, cfPath, kCFURLPOSIXPathStyle, true);
    CFRelease(cfPath);
    if (!url) return false;
    bundle_ = CFBundleCreate(kCFAllocatorDefault, url);
    CFRelease(url);
    if (!bundle_) return false;

    auto entry = reinterpret_cast<BundleEntryFunc>(
        CFBundleGetFunctionPointerForName(bundle_, CFSTR("bundleEntry")));
    getFactory_ = reinterpret_cast<GetFactoryFunc>(
        CFBundleGetFunctionPointerForName(bundle_, CFSTR("GetPluginFactory")));
    bundleExit_ = reinterpret_cast<BundleExitFunc>(
        CFBundleGetFunctionPointerForName(bundle_, CFSTR("bundleExit")));
    if (!getFactory_ || (entry && !entry(bundle_))) return false;
    return true;
  }

  void unload() {
    editorClose();  // D-WIN: never leak the editor window past the plugin
    if (compCP_ && ctrlCP_) {
      compCP_->disconnect(ctrlCP_);
      ctrlCP_->disconnect(compCP_);
    }
    if (compCP_) {
      compCP_->release();
      compCP_ = nullptr;
    }
    if (ctrlCP_) {
      ctrlCP_->release();
      ctrlCP_ = nullptr;
    }
    if (processor_) processor_->setProcessing(false);
    if (component_) component_->setActive(false);
    if (controller_) {
      controller_->terminate();
      controller_->release();
      controller_ = nullptr;
    }
    if (processor_) {
      processor_->release();
      processor_ = nullptr;
    }
    if (component_) {
      component_->terminate();
      component_->release();
      component_ = nullptr;
    }
    if (factory_) {
      factory_->release();
      factory_ = nullptr;
    }
    if (bundleExit_) bundleExit_();
    if (bundle_) {
      CFRelease(bundle_);
      bundle_ = nullptr;
    }
  }

  CFBundleRef bundle_ = nullptr;
  GetFactoryFunc getFactory_ = nullptr;
  BundleExitFunc bundleExit_ = nullptr;
  IPluginFactory* factory_ = nullptr;
  IComponent* component_ = nullptr;
  IAudioProcessor* processor_ = nullptr;
  IEditController* controller_ = nullptr;
  int32 channels_ = 2;  // negotiated channel count (1 = mono-adapted, 2 = stereo)
  std::vector<float> outL_, outR_;

  // Params staged on the audio thread (queueParam) and drained into the SDK in
  // process(). Fixed-size — no allocation on the audio thread.
  static constexpr int kMaxPending = 64;
  ParamID pendingId_[kMaxPending] = {};
  double pendingVal_[kMaxPending] = {};
  int pending_ = 0;
  HostParamChanges paramChanges_;

  // Native editor window (main thread). view_ non-null == editor open.
  IPlugView* view_ = nullptr;
  lpw_window* window_ = nullptr;
  HostPlugFrame frame_;

  // Host context + controller wiring (stack-owned host objects; queried
  // connection points). Real commercial plugins need these to load and to
  // expose params / an editor.
  HostApplication hostApp_;
  ComponentHandler componentHandler_;
  IConnectionPoint* compCP_ = nullptr;
  IConnectionPoint* ctrlCP_ = nullptr;
  std::string name_;  // plugin display name, for the editor window title
};

}  // namespace

namespace loopy {
IPluginHost* createVst3Host() { return new Vst3Host(); }
}  // namespace loopy

#elif defined(LOOPY_ENABLE_PLUGINS)

#include "plugin_host.h"
namespace loopy {
IPluginHost* createVst3Host() { return nullptr; }  // ports: parts 8–9
}  // namespace loopy

#endif
