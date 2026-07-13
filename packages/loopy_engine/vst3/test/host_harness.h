/*
 * host_harness.h — golden-parity audio-diff harness (umbrella D-VALIDATE,
 * part 4 of the VST3 pilot).
 *
 * Proves the built VST3 plugins produce the SAME samples as calling
 * engine_fx.c's fx_apply_chain directly, not just "structurally similar."
 * Loads a plugin's factory (GetPluginFactory -> createInstance ->
 * IComponent::initialize/setActive -> IAudioProcessor::process, no
 * windowing, no editor, no scanning), drives it through a fixed signal
 * matrix, and diffs its output against a direct fx_apply_chain call over
 * the identical input/params. Both paths call the exact same compiled
 * fx_apply_chain with no intervening math, so this is verified to be
 * effectively bit-exact in practice (tolerance 1e-6f) — not the looser
 * 1e-4f perf_render.c's golden master-parity test uses for its structurally
 * different, legitimately noisier live-vs-offline-reconstruction
 * comparison; reusing that number here would have hidden a real
 * small-magnitude bug this harness exists to catch.
 *
 * WHY NOT the existing host/slot.cpp + host_vst3.cpp hosting stack: that
 * stack's job is loading arbitrary THIRD-PARTY plugins with a "best effort"
 * runtime contract (D-LIFE's dry-passthrough-on-failure posture, adapter
 * buffering, etc.) — it is deliberately forgiving of imperfect plugins. This
 * harness's job is the opposite: a precision diff against a known-exact
 * reference, for a plugin we wrote and control completely. Reusing the
 * hosting stack would route through machinery (the sample/block adapter,
 * the ready/not-ready state machine) that exists specifically to tolerate
 * the imprecision this harness needs to detect — the wrong tool for this
 * job, not an oversight.
 *
 * WHY NOT dlopen() the built .vst3 bundle: the DSP-parity claim this part
 * makes ("routing audio through the built .vst3 produces the same samples")
 * is about the compiled processor.cpp/engine_fx.c code path, not the bundle
 * packaging step (Info.plist, codesign, .vst3 folder layout) — that's
 * already proven separately by parts 2/3's own CMake build acceptance
 * criteria. Linking factory.cpp/processor.cpp directly into this harness
 * (per-plugin, in its own binary — see test_delay_parity.cpp /
 * test_reverb_parity.cpp) compiles and links the exact same source a
 * dlopen'd bundle would run, without adding a CMake dependency to the
 * otherwise CMake-independent run_native_tests.sh harness — though it is
 * NOT guaranteed to produce byte-identical machine code to a Release-flag
 * CMake build (this harness compiles ad hoc via run_native_tests.sh's own
 * flags, not vst3/CMakeLists.txt's), so it proves DSP-algorithm parity, not
 * bitwise-identical codegen; the 1e-6f tolerance above accommodates that
 * gap without being loose enough to hide a real bug. Two plugins'
 * factory.cpp each define a global (non-namespaced) GetPluginFactory() via
 * the SDK's BEGIN_FACTORY macro, so they cannot be linked into the same
 * binary anyway — one binary per plugin is required either way.
 *
 * KNOWN BLIND SPOT: every signal in the matrix is mono (l == r fed to both
 * channels), matching the umbrella's specific DSP-parity requirement (a
 * mono source through the stereo-bus wrapper must match engine_fx.c's own
 * mono-seeds-l-equals-r convention, engine_private.h). Because the direct
 * fx_apply_chain reference is symmetric under mono input, a channel-
 * crossing bug in the wrapper (e.g. writing L's result into the R output
 * buffer) would be invisible to the mono matrix alone — runChannelCrossCheck
 * (host_harness.cpp) closes this gap with one genuinely asymmetric
 * L-impulse/R-silence case per plugin.
 *
 * VARIABLE PARAM WIDTH (part 6): originally hardcoded to exactly 3 params
 * (fine for Delay/Reverb/Echo, parts 2/3/5). Widened here to
 * ParityConfig::paramCount (<= LE_FX_PARAMS, engine_fx.h's own per-slot
 * param-array width) so Drive/Filter/Tremolo (2 params, parts 6-8) and
 * Octaver (4 params, part 9) fit without a second widening. ParamSpec::params
 * and ParamCombo::values are sized to LE_FX_PARAMS (the true upper bound —
 * one array per engine chain slot); runHosted/runDirect (host_harness.cpp)
 * only ever read the first `paramCount` entries, so a config that leaves
 * `paramCount` at its default (below) can omit the rest without them being
 * touched.
 */
#pragma once

#include <cstdint>
// libc++'s <atomic> and <stdatomic.h> (pulled in below via engine_fx.h ->
// engine_private.h) cannot both be included in one TU before C++23 — <vector>
// transitively pulls in <atomic>, so it must come first, matching the part
// 2/3 wrapper tests' own include order (their <vector> also precedes their
// processor.h -> engine_fx.h chain).
#include <vector>

#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"

extern "C" {
#include "engine_fx.h"
}

namespace loopy_vst3_test {

// One of a plugin's user-facing params (e.g. Time/Feedback/Mix, or Drive's
// Drive/Level). ParityConfig::paramCount says how many of these (and of
// ParamCombo::values below) a given plugin actually uses.
struct ParamSpec {
  Steinberg::Vst::ParamID id;
  const char* name;
};

// One param-value combination to sweep. Sized to LE_FX_PARAMS (the engine's
// own per-slot param-array width) so every effect's widest case (Octaver, 4
// params, part 9) fits without a further widening; a plugin with fewer
// params just leaves the trailing values at their aggregate-init default of
// 0.0f, which runHosted/runDirect never read past paramCount anyway.
struct ParamCombo {
  const char* label;
  float values[LE_FX_PARAMS];
};

// Computes the ring capacity (samples) the plugin under test allocates for a
// given sample rate — Delay uses a fixed 48000 regardless of sr
// (loopy_vst3_delay::Processor::kDelayCapFrames); Reverb scales with sr
// (loopy_vst3_reverb::Processor::computeRingCapacity, part 3's fix). Passed
// in so this harness's direct fx_apply_chain comparison uses the exact cap
// the hosted path actually used — a cap mismatch would itself cause a
// spurious divergence unrelated to any real bug. Each ParityConfig sources
// this from the plugin's own processor.h rather than re-deriving the
// formula, so the two can't silently drift apart.
using CapFn = int (*)(double sampleRate);

// Configuration for one plugin's parity suite. Exactly 5 combos: default,
// all-min, all-max, and two distinct asymmetric ("mixed") combos — two, not
// one, because a param-index-swap bug only shows up when the swapped
// params' values actually differ, and a single hand-picked asymmetric row
// makes that coverage depend entirely on that one row never becoming
// symmetric by accident.
struct ParityConfig {
  const char* pluginName;
  Steinberg::IPluginFactory* (*getFactory)();
  int32_t fxType;  // LE_FX_DELAY, LE_FX_REVERB, LE_FX_ECHO, LE_FX_DRIVE, ...
  // Defaults to 3 (the width every ParityConfig used before this field
  // existed) so test_delay_parity.cpp/test_reverb_parity.cpp/
  // test_echo_parity.cpp (parts 2, 3, 5) — which never set this field —
  // keep compiling and passing unmodified against this widened harness, the
  // part 6 regression gate proving the widening is behavior-preserving.
  // Every new plugin (2 or 4 params) must set this explicitly.
  int paramCount = 3;
  ParamSpec params[LE_FX_PARAMS];
  ParamCombo combos[5];
  CapFn computeCap;
};

// Runs the full parity matrix (signal types x sample rates x param combos x
// block-size modes) plus the channel-crossing check (see the "KNOWN BLIND
// SPOT" note above) for one plugin, printing CHECK-style failure lines.
// Returns the failure count (0 = every case matched within tolerance).
int runParityTests(const ParityConfig& config);

}  // namespace loopy_vst3_test
