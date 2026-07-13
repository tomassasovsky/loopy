/*
 * test_drive_parity.cpp — golden-parity suite entry point for "Loopy Drive"
 * (see host_harness.h for the full rationale). Links drive/factory.cpp,
 * drive/processor.cpp, drive/controller.cpp directly (this plugin's
 * GetPluginFactory() is a plain global C++ function once linked in — no
 * dlopen needed) plus engine_fx.c/plugin_disabled.c for the direct
 * fx_apply_chain comparison path and the link-seam stub (D-LINK).
 *
 * First plugin to exercise the widened (part 6) harness: paramCount=2, one
 * fewer than the fixed-3 shape parts 2/3/5 used.
 */
#include "host_harness.h"
#include "ids.h"
#include "processor.h"

// Defined by drive/factory.cpp's BEGIN_FACTORY macro at global scope.
Steinberg::IPluginFactory* GetPluginFactory();

int main() {
  using loopy_vst3_test::ParamCombo;
  using loopy_vst3_test::ParamSpec;
  using loopy_vst3_test::ParityConfig;

  ParityConfig config;
  config.pluginName = "Loopy Drive";
  config.getFactory = &GetPluginFactory;
  config.fxType = LE_FX_DRIVE;
  config.paramCount = 2;
  config.params[0] = ParamSpec{loopy_vst3_drive::kDriveId, "Drive"};
  config.params[1] = ParamSpec{loopy_vst3_drive::kLevelId, "Level"};
  config.combos[0] = ParamCombo{"default", {0.5f, 0.8f}};
  config.combos[1] = ParamCombo{"min", {0.0f, 0.0f}};
  config.combos[2] = ParamCombo{"max", {1.0f, 1.0f}};
  config.combos[3] = ParamCombo{"mixed1", {0.75f, 0.2f}};
  config.combos[4] = ParamCombo{"mixed2", {0.15f, 0.85f}};
  // LE_FX_DRIVE has a NULL `prepare` vtable entry (engine_fx.c) — no ring to
  // size, and `cap` is never read by fx_drive_process either (marked
  // `(void)cap`) — so any value here is equally correct; 0 makes that
  // explicit rather than implying a real capacity computation exists.
  config.computeCap = [](double) -> int { return 0; };

  const int failures = loopy_vst3_test::runParityTests(config);
  return failures == 0 ? 0 : 1;
}
