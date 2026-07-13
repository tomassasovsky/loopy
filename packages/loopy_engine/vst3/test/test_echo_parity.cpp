/*
 * test_echo_parity.cpp — golden-parity suite entry point for "Loopy Echo"
 * (see host_harness.h for the full rationale). Links echo/factory.cpp,
 * echo/processor.cpp, echo/controller.cpp directly (this plugin's
 * GetPluginFactory() is a plain global C++ function once linked in — no
 * dlopen needed) plus engine_fx.c/plugin_disabled.c for the direct
 * fx_apply_chain comparison path and the link-seam stub (D-LINK).
 */
#include "host_harness.h"
#include "ids.h"
#include "processor.h"

// Defined by echo/factory.cpp's BEGIN_FACTORY macro at global scope.
Steinberg::IPluginFactory* GetPluginFactory();

int main() {
  using loopy_vst3_test::ParamCombo;
  using loopy_vst3_test::ParamSpec;
  using loopy_vst3_test::ParityConfig;

  ParityConfig config;
  config.pluginName = "Loopy Echo";
  config.getFactory = &GetPluginFactory;
  config.fxType = LE_FX_ECHO;
  config.params[0] = ParamSpec{loopy_vst3_echo::kTimeId, "Time"};
  config.params[1] = ParamSpec{loopy_vst3_echo::kFeedbackId, "Feedback"};
  config.params[2] = ParamSpec{loopy_vst3_echo::kMixId, "Mix"};
  config.combos[0] = ParamCombo{"default", {0.45f, 0.5f, 0.35f}};
  config.combos[1] = ParamCombo{"min", {0.0f, 0.0f, 0.0f}};
  config.combos[2] = ParamCombo{"max", {1.0f, 1.0f, 1.0f}};
  config.combos[3] = ParamCombo{"mixed1", {0.75f, 0.2f, 0.6f}};
  config.combos[4] = ParamCombo{"mixed2", {0.15f, 0.85f, 0.45f}};
  // References the plugin's own public constant (processor.h) rather than
  // re-deriving the literal, so the two can't silently drift apart. Fixed
  // regardless of sample rate, matching Delay's ring sizing (Echo shares the
  // same underlying delay-ring mechanism).
  config.computeCap = [](double) -> int {
    return loopy_vst3_echo::Processor::kEchoCapFrames;
  };

  const int failures = loopy_vst3_test::runParityTests(config);
  return failures == 0 ? 0 : 1;
}
