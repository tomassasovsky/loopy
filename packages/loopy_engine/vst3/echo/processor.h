/*
 * processor.h — "Loopy Echo" VST3 audio processor.
 *
 * Wraps LE_FX_ECHO through the engine's existing public engine_fx.h seam
 * (umbrella D-SEAM): one le_fx_state, chain slot 0, driven by
 * le_fx_prepare (initialize) -> le_fx_entry_reset (setActive) ->
 * fx_apply_chain (process, per block). No reimplementation of fx_echo —
 * this class only adapts VST3's ProcessData shape to that call.
 */
#pragma once

#include "public.sdk/source/vst/vstaudioeffect.h"

#include "ids.h"

extern "C" {
#include "engine_fx.h"
}

namespace loopy_vst3_echo {

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

  // Fixed delay-ring capacity in samples — Echo shares the same underlying
  // delay-ring mechanism (fx->delay[slot][chan]) and normalized-time mapping
  // as Delay (engine_fx.c's fx_echo/fx_delay). Delay and Reverb have since
  // moved to a sample-rate-scaled ring (delay/processor.h's and
  // reverb/processor.h's computeRingCapacity) — Echo has the identical
  // fixed-cap bug (max delay time only equals 1 s at exactly 48 kHz) but is
  // intentionally not fixed here; it's tracked separately (see the
  // 2026-07-13 fix-delay-vst3-samplerate-scaled-ring plan's Technical
  // Considerations, which calls out Echo as out of scope for that fix).
  // Public so the golden-parity harness (vst3/test/) can reference this
  // exact constant instead of re-deriving it as a duplicated literal.
  static constexpr int kEchoCapFrames = 48000;

 private:
  le_fx_state fx_{};
  int32_t types_[LE_FX_MAX] = {};
  float params_[LE_FX_MAX][LE_FX_PARAMS] = {};
};

}  // namespace loopy_vst3_echo
