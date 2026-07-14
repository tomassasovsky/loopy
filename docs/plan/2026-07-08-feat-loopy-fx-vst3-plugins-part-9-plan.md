---
title: "feat(vst3): Loopy Octaver VST3 plugin — macOS (part 9)"
type: feat
date: 2026-07-08
part: 9 of 17
umbrella: ./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
---

> **Part 9 of the [Loopy FX as VST3 plugins](./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
> plan.** Shared design (D-SEAM, D-LINK, D-GUID, D-PARAM, D-NOGUI,
> D-ALL-EFFECTS, D-HARNESS-GENERIC) lives in the umbrella. Goes **last**
> among the five new plugins, deliberately: Octaver wraps the hardest kernel
> (`fx_octaver`, a pitch-shift algorithm — the exact reason the sibling
> brainstorm rejected an Ableton stock-device approximation for it, "no
> honest equivalent") and is the only one of the seven effects with 4
> params, exercising the upper bound of part 6's generalized harness.

## Dependencies

Part 1 (`loopy_dsp_core` static lib). Part 6 (generalized `host_harness.h`,
sized for a 4-param max specifically so this part fits without further
widening — consumed here, not modified further).

## Overview

`loopy_vst3_octaver` wraps `LE_FX_OCTAVER` (`engine_fx.c`'s `fx_octaver`,
line 470) through the same seam and pattern as the prior plugin parts, with
one Octaver-specific concern the others don't have: **pitch-shift latency**.
If `fx_octaver`'s algorithm buffers audio internally (phase-vocoder/PSOLA
approaches typically require a lookahead window), the wrapper must report
that via `IAudioProcessor::getLatencySamples()` so the host's automatic
delay compensation keeps this track's Octaver output aligned with other
tracks — a silent, audible sync bug if skipped, not a cosmetic detail.
Confirm at implementation time whether `fx_octaver` is genuinely
zero-latency (some real-time-oriented pitch shifters are) or has an internal
buffer that needs reporting.

Mode (the 4th param, default `0.0`) is a discrete-ish selector rather than a
continuous knob. Per umbrella D-PARAM, register it as a `Vst::RangeParameter`
with the same linear normalized-to-plain convention as the other three
params (consistent with how the engine itself treats it) — evaluate at
implementation time whether a `StringListParameter` gives a materially
better host UI (readable mode names in Ableton's generic parameter list)
without breaking the plain-value agreement with Loopy's own UI; if so, use
it, documenting the deviation from the otherwise-uniform `RangeParameter`
pattern.

## Tasks

- [ ] New source tree `packages/loopy_engine/vst3/octaver/` —
  `processor.h/.cpp`, `controller.h/.cpp`, `ids.h`, `factory.cpp` (processor
  subcategory `"Fx|Pitch Shift"`).
- [ ] Mint the processor + controller GUIDs **now**, permanent (D-GUID).
  New `test_vst3_octaver_ids.cpp`.
- [ ] `processor.cpp`: `le_fx_prepare(&fx, 0, LE_FX_OCTAVER, cap)` on
  activate, `le_fx_entry_reset` before first block, `fx_apply_chain(...,
  count=1, ...)` per block. Investigate `fx_octaver`'s internal buffering; if
  non-zero, override `getLatencySamples()` to report it and confirm Ableton
  applies delay compensation correctly (part of manual verification below).
- [ ] `controller.cpp`: registers four `Vst::RangeParameter`s (Shift, Tone,
  Mix, Mode) matching `TrackEffectType.octaver`
  ([track_effect.dart:93-102](../../packages/loopy_engine/lib/src/track_effect.dart)),
  defaults from `le_fx_defaults(LE_FX_OCTAVER, ...)`
  ([track_effect.dart:121-131](../../packages/loopy_engine/lib/src/track_effect.dart)).
  Decide Mode's parameter type (see Overview) and document the choice in the
  controller source.
- [ ] New CMake target block: `loopy_vst3_octaver`, same link/bundle/codesign
  shape as prior parts.
- [ ] New `test_octaver_parity.cpp` using the already-generalized 4-param
  harness (part 6) — sweep across Shift/Tone/Mix/Mode combinations,
  including edges and the documented default; if latency reporting is
  added, the parity diff must account for the reported latency offset when
  aligning the two output buffers (a naive sample-for-sample diff would
  falsely fail against a correctly-latency-compensated plugin).
- [ ] Manual verification: insert "Loopy Octaver" on an audio track in
  Ableton; confirm Shift/Tone/Mix/Mode ranges/defaults and (if applicable)
  readable Mode labeling; play audio through it and confirm the pitch-shift
  output sounds correct and time-aligned with other tracks (delay
  compensation check, if latency reporting was added); automate one
  parameter.

## File References

- New: `packages/loopy_engine/vst3/octaver/` (processor, controller, ids,
  factory, `test_vst3_octaver_ids.cpp`)
- New: `packages/loopy_engine/vst3/test/test_octaver_parity.cpp`
- [core/engine_fx.c:470](../../packages/loopy_engine/src/core/engine_fx.c) (`fx_octaver` kernel, reference only)
- [track_effect.dart:93-102,121-131](../../packages/loopy_engine/lib/src/track_effect.dart) (param metadata source of truth)
- `packages/loopy_engine/vst3/CMakeLists.txt` (new target block)
- `packages/loopy_engine/vst3/test/host_harness.h` (consumed, unchanged from part 6)

## Acceptance Criteria

- [ ] `loopy_vst3_octaver` builds a valid `.vst3` bundle; GUID-drift test
  passes; `test_octaver_parity.cpp` passes across the full 4-param sweep.
- [ ] Latency behavior is either confirmed zero and documented as such, or
  correctly reported via `getLatencySamples()` and proven aligned in the
  manual Ableton check.
- [ ] Manual Ableton load check passes and is recorded in the PR.
- [ ] No change to `engine_fx.c`, `engine_fx.h`, `host_harness.h`/`.cpp`, or
  any file outside the new `vst3/octaver/` tree and
  `CMakeLists.txt`/`run_native_tests.sh` wiring.
- [ ] Existing native test suite still passes.

## Out of Scope

daw_export wiring (part 10); code signing (part 12); Windows/Linux ports
(parts 13-14). This part completes the seven-plugin set — parts 10+ assume
all seven bundles exist.
