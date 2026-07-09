#include "controller.h"

#include "ids.h"
#include "pluginterfaces/base/fstrdefs.h"
#include "pluginterfaces/base/ibstream.h"

extern "C" {
#include "engine_fx.h"
}

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace loopy_vst3_octaver {

tresult PLUGIN_API Controller::initialize(FUnknown* context) {
  tresult result = EditController::initialize(context);
  if (result != kResultOk) return result;

  float defaults[LE_FX_PARAMS];
  le_fx_defaults(LE_FX_OCTAVER, defaults);

  // min=0/max=1 is not an arbitrary placeholder range — it is the identity
  // mapping onto engine_fx.c's own normalized-param convention (umbrella
  // D-PARAM), the same convention Loopy's own UI sliders already use.
  parameters.addParameter(
      new RangeParameter(STR16("Shift"), kShiftId, nullptr, 0., 1., defaults[0]));
  parameters.addParameter(
      new RangeParameter(STR16("Tone"), kToneId, nullptr, 0., 1., defaults[1]));
  parameters.addParameter(
      new RangeParameter(STR16("Mix"), kMixId, nullptr, 0., 1., defaults[2]));

  // Mode is the one deviation from this series' otherwise-uniform
  // RangeParameter pattern (documented in controller.h). fx_octaver treats
  // p[3] as a hard binary switch (`requested = p[3] >= 0.5f ? 1 : 0`,
  // engine_fx.c) with exactly two states, so a StringListParameter gives
  // Ableton's generic parameter list readable labels instead of a bare 0/1
  // slider — a materially better host UI for a genuinely discrete control,
  // with no cost to the plain-value agreement: two appendString() calls set
  // stepCount to 1, so toPlain/toNormalized round-trip through the same
  // 0..1-normalized / 0..1-plain space every other parameter (and every
  // other plugin's wire format) already uses — index 0 <-> plain 0.0
  // <-> normalized 0.0, index 1 <-> plain 1.0 <-> normalized 1.0.
  // StringListParameter::toPlain splits [0,1) at the normalized midpoint
  // (futils.h's FromNormalized: floor(norm*(stepCount+1)), clamped to
  // stepCount) — for stepCount=1 that boundary is exactly 0.5, matching
  // fx_octaver's own `p[3] >= 0.5f ? 1 : 0` threshold. StringListParameter's
  // constructor hardcodes defaultNormalizedValue to 0 (index 0, "Phase
  // Vocoder") — which already matches defaults[3] (fx_octaver_defaults'
  // mode = 0.0), so no extra default-value wiring is needed here.
  auto* modeParam = new StringListParameter(STR16("Mode"), kModeId);
  modeParam->appendString(STR16("Phase Vocoder"));
  modeParam->appendString(STR16("PSOLA"));
  parameters.addParameter(modeParam);

  return kResultOk;
}

tresult PLUGIN_API Controller::setComponentState(IBStream* state) {
  if (!state) return kInvalidArgument;
  // Same wire format Processor::getState writes (LE_FX_PARAMS raw floats,
  // already in the 0..1 normalized convention every parameter shares,
  // Mode's StringListParameter included — see controller.cpp's initialize()
  // comment). No plain<->normalized conversion needed here.
  float saved[LE_FX_PARAMS];
  const int32 n = static_cast<int32>(sizeof(saved));
  int32 read = 0;
  if (state->read(saved, n, &read) != kResultOk || read != n) return kResultFalse;
  setParamNormalized(kShiftId, saved[0]);
  setParamNormalized(kToneId, saved[1]);
  setParamNormalized(kMixId, saved[2]);
  setParamNormalized(kModeId, saved[3]);
  return kResultOk;
}

}  // namespace loopy_vst3_octaver
