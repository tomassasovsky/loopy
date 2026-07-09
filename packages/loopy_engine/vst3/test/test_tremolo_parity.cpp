/*
 * test_tremolo_parity.cpp — golden-parity suite entry point for "Loopy
 * Tremolo" (see host_harness.h for the full rationale). Links
 * tremolo/factory.cpp, tremolo/processor.cpp, tremolo/controller.cpp
 * directly (this plugin's GetPluginFactory() is a plain global C++ function
 * once linked in — no dlopen needed) plus engine_fx.c/plugin_disabled.c for
 * the direct fx_apply_chain comparison path and the link-seam stub
 * (D-LINK).
 *
 * Reuses part 6's generalized harness unchanged — Tremolo is also a
 * 2-param effect. The min ("rate=0.0", 0.1 Hz) and max ("rate=1.0", 12 Hz)
 * combos below double as this part's slow-vs-fast Rate check (the plan's
 * specific LFO block-boundary-phase concern): the harness already sweeps
 * every combo across three block-size regimes (4096 one-shot, 64 regular,
 * 61 irregular-final-block), so the slowest and fastest LFO rates both get
 * exercised at every block boundary, not just a hand-picked extra case.
 */
#include "host_harness.h"
#include "ids.h"
#include "processor.h"

// Defined by tremolo/factory.cpp's BEGIN_FACTORY macro at global scope.
Steinberg::IPluginFactory* GetPluginFactory();

int main() {
  using loopy_vst3_test::ParamCombo;
  using loopy_vst3_test::ParamSpec;
  using loopy_vst3_test::ParityConfig;

  ParityConfig config;
  config.pluginName = "Loopy Tremolo";
  config.getFactory = &GetPluginFactory;
  config.fxType = LE_FX_TREMOLO;
  config.paramCount = 2;
  config.params[0] = ParamSpec{loopy_vst3_tremolo::kRateId, "Rate"};
  config.params[1] = ParamSpec{loopy_vst3_tremolo::kDepthId, "Depth"};
  config.combos[0] = ParamCombo{"default", {0.3f, 0.7f}};
  config.combos[1] = ParamCombo{"min", {0.0f, 0.0f}};   // slowest LFO: 0.1 Hz
  config.combos[2] = ParamCombo{"max", {1.0f, 1.0f}};   // fastest LFO: 12 Hz
  config.combos[3] = ParamCombo{"mixed1", {0.85f, 0.2f}};
  config.combos[4] = ParamCombo{"mixed2", {0.1f, 0.9f}};
  // LE_FX_TREMOLO has a NULL `prepare` vtable entry (engine_fx.c) — no ring
  // to size, and `cap` is never read by fx_tremolo_process either (marked
  // `(void)cap`) — so any value here is equally correct; 0 makes that
  // explicit rather than implying a real capacity computation exists.
  config.computeCap = [](double) -> int { return 0; };

  const int failures = loopy_vst3_test::runParityTests(config);
  return failures == 0 ? 0 : 1;
}
