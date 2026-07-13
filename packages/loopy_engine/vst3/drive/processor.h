/*
 * processor.h — "Loopy Drive" VST3 audio processor.
 *
 * Wraps LE_FX_DRIVE through the engine's existing public engine_fx.h seam
 * (umbrella D-SEAM): one le_fx_state, chain slot 0, driven by
 * le_fx_prepare (initialize) -> le_fx_entry_reset (setActive) ->
 * fx_apply_chain (process, per block). No reimplementation of fx_drive —
 * this class only adapts VST3's ProcessData shape to that call.
 *
 * The simplest of the seven wrappers: fx_drive is a stateless soft-clip
 * (tanh saturation + trim, engine_fx.c) with no ring buffer and no per-
 * channel filter memory — its vtable row's `prepare` is NULL (engine_fx.c),
 * so le_fx_prepare is a no-op for this type, and `cap` is never read by
 * fx_drive_process/fx_apply_chain for LE_FX_DRIVE either (both mark it
 * `(void)cap`). No ring-capacity constant exists here for that reason —
 * unlike Delay/Echo/Reverb, there is nothing to size.
 */
#pragma once

#include "public.sdk/source/vst/vstaudioeffect.h"

#include "ids.h"

extern "C" {
#include "engine_fx.h"
}

namespace loopy_vst3_drive {

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

 private:
  le_fx_state fx_{};
  int32_t types_[LE_FX_MAX] = {};
  float params_[LE_FX_MAX][LE_FX_PARAMS] = {};
};

}  // namespace loopy_vst3_drive
