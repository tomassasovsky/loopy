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
  Steinberg::tresult PLUGIN_API setActive(Steinberg::TBool state) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API process(Steinberg::Vst::ProcessData& data) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API setState(Steinberg::IBStream* state) SMTG_OVERRIDE;
  Steinberg::tresult PLUGIN_API getState(Steinberg::IBStream* state) SMTG_OVERRIDE;

  // Fixed delay-ring capacity in samples, matching the live engine's own
  // default when no per-track override is set
  // (le_fx_prepare_entry, engine_commands.c). Not sample-rate-scaled — this
  // is a pre-existing property of fx_delay's own normalized-time mapping
  // (engine_fx.c), not something this wrapper adjusts (D-SEAM: drive the
  // existing DSP as-is, never reimplement it). Public so the golden-parity
  // harness (vst3/test/) can reference this exact constant instead of
  // re-deriving it as a duplicated literal.
  static constexpr int kDelayCapFrames = 48000;

 private:
  le_fx_state fx_{};
  int32_t types_[LE_FX_MAX] = {};
  float params_[LE_FX_MAX][LE_FX_PARAMS] = {};
};

}  // namespace loopy_vst3_delay
