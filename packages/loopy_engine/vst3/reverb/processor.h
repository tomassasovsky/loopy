/*
 * processor.h — "Loopy Reverb" VST3 audio processor.
 *
 * Wraps LE_FX_REVERB through the engine's existing public engine_fx.h seam
 * (umbrella D-SEAM): one le_fx_state, chain slot 0, driven by
 * le_fx_prepare (initialize) -> le_fx_entry_reset (setActive) ->
 * fx_apply_chain (process, per block). No reimplementation of fx_reverb —
 * this class only adapts VST3's ProcessData shape to that call. Structurally
 * identical to part 2's Delay processor (packages/loopy_engine/vst3/delay/) —
 * see that part for the proven wrapper/CMake/packaging pattern this repeats.
 */
#pragma once

#include "public.sdk/source/vst/vstaudioeffect.h"

#include "ids.h"

extern "C" {
#include "engine_fx.h"
}

namespace loopy_vst3_reverb {

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
  // (cap_'s own comment below) instead of only checking that *some*
  // non-silent output comes out — a weaker check that the pre-fix
  // fixed-48000 cap would also have passed at 96 kHz, since a partially
  // dropped comb/allpass network still produces a nonzero, finite tail.
  int ringCapacityForTesting() const { return cap_; }

  // The cap_ formula itself, exposed so callers that need to know the ring
  // size without a live Processor instance (the golden-parity harness,
  // vst3/test/) can call the exact same computation setupProcessing() uses
  // below, instead of re-deriving it as a duplicated literal formula.
  static int computeRingCapacity(double sampleRate) {
    const int cap = static_cast<int>(sampleRate + 0.5);
    return cap < 1 ? 1 : cap;
  }

 private:
  // Ring capacity in samples for the slot's single packed comb/allpass
  // buffer (delay[slot][0] — delay[slot][1] is unused by reverb), sized to
  // the ACTUAL negotiated host sample rate in setupProcessing — matching
  // engine.c's real engine (fx_delay_frames = sample_rate, "1 s of delay
  // line per slot"). A fixed constant was tried first and rejected: the
  // combined comb+allpass+spread offsets across both banks total ~25450
  // samples at 44.1 kHz but scale linearly with sample rate (fx_reverb's own
  // `scale = sr / 44100`), so a fixed 48000 cap is already exceeded above
  // ~83 kHz — a common production rate (88.2/96 kHz) — at which point
  // engine_fx.c's `if (off + len > cap) break` guard (safe, never a buffer
  // overflow) silently drops comb/allpass lines from the network, not just
  // shortening the tail. Sizing to the real sample rate avoids that
  // entirely. Defaults to 48000 before setupProcessing first runs (process()
  // is a no-op with a NULL ring either way, per fx_reverb's own guard).
  int cap_ = 48000;

  le_fx_state fx_{};
  int32_t types_[LE_FX_MAX] = {};
  float params_[LE_FX_MAX][LE_FX_PARAMS] = {};
};

}  // namespace loopy_vst3_reverb
