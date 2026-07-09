/*
 * controller.h — "Loopy Octaver" VST3 edit controller.
 *
 * No custom editor (umbrella D-NOGUI): registers ParameterInfo only, and
 * relies on the host's generic auto-generated parameter list. One deviation
 * from the otherwise-uniform RangeParameter pattern: Mode is a genuinely
 * discrete 2-way selector (phase vocoder / PSOLA — engine_fx.c's fx_octaver
 * `requested = p[3] >= 0.5f ? 1 : 0`), so it is registered as a
 * StringListParameter instead, giving Ableton's generic parameter list
 * readable "Phase Vocoder"/"PSOLA" labels rather than a bare 0..1 slider.
 * See controller.cpp for why this is compatible with the same plain-value
 * wire format every other parameter (and every other plugin) shares.
 */
#pragma once

#include "public.sdk/source/vst/vsteditcontroller.h"

namespace loopy_vst3_octaver {

class Controller : public Steinberg::Vst::EditController {
 public:
  static Steinberg::FUnknown* createInstance(void*) {
    return static_cast<Steinberg::Vst::IEditController*>(new Controller());
  }

  Steinberg::tresult PLUGIN_API initialize(Steinberg::FUnknown* context) SMTG_OVERRIDE;

  // Syncs the generic parameter list's displayed values from the same
  // component-state bytes Processor::getState wrote, so a reloaded project
  // shows the saved Shift/Tone/Mix/Mode immediately instead of stale
  // defaults until the user first touches a control.
  Steinberg::tresult PLUGIN_API setComponentState(Steinberg::IBStream* state) SMTG_OVERRIDE;
};

}  // namespace loopy_vst3_octaver
