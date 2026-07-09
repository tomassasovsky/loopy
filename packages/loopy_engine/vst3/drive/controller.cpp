#include "controller.h"

#include "ids.h"
#include "pluginterfaces/base/fstrdefs.h"
#include "pluginterfaces/base/ibstream.h"

extern "C" {
#include "engine_fx.h"
}

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace loopy_vst3_drive {

tresult PLUGIN_API Controller::initialize(FUnknown* context) {
  tresult result = EditController::initialize(context);
  if (result != kResultOk) return result;

  float defaults[LE_FX_PARAMS];
  le_fx_defaults(LE_FX_DRIVE, defaults);

  // min=0/max=1 is not an arbitrary placeholder range — it is the identity
  // mapping onto engine_fx.c's own normalized-param convention (umbrella
  // D-PARAM), the same convention Loopy's own UI sliders already use.
  parameters.addParameter(
      new RangeParameter(STR16("Drive"), kDriveId, nullptr, 0., 1., defaults[0]));
  parameters.addParameter(
      new RangeParameter(STR16("Level"), kLevelId, nullptr, 0., 1., defaults[1]));

  return kResultOk;
}

tresult PLUGIN_API Controller::setComponentState(IBStream* state) {
  if (!state) return kInvalidArgument;
  // Same wire format Processor::getState writes (LE_FX_PARAMS raw floats,
  // already in the 0..1 normalized convention both sides share — no
  // plain<->normalized conversion needed here).
  float saved[LE_FX_PARAMS];
  const int32 n = static_cast<int32>(sizeof(saved));
  int32 read = 0;
  if (state->read(saved, n, &read) != kResultOk || read != n) return kResultFalse;
  setParamNormalized(kDriveId, saved[0]);
  setParamNormalized(kLevelId, saved[1]);
  return kResultOk;
}

}  // namespace loopy_vst3_drive
