/*
 * processor.h — "Loopy Octaver" VST3 audio processor.
 *
 * Wraps LE_FX_OCTAVER through the engine's existing public engine_fx.h seam
 * (umbrella D-SEAM): one le_fx_state, chain slot 0, driven by
 * le_fx_prepare (setupProcessing) -> le_fx_entry_reset (setActive) ->
 * fx_apply_chain (process, per block). No reimplementation of fx_octaver —
 * this class only adapts VST3's ProcessData shape to that call.
 *
 * Two properties set Octaver apart from every prior plugin in this series:
 *
 * 1. Sample-rate-scaled ring, like Reverb (part 3), NOT Delay/Echo's fixed
 *    cap. fx_octaver's own doc comment (engine_fx.c) states "The ring length
 *    `cap` equals the sample rate (1 s), used here as the time base for the
 *    smoothing / dip constants" — its zipper-free param smoothing and
 *    mode-switch crossfade both compute their ~5ms/~15ms time constants as
 *    `1 / (const * cap)`, assuming cap IS the sample rate. A fixed cap would
 *    silently make those time constants wrong by the sample-rate ratio at
 *    any rate other than the one the fixed constant assumed — the same
 *    class of bug part 3 fixed for Reverb, caught here by reading the
 *    kernel's own doc comment rather than assuming Delay's convention.
 * 2. Non-zero, real latency: `fx_octaver`'s phase-vocoder/PSOLA paths both
 *    report `LE_PV_N` (1024) frames via the engine's existing
 *    `le_fx_added_latency` seam (engine_fx.h) — getLatencySamples()
 *    forwards that unchanged so the host's delay compensation keeps this
 *    track aligned with others, rather than silently reporting zero.
 */
#pragma once

#include "public.sdk/source/vst/vstaudioeffect.h"

#include "ids.h"

extern "C" {
#include "engine_fx.h"
}

namespace loopy_vst3_octaver {

class Processor : public Steinberg::Vst::AudioEffect {
 public:
  Processor();
  ~Processor() SMTG_OVERRIDE;

  static Steinberg::FUnknown* createInstance(void*) {
    return static_cast<Steinberg::Vst::IAudioProcessor*>(new Processor());
  }

  Steinberg::tresult PLUGIN_API initialize(Steinberg::FUnknown* context) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API terminate() SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API setupProcessing(
      Steinberg::Vst::ProcessSetup& newSetup) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API setActive(Steinberg::TBool state) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API process(Steinberg::Vst::ProcessData& data) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API setState(Steinberg::IBStream* state) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API getState(Steinberg::IBStream* state) SMTG_OVERRIDE;
  Steinberg::uint32 PLUGIN_API getLatencySamples() SMTG_OVERRIDE;

  // Test-only: the ring capacity setupProcessing() most recently computed.
  int ringCapacityForTesting() const { return cap_; }

  // Same formula as loopy_vst3_reverb::Processor::computeRingCapacity —
  // exposed so the golden-parity harness (vst3/test/) can call the exact
  // cap this processor actually used, instead of re-deriving the formula.
  static int computeRingCapacity(double sampleRate) {
    const int cap = static_cast<int>(sampleRate + 0.5);
    return cap < 1 ? 1 : cap;
  }

 private:
  // Ring capacity in samples for the slot's per-channel FIFO
  // (fx_.delay[0][0]/[1] — unlike Reverb, Octaver allocates BOTH channels,
  // one independent FIFO per channel), sized to the actual negotiated host
  // sample rate in setupProcessing (see the class comment above for why a
  // fixed constant is wrong for this kernel specifically). Defaults to
  // 48000 before setupProcessing first runs (process() is a no-op with a
  // NULL ring either way, per fx_octaver's own guard).
  int cap_ = 48000;

  le_fx_state fx_{};
  int32_t types_[LE_FX_MAX] = {};
  float params_[LE_FX_MAX][LE_FX_PARAMS] = {};
};

}  // namespace loopy_vst3_octaver
