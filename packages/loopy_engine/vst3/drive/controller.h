/*
 * controller.h — "Loopy Drive" VST3 edit controller.
 *
 * No custom editor (umbrella D-NOGUI): registers ParameterInfo only, and
 * relies on the host's generic auto-generated parameter list.
 */
#pragma once

#include "public.sdk/source/vst/vsteditcontroller.h"

namespace loopy_vst3_drive {

class Controller : public Steinberg::Vst::EditController {
 public:
  static Steinberg::FUnknown* createInstance(void*) {
    return static_cast<Steinberg::Vst::IEditController*>(new Controller());
  }

  Steinberg::tresult PLUGIN_API initialize(Steinberg::FUnknown* context) SMTG_OVERRIDE;

  // Syncs the generic parameter list's displayed values from the same
  // component-state bytes Processor::getState wrote, so a reloaded project
  // shows the saved Drive/Level immediately instead of stale defaults until
  // the user first touches a control.
  Steinberg::tresult PLUGIN_API setComponentState(Steinberg::IBStream* state) SMTG_OVERRIDE;
};

}  // namespace loopy_vst3_drive
