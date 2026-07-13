/*
 * test_octaver_parity.cpp — golden-parity suite entry point for "Loopy
 * Octaver" (see host_harness.h for the full rationale). Links
 * octaver/factory.cpp, octaver/processor.cpp, octaver/controller.cpp
 * directly (this plugin's GetPluginFactory() is a plain global C++
 * function once linked in — no dlopen needed) plus engine_fx.c/
 * plugin_disabled.c for the direct fx_apply_chain comparison path and the
 * link-seam stub (D-LINK).
 *
 * The first (and only) plugin to use all 4 of the part-6-generalized
 * harness's param slots — Shift/Tone/Mix/Mode — exercising its upper bound.
 *
 * NO offset/alignment math is needed here despite Octaver's non-zero
 * getLatencySamples() (LE_PV_N=1024): that value is host-facing metadata
 * for external delay compensation, not something that shifts what
 * IAudioProcessor::process() itself outputs — both the hosted and direct
 * paths call the exact same fx_apply_chain per sample, so they stay
 * bit-exact with no offset applied. Confirmed empirically: this suite
 * passes at the harness's existing 1e-6f tolerance with a plain
 * sample-for-sample diffCount, the same comparison every other plugin's
 * parity suite uses.
 */
#include "host_harness.h"
#include "ids.h"
#include "processor.h"

// Defined by octaver/factory.cpp's BEGIN_FACTORY macro at global scope.
Steinberg::IPluginFactory* GetPluginFactory();

int main() {
  using loopy_vst3_test::ParamCombo;
  using loopy_vst3_test::ParamSpec;
  using loopy_vst3_test::ParityConfig;

  ParityConfig config;
  config.pluginName = "Loopy Octaver";
  config.getFactory = &GetPluginFactory;
  config.fxType = LE_FX_OCTAVER;
  config.paramCount = 4;
  config.params[0] = ParamSpec{loopy_vst3_octaver::kShiftId, "Shift"};
  config.params[1] = ParamSpec{loopy_vst3_octaver::kToneId, "Tone"};
  config.params[2] = ParamSpec{loopy_vst3_octaver::kMixId, "Mix"};
  config.params[3] = ParamSpec{loopy_vst3_octaver::kModeId, "Mode"};
  // Documented default (fx_octaver_defaults): shift=0.25 (one octave down),
  // tone=0.5, mix=0.5, mode=0.0 (phase vocoder).
  config.combos[0] = ParamCombo{"default", {0.25f, 0.5f, 0.5f, 0.0f}};
  config.combos[1] = ParamCombo{"min", {0.0f, 0.0f, 0.0f, 0.0f}};
  config.combos[2] = ParamCombo{"max", {1.0f, 1.0f, 1.0f, 1.0f}};   // mode=1 -> PSOLA
  config.combos[3] = ParamCombo{"mixed1", {0.75f, 0.2f, 0.6f, 0.0f}};
  config.combos[4] = ParamCombo{"mixed2", {0.15f, 0.85f, 0.45f, 1.0f}};
  // Sample-rate-scaled, matching processor.h's cap_ (fx_octaver's own
  // smoothing/crossfade time constants assume cap == sample rate — see
  // processor.h's class comment). References the plugin's own public
  // formula rather than re-deriving it, so the two can't silently drift
  // apart.
  config.computeCap = [](double sr) -> int {
    return loopy_vst3_octaver::Processor::computeRingCapacity(sr);
  };

  const int failures = loopy_vst3_test::runParityTests(config);
  return failures == 0 ? 0 : 1;
}
