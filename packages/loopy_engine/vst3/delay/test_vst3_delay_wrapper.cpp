/*
 * test_vst3_delay_wrapper.cpp — wrapper-level tests promised by the umbrella
 * plan's Testing Strategy (docs/plan/2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
 * "part 2/3 add wrapper-level tests (parameter round-trip, default values
 * match le_fx_defaults, GUID-constant drift assertion)"). The GUID assertion
 * is test_vst3_delay_ids.cpp; this covers the other two, entirely
 * host-independent (no real DAW, no dlopen — Processor/Controller are
 * instantiated directly, same pattern test_plugin_slot.c already uses for
 * the engine's plugin-slot ABI).
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
 * ad hoc verification, see the part 2 PR description) with no such warning.
 */
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "controller.h"
#include "fake_parameter_changes.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "processor.h"
#include "public.sdk/source/common/memorystream.h"

using namespace Steinberg;
using namespace Steinberg::Vst;
using loopy_vst3_delay::Controller;
using loopy_vst3_delay::kFeedbackId;
using loopy_vst3_delay::kMixId;
using loopy_vst3_delay::kTimeId;
using loopy_vst3_delay::Processor;
using loopy_vst3_test::FakeParameterChanges;

int g_failures = 0;
#define CHECK(cond)                                              \
  do {                                                            \
    if (!(cond)) {                                                \
      std::printf("  FAIL: %s (line %d)\n", #cond, __LINE__);     \
      g_failures++;                                               \
    }                                                              \
  } while (0)

namespace {

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
  // Independently-known engine default (engine_fx.c's fx_delay_defaults),
  // not re-derived from le_fx_defaults here — a real assertion, not a tautology.
  CHECK(std::fabs(saved[0] - 0.35) < kEps);
  CHECK(std::fabs(saved[1] - 0.35) < kEps);
  CHECK(std::fabs(saved[2] - 0.35) < kEps);

  processor.terminate();
}

static void test_processor_param_round_trip() {
  std::printf("test_processor_param_round_trip\n");
  Processor processor;
  CHECK(processor.initialize(nullptr) == kResultOk);

  FakeParameterChanges changes;
  changes.add(kTimeId, 0.9);
  changes.add(kFeedbackId, 0.1);
  changes.add(kMixId, 0.75);

  IAudioProcessor* proc = nullptr;
  CHECK(processor.queryInterface(IAudioProcessor::iid, (void**)&proc) == kResultOk);
  CHECK(proc != nullptr);
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
  CHECK(info.id == kTimeId);
  CHECK(std::fabs(info.defaultNormalizedValue - 0.35) < kEps);
  CHECK(controller.getParameterInfo(1, info) == kResultOk);
  CHECK(info.id == kFeedbackId);
  CHECK(std::fabs(info.defaultNormalizedValue - 0.35) < kEps);
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
  CHECK(std::fabs(controller.getParamNormalized(kTimeId) - 0.4) < kEps);
  CHECK(std::fabs(controller.getParamNormalized(kFeedbackId) - 0.6) < kEps);
  CHECK(std::fabs(controller.getParamNormalized(kMixId) - 0.15) < kEps);

  controller.terminate();
}

int main() {
  test_processor_defaults_match_engine();
  test_processor_param_round_trip();
  test_processor_set_state_restores_params();
  test_controller_registers_params_with_defaults();
  test_controller_syncs_from_component_state();
  if (g_failures == 0) {
    std::printf("ALL PASSED\n");
    return 0;
  }
  std::printf("%d FAILURE(S)\n", g_failures);
  return 1;
}
