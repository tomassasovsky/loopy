---
title: Fix Loopy Delay VST3 delay-ring capacity to scale with host sample rate
type: fix
date: 2026-07-13
---

## Fix Loopy Delay VST3 delay-ring capacity to scale with host sample rate - Standard

## Overview

`packages/loopy_engine/vst3/delay/processor.h` hardcodes
`static constexpr int kDelayCapFrames = 48000;` and the Delay processor never
overrides `setupProcessing()`, so the delay-ring capacity is fixed at 48000
frames regardless of the host's actual negotiated sample rate. This plan
mirrors the sibling Reverb VST3 plugin's already-shipped fix for the identical
problem (`packages/loopy_engine/vst3/reverb/processor.h`/`.cpp`, part 3 of the
same umbrella plan) onto Delay.

## Problem Statement / Motivation

`fx_delay`'s normalized "Time" parameter (`engine_fx.c`) maps directly onto
the ring's capacity in samples: `d = p[0] * (cap - 1)`. The live engine sizes
this ring to the real sample rate (`engine.c`: `fx_delay_frames = sample_rate`,
"1 s of delay line"), and Reverb's VST3 wrapper does the same for its own
comb/allpass ring. Because Delay's VST3 wrapper does not, its actual max delay
time only equals 1 s at exactly 48 kHz:

- At 96 kHz, `cap` stays 48000 frames = 0.5 s of *actual* audio time.
- At 44.1 kHz, `cap` stays 48000 frames = ~1.088 s of actual audio time.

This is a correctness bug: the same normalized "Time" value produces a
different delay time depending on the host's sample rate, and diverges from
both the live engine and from Reverb's own (correct) behavior at the same
sample rate.

## Proposed Solution

Mirror Reverb's structure in the Delay processor, verbatim where the pattern
applies:

1. **`packages/loopy_engine/vst3/delay/processor.h`**
   - Add `setupProcessing(Steinberg::Vst::ProcessSetup&)` override declaration.
   - Add a `static int computeRingCapacity(double sampleRate)` public static
     method — same formula as Reverb's (`round(sampleRate)`, floored at 1).
   - Add `int ringCapacityForTesting() const { return cap_; }` public accessor.
   - Add a private `int cap_ = kDelayCapFrames;` member (default kept at
     48000, matching pre-`setupProcessing()` behavior and Reverb's own
     `cap_ = 48000` default).
   - Keep `kDelayCapFrames` (still referenced by
     `vst3/test/test_delay_parity.cpp` — do not remove it). Rewrite its doc
     comment: drop the "not something this wrapper adjusts... D-SEAM scope"
     framing (explicitly superseded per this issue) and instead describe it
     as `cap_`'s default/initial value before `setupProcessing()` first runs,
     matching how Reverb's header frames its own `cap_ = 48000` default.

2. **`packages/loopy_engine/vst3/delay/processor.cpp`**
   - Remove the `le_fx_prepare(&fx_, 0, LE_FX_DELAY, kDelayCapFrames)` call
     from `initialize()` (keep `types_[0] = LE_FX_DELAY;` and
     `le_fx_defaults(...)` there, matching Reverb's `initialize()`).
   - Add `setupProcessing()`: call `AudioEffect::setupProcessing(newSetup)`
     first; if it fails, return its result. Compute
     `computeRingCapacity(processSetup.sampleRate)`; if it differs from
     `cap_`, free `fx_.delay[0][0]` and `fx_.delay[0][1]` (both channels —
     Delay's `fx_stereo_ring_prepare` allocates both, unlike Reverb's
     single-buffer `fx_reverb_prepare`) and null them, then update `cap_`.
     Call `le_fx_prepare(&fx_, 0, LE_FX_DELAY, cap_)`; return `kResultFalse`
     on failure, else `kResultOk`.
   - Replace both remaining uses of `kDelayCapFrames` in `process()` with
     `cap_`.
   - `terminate()` is unchanged (already frees both `delay[0][0]`/`[1]`).

3. **`packages/loopy_engine/vst3/delay/test_vst3_delay_wrapper.cpp`**
   - Add a `setupProcessing48k(IAudioProcessor*)` helper, identical to
     Reverb's wrapper test, and call it in `test_processor_param_round_trip`
     before `processSilentBlock` (now needed since `initialize()` no longer
     prepares the ring — the test itself only checks param storage so this
     is precautionary/consistency with Reverb's test file, not a hard
     requirement, but keeps the file's tests structurally uniform).
   - Add `test_delay_stays_correct_at_96khz` (or similarly named), mirroring
     Reverb's `test_reverb_stays_correct_at_96khz`: call `setupProcessing`
     with `sampleRate = 96000.0`, assert
     `processor.ringCapacityForTesting() >= 96000` (Delay's cap formula is
     simpler than Reverb's — it's just `round(sampleRate)`, so the expected
     value is exactly the sample rate, not a derived comb/allpass sum), call
     `setActive(true)`, drive an impulse through `process()`, and assert the
     output is finite and that the *delayed* impulse (not the dry sample)
     is still audible near where a ~1 s delay at 96 kHz would place it
     (e.g. sample index `~95999` at "Time"=1.0), which the pre-fix
     fixed-48000 cap could never reach at 96 kHz since the ring itself would
     have looped/wrapped at half that index.

4. **`packages/loopy_engine/vst3/test/test_delay_parity.cpp`**
   - Change `config.computeCap` from the lambda returning the fixed
     `loopy_vst3_delay::Processor::kDelayCapFrames` literal to
     `&loopy_vst3_delay::Processor::computeRingCapacity`, matching how
     `test_reverb_parity.cpp` wires its own `computeCap`. Update the adjacent
     comment (currently states "Fixed regardless of sample rate (part 2) —
     not scaled like Reverb's (part 3's fix)") to reflect that Delay now
     scales too.
   - This is required, not optional: `host_harness.cpp`'s `runParityTests`
     already sweeps `{44100, 48000, 88200, 96000}` and calls
     `proc->setupProcessing(setup)` in `runHosted`. Once the hosted path's
     real cap scales with sample rate, `runDirect`'s reference call must use
     the same scaled cap (via `config.computeCap(sr)`) or the harness would
     start failing at every non-48kHz rate from a cap *mismatch* alone —
     not a real DSP bug, but a spurious divergence this plan must not
     introduce.

5. **`packages/loopy_engine/vst3/test/host_harness.h`**
   - Update the stale comment (lines ~107-116) that currently reads "Delay
     uses a fixed 48000 regardless of sr ... Reverb scales with sr" to state
     both plugins now scale ring capacity with the real sample rate via
     their own `computeRingCapacity`.

## Technical Considerations

- **Safety of the NULL-ring window before first `setupProcessing()`:**
  `fx_delay` (`engine_fx.c:71-88`) already guards `if (buf == NULL || cap <= 1)
  return x;` — a safe dry passthrough. This is the exact same guard structure
  `fx_reverb` relies on in the identical window, so moving Delay's
  `le_fx_prepare` call out of `initialize()` is safe by inspection, not a new
  risk.
- **Both channels must be freed on cap change**, unlike Reverb (which only
  uses `delay[slot][0]`). Delay's `fx_stereo_ring_prepare` allocates
  `delay[slot][0]` AND `delay[slot][1]` (confirmed: `engine_fx.c`'s
  `fx_stereo_ring_prepare`, and `delay/processor.cpp`'s existing `terminate()`
  already frees both). Reverb's `setupProcessing()` only frees `delay[0][0]`
  because `fx_reverb_prepare` only ever allocates that one slot. Copying
  Reverb's free logic verbatim (freeing only `[0]`) would leak the old `[1]`
  buffer on every sample-rate change for Delay — this must be adapted, not
  copied byte-for-byte.
- **No engine core changes.** `engine_fx.c`, `engine.c`, and every other VST3
  plugin (Echo, Drive, Filter, Tremolo, Octaver) are out of scope. Echo also
  uses `fx_stereo_ring_prepare` with its own similar (separately-tracked, not
  this issue) fixed-cap wrapper pattern — not touched here.
- **User-flow analysis skipped**: this is a backend DSP/plugin-correctness
  fix with no user-facing flow or UI surface — the user-flow-analysis-agent
  step in `/plan` is not applicable and was skipped for that reason.
- **No live user available during brainstorm/plan** — the assumptions above
  (keep `kDelayCapFrames`, touch the two dependent test-harness files) were
  made autonomously per the brainstorm doc's Open Questions section and are
  documented there for review.

## Success Criteria

```success-criteria
GOAL: Loopy Delay VST3's delay-ring capacity scales with the host's negotiated sample rate, matching Reverb's already-shipped pattern, with no regression in existing wrapper/parity/GUID tests.

SUCCESS CRITERIA:
- processor.h declares setupProcessing(), computeRingCapacity(), ringCapacityForTesting(), and a cap_ member | verify: grep -q "setupProcessing" packages/loopy_engine/vst3/delay/processor.h && grep -q "computeRingCapacity" packages/loopy_engine/vst3/delay/processor.h && grep -q "ringCapacityForTesting" packages/loopy_engine/vst3/delay/processor.h && grep -q "cap_" packages/loopy_engine/vst3/delay/processor.h
- processor.cpp no longer prepares the ring in initialize() and uses cap_ (not kDelayCapFrames) in process() | verify: ! grep -q "le_fx_prepare(&fx_, 0, LE_FX_DELAY, kDelayCapFrames)" packages/loopy_engine/vst3/delay/processor.cpp && grep -q "fx_apply_chain(&fx_, sr, cap_" packages/loopy_engine/vst3/delay/processor.cpp
- A 96kHz regression test exists in the delay wrapper test file and passes | verify: grep -q "96000" packages/loopy_engine/vst3/delay/test_vst3_delay_wrapper.cpp
- test_delay_parity.cpp's computeCap references computeRingCapacity, not the fixed constant | verify: grep -q "computeRingCapacity" packages/loopy_engine/vst3/test/test_delay_parity.cpp && ! grep -q "kDelayCapFrames" packages/loopy_engine/vst3/test/test_delay_parity.cpp
- Full VST3 CMake test suite (delay + reverb wrapper, all 7 plugins' parity/GUID tests) builds and passes on macOS | verify: manual 1) cd packages/loopy_engine/vst3 2) cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug 3) cmake --build build 4) ctest --test-dir build --output-on-failure 5) confirm all tests, especially vst3_delay_wrapper and vst3_delay_parity, report Passed
- No unrelated files outside packages/loopy_engine/vst3/delay/, packages/loopy_engine/vst3/test/test_delay_parity.cpp, and packages/loopy_engine/vst3/test/host_harness.h are modified | verify: git diff --name-only | grep -v -E "^(packages/loopy_engine/vst3/delay/|packages/loopy_engine/vst3/test/test_delay_parity.cpp|packages/loopy_engine/vst3/test/host_harness.h|docs/brainstorm/|docs/plan/)" | wc -l | grep -qx 0

NON-GOALS:
- Changing engine_fx.c, engine.c, or any other VST3 plugin (Echo, Drive, Filter, Tremolo, Octaver).
- Adding sample-accurate (per-sample) automation for the Time/Feedback/Mix parameters — out of scope, pre-existing D-SEAM block-rate limitation shared with every other VST3 wrapper in this repo.
- Windows/Linux-specific work (parts 13/14) — this fix is portable C++ shared by all platforms' CMake targets, no OS-specific branch needed.

VERIFICATION COMMAND: grep -q "setupProcessing" packages/loopy_engine/vst3/delay/processor.h && grep -q "computeRingCapacity" packages/loopy_engine/vst3/delay/processor.h && grep -q "ringCapacityForTesting" packages/loopy_engine/vst3/delay/processor.h && grep -q "cap_" packages/loopy_engine/vst3/delay/processor.h && ! grep -q "le_fx_prepare(&fx_, 0, LE_FX_DELAY, kDelayCapFrames)" packages/loopy_engine/vst3/delay/processor.cpp && grep -q "fx_apply_chain(&fx_, sr, cap_" packages/loopy_engine/vst3/delay/processor.cpp && grep -q "96000" packages/loopy_engine/vst3/delay/test_vst3_delay_wrapper.cpp && grep -q "computeRingCapacity" packages/loopy_engine/vst3/test/test_delay_parity.cpp && ! grep -q "kDelayCapFrames" packages/loopy_engine/vst3/test/test_delay_parity.cpp
```

## Success Metrics

- `ctest --test-dir packages/loopy_engine/vst3/build` reports 100% pass,
  including the new 96 kHz Delay regression test and the existing
  `vst3_delay_parity` / `vst3_reverb_parity` / `vst3_delay_wrapper` /
  `vst3_reverb_wrapper` suites (all sample rates in the existing
  `{44100, 48000, 88200, 96000}` sweep).
- `vst3_delay_parity`'s golden-parity diff (hosted vs. direct `fx_apply_chain`)
  stays within its existing 1e-6f tolerance at every swept sample rate after
  `computeCap` is switched to `computeRingCapacity`.

## Dependencies & Risks

- **Risk: forgetting to free `delay[0][1]` on cap change** (Reverb's pattern
  only frees `[0]`) — would leak the old-sized ring on every sample-rate
  change. Mitigated by the explicit callout in Technical Considerations above
  and a close read of `terminate()`'s existing both-channels-freed pattern
  before writing `setupProcessing()`.
- **Risk: CMake/CTest environment may not be available in the build sandbox**
  (macOS-only bundle codesign step, `third_party/vst3sdk` vendored SDK). If
  `cmake`/`codesign` aren't available in the execution environment, the
  `ctest` success criterion becomes a manual verification step for the repo
  owner (already marked `verify: manual` above) rather than blocking the fix
  from shipping — the file-content `grep`-based criteria above are the
  automatable subset that must pass regardless.
- **Dependency**: none on other in-flight fixes from the same review pass —
  this issue is isolated to `delay/` plus the two shared test-harness files
  it must touch to stay green.

## References & Research

- Proven pattern this mirrors: `packages/loopy_engine/vst3/reverb/processor.h`,
  `packages/loopy_engine/vst3/reverb/processor.cpp`'s `setupProcessing()`
  (lines ~33-49), `packages/loopy_engine/vst3/reverb/test_vst3_reverb_wrapper.cpp`'s
  `test_reverb_stays_correct_at_96khz`.
- Bug site: `packages/loopy_engine/vst3/delay/processor.h:45-46`
  (`kDelayCapFrames`), `packages/loopy_engine/vst3/delay/processor.cpp:28,100`.
  entry points: `test_vst3_delay_parity.cpp:38`, `test/host_harness.h:107-116`.
- DSP ground truth: `packages/loopy_engine/src/core/engine_fx.c`'s `fx_delay`
  (line ~71), `fx_stereo_ring_prepare` (line ~799), `le_fx_prepare` (line
  ~1006); `packages/loopy_engine/src/core/engine.c`'s
  `fx_delay_frames = sample_rate` convention.
- Build/test wiring: `packages/loopy_engine/vst3/CMakeLists.txt` (wrapper +
  parity test target definitions, lines ~260-306).
- Brainstorm doc:
  `docs/brainstorm/2026-07-13-fix-delay-vst3-samplerate-scaled-ring-brainstorm-doc.md`.
