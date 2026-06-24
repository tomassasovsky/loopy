// VST3 host backend — loads + drives one VST3 plugin as an IPluginHost.
//
// Hand-rolled against pluginterfaces only (the IComponent / IAudioProcessor
// lifecycle); no base/public.sdk hosting layer is linked — only the vendored
// class IIDs (coreiids.cpp). Part 3 hosts at the plugin's DEFAULT state: stereo
// in/out, no parameter changes, no events. The adapter (slot.cpp) calls
// process() with a fixed block on the audio thread; load/teardown are control
// thread. A richer host context (IHostApplication) is a follow-up — some
// plugins refuse a null context; those simply fail to load here.

#if defined(LOOPY_ENABLE_PLUGINS) && (defined(__APPLE__) || defined(_WIN32))

// The whole host class is portable C++ against pluginterfaces; only bundle
// loading (openBundle) and the editor's platform view type differ per OS, each
// isolated in a small #if below. macOS loads a CFBundle; Windows LoadLibrary's a
// DLL. Everything between is byte-identical across the two platforms.
#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#elif defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#endif

#include <atomic>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

#include "pluginterfaces/base/ibstream.h"
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

#if defined(__APPLE__)
typedef bool (*BundleEntryFunc)(CFBundleRef);
typedef bool (*BundleExitFunc)();
typedef IPluginFactory* (*GetFactoryFunc)();
#elif defined(_WIN32)
typedef bool(PLUGIN_API* InitDllFunc)();
typedef bool(PLUGIN_API* ExitDllFunc)();
typedef IPluginFactory*(PLUGIN_API* GetFactoryFunc)();

// Converts a UTF-8 path (as carried on PluginDescriptor) to a wide string for
// LoadLibraryExW.
std::wstring widen(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
  if (n <= 0) return std::wstring();
  std::wstring out(static_cast<size_t>(n - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, out.data(), n);
  return out;
}

// SEH filter for the load guard: catch hardware faults (access violation,
// illegal instruction, …) raised inside a misbehaving plugin's load path so it
// fails gracefully instead of killing the host; let real C++ exceptions
// (MSVC code 0xE06D7363) propagate normally.
inline int loadSehFilter(unsigned long code) {
  return code == 0xE06D7363ul ? EXCEPTION_CONTINUE_SEARCH
                              : EXCEPTION_EXECUTE_HANDLER;
}
#endif

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

// A growable in-memory IBStream for plugin state get/set (D-P1). Stack-owned.
class MemoryStream : public IBStream {
 public:
  std::vector<uint8_t> data;
  int64 pos = 0;

  MemoryStream() = default;
  MemoryStream(const uint8_t* d, int n) : data(d, d + n) {}

  tresult PLUGIN_API read(void* buffer, int32 numBytes,
                          int32* numRead) override {
    if (numBytes < 0) numBytes = 0;  // mirror write()'s clamp
    int64 avail = static_cast<int64>(data.size()) - pos;
    int32 n = (avail <= 0) ? 0
              : (numBytes < avail ? numBytes : static_cast<int32>(avail));
    if (n > 0) std::memcpy(buffer, data.data() + pos, static_cast<size_t>(n));
    pos += n;
    if (numRead) *numRead = n;
    return kResultOk;
  }
  tresult PLUGIN_API write(void* buffer, int32 numBytes,
                           int32* numWritten) override {
    if (numBytes < 0) numBytes = 0;
    if (pos + numBytes > static_cast<int64>(data.size())) {
      data.resize(static_cast<size_t>(pos + numBytes));
    }
    if (numBytes > 0) {
      std::memcpy(data.data() + pos, buffer, static_cast<size_t>(numBytes));
    }
    pos += numBytes;
    if (numWritten) *numWritten = numBytes;
    return kResultOk;
  }
  tresult PLUGIN_API seek(int64 p, int32 mode, int64* result) override {
    if (mode == kIBSeekSet) {
      pos = p;
    } else if (mode == kIBSeekCur) {
      pos += p;
    } else {
      pos = static_cast<int64>(data.size()) + p;
    }
    if (pos < 0) pos = 0;
    if (result) *result = pos;
    return kResultOk;
  }
  tresult PLUGIN_API tell(int64* p) override {
    if (p) *p = pos;
    return kResultOk;
  }
  tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
    if (iidEq(iid, IBStream::iid) || iidEq(iid, FUnknown::iid)) {
      *obj = this;
      return kResultOk;
    }
    *obj = nullptr;
    return kNoInterface;
  }
  uint32 PLUGIN_API addRef() override { return 1; }
  uint32 PLUGIN_API release() override { return 1; }
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

// Host-side IAttributeList backing an IMessage. Heap-allocated and reference
// counted (the plugin owns it for the message's lifetime), unlike the stack
// helpers above. Stores one value per string key; a later setX overwrites the
// prior value/type. Mirrors the SDK's reference HostAttributeList.
class HostAttributeList final : public IAttributeList {
 public:
  tresult PLUGIN_API setInt(AttrID id, int64 value) override {
    attrs_[id] = Attr::ofInt(value);
    return kResultOk;
  }
  tresult PLUGIN_API getInt(AttrID id, int64& value) override {
    const Attr* a = find(id, Attr::kInt);
    if (!a) return kResultFalse;
    value = a->i;
    return kResultOk;
  }
  tresult PLUGIN_API setFloat(AttrID id, double value) override {
    attrs_[id] = Attr::ofFloat(value);
    return kResultOk;
  }
  tresult PLUGIN_API getFloat(AttrID id, double& value) override {
    const Attr* a = find(id, Attr::kFloat);
    if (!a) return kResultFalse;
    value = a->f;
    return kResultOk;
  }
  tresult PLUGIN_API setString(AttrID id, const TChar* string) override {
    attrs_[id] = Attr::ofString(string);
    return kResultOk;
  }
  tresult PLUGIN_API getString(AttrID id, TChar* string,
                               uint32 sizeInBytes) override {
    const Attr* a = find(id, Attr::kString);
    if (!a || !string) return kResultFalse;
    // str includes its null terminator; copy as many whole bytes as fit.
    const uint32 have = static_cast<uint32>(a->str.size() * sizeof(TChar));
    const uint32 n = have < sizeInBytes ? have : sizeInBytes;
    std::memcpy(string, a->str.data(), n);
    return kResultOk;
  }
  tresult PLUGIN_API setBinary(AttrID id, const void* data,
                               uint32 sizeInBytes) override {
    attrs_[id] = Attr::ofBinary(data, sizeInBytes);
    return kResultOk;
  }
  tresult PLUGIN_API getBinary(AttrID id, const void*& data,
                               uint32& sizeInBytes) override {
    const Attr* a = find(id, Attr::kBinary);
    if (!a) {
      data = nullptr;
      sizeInBytes = 0;
      return kResultFalse;
    }
    data = a->bin.data();
    sizeInBytes = static_cast<uint32>(a->bin.size());
    return kResultOk;
  }
  tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
    if (iidEq(iid, IAttributeList::iid) || iidEq(iid, FUnknown::iid)) {
      addRef();
      *obj = this;
      return kResultOk;
    }
    *obj = nullptr;
    return kNoInterface;
  }
  uint32 PLUGIN_API addRef() override { return ++refs_; }
  uint32 PLUGIN_API release() override {
    const uint32 r = --refs_;
    if (r == 0) delete this;
    return r;
  }

 private:
  struct Attr {
    enum Type { kInt, kFloat, kString, kBinary } type = kInt;
    int64 i = 0;
    double f = 0.0;
    std::vector<TChar> str;     // UTF-16, includes the null terminator
    std::vector<uint8_t> bin;
    static Attr ofInt(int64 v) {
      Attr a;
      a.type = kInt;
      a.i = v;
      return a;
    }
    static Attr ofFloat(double v) {
      Attr a;
      a.type = kFloat;
      a.f = v;
      return a;
    }
    static Attr ofString(const TChar* s) {
      Attr a;
      a.type = kString;
      size_t n = 0;
      if (s) {
        while (s[n]) ++n;
      }
      a.str.assign(s, s + n);
      a.str.push_back(0);  // keep the terminator for getString
      return a;
    }
    static Attr ofBinary(const void* d, uint32 n) {
      Attr a;
      a.type = kBinary;
      const uint8_t* p = static_cast<const uint8_t*>(d);
      if (p && n) a.bin.assign(p, p + n);
      return a;
    }
  };
  const Attr* find(AttrID id, Attr::Type type) const {
    auto it = attrs_.find(id);
    if (it == attrs_.end() || it->second.type != type) return nullptr;
    return &it->second;
  }
  std::map<std::string, Attr> attrs_;
  std::atomic<uint32> refs_{1};
};

// Host-side IMessage handed to plugins via IHostApplication::createInstance.
// DPF-based plugins (and many others) mint one to carry parameter/state gestures
// between their controller and processor halves over IConnectionPoint; with a
// null message the editor's notify path asserts and the GUI can't reach the DSP.
// Heap-allocated + reference counted; owns its attribute list (getAttributes
// returns a borrowed pointer per the VST3 convention).
class HostMessage final : public IMessage {
 public:
  HostMessage() : attributes_(new HostAttributeList()) {}
  FIDString PLUGIN_API getMessageID() override { return messageId_.c_str(); }
  void PLUGIN_API setMessageID(FIDString id) override {
    messageId_ = id ? id : "";
  }
  IAttributeList* PLUGIN_API getAttributes() override { return attributes_; }
  tresult PLUGIN_API queryInterface(const TUID iid, void** obj) override {
    if (iidEq(iid, IMessage::iid) || iidEq(iid, FUnknown::iid)) {
      addRef();
      *obj = this;
      return kResultOk;
    }
    *obj = nullptr;
    return kNoInterface;
  }
  uint32 PLUGIN_API addRef() override { return ++refs_; }
  uint32 PLUGIN_API release() override {
    const uint32 r = --refs_;
    if (r == 0) delete this;
    return r;
  }

 private:
  ~HostMessage() { attributes_->release(); }
  std::string messageId_;
  HostAttributeList* attributes_;
  std::atomic<uint32> refs_{1};
};

// Minimal host context. Real commercial plugins refuse a NULL context in
// initialize(); most only need a non-null IHostApplication to exist. We also
// mint IMessage / IAttributeList on request so component<->controller messaging
// (notably DPF-based editors) works. Stack-owned.
class HostApplication : public IHostApplication {
 public:
  tresult PLUGIN_API getName(String128 name) override {
    static const char16 kName[] = u"Loopy";
    std::memcpy(name, kName, sizeof(kName));
    return kResultOk;
  }
  tresult PLUGIN_API createInstance(TUID cid, TUID _iid, void** obj) override {
    if (!obj) return kInvalidArgument;
    *obj = nullptr;
    // The two objects plugins ask the host to allocate for controller<->processor
    // messaging. queryInterface adds a ref; release our construction ref so the
    // caller owns exactly one (it releases when done, freeing the object).
    if (iidEq(cid, IMessage::iid)) {
      auto* m = new HostMessage();
      const tresult r = m->queryInterface(_iid, obj);
      m->release();
      return r == kResultOk ? kResultOk : kResultFalse;
    }
    if (iidEq(cid, IAttributeList::iid)) {
      auto* a = new HostAttributeList();
      const tresult r = a->queryInterface(_iid, obj);
      a->release();
      return r == kResultOk ? kResultOk : kResultFalse;
    }
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
#if defined(_WIN32)
    // A third-party plugin can fault (access violation) inside its own
    // createInstance/initialize on load — observed with a VST3 that derefs a
    // failed handle (INVALID_HANDLE_VALUE, e.g. a missing model/resource file).
    // SEH-guard the load so a misbehaving plugin yields a clean load failure
    // instead of crashing the whole app (D-RT: documented best-effort, no
    // watchdog). The discarded host's destructor (unload) frees what was set.
    __try {
      return loadImpl(desc, sampleRate, maxBlock);
    } __except (loadSehFilter(GetExceptionCode())) {
      LPV_LOG("load: structured exception in plugin — load failed\n");
      crashed_ = true;  // unload() must not call back into the dead plugin
      return loopy::LoadStatus::failed;
    }
#else
    return loadImpl(desc, sampleRate, maxBlock);
#endif
  }

  loopy::LoadStatus loadImpl(const loopy::PluginDescriptor& desc,
                             double sampleRate, int maxBlock) {
    using loopy::LoadStatus;
    name_ = desc.name;  // for the editor window title
    LPV_LOG("load '%s' (id %s)\n", desc.path.c_str(), desc.id.c_str());
    if (!openBundle(desc.path)) {
      LPV_LOG("  openBundle failed\n");
      return LoadStatus::failed;
    }
    LPV_LOG("  openBundle ok\n");

    IPluginFactory* factory = getFactory_();
    if (!factory) return LoadStatus::failed;
    factory_ = factory;
    LPV_LOG("  got factory\n");

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
    LPV_LOG("  IComponent created\n");

    // Pass a real host context — commercial plugins reject a null context.
    if (component_->initialize(&hostApp_) != kResultOk) {
      LPV_LOG("  component initialize failed\n");
      return LoadStatus::failed;
    }
    LPV_LOG("  component initialized\n");
    if (component_->queryInterface(IAudioProcessor::iid,
                                   reinterpret_cast<void**>(&processor_)) !=
            kResultOk ||
        !processor_) {
      return LoadStatus::failed;
    }
    if (processor_->canProcessSampleSize(kSample32) != kResultOk) {
      return LoadStatus::failed;
    }
    LPV_LOG("  got IAudioProcessor (sample32 ok)\n");

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
    LPV_LOG("  buses in=%d out=%d\n", numIn, numOut);

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
    LPV_LOG("  arrangement chIn=%d chOut=%d -> channels=%d\n", chIn, chOut,
            channels_);

    ProcessSetup setup;
    setup.processMode = kRealtime;
    setup.symbolicSampleSize = kSample32;
    setup.maxSamplesPerBlock = maxBlock;
    setup.sampleRate = sampleRate;
    if (processor_->setupProcessing(setup) != kResultOk) {
      return LoadStatus::failed;
    }
    LPV_LOG("  setupProcessing ok\n");

    component_->activateBus(kAudio, kInput, 0, true);
    component_->activateBus(kAudio, kOutput, 0, true);
    if (component_->setActive(true) != kResultOk) return LoadStatus::failed;
    processor_->setProcessing(true);  // some plugins return notImplemented
    LPV_LOG("  activated + processing\n");

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
    if (firstProcess_) {  // one-shot: did the audio thread reach process()?
      firstProcess_ = false;
      LPV_LOG("process: first call n=%d channels=%d\n", n, channels_);
    }
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
    // A fresh, empty output container each block — the plugin fills it with any
    // param changes it originates; we discard them but must not pass null.
    outParamChanges_.clear();

    ProcessData data;  // default ctor zeroes the optional pointers
    data.processMode = kRealtime;
    data.symbolicSampleSize = kSample32;
    data.numSamples = n;
    data.numInputs = 1;
    data.numOutputs = 1;
    data.inputs = &in;
    data.outputs = &out;
    data.inputParameterChanges = &paramChanges_;
    data.outputParameterChanges = &outParamChanges_;
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

  bool paramValueText(uint32_t id, double value, std::string& out) override {
    if (!controller_) return false;
    // VST3 strings work in NORMALIZED units — convert the plain value back.
    const Vst::ParamValue norm = controller_->plainParamToNormalized(id, value);
    Vst::String128 str;
    if (controller_->getParamStringByValue(id, norm, str) != kResultOk) {
      return false;
    }
    out = u16ToUtf8(str);
    return true;
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
#if defined(__APPLE__)
    const FIDString platformType = kPlatformTypeNSView;
#elif defined(_WIN32)
    const FIDString platformType = kPlatformTypeHWND;
#endif
    if (view->isPlatformTypeSupported(platformType) != kResultTrue) {
      LPV_LOG("editorOpen: platform view type unsupported\n");
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
    void* parent = lpw_window_content_view(window_);
    if (view->attached(parent, platformType) != kResultOk) {
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

  // --- Opaque state (main thread; D-P1) ---

  bool stateGet(std::vector<uint8_t>& out) override {
    if (!component_) return false;
    MemoryStream stream;
    if (component_->getState(&stream) != kResultOk) return false;
    out.insert(out.end(), stream.data.begin(), stream.data.end());
    return true;
  }

  bool stateSet(const uint8_t* data, int size) override {
    if (!component_ || !data || size <= 0) return false;
    MemoryStream stream(data, size);
    stream.seek(0, IBStream::kIBSeekSet, nullptr);
    if (component_->setState(&stream) != kResultOk) return false;
    // Sync the controller so its params + editor reflect the restored state.
    if (controller_) {
      stream.seek(0, IBStream::kIBSeekSet, nullptr);
      controller_->setComponentState(&stream);
    }
    return true;
  }

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

  // The plugin's binary is the only platform-specific load step. The scan stores
  // the resolved loadable path on the descriptor (a Windows .vst3 bundle is
  // resolved to its inner Contents\x86_64-win DLL there), so the host loads
  // `path` directly on both platforms.
  bool openBundle(const std::string& path) {
#if defined(__APPLE__)
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
#elif defined(_WIN32)
    const std::wstring wpath = widen(path);
    dll_ = LoadLibraryExW(wpath.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!dll_) return false;
    auto initDll = reinterpret_cast<InitDllFunc>(GetProcAddress(dll_, "InitDll"));
    getFactory_ =
        reinterpret_cast<GetFactoryFunc>(GetProcAddress(dll_, "GetPluginFactory"));
    exitDll_ = reinterpret_cast<ExitDllFunc>(GetProcAddress(dll_, "ExitDll"));
    if (!getFactory_ || (initDll && !initDll())) return false;
    return true;
#endif
  }

  void unload() {
#if defined(_WIN32)
    if (crashed_) {
      // A plugin that faulted mid-load left its module + factory in an unknown
      // (possibly corrupt) state — calling back into it (release / ExitDll /
      // FreeLibrary) crashes again. Deliberately forget every handle WITHOUT
      // touching the plugin: the dead plugin's DLL stays mapped (a bounded,
      // best-effort leak — D-RT) but the app survives. No editor can be open
      // (the fault was during load, before any editor).
      component_ = nullptr;
      processor_ = nullptr;
      controller_ = nullptr;
      compCP_ = nullptr;
      ctrlCP_ = nullptr;
      factory_ = nullptr;
      dll_ = nullptr;
      exitDll_ = nullptr;
      getFactory_ = nullptr;
      return;
    }
#endif
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
#if defined(__APPLE__)
    if (bundleExit_) bundleExit_();
    if (bundle_) {
      CFRelease(bundle_);
      bundle_ = nullptr;
    }
#elif defined(_WIN32)
    if (exitDll_) exitDll_();
    if (dll_) {
      FreeLibrary(dll_);
      dll_ = nullptr;
    }
    getFactory_ = nullptr;
#endif
  }

#if defined(__APPLE__)
  CFBundleRef bundle_ = nullptr;
  BundleExitFunc bundleExit_ = nullptr;
#elif defined(_WIN32)
  HMODULE dll_ = nullptr;
  ExitDllFunc exitDll_ = nullptr;
#endif
  GetFactoryFunc getFactory_ = nullptr;
  IPluginFactory* factory_ = nullptr;
  IComponent* component_ = nullptr;
  IAudioProcessor* processor_ = nullptr;
  IEditController* controller_ = nullptr;
  int32 channels_ = 2;  // negotiated channel count (1 = mono-adapted, 2 = stereo)
  bool firstProcess_ = true;  // one-shot diagnostic trace gate (see process())
  bool crashed_ = false;  // load SEH-faulted: unload() must not touch the plugin
  std::vector<float> outL_, outR_;

  // Params staged on the audio thread (queueParam) and drained into the SDK in
  // process(). Fixed-size — no allocation on the audio thread.
  static constexpr int kMaxPending = 64;
  ParamID pendingId_[kMaxPending] = {};
  double pendingVal_[kMaxPending] = {};
  int pending_ = 0;
  HostParamChanges paramChanges_;
  // The plugin writes its own param gestures (e.g. GUI moves) here. We don't
  // read them back, but a valid container must be supplied: some plugins
  // (notably DPF-based VST3s) assert on a null outputParameterChanges.
  HostParamChanges outParamChanges_;

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

// Non-Apple, non-Windows plugin build: VST3 hosting lands with the Linux port
// (part 9). Stub so the symbol resolves.
#include "plugin_host.h"
namespace loopy {
IPluginHost* createVst3Host() { return nullptr; }  // port: part 9
}  // namespace loopy

#endif
