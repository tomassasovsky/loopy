/*
 * test_filter_parity.cpp — golden-parity suite entry point for "Loopy
 * Filter" (see host_harness.h for the full rationale). Links
 * filter/factory.cpp, filter/processor.cpp, filter/controller.cpp directly
 * (this plugin's GetPluginFactory() is a plain global C++ function once
 * linked in — no dlopen needed) plus engine_fx.c/plugin_disabled.c for the
 * direct fx_apply_chain comparison path and the link-seam stub (D-LINK).
 *
 * Reuses part 6's generalized harness unchanged — Filter is also a 2-param
 * effect, no further widening needed.
 */
#include "host_harness.h"
#include "ids.h"
#include "processor.h"

// Defined by filter/factory.cpp's BEGIN_FACTORY macro at global scope.
Steinberg::IPluginFactory* GetPluginFactory();

int main() {
  using loopy_vst3_test::ParamCombo;
  using loopy_vst3_test::ParamSpec;
  using loopy_vst3_test::ParityConfig;

  ParityConfig config;
  config.pluginName = "Loopy Filter";
  config.getFactory = &GetPluginFactory;
  config.fxType = LE_FX_FILTER;
  config.paramCount = 2;
  config.params[0] = ParamSpec{loopy_vst3_filter::kCutoffId, "Cutoff"};
  config.params[1] = ParamSpec{loopy_vst3_filter::kResonanceId, "Resonance"};
  config.combos[0] = ParamCombo{"default", {0.5f, 0.2f}};
  config.combos[1] = ParamCombo{"min", {0.0f, 0.0f}};
  config.combos[2] = ParamCombo{"max", {1.0f, 1.0f}};
  config.combos[3] = ParamCombo{"mixed1", {0.75f, 0.6f}};
  config.combos[4] = ParamCombo{"mixed2", {0.15f, 0.85f}};
  // LE_FX_FILTER has a NULL `prepare` vtable entry (engine_fx.c) — no ring
  // to size, and `cap` is never read by fx_filter_process either (marked
  // `(void)cap`) — so any value here is equally correct; 0 makes that
  // explicit rather than implying a real capacity computation exists.
  config.computeCap = [](double) -> int { return 0; };

  const int failures = loopy_vst3_test::runParityTests(config);
  return failures == 0 ? 0 : 1;
}
