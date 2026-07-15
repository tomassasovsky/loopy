---
title: "feat(vst3): Loopy Echo VST3 plugin — macOS (part 5)"
type: feat
date: 2026-07-08
part: 5 of 17
umbrella: ./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
---

> **Part 5 of the [Loopy FX as VST3 plugins](./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
> plan.** Shared design (D-SEAM, D-LINK, D-GUID, D-PARAM, D-NOGUI,
> D-ALL-EFFECTS) lives in the umbrella. First of the five follow-on plugins
> ([2026-07-08 all-effects brainstorm](../brainstorm/2026-07-08-all-effects-vst3-plus-daw-export-brainstorm-doc.md))
> — Echo goes first because it wraps `LE_FX_ECHO`, the effect closest to
> already-solved ground: same 3-param width and the same delay-ring seam as
> the already-shipped Delay plugin (part 2), so this part needs **no**
> golden-parity harness changes, unlike parts 6-9.

## Dependencies

Part 1 (`loopy_dsp_core` static lib). No hard code dependency on parts 2/3,
but implementation should copy-adapt their scaffolding directly
(`packages/loopy_engine/vst3/delay/` is the closest template — same
fixed-capacity ring sizing, same 3-parameter controller shape).

## Overview

A new CMake target, `loopy_vst3_echo`, builds "Loopy Echo" — a VST3 audio
effect plugin wrapping `LE_FX_ECHO` (`engine_fx.c`'s `fx_echo`, line 537)
through the existing public `engine_fx.h` seam (umbrella D-SEAM): one
`le_fx_state`, slot 0, driven by `le_fx_prepare` (on activate) →
`le_fx_entry_reset` (before first block) → `fx_apply_chain` (per block,
`count=1`). No reimplementation of `fx_echo`.

Echo's ring buffer mirrors Delay's **fixed-capacity** sizing
(`kDelayCapFrames`, `delay/processor.h:46`) rather than Reverb's
sample-rate-scaled `computeRingCapacity` — both kernels share the same
underlying delay-ring mechanism in `engine_fx.c`, so the wrapper's buffer
allocation should copy Delay's approach, not Reverb's.

Same split `AudioEffect`/`EditController` pattern as parts 2/3, same
hand-rolled CMake/bundle packaging (no vendored SMTG helpers), no custom
editor (D-NOGUI).

## Tasks

- [ ] New source tree `packages/loopy_engine/vst3/echo/` —
  `processor.h/.cpp` (subclasses `Steinberg::Vst::AudioEffect`),
  `controller.h/.cpp` (subclasses `Steinberg::Vst::EditController`), `ids.h`
  (class GUIDs), `factory.cpp` (`BEGIN_FACTORY_DEF`/`DEF_CLASS`, processor
  subcategory `"Fx|Delay"` — Echo is a delay-family effect, matching
  Ableton's own categorization convention — controller entry
  `kVstComponentControllerClass`).
- [ ] Mint the processor + controller GUIDs **now**, permanent (umbrella
  D-GUID), a freshly hand-picked 32 bytes never reused from another plugin's
  `ids.h`. New `test_vst3_echo_ids.cpp` (mirrors
  `delay/test_vst3_delay_ids.cpp`): `memcmp`-asserts the constants against
  independently-transcribed hex, plus a processor-vs-controller distinctness
  check.
- [ ] `processor.cpp`: `initialize()` allocates one `le_fx_state` + prepares
  slot 0 via `le_fx_prepare(&fx, 0, LE_FX_ECHO, cap)` with Delay's fixed
  `kDelayCapFrames` ring sizing; `setActive(true)` calls
  `le_fx_entry_reset`; `process()` maps VST3's `ProcessData` stereo buffers
  into `fx_apply_chain(&fx, sr, cap, l, r, 1, types, params)` per block,
  reading queued normalized param changes from
  `ProcessData::inputParameterChanges`.
- [ ] `controller.cpp`: registers three `Vst::RangeParameter`s (Time,
  Feedback, Mix) with plain ranges matching `TrackEffectType.echo`'s
  existing metadata
  ([track_effect.dart:103-107](../../packages/loopy_engine/lib/src/track_effect.dart)),
  defaults from `le_fx_defaults(LE_FX_ECHO, ...)`
  ([track_effect.dart:121-131](../../packages/loopy_engine/lib/src/track_effect.dart)).
- [ ] New CMake target block in `packages/loopy_engine/vst3/CMakeLists.txt`
  (copy-adapt the ~25-line delay/reverb block): `loopy_vst3_echo` links
  `loopy_dsp_core`, `core_plugin_disabled_stub`, `sdk`, `sdk_common`;
  `OUTPUT_NAME "Loopy Echo"`; hand-authored `Info.plist` (bundle id
  `com.loopy.vst3.echo`); post-build ad-hoc codesign (real signing is part
  12).
- [ ] Dev-install: reuse the existing `LOOPY_VST3_DEV_INSTALL` CMake option
  to copy the built bundle to `~/Library/Audio/Plug-Ins/VST3/Loopy Echo.vst3`.
- [ ] Extend the golden-parity harness with `test_echo_parity.cpp` (mirrors
  `vst3/test/test_delay_parity.cpp`, 44 lines) — Echo's 3 params fit the
  existing `ParamSpec[3]`/`ParamCombo`/`ParityConfig` shape unchanged, so
  **no** `host_harness.h` widening is needed here (contrast part 6, which
  does need it for Drive). Wire the new suite into `run_native_tests.sh`
  alongside the existing delay/reverb entries.
- [ ] Manual verification: insert "Loopy Echo" on an audio track in a local
  Ableton Live instance; confirm Time/Feedback/Mix show with correct
  ranges/defaults; play audio through it and confirm no clicks; automate one
  parameter and confirm it responds.

## File References

- New: `packages/loopy_engine/vst3/echo/` (processor, controller, ids,
  factory, `test_vst3_echo_ids.cpp`)
- New: `packages/loopy_engine/vst3/test/test_echo_parity.cpp`
- [core/engine_fx.h](../../packages/loopy_engine/src/core/engine_fx.h) (consumed, unchanged)
- [core/engine_fx.c:537](../../packages/loopy_engine/src/core/engine_fx.c) (`fx_echo` kernel, reference only)
- `packages/loopy_engine/vst3/delay/` (structural + ring-sizing template)
- [track_effect.dart:103-107,121-131](../../packages/loopy_engine/lib/src/track_effect.dart) (param metadata source of truth)
- `packages/loopy_engine/vst3/CMakeLists.txt` (new target block)
- [test/run_native_tests.sh](../../packages/loopy_engine/src/test/run_native_tests.sh) (parity suite wiring)

## Acceptance Criteria

- [ ] `loopy_vst3_echo` builds a valid `.vst3` bundle on macOS.
- [ ] GUID-drift regression test passes and is wired into
  `run_native_tests.sh`.
- [ ] `test_echo_parity.cpp` passes as part of the native suite, proving the
  VST3-hosted path is bit-exact with `fx_apply_chain` for Echo.
- [ ] Manual Ableton load check (above) passes and is recorded in the PR.
- [ ] No change to `engine_fx.c`, `engine_fx.h`, `host_harness.h`, or any
  file outside the new `vst3/echo/` tree, `vst3/test/test_echo_parity.cpp`,
  and `CMakeLists.txt`/`run_native_tests.sh` wiring.
- [ ] Existing native test suite still passes unchanged.

## Out of Scope

Drive, Filter, Tremolo, Octaver (parts 6-9); daw_export wiring (part 10);
code signing/notarization (part 12); Windows/Linux ports (parts 13-14).
