/*
 * processor.h — "Loopy Delay" VST3 audio processor.
 *
 * Wraps LE_FX_DELAY through the engine's existing public engine_fx.h seam
 * (umbrella D-SEAM): one le_fx_state, chain slot 0, driven by
 * le_fx_prepare (initialize) -> le_fx_entry_reset (setActive) ->
 * fx_apply_chain (process, per block). No reimplementation of fx_delay —
 * this class only adapts VST3's ProcessData shape to that call.
 */
#pragma once

#include "public.sdk/source/vst/vstaudioeffect.h"

#include "ids.h"

extern "C" {
#include "engine_fx.h"
}

namespace loopy_vst3_delay {

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

  // Test-only: the ring capacity setupProcessing() most recently computed.
  // Lets wrapper tests assert the ring actually scales with sample rate
  // (cap_'s own comment below), the same hook Reverb's wrapper test uses
  // (reverb/processor.h, reverb/test_vst3_reverb_wrapper.cpp).
  int ringCapacityForTesting() const { return cap_; }

  // The cap_ formula itself, exposed so callers that need to know the ring
  // size without a live Processor instance (the golden-parity harness,
  // vst3/test/) can call the exact same computation setupProcessing() uses
  // below, instead of re-deriving it as a duplicated literal formula.
  // Identical formula to Reverb's own computeRingCapacity
  // (reverb/processor.h) — both plugins size their ring to "1 s of delay
  // line per slot" (engine.c's fx_delay_frames convention).
  static int computeRingCapacity(double sampleRate) {
    const int cap = static_cast<int>(sampleRate + 0.5);
    return cap < 1 ? 1 : cap;
  }

 private:
  // Ring capacity in samples for the slot's stereo delay-ring pair
  // (delay[slot][0] and delay[slot][1] — unlike Reverb, which packs both
  // stereo banks into a single delay[slot][0] buffer, Delay's
  // fx_stereo_ring_prepare allocates one full-cap ring per channel,
  // engine_fx.c), sized to the ACTUAL negotiated host sample rate in
  // setupProcessing — matching engine.c's real engine
  // (fx_delay_frames = sample_rate, "1 s of delay line per slot") and
  // Reverb's own cap_ (reverb/processor.h, which uses the identical
  // `int cap_ = 48000;` default — no public named constant there either).
  // Defaults to 48000 (the live engine's own default when no per-track
  // override is set, le_fx_prepare_entry/engine_commands.c) before
  // setupProcessing first runs (process() is a no-op with a NULL ring
  // either way, per fx_delay's own guard in engine_fx.c). That default was
  // this wrapper's original bug when it was also the fixed cap process()
  // actually used regardless of sample rate — fx_delay's normalized "Time"
  // parameter maps directly onto this cap in samples (engine_fx.c), so a
  // cap fixed at 48000 meant the same normalized value produced a
  // different delay time at every rate other than 48 kHz.
  int cap_ = 48000;

  le_fx_state fx_{};
  int32_t types_[LE_FX_MAX] = {};
  float params_[LE_FX_MAX][LE_FX_PARAMS] = {};
};

}  // namespace loopy_vst3_delay
