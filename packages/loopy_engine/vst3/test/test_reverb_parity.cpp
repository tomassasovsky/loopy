/*
 * test_reverb_parity.cpp — golden-parity suite entry point for "Loopy
 * Reverb" (see host_harness.h for the full rationale). Links
 * reverb/factory.cpp, reverb/processor.cpp, reverb/controller.cpp directly
 * (this plugin's GetPluginFactory() is a plain global C++ function once
 * linked in — no dlopen needed) plus engine_fx.c/plugin_disabled.c for the
 * direct fx_apply_chain comparison path and the link-seam stub (D-LINK).
 */
#include "host_harness.h"
#include "ids.h"
#include "processor.h"

// Defined by reverb/factory.cpp's BEGIN_FACTORY macro at global scope.
Steinberg::IPluginFactory* GetPluginFactory();

int main() {
  using loopy_vst3_test::ParamCombo;
  using loopy_vst3_test::ParamSpec;
  using loopy_vst3_test::ParityConfig;

  ParityConfig config;
  config.pluginName = "Loopy Reverb";
  config.getFactory = &GetPluginFactory;
  config.fxType = LE_FX_REVERB;
  config.params[0] = ParamSpec{loopy_vst3_reverb::kSizeId, "Size"};
  config.params[1] = ParamSpec{loopy_vst3_reverb::kDampingId, "Damping"};
  config.params[2] = ParamSpec{loopy_vst3_reverb::kMixId, "Mix"};
  config.combos[0] = ParamCombo{"default", {0.5f, 0.5f, 0.35f}};
  config.combos[1] = ParamCombo{"min", {0.0f, 0.0f, 0.0f}};
  config.combos[2] = ParamCombo{"max", {1.0f, 1.0f, 1.0f}};
  config.combos[3] = ParamCombo{"mixed1", {0.8f, 0.3f, 0.6f}};
  config.combos[4] = ParamCombo{"mixed2", {0.2f, 0.7f, 0.55f}};
  // References the plugin's own public formula (processor.h) rather than
  // re-deriving it, so the two can't silently drift apart. Scales with the
  // real negotiated sample rate (part 3's fix) — must match exactly, or a
  // cap mismatch alone would cause a spurious divergence unrelated to any
  // real bug.
  config.computeCap = &loopy_vst3_reverb::Processor::computeRingCapacity;

  const int failures = loopy_vst3_test::runParityTests(config);
  return failures == 0 ? 0 : 1;
}
