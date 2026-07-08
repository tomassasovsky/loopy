#include "processor.h"

#include <cstdlib>

#include "pluginterfaces/base/fstrdefs.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/vstspeaker.h"

using namespace Steinberg;
using namespace Steinberg::Vst;

namespace loopy_vst3_reverb {

Processor::Processor() { setControllerClass(kControllerUID); }

Processor::~Processor() = default;

tresult PLUGIN_API Processor::initialize(FUnknown* context) {
  tresult result = AudioEffect::initialize(context);
  if (result != kResultOk) return result;

  addAudioInput(STR16("Stereo In"), Vst::SpeakerArr::kStereo);
  addAudioOutput(STR16("Stereo Out"), Vst::SpeakerArr::kStereo);

  types_[0] = LE_FX_REVERB;
  le_fx_defaults(LE_FX_REVERB, params_[0]);
  // The ring itself is sized in setupProcessing(), once the host's real
  // sample rate is known — see processor.h's cap_ comment.
  return kResultOk;
}

tresult PLUGIN_API Processor::setupProcessing(ProcessSetup& newSetup) {
  tresult result = AudioEffect::setupProcessing(newSetup);
  if (result != kResultOk) return result;

  int newCap = static_cast<int>(processSetup.sampleRate + 0.5);
  if (newCap < 1) newCap = 1;
  if (newCap != cap_) {
    // Sample rate changed since the ring was last sized (or this is the
    // first call) — free and let le_fx_prepare below reallocate at the new
    // size. fx_alloc_ring only allocates when the pointer is NULL, so
    // without this the ring would silently stay sized to the OLD rate.
    free(fx_.delay[0][0]);
    fx_.delay[0][0] = nullptr;
    cap_ = newCap;
  }
  if (le_fx_prepare(&fx_, 0, LE_FX_REVERB, cap_) != LE_OK) return kResultFalse;
  return kResultOk;
}

tresult PLUGIN_API Processor::terminate() {
  // Reverb packs both stereo banks into delay[0][0] only (delay[0][1] is
  // never allocated for LE_FX_REVERB — engine_fx.c's fx_reverb comment).
  // le_fx_free_octaver is a defensive no-op here (its buffers are never
  // allocated for this type either), called anyway for parity with the
  // engine's own full slot-teardown pattern (engine.c's le_lane_reset /
  // le_monitor_input_reset), in case a future change ever reuses fx_ for a
  // different effect type.
  free(fx_.delay[0][0]);
  fx_.delay[0][0] = nullptr;
  le_fx_free_octaver(&fx_, 0);
  return AudioEffect::terminate();
}

tresult PLUGIN_API Processor::setActive(TBool state) {
  if (state) le_fx_entry_reset(&fx_, 0);
  return AudioEffect::setActive(state);
}

tresult PLUGIN_API Processor::process(ProcessData& data) {
  // Drain queued param changes (last point per queue wins — block-rate, not
  // sample-accurate automation; matches D-SEAM's "drive the existing DSP
  // as-is" scope for this pilot).
  if (IParameterChanges* changes = data.inputParameterChanges) {
    const int32 count = changes->getParameterCount();
    for (int32 i = 0; i < count; ++i) {
      IParamValueQueue* queue = changes->getParameterData(i);
      if (!queue) continue;
      const int32 points = queue->getPointCount();
      if (points <= 0) continue;
      int32 sampleOffset = 0;
      ParamValue value = 0.0;
      if (queue->getPoint(points - 1, sampleOffset, value) != kResultTrue) continue;
      switch (queue->getParameterId()) {
        case kSizeId: params_[0][0] = static_cast<float>(value); break;
        case kDampingId: params_[0][1] = static_cast<float>(value); break;
        case kMixId: params_[0][2] = static_cast<float>(value); break;
        default: break;
      }
    }
  }

  if (data.numSamples <= 0 || data.numInputs == 0 || data.numOutputs == 0) {
    return kResultOk;
  }

  AudioBusBuffers& in = data.inputs[0];
  AudioBusBuffers& out = data.outputs[0];
  if (in.numChannels == 0 || out.numChannels == 0 || !in.channelBuffers32 ||
      !out.channelBuffers32) {
    return kResultOk;
  }

  // initialize() declares a stereo bus, but this processor never overrides
  // setBusArrangements — the AudioEffect base accepts whatever arrangement a
  // host renegotiates for an existing bus (public.sdk/source/vst/
  // vstaudioeffect.cpp), so a host can still hand us a mono bus at process
  // time. fx_reverb reads/writes l and r together (not per-channel like
  // delay/echo) and its own doc comment guarantees a mono source (l == r)
  // still yields a decorrelated stereo tail from the bank spread alone — so
  // aliasing channel 1 onto channel 0 here preserves that exactly, the same
  // seeding convention the live engine itself relies on
  // (engine_private.h's "a mono source seeds l == r" note).
  Sample32* inL = in.channelBuffers32[0];
  Sample32* inR = in.numChannels > 1 ? in.channelBuffers32[1] : inL;
  Sample32* outL = out.channelBuffers32[0];
  Sample32* outR = out.numChannels > 1 ? out.channelBuffers32[1] : outL;

  const int sr = static_cast<int>(processSetup.sampleRate);
  for (int32 i = 0; i < data.numSamples; ++i) {
    float l = inL[i];
    float r = inR[i];
    fx_apply_chain(&fx_, sr, cap_, &l, &r, 1, types_, params_);
    outL[i] = l;
    if (outR != outL) outR[i] = r;
  }
  return kResultOk;
}

tresult PLUGIN_API Processor::setState(IBStream* state) {
  if (!state) return kInvalidArgument;
  float saved[LE_FX_PARAMS];
  const int32 n = static_cast<int32>(sizeof(saved));
  int32 read = 0;
  if (state->read(saved, n, &read) != kResultOk || read != n) return kResultFalse;
  for (int32 i = 0; i < LE_FX_PARAMS; ++i) params_[0][i] = saved[i];
  return kResultOk;
}

tresult PLUGIN_API Processor::getState(IBStream* state) {
  if (!state) return kInvalidArgument;
  int32 written = 0;
  const int32 n = static_cast<int32>(sizeof(params_[0]));
  if (state->write(params_[0], n, &written) != kResultOk || written != n) {
    return kResultFalse;
  }
  return kResultOk;
}

}  // namespace loopy_vst3_reverb
