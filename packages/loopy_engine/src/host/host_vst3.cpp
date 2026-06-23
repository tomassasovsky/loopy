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

#include <cstring>
#include <string>
#include <vector>

#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/vstspeaker.h"
#include "plugin_host.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace {

typedef bool (*BundleEntryFunc)(CFBundleRef);
typedef bool (*BundleExitFunc)();
typedef IPluginFactory* (*GetFactoryFunc)();

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

class Vst3Host final : public loopy::IPluginHost {
 public:
  ~Vst3Host() override { unload(); }

  loopy::LoadStatus load(const loopy::PluginDescriptor& desc, double sampleRate,
                         int maxBlock) override {
    using loopy::LoadStatus;
    if (!openBundle(desc.path)) return LoadStatus::failed;

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
      return LoadStatus::failed;
    }
    component_ = static_cast<IComponent*>(obj);

    if (component_->initialize(nullptr) != kResultOk) return LoadStatus::failed;
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
    if (numIn < 1 || numOut < 1) return LoadStatus::unsupportedTopology;
    if (numIn > 1 || numOut > 1) return LoadStatus::unsupportedTopology;

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

    ProcessData data;  // default ctor zeroes the optional pointers
    data.processMode = kRealtime;
    data.symbolicSampleSize = kSample32;
    data.numSamples = n;
    data.numInputs = 1;
    data.numOutputs = 1;
    data.inputs = &in;
    data.outputs = &out;
    processor_->process(data);

    const size_t bytes = sizeof(float) * static_cast<size_t>(n);
    std::memcpy(l, outL_.data(), bytes);
    // Mono -> stereo: duplicate the single processed channel to the right.
    std::memcpy(r, channels_ == 1 ? outL_.data() : outR_.data(), bytes);
  }

 private:
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
    if (processor_) processor_->setProcessing(false);
    if (component_) component_->setActive(false);
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
  int32 channels_ = 2;  // negotiated channel count (1 = mono-adapted, 2 = stereo)
  std::vector<float> outL_, outR_;
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
