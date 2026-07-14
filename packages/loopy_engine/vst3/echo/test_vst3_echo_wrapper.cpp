/*
 * test_vst3_echo_wrapper.cpp — wrapper-level tests promised by the umbrella
 * plan's Testing Strategy (docs/plan/2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
 * "part 2/3 add wrapper-level tests (parameter round-trip, default values
 * match le_fx_defaults, GUID-constant drift assertion)") — Echo had no
 * wrapper-level test file before this fix (only test_vst3_echo_ids.cpp
 * covers the GUID assertion); this file adds the rest, entirely
 * host-independent (no real DAW, no dlopen — Processor/Controller are
 * instantiated directly, the same pattern delay/reverb's wrapper tests use).
 *
 * Wired into CMakeLists.txt via loopy_vst3_add_wrapper_test(echo).
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
#include "fake_parameter_changes.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "processor.h"
#include "public.sdk/source/common/memorystream.h"

using namespace Steinberg;
using namespace Steinberg::Vst;
using loopy_vst3_echo::Controller;
using loopy_vst3_echo::kFeedbackId;
using loopy_vst3_echo::kMixId;
using loopy_vst3_echo::kTimeId;
using loopy_vst3_echo::Processor;
using loopy_vst3_test::FakeParameterChanges;

int g_failures = 0;
#define CHECK(cond)                                              \
  do {                                                             \
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

// Echo's ring is now sized in setupProcessing() (not initialize()), from
// the real negotiated sample rate — any test that actually exercises the
// DSP (not just param/state storage) must call this first, or the ring
// stays NULL and fx_echo's own guard makes process() a pure dry
// passthrough. Mirrors delay/reverb's wrapper test helper of the same name.
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
  // Independently-known engine default (engine_fx.c's fx_echo_defaults),
  // not re-derived from le_fx_defaults here — a real assertion, not a tautology.
  CHECK(std::fabs(saved[0] - 0.45) < kEps);
  CHECK(std::fabs(saved[1] - 0.5) < kEps);
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
  CHECK(info.id == kTimeId);
  CHECK(std::fabs(info.defaultNormalizedValue - 0.45) < kEps);
  CHECK(controller.getParameterInfo(1, info) == kResultOk);
  CHECK(info.id == kFeedbackId);
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
  CHECK(std::fabs(controller.getParamNormalized(kTimeId) - 0.4) < kEps);
  CHECK(std::fabs(controller.getParamNormalized(kFeedbackId) - 0.6) < kEps);
  CHECK(std::fabs(controller.getParamNormalized(kMixId) - 0.15) < kEps);

  controller.terminate();
}

// Unlike fx_delay (a pure linear feedback delay, which Delay's own
// equivalent regression test exploits to expect an exact unit-amplitude
// sample at a precomputed index), fx_echo (engine_fx.c) also runs the
// tapped signal through a one-pole lowpass ("darken the loop") and a tanh
// soft-saturator before mixing it back in, and wobbles the read position
// with a slow wow/flutter LFO (+/- ~0.004*sampleRate samples) — so an
// echoed impulse does not reappear as an exact amplitude at one precise
// sample index the way Delay's does. What IS still exactly true: the ring
// starts zero-filled (fx_alloc_ring calloc's it) and, with Feedback=0, the
// impulse is the only nonzero value ever written into it — so any output
// sample read back before the ring's wobbling tap sweeps near that one
// entry must be exactly zero. That "silence, then audible energy" window
// is coarser than an exact-sample check but still precise enough to tell
// "ring sized to the real rate" apart from "ring stuck at a smaller, wrong
// cap": the two place the echoed impulse in windows tens of thousands of
// samples apart — far outside the few-hundred-sample smearing the
// LFO/lowpass introduce.
struct EchoImpulseResult {
  bool anyNonFinite = false;
  bool silentBeforeWindow = true;
  bool audibleInWindow = false;
};

// Feeds one Time=1.0/Feedback=0/Mix=1.0 impulse through `proc` for `n`
// samples and reports whether every sample before `windowStart` reads back
// exactly zero and whether any sample in [windowStart, n) is audible
// (magnitude above kAudibleThreshold).
constexpr float kAudibleThreshold = 1e-4f;

EchoImpulseResult runEchoImpulse(IAudioProcessor* proc, int32 n, int32 windowStart) {
  FakeParameterChanges changes;
  changes.add(kTimeId, 1.0);      // max delay: d approaches cap - 1 samples
  changes.add(kFeedbackId, 0.0);  // no repeats: the ring's only nonzero entry
  changes.add(kMixId, 1.0);       // fully wet: output == the echoed tap alone

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
  data.inputParameterChanges = &changes;
  CHECK(proc->process(data) == kResultOk);

  EchoImpulseResult result;
  for (int32 i = 0; i < n; ++i) {
    if (!std::isfinite(outL[i]) || !std::isfinite(outR[i])) result.anyNonFinite = true;
    const bool audible =
        std::fabs(outL[i]) > kAudibleThreshold || std::fabs(outR[i]) > kAudibleThreshold;
    if (i < windowStart && audible) result.silentBeforeWindow = false;
    if (i >= windowStart && audible) result.audibleInWindow = true;
  }
  return result;
}

// Regression test for the fixed-cap bug this wrapper used to have: a fixed
// 48000-sample ring meant the "Time" parameter's max delay (normalized 1.0)
// was only actually 1 s at exactly 48 kHz — at 96 kHz it was capped to 0.5 s
// of real audio time instead, since fx_echo's d = p[0] * (cap - 1) maps
// directly onto whatever cap this wrapper hands it (engine_fx.c).
// setupProcessing() now sizes the ring to the real negotiated rate instead
// (mirrors reverb/processor.cpp's fix), so at 96 kHz the echoed impulse
// must land near the ring's true end (cap-1, ~95999), not near the pre-fix
// fixed cap's end (~47999) — a window (kOldBugWindowEnd) chosen squarely
// between the two so the pre-fix cap's echo falls outside the "silent
// before" region and this test fails against the old code.
static void test_echo_stays_correct_at_96khz() {
  std::printf("test_echo_stays_correct_at_96khz\n");
  Processor processor;
  CHECK(processor.initialize(nullptr) == kResultOk);
  IAudioProcessor* proc = nullptr;
  CHECK(processor.queryInterface(IAudioProcessor::iid, (void**)&proc) == kResultOk);

  ProcessSetup setup;
  setup.processMode = kRealtime;
  setup.symbolicSampleSize = kSample32;
  setup.maxSamplesPerBlock = 96000;
  setup.sampleRate = 96000.0;
  CHECK(proc->setupProcessing(setup) == kResultOk);

  // The actual invariant this regression guards: the ring must be sized to
  // the real 96 kHz sample rate, not a fixed 48000 — checking only "nonzero,
  // finite output" would not have caught the pre-fix bug, since a ring
  // capped at 48000 still produces nonzero, finite output (just with the
  // wrong delay time).
  const int cap = processor.ringCapacityForTesting();
  CHECK(cap >= 96000);

  CHECK(processor.setActive(true) == kResultOk);

  // Squarely between the pre-fix cap's echo window (~47999, +/- a few
  // hundred for wow/flutter) and the correct 96 kHz cap's echo window
  // (~95999, +/- a few hundred) — either bug regresses this to fail.
  constexpr int32 kOldBugWindowEnd = 70000;
  const EchoImpulseResult result = runEchoImpulse(proc, cap, kOldBugWindowEnd);
  CHECK(!result.anyNonFinite);
  CHECK(result.silentBeforeWindow);
  CHECK(result.audibleInWindow);

  processor.terminate();
}

// Regression test for the free/reallocate branch inside setupProcessing()
// itself (processor.cpp's `if (newCap != cap_)` block) — the Echo/Delay-
// specific risk its own code comment calls out: unlike Reverb (one buffer,
// delay[0][0]), Echo's fx_stereo_ring_prepare allocates one ring PER
// CHANNEL, so both delay[0][0] and delay[0][1] must be freed on a
// sample-rate change or [1] leaks silently. Every other test in this file
// (and the golden-parity harness, which creates a fresh Processor per swept
// rate) only ever calls setupProcessing() once per instance, so that branch
// — with real, non-NULL buffers to free — was previously never exercised.
// This test calls it twice on the SAME instance and confirms both that the
// cap actually grows and that the plugin still produces a correctly-timed
// echo (not just "didn't crash") after the reallocation — a stale cap_ left
// over from the first call (the classic version of this bug) would place
// the second echo in the wrong window entirely.
static void test_setupProcessing_reallocates_ring_on_rate_change() {
  std::printf("test_setupProcessing_reallocates_ring_on_rate_change\n");
  Processor processor;
  CHECK(processor.initialize(nullptr) == kResultOk);
  IAudioProcessor* proc = nullptr;
  CHECK(processor.queryInterface(IAudioProcessor::iid, (void**)&proc) == kResultOk);

  ProcessSetup setup44k;
  setup44k.processMode = kRealtime;
  setup44k.symbolicSampleSize = kSample32;
  setup44k.maxSamplesPerBlock = 44100;
  setup44k.sampleRate = 44100.0;
  CHECK(proc->setupProcessing(setup44k) == kResultOk);
  const int cap44k = processor.ringCapacityForTesting();
  CHECK(cap44k == Processor::computeRingCapacity(44100.0));

  CHECK(processor.setActive(true) == kResultOk);
  // Margin comfortably above the ~176-sample (0.004 * 44100) wow/flutter
  // depth, so the echo's smear can't leak past the window boundary.
  const EchoImpulseResult result44k = runEchoImpulse(proc, cap44k, cap44k - 5000);
  CHECK(!result44k.anyNonFinite);
  CHECK(result44k.silentBeforeWindow);
  CHECK(result44k.audibleInWindow);
  CHECK(processor.setActive(false) == kResultOk);

  // Same Processor, same fx_ — this setupProcessing() call must free the
  // 44.1 kHz-sized rings (both channels) and reallocate at the new,
  // larger 96 kHz size. A dropped delay[0][1] free here would leak, not
  // crash, so only the assertions below (not a memory error) would ever
  // catch a regression without running under ASan.
  ProcessSetup setup96k;
  setup96k.processMode = kRealtime;
  setup96k.symbolicSampleSize = kSample32;
  setup96k.maxSamplesPerBlock = 96000;
  setup96k.sampleRate = 96000.0;
  CHECK(proc->setupProcessing(setup96k) == kResultOk);
  const int cap96k = processor.ringCapacityForTesting();
  CHECK(cap96k == Processor::computeRingCapacity(96000.0));
  CHECK(cap96k > cap44k);

  CHECK(processor.setActive(true) == kResultOk);
  // Margin comfortably above the ~384-sample (0.004 * 96000) wow/flutter
  // depth. If cap_ had stayed stuck at the 44.1 kHz size (the reallocation
  // bug this test targets), the echo would land far outside this window
  // (near cap44k-1, well below cap96k - 5000).
  const EchoImpulseResult result96k = runEchoImpulse(proc, cap96k, cap96k - 5000);
  CHECK(!result96k.anyNonFinite);
  CHECK(result96k.silentBeforeWindow);
  CHECK(result96k.audibleInWindow);

  processor.terminate();
}

int main() {
  test_processor_defaults_match_engine();
  test_processor_param_round_trip();
  test_processor_set_state_restores_params();
  test_controller_registers_params_with_defaults();
  test_controller_syncs_from_component_state();
  test_echo_stays_correct_at_96khz();
  test_setupProcessing_reallocates_ring_on_rate_change();
  if (g_failures == 0) {
    std::printf("ALL PASSED\n");
    return 0;
  }
  std::printf("%d FAILURE(S)\n", g_failures);
  return 1;
}
