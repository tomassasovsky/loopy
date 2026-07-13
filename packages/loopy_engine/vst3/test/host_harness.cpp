#include "host_harness.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "fake_parameter_changes.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace loopy_vst3_test {

namespace {

// Tolerance for the main matrix and the channel-cross check: both the
// hosted and direct paths call the exact same compiled fx_apply_chain with
// no intervening math, verified effectively bit-exact in practice — see
// host_harness.h's rationale comment for why this is far tighter than
// perf_render.c's 1e-4f (a structurally different comparison).
constexpr float kTolerance = 1e-6f;

// ---- fixed test-signal generators ------------------------------------------
// Mono (l == r fed to both channels) — the umbrella's own DSP-parity
// requirement is specifically that a mono source through the stereo-bus
// wrapper matches engine_fx.c's mono-seeds-l-equals-r convention
// (engine_private.h), so every signal here exercises exactly that. The
// separate channel-crossing check below (runChannelCrossCheck) covers what
// a mono-only matrix structurally can't (see host_harness.h).

void genSilence(std::vector<float>& out, int n, double) { out.assign(n, 0.0f); }

void genImpulse(std::vector<float>& out, int n, double) {
  out.assign(n, 0.0f);
  if (n > 0) out[0] = 1.0f;
}

void genLogSweep(std::vector<float>& out, int n, double sr) {
  out.resize(n);
  const double f0 = 20.0;
  const double f1 = sr * 0.45;  // just under Nyquist
  const double total = n / sr;
  double phase = 0.0;
  for (int i = 0; i < n; ++i) {
    const double t = i / sr;
    const double freq = f0 * std::pow(f1 / f0, total > 0.0 ? t / total : 0.0);
    phase += 2.0 * M_PI * freq / sr;
    out[i] = static_cast<float>(std::sin(phase)) * 0.5f;
  }
}

void genWhiteNoise(std::vector<float>& out, int n, double) {
  out.resize(n);
  // Fixed seed: deterministic and reproducible across runs/platforms (a
  // real RNG isn't needed — just a decorrelated, non-periodic-sounding
  // signal), matching this suite's need for byte-for-byte repeatability.
  uint32_t state = 0x1234567u;
  for (int i = 0; i < n; ++i) {
    state = state * 1664525u + 1013904223u;  // classic LCG
    const float u = static_cast<float>(state >> 8) / static_cast<float>(1u << 24);
    out[i] = (u * 2.0f - 1.0f) * 0.5f;
  }
}

struct NamedSignal {
  const char* name;
  void (*generate)(std::vector<float>&, int, double);
};

const NamedSignal kSignals[] = {
    {"silence", genSilence},
    {"impulse", genImpulse},
    {"logsweep", genLogSweep},
    {"whitenoise", genWhiteNoise},
};

// Drives separate `inL`/`inR` signals through the VST3-hosted processor,
// split into `blockSize`-sample process() calls — the processor's internal
// DSP state must persist correctly across calls, the same guarantee a real
// host's block-based callback relies on (including an irregular final
// block when blockSize doesn't evenly divide the signal length). The param
// combo is queued once, on the first block only (matching how a host would
// apply a static, non-automated param set for an offline render).
bool runHosted(IPluginFactory* factory, const char* processorCid,
              const ParamSpec params[3], const ParamCombo& combo, double sr,
              const std::vector<float>& inLSignal, const std::vector<float>& inRSignal,
              int blockSize, std::vector<float>& outL, std::vector<float>& outR) {
  FUnknown* unk = nullptr;
  if (factory->createInstance(processorCid, IAudioProcessor::iid, (void**)&unk) !=
          kResultOk ||
      !unk) {
    return false;
  }
  IComponent* component = nullptr;
  IAudioProcessor* proc = nullptr;
  unk->queryInterface(IComponent::iid, (void**)&component);
  unk->queryInterface(IAudioProcessor::iid, (void**)&proc);
  if (!component || !proc) {
    if (component) component->release();
    if (proc) proc->release();
    unk->release();
    return false;
  }

  const bool initialized = component->initialize(nullptr) == kResultOk;

  ProcessSetup setup;
  setup.processMode = kRealtime;
  setup.symbolicSampleSize = kSample32;
  setup.maxSamplesPerBlock = blockSize;
  setup.sampleRate = sr;
  const bool setup_ok = initialized && proc->setupProcessing(setup) == kResultOk;
  const bool active = setup_ok && component->setActive(true) == kResultOk;

  bool ok = active;
  if (ok) {
    const int n = static_cast<int>(inLSignal.size());
    outL.assign(n, 0.0f);
    outR.assign(n, 0.0f);

    FakeParameterChanges changes;
    changes.add(params[0].id, combo.values[0]);
    changes.add(params[1].id, combo.values[1]);
    changes.add(params[2].id, combo.values[2]);

    int pos = 0;
    bool first = true;
    while (ok && pos < n) {
      const int thisBlock = std::min(blockSize, n - pos);
      std::vector<float> inL(inLSignal.begin() + pos, inLSignal.begin() + pos + thisBlock);
      std::vector<float> inR(inRSignal.begin() + pos, inRSignal.begin() + pos + thisBlock);
      std::vector<float> bufOutL(thisBlock, 0.0f), bufOutR(thisBlock, 0.0f);
      float* inChans[2] = {inL.data(), inR.data()};
      float* outChans[2] = {bufOutL.data(), bufOutR.data()};
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
      data.numSamples = thisBlock;
      data.numInputs = 1;
      data.numOutputs = 1;
      data.inputs = &inBus;
      data.outputs = &outBus;
      data.inputParameterChanges = first ? &changes : nullptr;

      ok = proc->process(data) == kResultOk;
      for (int i = 0; i < thisBlock; ++i) {
        outL[pos + i] = bufOutL[i];
        outR[pos + i] = bufOutR[i];
      }
      pos += thisBlock;
      first = false;
    }
  }

  // Only tear down what was actually torn up — calling setActive(false)
  // without a prior successful setActive(true), or terminate() without a
  // prior successful initialize(), would violate the VST3 IComponent state
  // machine even though today's Processor tolerates it defensively.
  if (active) component->setActive(false);
  if (initialized) component->terminate();
  // Each successful queryInterface() above addRef'd per the FUnknown/COM
  // contract, independently of unk's own reference — release all three or
  // the processor instance's refcount never reaches 0 and it leaks.
  component->release();
  proc->release();
  unk->release();
  return ok;
}

// Drives the identical signal + param combo through fx_apply_chain directly
// — the same seam the VST3 processor itself calls internally (D-SEAM) — so
// this is the ground truth the hosted path above must match. Returns false
// on allocation failure (le_fx_prepare, OOM) so the caller reports a clear
// harness-level error instead of silently comparing against a half-
// initialized (all-NULL-ring, dry-passthrough) reference.
bool runDirect(int32_t fxType, const ParamCombo& combo, int cap, double sr,
              const std::vector<float>& inLSignal, const std::vector<float>& inRSignal,
              std::vector<float>& outL, std::vector<float>& outR) {
  le_fx_state fx;
  memset(&fx, 0, sizeof(fx));
  const bool prepared = le_fx_prepare(&fx, 0, fxType, cap) == LE_OK;
  le_fx_entry_reset(&fx, 0);

  int32_t types[LE_FX_MAX] = {};
  types[0] = fxType;
  float params[LE_FX_MAX][LE_FX_PARAMS] = {};
  params[0][0] = combo.values[0];
  params[0][1] = combo.values[1];
  params[0][2] = combo.values[2];

  const int n = static_cast<int>(inLSignal.size());
  outL.assign(n, 0.0f);
  outR.assign(n, 0.0f);
  if (prepared) {
    for (int i = 0; i < n; ++i) {
      float l = inLSignal[i];
      float r = inRSignal[i];
      fx_apply_chain(&fx, static_cast<int>(sr), cap, &l, &r, 1, types, params);
      outL[i] = l;
      outR[i] = r;
    }
  }
  free(fx.delay[0][0]);
  free(fx.delay[0][1]);
  return prepared;
}

int diffCount(const std::vector<float>& hostedL, const std::vector<float>& hostedR,
             const std::vector<float>& directL, const std::vector<float>& directR) {
  int mismatches = 0;
  const int n = static_cast<int>(hostedL.size());
  for (int i = 0; i < n; ++i) {
    if (std::fabs(hostedL[i] - directL[i]) > kTolerance) mismatches++;
    if (std::fabs(hostedR[i] - directR[i]) > kTolerance) mismatches++;
  }
  return mismatches;
}

// One genuinely stereo-differentiated case (L = impulse, R = silence) per
// param combo, at one representative sample rate/block size — closes the
// mono-matrix's blind spot (host_harness.h) by making a channel-crossing
// bug in the wrapper actually observable: with mono input the direct
// reference is symmetric (directL == directR) by construction, so a
// swapped-channel bug would be invisible there.
int runChannelCrossCheck(IPluginFactory* factory, const char* processorCid,
                         const ParityConfig& config) {
  int failures = 0;
  const int n = 4096;
  std::vector<float> inL(n, 0.0f), inR(n, 0.0f);
  inL[0] = 1.0f;  // R stays silent throughout

  const double sr = 48000.0;
  const int cap = config.computeCap(sr);

  for (const auto& combo : config.combos) {
    std::vector<float> directL, directR;
    if (!runDirect(config.fxType, combo, cap, sr, inL, inR, directL, directR)) {
      std::printf("  FAIL: %s channel-cross combo=%s: direct run failed (OOM)\n",
                  config.pluginName, combo.label);
      failures++;
      continue;
    }
    std::vector<float> hostedL, hostedR;
    if (!runHosted(factory, processorCid, config.params, combo, sr, inL, inR, n,
                   hostedL, hostedR)) {
      std::printf("  FAIL: %s channel-cross combo=%s: hosted run failed\n",
                  config.pluginName, combo.label);
      failures++;
      continue;
    }
    const int mismatches = diffCount(hostedL, hostedR, directL, directR);
    if (mismatches > 0) {
      std::printf(
          "  FAIL: %s channel-cross combo=%s: %d/%d samples diverge "
          "(tolerance %g) — possible L/R channel swap\n",
          config.pluginName, combo.label, mismatches, n * 2, kTolerance);
      failures++;
    }
  }
  return failures;
}

}  // namespace

int runParityTests(const ParityConfig& config) {
  int failures = 0;

  IPluginFactory* factory = config.getFactory();
  if (!factory) {
    std::printf("  FAIL: %s: no factory\n", config.pluginName);
    return 1;
  }

  // Locate the processor (kVstAudioEffectClass) entry's class id — the
  // controller isn't needed at all here: this harness drives DSP through
  // IAudioProcessor::process() directly, not through the controller's
  // registered RangeParameters.
  const int32 classCount = factory->countClasses();
  char processorCid[16] = {};
  bool found = false;
  for (int32 i = 0; i < classCount; ++i) {
    PClassInfo info;
    if (factory->getClassInfo(i, &info) != kResultOk) continue;
    if (std::strcmp(info.category, kVstAudioEffectClass) == 0) {
      std::memcpy(processorCid, info.cid, sizeof(processorCid));
      found = true;
      break;
    }
  }
  if (!found) {
    std::printf("  FAIL: %s: no processor class in factory\n", config.pluginName);
    factory->release();
    return 1;
  }

  const int signalLen = 4096;
  // 96000 and 88200 both exceed the ~83 kHz threshold reverb/processor.h's
  // fixed-cap-vs-scaled-cap comment documents (part 3's fix); 88200 sits
  // closer to that boundary for a tighter regression margin than 96000
  // alone.
  const double sampleRates[] = {44100.0, 48000.0, 88200.0, 96000.0};
  // 4096 (one-shot), 64 (regular small-block streaming), and 61 (does NOT
  // evenly divide signalLen, so the final block is short — exercises the
  // `thisBlock = min(blockSize, n - pos)` partial-final-block path, the
  // most common real-world host block-size irregularity).
  const int blockSizes[] = {4096, 64, 61};

  for (const auto& sig : kSignals) {
    for (double sr : sampleRates) {
      std::vector<float> signal;
      sig.generate(signal, signalLen, sr);
      const int cap = config.computeCap(sr);

      for (const auto& combo : config.combos) {
        std::vector<float> directL, directR;
        if (!runDirect(config.fxType, combo, cap, sr, signal, signal, directL, directR)) {
          std::printf("  FAIL: %s %s sr=%.0f combo=%s: direct run failed (OOM)\n",
                      config.pluginName, sig.name, sr, combo.label);
          failures++;
          continue;
        }

        for (int blockSize : blockSizes) {
          std::vector<float> hostedL, hostedR;
          const bool ok = runHosted(factory, processorCid, config.params, combo,
                                    sr, signal, signal, blockSize, hostedL, hostedR);
          if (!ok) {
            std::printf(
                "  FAIL: %s %s sr=%.0f combo=%s block=%d: hosted run failed\n",
                config.pluginName, sig.name, sr, combo.label, blockSize);
            failures++;
            continue;
          }
          const int mismatches = diffCount(hostedL, hostedR, directL, directR);
          if (mismatches > 0) {
            std::printf(
                "  FAIL: %s %s sr=%.0f combo=%s block=%d: %d/%d samples "
                "diverge (tolerance %g)\n",
                config.pluginName, sig.name, sr, combo.label, blockSize,
                mismatches, signalLen * 2, kTolerance);
            failures++;
          }
        }
      }
    }
  }

  failures += runChannelCrossCheck(factory, processorCid, config);

  factory->release();
  if (failures == 0) std::printf("%s: ALL PASSED\n", config.pluginName);
  return failures;
}

}  // namespace loopy_vst3_test
