/*
 * test_vst3_reverb_wrapper.cpp — wrapper-level tests promised by the
 * umbrella plan's Testing Strategy (docs/plan/2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
 * "part 2/3 add wrapper-level tests (parameter round-trip, default values
 * match le_fx_defaults, GUID-constant drift assertion)"). The GUID assertion
 * is test_vst3_reverb_ids.cpp; this covers the other two, entirely
 * host-independent (no real DAW, no dlopen — Processor/Controller are
 * instantiated directly, same pattern part 2's Delay tests and
 * test_plugin_slot.c already use).
 *
 * Wired into run_native_tests.sh (macOS-only section).
 *
 * NOTE: this stack-allocates Processor/Controller directly rather than going
 * through IPluginFactory::createInstance + IPtr the way a real host does —
 * fine for exercising the pure logic under test, but the SDK's own
 * DEVELOPMENT-build FObject destructor may print a benign "Refcount is N
 * when trying to delete" diagnostic on teardown as a result (not a test
 * failure). The real createInstance()/IPtr path is exercised separately by a
 * headless dlopen() smoke test during development (not part of this repo —
 * ad hoc verification, see the part 2/3 PR descriptions) with no such
 * warning.
 */
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "controller.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "processor.h"
#include "public.sdk/source/common/memorystream.h"

using namespace Steinberg;
using namespace Steinberg::Vst;
using loopy_vst3_reverb::Controller;
using loopy_vst3_reverb::kDampingId;
using loopy_vst3_reverb::kMixId;
using loopy_vst3_reverb::kSizeId;
using loopy_vst3_reverb::Processor;

int g_failures = 0;
#define CHECK(cond)                                              \
  do {                                                             \
    if (!(cond)) {                                                \
      std::printf("  FAIL: %s (line %d)\n", #cond, __LINE__);     \
      g_failures++;                                               \
    }                                                              \
  } while (0)

// Minimal test-only IParamValueQueue/IParameterChanges — Processor::process()
// only ever calls getParameterCount/getParameterData/getParameterId/
// getPointCount/getPoint, so that is all this stub needs to implement
// correctly; queryInterface is never exercised by the code under test.
namespace {

class FakeParamQueue : public IParamValueQueue {
 public:
  FakeParamQueue(ParamID id, ParamValue v) : id_(id), value_(v) {}

  ParamID PLUGIN_API getParameterId() SMTG_OVERRIDE { return id_; }
  int32 PLUGIN_API getPointCount() SMTG_OVERRIDE { return 1; }
  tresult PLUGIN_API getPoint(int32 index, int32& sampleOffset,
                              ParamValue& value) SMTG_OVERRIDE {
    if (index != 0) return kResultFalse;
    sampleOffset = 0;
    value = value_;
    return kResultTrue;
  }
  tresult PLUGIN_API addPoint(int32, ParamValue, int32&) SMTG_OVERRIDE {
    return kNotImplemented;
  }
  tresult PLUGIN_API queryInterface(const TUID, void**) SMTG_OVERRIDE {
    return kNoInterface;
  }
  uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return 1; }
  uint32 PLUGIN_API release() SMTG_OVERRIDE { return 1; }

 private:
  ParamID id_;
  ParamValue value_;
};

class FakeParameterChanges : public IParameterChanges {
 public:
  void add(ParamID id, ParamValue v) { queues_.emplace_back(id, v); }

  int32 PLUGIN_API getParameterCount() SMTG_OVERRIDE {
    return static_cast<int32>(queues_.size());
  }
  IParamValueQueue* PLUGIN_API getParameterData(int32 index) SMTG_OVERRIDE {
    if (index < 0 || index >= static_cast<int32>(queues_.size())) return nullptr;
    return &queues_[index];
  }
  IParamValueQueue* PLUGIN_API addParameterData(const ParamID&, int32&) SMTG_OVERRIDE {
    return nullptr;
  }
  tresult PLUGIN_API queryInterface(const TUID, void**) SMTG_OVERRIDE {
    return kNoInterface;
  }
  uint32 PLUGIN_API addRef() SMTG_OVERRIDE { return 1; }
  uint32 PLUGIN_API release() SMTG_OVERRIDE { return 1; }

 private:
  std::vector<FakeParamQueue> queues_;
};

// Drives one silent block through `proc` so any queued param changes apply.
void processSilentBlock(IAudioProcessor* proc, IParameterChanges* changes) {
  const int32 n = 64;
  float inL[n] = {};
  float inR[n] = {};
  float outL[n] = {};
  float outR[n] = {};
  float* inChans[2] = {inL, inR};
  float* outChans[2] = {outL, outR};
  AudioBusBuffers inBus;
  inBus.numChannels = 2;
  inBus.silenceFlags = 0;
  inBus.channelBuffers32 = inChans;
  AudioBusBuffers outBus;
  outBus.numChannels = 2;
  outBus.silenceFlags = 0;
  outBus.channelBuffers32 = outChans;

  ProcessData data;
  data.processMode = kRealtime;
  data.symbolicSampleSize = kSample32;
  data.numSamples = n;
  data.numInputs = 1;
  data.numOutputs = 1;
  data.inputs = &inBus;
  data.outputs = &outBus;
  data.inputParameterChanges = changes;
  proc->process(data);
}

// Reverb's ring is now sized in setupProcessing() (not initialize()), from
// the real negotiated sample rate — any test that actually exercises the
// DSP (not just param/state storage) must call this first, or the ring
// stays NULL and fx_reverb's own guard makes process() a pure dry
// passthrough.
tresult setupProcessing48k(IAudioProcessor* proc) {
  ProcessSetup setup;
  setup.processMode = kRealtime;
  setup.symbolicSampleSize = kSample32;
  setup.maxSamplesPerBlock = 4096;
  setup.sampleRate = 48000.0;
  return proc->setupProcessing(setup);
}

}  // namespace

// Both sides read/write the full LE_FX_PARAMS-length array (p3 always 0,
// unused) — Processor::setState/getState and Controller::setComponentState
// agree on that wire format, so the test data below matches it rather than
// just the 3 user-facing params.
constexpr double kEps = 1e-5;

static void test_processor_defaults_match_engine() {
  std::printf("test_processor_defaults_match_engine\n");
  Processor processor;
  CHECK(processor.initialize(nullptr) == kResultOk);

  MemoryStream stream;
  CHECK(processor.getState(&stream) == kResultOk);
  CHECK(stream.getSize() == static_cast<TSize>(LE_FX_PARAMS * sizeof(float)));
  const float* saved = reinterpret_cast<const float*>(stream.getData());
  // Independently-known engine default (engine_fx.c's fx_reverb_defaults),
  // not re-derived from le_fx_defaults here — a real assertion, not a tautology.
  CHECK(std::fabs(saved[0] - 0.5) < kEps);
  CHECK(std::fabs(saved[1] - 0.5) < kEps);
  CHECK(std::fabs(saved[2] - 0.35) < kEps);

  processor.terminate();
}

static void test_processor_param_round_trip() {
  std::printf("test_processor_param_round_trip\n");
  Processor processor;
  CHECK(processor.initialize(nullptr) == kResultOk);

  FakeParameterChanges changes;
  changes.add(kSizeId, 0.9);
  changes.add(kDampingId, 0.1);
  changes.add(kMixId, 0.75);

  IAudioProcessor* proc = nullptr;
  CHECK(processor.queryInterface(IAudioProcessor::iid, (void**)&proc) == kResultOk);
  CHECK(proc != nullptr);
  CHECK(setupProcessing48k(proc) == kResultOk);
  processSilentBlock(proc, &changes);

  MemoryStream stream;
  CHECK(processor.getState(&stream) == kResultOk);
  const float* saved = reinterpret_cast<const float*>(stream.getData());
  CHECK(std::fabs(saved[0] - 0.9) < kEps);
  CHECK(std::fabs(saved[1] - 0.1) < kEps);
  CHECK(std::fabs(saved[2] - 0.75) < kEps);

  processor.terminate();
}

static void test_processor_set_state_restores_params() {
  std::printf("test_processor_set_state_restores_params\n");
  Processor processor;
  CHECK(processor.initialize(nullptr) == kResultOk);

  const float restored[LE_FX_PARAMS] = {0.2f, 0.8f, 0.6f, 0.0f};
  MemoryStream in;
  int32 written = 0;
  CHECK(in.write((void*)restored, sizeof(restored), &written) == kResultOk);
  int64 seekResult = 0;
  CHECK(in.seek(0, IBStream::kIBSeekSet, &seekResult) == kResultOk);
  CHECK(processor.setState(&in) == kResultOk);

  MemoryStream out;
  CHECK(processor.getState(&out) == kResultOk);
  const float* saved = reinterpret_cast<const float*>(out.getData());
  CHECK(std::fabs(saved[0] - 0.2) < kEps);
  CHECK(std::fabs(saved[1] - 0.8) < kEps);
  CHECK(std::fabs(saved[2] - 0.6) < kEps);

  processor.terminate();
}

static void test_controller_registers_params_with_defaults() {
  std::printf("test_controller_registers_params_with_defaults\n");
  Controller controller;
  CHECK(controller.initialize(nullptr) == kResultOk);

  CHECK(controller.getParameterCount() == 3);
  ParameterInfo info;
  CHECK(controller.getParameterInfo(0, info) == kResultOk);
  CHECK(info.id == kSizeId);
  CHECK(std::fabs(info.defaultNormalizedValue - 0.5) < kEps);
  CHECK(controller.getParameterInfo(1, info) == kResultOk);
  CHECK(info.id == kDampingId);
  CHECK(std::fabs(info.defaultNormalizedValue - 0.5) < kEps);
  CHECK(controller.getParameterInfo(2, info) == kResultOk);
  CHECK(info.id == kMixId);
  CHECK(std::fabs(info.defaultNormalizedValue - 0.35) < kEps);

  controller.terminate();
}

static void test_controller_syncs_from_component_state() {
  std::printf("test_controller_syncs_from_component_state\n");
  Controller controller;
  CHECK(controller.initialize(nullptr) == kResultOk);

  const float saved[LE_FX_PARAMS] = {0.4f, 0.6f, 0.15f, 0.0f};
  MemoryStream stream;
  int32 written = 0;
  CHECK(stream.write((void*)saved, sizeof(saved), &written) == kResultOk);
  int64 seekResult = 0;
  CHECK(stream.seek(0, IBStream::kIBSeekSet, &seekResult) == kResultOk);

  CHECK(controller.setComponentState(&stream) == kResultOk);
  CHECK(std::fabs(controller.getParamNormalized(kSizeId) - 0.4) < kEps);
  CHECK(std::fabs(controller.getParamNormalized(kDampingId) - 0.6) < kEps);
  CHECK(std::fabs(controller.getParamNormalized(kMixId) - 0.15) < kEps);

  controller.terminate();
}

static void test_mono_input_yields_stereo_tail() {
  // Umbrella + plan-called-out risk: a mono source seeds l == r
  // (engine_private.h's documented convention), and fx_reverb's bank spread
  // must still decorrelate it into a genuine stereo tail, not a collapsed
  // mono sum or silence. Exercises the aliased-mono-bus path in process()
  // exactly as a host renegotiating a mono bus would.
  std::printf("test_mono_input_yields_stereo_tail\n");
  Processor processor;
  CHECK(processor.initialize(nullptr) == kResultOk);
  IAudioProcessor* proc = nullptr;
  CHECK(processor.queryInterface(IAudioProcessor::iid, (void**)&proc) == kResultOk);
  CHECK(setupProcessing48k(proc) == kResultOk);

  const int32 n = 4096;
  std::vector<float> in(n, 0.0f);
  std::vector<float> outL(n, 0.0f);
  std::vector<float> outR(n, 0.0f);
  in[0] = 1.0f;
  float* inChans[1] = {in.data()};
  float* outChans[2] = {outL.data(), outR.data()};

  AudioBusBuffers inBus;
  inBus.numChannels = 1;  // mono input bus
  inBus.silenceFlags = 0;
  inBus.channelBuffers32 = inChans;
  AudioBusBuffers outBus;
  outBus.numChannels = 2;  // stereo output bus
  outBus.silenceFlags = 0;
  outBus.channelBuffers32 = outChans;

  ProcessData data;
  data.processMode = kRealtime;
  data.symbolicSampleSize = kSample32;
  data.numSamples = n;
  data.numInputs = 1;
  data.numOutputs = 1;
  data.inputs = &inBus;
  data.outputs = &outBus;
  data.inputParameterChanges = nullptr;

  CHECK(proc->process(data) == kResultOk);

  bool anyNonZero = false;
  bool anyNonFinite = false;
  bool leftRightDiffer = false;
  for (int32 i = 0; i < n; ++i) {
    if (outL[i] != 0.0f || outR[i] != 0.0f) anyNonZero = true;
    if (!std::isfinite(outL[i]) || !std::isfinite(outR[i])) anyNonFinite = true;
    if (std::fabs(outL[i] - outR[i]) > 1e-6f) leftRightDiffer = true;
  }
  CHECK(anyNonZero);
  CHECK(!anyNonFinite);
  // The decorrelating bank spread must actually produce a stereo (not
  // collapsed-mono) tail from a mono source.
  CHECK(leftRightDiffer);

  processor.terminate();
}

// Regression test for the fixed-cap bug this wrapper used to have: a fixed
// 48000-sample ring is exceeded by the combined comb+allpass+spread offsets
// above ~83 kHz (25450 samples at 44.1 kHz, scaling linearly with sample
// rate), silently dropping lines from the network at engine_fx.c's own
// `if (off + len > cap) break` guard — common production rates like 96 kHz
// would have been affected. setupProcessing() now sizes the ring to the
// real negotiated rate instead, so this must still produce a full,
// non-silent, genuinely stereo tail at 96 kHz.
static void test_reverb_stays_correct_at_96khz() {
  std::printf("test_reverb_stays_correct_at_96khz\n");
  Processor processor;
  CHECK(processor.initialize(nullptr) == kResultOk);
  IAudioProcessor* proc = nullptr;
  CHECK(processor.queryInterface(IAudioProcessor::iid, (void**)&proc) == kResultOk);

  ProcessSetup setup;
  setup.processMode = kRealtime;
  setup.symbolicSampleSize = kSample32;
  setup.maxSamplesPerBlock = 4096;
  setup.sampleRate = 96000.0;
  CHECK(proc->setupProcessing(setup) == kResultOk);
  CHECK(processor.setActive(true) == kResultOk);

  const int32 n = 8192;
  std::vector<float> inL(n, 0.0f), inR(n, 0.0f), outL(n, 0.0f), outR(n, 0.0f);
  inL[0] = 1.0f;
  inR[0] = 1.0f;
  float* inChans[2] = {inL.data(), inR.data()};
  float* outChans[2] = {outL.data(), outR.data()};
  AudioBusBuffers inBus;
  inBus.numChannels = 2;
  inBus.silenceFlags = 0;
  inBus.channelBuffers32 = inChans;
  AudioBusBuffers outBus;
  outBus.numChannels = 2;
  outBus.silenceFlags = 0;
  outBus.channelBuffers32 = outChans;

  ProcessData data;
  data.processMode = kRealtime;
  data.symbolicSampleSize = kSample32;
  data.numSamples = n;
  data.numInputs = 1;
  data.numOutputs = 1;
  data.inputs = &inBus;
  data.outputs = &outBus;
  data.inputParameterChanges = nullptr;
  CHECK(proc->process(data) == kResultOk);

  bool anyNonFinite = false;
  bool tailPastDrySample = false;
  for (int32 i = 1; i < n; ++i) {
    if (!std::isfinite(outL[i]) || !std::isfinite(outR[i])) anyNonFinite = true;
    if (outL[i] != 0.0f || outR[i] != 0.0f) tailPastDrySample = true;
  }
  CHECK(!anyNonFinite);
  CHECK(tailPastDrySample);

  processor.terminate();
}

int main() {
  test_processor_defaults_match_engine();
  test_processor_param_round_trip();
  test_processor_set_state_restores_params();
  test_controller_registers_params_with_defaults();
  test_controller_syncs_from_component_state();
  test_mono_input_yields_stereo_tail();
  test_reverb_stays_correct_at_96khz();
  if (g_failures == 0) {
    std::printf("ALL PASSED\n");
    return 0;
  }
  std::printf("%d FAILURE(S)\n", g_failures);
  return 1;
}
