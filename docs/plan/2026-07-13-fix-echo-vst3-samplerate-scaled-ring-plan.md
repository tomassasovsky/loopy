---
title: Fix Loopy Echo VST3 delay-ring capacity to scale with host sample rate
type: fix
date: 2026-07-13
---

## Fix Loopy Echo VST3 delay-ring capacity to scale with host sample rate - Standard

## Overview

`packages/loopy_engine/vst3/echo/processor.h` hardcodes
`static constexpr int kEchoCapFrames = 48000;` and the Echo processor never
overrides `setupProcessing()`, so the delay-ring capacity is fixed at 48000
frames regardless of the host's actual negotiated sample rate. This plan
mirrors the sibling Reverb VST3 plugin's already-shipped fix for the
identical problem (`packages/loopy_engine/vst3/reverb/processor.h`/`.cpp`)
onto Echo, adapted for Echo's per-channel ring allocation (shared with
Delay's `fx_stereo_ring_prepare`, not Reverb's single packed buffer).

## Problem Statement / Motivation

`fx_echo`'s normalized "Time" parameter (`engine_fx.c`) maps directly onto
the ring's capacity in samples (same `d = p[0] * (cap - 1)` shape `fx_delay`
uses). The live engine sizes this ring to the real sample rate (`engine.c`:
`fx_delay_frames = sample_rate`, "1 s of delay line"), and Reverb's VST3
wrapper does the same for its own comb/allpass ring. Because Echo's VST3
wrapper does not, its actual max delay time only equals 1 s at exactly
48 kHz:

- At 96 kHz, `cap` stays 48000 frames = 0.5 s of *actual* audio time.
- At 44.1 kHz, `cap` stays 48000 frames = ~1.088 s of actual audio time.

This is a correctness bug: the same normalized "Time" value produces a
different echo time depending on the host's sample rate, and diverges from
both the live engine and from Reverb's own (correct) behavior at the same
sample rate.

## Proposed Solution

Mirror Reverb's structure in the Echo processor, adapted for the
per-channel ring Echo shares with Delay:

1. **`packages/loopy_engine/vst3/echo/processor.h`**
   - Add `setupProcessing(Steinberg::Vst::ProcessSetup&)` override
     declaration.
   - Add a `static int computeRingCapacity(double sampleRate)` public static
     method — same formula as Reverb's (`round(sampleRate)`, floored at 1).
   - Add `int ringCapacityForTesting() const { return cap_; }` public
     accessor.
   - Add a private `int cap_ = kEchoCapFrames;` member (default kept at
     48000, matching pre-`setupProcessing()` behavior and Reverb's own
     `cap_ = 48000` default).
   - Keep `kEchoCapFrames` (still referenced by
     `vst3/test/test_echo_parity.cpp` — do not remove it). Rewrite its doc
     comment: drop the "copies Delay's fixed sizing... D-SEAM scope" framing
     (superseded by this fix) and instead describe it as `cap_`'s
     default/initial value before `setupProcessing()` first runs, matching
     how Reverb's header frames its own `cap_ = 48000` default.

2. **`packages/loopy_engine/vst3/echo/processor.cpp`**
   - Remove the `le_fx_prepare(&fx_, 0, LE_FX_ECHO, kEchoCapFrames)` call
     from `initialize()` (keep `types_[0] = LE_FX_ECHO;` and
     `le_fx_defaults(...)` there, matching Reverb's `initialize()`).
   - Add `setupProcessing()`: call `AudioEffect::setupProcessing(newSetup)`
     first; if it fails, return its result. Compute
     `computeRingCapacity(processSetup.sampleRate)`; if it differs from
     `cap_`, free `fx_.delay[0][0]` and `fx_.delay[0][1]` (both channels —
     Echo's `fx_stereo_ring_prepare` allocates both, same as Delay, unlike
     Reverb's single-buffer `fx_reverb_prepare`) and null them, then update
     `cap_`. Call `le_fx_prepare(&fx_, 0, LE_FX_ECHO, cap_)`; return
     `kResultFalse` on failure, else `kResultOk`.
   - Replace both remaining uses of `kEchoCapFrames` in `process()` with
     `cap_`.
   - `terminate()` is unchanged (already frees both `delay[0][0]`/`[1]`).

3. **`packages/loopy_engine/vst3/echo/test_vst3_echo_wrapper.cpp` (new file)**
   - Echo currently has no wrapper test file (only `test_vst3_echo_ids.cpp`
     exists), unlike Delay/Reverb. Create one with the same baseline
     coverage those two establish, using Echo's own engine defaults
     (`fx_echo_defaults`: Time=0.45, Feedback=0.5, Mix=0.35) and param IDs
     (`kTimeId`/`kFeedbackId`/`kMixId`, `ids.h`):
     - `test_processor_defaults_match_engine`
     - `test_processor_param_round_trip` (calls a `setupProcessing48k`
       helper first, since `initialize()` no longer prepares the ring)
     - `test_processor_set_state_restores_params`
     - `test_controller_registers_params_with_defaults`
     - `test_controller_syncs_from_component_state`
   - Add `test_echo_stays_correct_at_96khz`, mirroring Delay's
     equivalently-named test (same ring-capacity formula shape as Delay,
     `round(sampleRate)`, since Echo's `fx_echo` cap check is the same shape
     as `fx_delay`'s): call `setupProcessing` with `sampleRate = 96000.0`,
     assert `processor.ringCapacityForTesting() >= 96000`, call
     `setActive(true)`, drive an impulse through `process()` with
     Time=1.0/Feedback=0/Mix=1.0, and assert the output is finite and that
     the delayed impulse lands at sample index `cap - 1` (e.g. `~95999` at
     96 kHz) — a location the pre-fix fixed-48000 cap could never reach at
     96 kHz since the ring itself would have wrapped at half that index.
   - Add `test_setupProcessing_reallocates_ring_on_rate_change`, mirroring
     Delay's test of the same name: call `setupProcessing()` at 44.1 kHz,
     verify a clean delayed tap, call `setActive(false)`, then call
     `setupProcessing()` again at 96 kHz on the *same* `Processor` instance,
     verify the cap grew and a clean delayed tap still lands correctly —
     the regression test for the free/reallocate branch (`if (newCap !=
     cap_)`) itself, including both channels being freed, which no
     single-`setupProcessing()`-call test can exercise.
   - Register in `CMakeLists.txt` via `loopy_vst3_add_wrapper_test(echo)`
     and update the adjacent "Wrapper-level tests exist only for Delay
     (part 2) and Reverb (part 3)" comment to include Echo.

4. **`packages/loopy_engine/vst3/test/test_echo_parity.cpp`**
   - Change `config.computeCap` from the lambda returning the fixed
     `loopy_vst3_echo::Processor::kEchoCapFrames` literal to
     `&loopy_vst3_echo::Processor::computeRingCapacity`, matching how
     `test_reverb_parity.cpp` wires its own `computeCap`. Update the
     adjacent comment (currently states "Fixed regardless of sample rate,
     matching Delay's ring sizing") to reflect that Echo now scales, like
     Reverb.
   - This is required, not optional: `host_harness.cpp`'s `runParityTests`
     already sweeps `{44100, 48000, 88200, 96000}` and calls
     `proc->setupProcessing(setup)` in `runHosted`. Once the hosted path's
     real cap scales with sample rate, `runDirect`'s reference call must use
     the same scaled cap (via `config.computeCap(sr)`) or the harness would
     start failing at every non-48kHz rate from a cap *mismatch* alone —
     not a real DSP bug, but a spurious divergence this plan must not
     introduce.

5. **`packages/loopy_engine/vst3/test/host_harness.h`**
   - Update the comment (lines ~107-116) describing which plugins scale
     their ring capacity with sample rate, to state that Reverb and Echo
     both scale via their own `computeRingCapacity` while Delay remains
     fixed (a separate, already-identified but not-yet-landed finding, out
     of scope here).

## Technical Considerations

- **Safety of the NULL-ring window before first `setupProcessing()`:**
  `fx_echo` (`engine_fx.c`) already guards `if (buf == NULL || cap <= 1)
  return x;` — a safe dry passthrough. This is the exact same guard
  structure `fx_reverb` relies on in the identical window, so moving Echo's
  `le_fx_prepare` call out of `initialize()` is safe by inspection, not a
  new risk.
- **Both channels must be freed on cap change**, unlike Reverb (which only
  uses `delay[slot][0]`). Echo's `fx_stereo_ring_prepare` allocates
  `delay[slot][0]` AND `delay[slot][1]` (confirmed:
  `engine_fx.c`'s `LE_FX` dispatch table wires `LE_FX_ECHO` to
  `fx_stereo_ring_prepare`, and `echo/processor.cpp`'s existing
  `terminate()` already frees both). Reverb's `setupProcessing()` only
  frees `delay[0][0]` because `fx_reverb_prepare` only ever allocates that
  one slot. Copying Reverb's free logic verbatim (freeing only `[0]`) would
  leak the old `[1]` buffer on every sample-rate change for Echo — this
  must be adapted, not copied byte-for-byte.
- **No engine core changes.** `engine_fx.c`, `engine.c`, `delay/`, and every
  other VST3 plugin (Drive, Filter, Tremolo, Octaver) are out of scope.
  Delay has the identical fixed-cap bug but is a separate, independently
  tracked finding, not touched here.
- **User-flow analysis skipped**: this is a backend DSP/plugin-correctness
  fix with no user-facing flow or UI surface — the user-flow-analysis-agent
  step in `/plan` is not applicable and was skipped for that reason.
- **No live user available during brainstorm/plan** — the assumptions above
  (keep `kEchoCapFrames`, create a new wrapper test file, update the one
  dependent test-harness file) were made autonomously per the brainstorm
  doc's Open Questions section and are documented there for review.

## Success Criteria

```success-criteria
GOAL: Loopy Echo VST3's delay-ring capacity scales with the host's negotiated sample rate, matching Reverb's already-shipped pattern, with no regression in existing GUID/parity tests.

SUCCESS CRITERIA:
- processor.h declares setupProcessing(), computeRingCapacity(), ringCapacityForTesting(), and a cap_ member | verify: grep -q "setupProcessing" packages/loopy_engine/vst3/echo/processor.h && grep -q "computeRingCapacity" packages/loopy_engine/vst3/echo/processor.h && grep -q "ringCapacityForTesting" packages/loopy_engine/vst3/echo/processor.h && grep -q "cap_" packages/loopy_engine/vst3/echo/processor.h
- processor.cpp no longer prepares the ring in initialize() and uses cap_ (not kEchoCapFrames) in process() | verify: ! grep -q "le_fx_prepare(&fx_, 0, LE_FX_ECHO, kEchoCapFrames)" packages/loopy_engine/vst3/echo/processor.cpp && grep -q "fx_apply_chain(&fx_, sr, cap_" packages/loopy_engine/vst3/echo/processor.cpp
- A new echo wrapper test file exists with a 96kHz regression test and is wired into CMake | verify: grep -q "96000" packages/loopy_engine/vst3/echo/test_vst3_echo_wrapper.cpp && grep -q "loopy_vst3_add_wrapper_test(echo)" packages/loopy_engine/vst3/CMakeLists.txt
- test_echo_parity.cpp's computeCap references computeRingCapacity, not the fixed constant | verify: grep -q "computeRingCapacity" packages/loopy_engine/vst3/test/test_echo_parity.cpp && ! grep -q "kEchoCapFrames" packages/loopy_engine/vst3/test/test_echo_parity.cpp
- Full VST3 CMake test suite (echo + delay + reverb wrapper, all 7 plugins' parity/GUID tests) builds and passes on macOS | verify: manual 1) cd packages/loopy_engine/vst3 2) cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug 3) cmake --build build 4) ctest --test-dir build --output-on-failure 5) confirm all tests, especially vst3_echo_wrapper and vst3_echo_parity, report Passed
- No unrelated files outside packages/loopy_engine/vst3/echo/, packages/loopy_engine/vst3/CMakeLists.txt, packages/loopy_engine/vst3/test/test_echo_parity.cpp, and packages/loopy_engine/vst3/test/host_harness.h are modified | verify: git diff --name-only | grep -v -E "^(packages/loopy_engine/vst3/echo/|packages/loopy_engine/vst3/CMakeLists.txt|packages/loopy_engine/vst3/test/test_echo_parity.cpp|packages/loopy_engine/vst3/test/host_harness.h|docs/brainstorm/|docs/plan/|\.github/cspell\.json)" | wc -l | grep -qx 0

NON-GOALS:
- Changing engine_fx.c, engine.c, delay/, or any other VST3 plugin (Drive, Filter, Tremolo, Octaver).
- Adding sample-accurate (per-sample) automation for the Time/Feedback/Mix parameters — out of scope, pre-existing D-SEAM block-rate limitation shared with every other VST3 wrapper in this repo.
- Windows/Linux-specific work — this fix is portable C++ shared by all platforms' CMake targets, no OS-specific branch needed.

VERIFICATION COMMAND: grep -q "setupProcessing" packages/loopy_engine/vst3/echo/processor.h && grep -q "computeRingCapacity" packages/loopy_engine/vst3/echo/processor.h && grep -q "ringCapacityForTesting" packages/loopy_engine/vst3/echo/processor.h && grep -q "cap_" packages/loopy_engine/vst3/echo/processor.h && ! grep -q "le_fx_prepare(&fx_, 0, LE_FX_ECHO, kEchoCapFrames)" packages/loopy_engine/vst3/echo/processor.cpp && grep -q "fx_apply_chain(&fx_, sr, cap_" packages/loopy_engine/vst3/echo/processor.cpp && grep -q "96000" packages/loopy_engine/vst3/echo/test_vst3_echo_wrapper.cpp && grep -q "loopy_vst3_add_wrapper_test(echo)" packages/loopy_engine/vst3/CMakeLists.txt && grep -q "computeRingCapacity" packages/loopy_engine/vst3/test/test_echo_parity.cpp && ! grep -q "kEchoCapFrames" packages/loopy_engine/vst3/test/test_echo_parity.cpp
```

## Success Metrics

- `ctest --test-dir packages/loopy_engine/vst3/build` reports 100% pass,
  including the new 96 kHz Echo regression test and the existing
  `vst3_echo_parity` / `vst3_reverb_parity` / `vst3_reverb_wrapper` suites
  (all sample rates in the existing `{44100, 48000, 88200, 96000}` sweep).
- `vst3_echo_parity`'s golden-parity diff (hosted vs. direct
  `fx_apply_chain`) stays within its existing 1e-6f tolerance at every swept
  sample rate after `computeCap` is switched to `computeRingCapacity`.

## Dependencies & Risks

- **Risk: forgetting to free `delay[0][1]` on cap change** (Reverb's pattern
  only frees `[0]`) — would leak the old-sized ring on every sample-rate
  change. Mitigated by the explicit callout in Technical Considerations
  above and a close read of `terminate()`'s existing both-channels-freed
  pattern before writing `setupProcessing()`.
- **Risk: CMake/CTest environment may not be available in the build
  sandbox** (macOS-only bundle codesign step, `third_party/vst3sdk`
  vendored SDK). If `cmake`/`codesign` aren't available in the execution
  environment, the `ctest` success criterion becomes a manual verification
  step for the repo owner (already marked `verify: manual` above) rather
  than blocking the fix from shipping — the file-content `grep`-based
  criteria above are the automatable subset that must pass regardless.
- **Dependency**: none on other in-flight fixes — this issue is isolated to
  `echo/` plus the two shared test-harness files it must touch to stay
  green. Delay's identical bug is a separate, independent finding.

## References & Research

- Proven pattern this mirrors: `packages/loopy_engine/vst3/reverb/processor.h`,
  `packages/loopy_engine/vst3/reverb/processor.cpp`'s `setupProcessing()`,
  `packages/loopy_engine/vst3/reverb/test_vst3_reverb_wrapper.cpp`'s
  `test_reverb_stays_correct_at_96khz`.
- Bug site: `packages/loopy_engine/vst3/echo/processor.h` (`kEchoCapFrames`),
  `packages/loopy_engine/vst3/echo/processor.cpp` (`initialize()`,
  `process()`). Entry point: `vst3/test/test_echo_parity.cpp`.
- DSP ground truth: `packages/loopy_engine/src/core/engine_fx.c`'s
  `fx_echo`, `fx_stereo_ring_prepare`, `le_fx_prepare`;
  `packages/loopy_engine/src/core/engine.c`'s `fx_delay_frames =
  sample_rate` convention.
- Build/test wiring: `packages/loopy_engine/vst3/CMakeLists.txt` (wrapper +
  parity test target definitions).
- Brainstorm doc:
  `docs/brainstorm/2026-07-13-fix-echo-vst3-samplerate-scaled-ring-brainstorm-doc.md`.
