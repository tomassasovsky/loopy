---
title: "feat(vst3): Loopy Delay VST3 plugin — macOS (part 2)"
type: feat
date: 2026-07-08
part: 2 of 12
umbrella: ./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
---

> **Part 2 of the [Loopy FX as VST3 plugins](./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
> pilot.** Shared design (D-SEAM, D-LINK, D-GUID, D-PARAM, D-NOGUI) lives in
> the umbrella. This part builds the **first** of the two pilot plugins —
> Delay, chosen first as the simpler kernel to prove the wrapper/build
> pattern before Reverb (part 3) reuses it.

## Dependencies

Part 1 (`loopy_dsp_core` static lib).

## Overview

A new CMake target, `loopy_vst3_delay`, builds "Loopy Delay" — a VST3 audio
effect plugin wrapping `LE_FX_DELAY` through the existing public
`engine_fx.h` seam (umbrella D-SEAM): one `le_fx_state`, slot 0, driven by
`le_fx_prepare` (on activate) → `le_fx_entry_reset` (before first block) →
`fx_apply_chain` (per block, `count=1`). No reimplementation of `fx_delay`.

Uses the **split `AudioEffect`/`EditController`** pattern (not
`vstsinglecomponenteffect`, which the vendored SDK's own header warns is a
workaround for hosts with limited two-component support, not standard
practice) — matching Steinberg's own reference `adelay` sample. No custom
editor (D-NOGUI): the `EditController` exposes `ParameterInfo` only; Ableton
renders the generic parameter list.

The vendored SDK has **no** CMake helper modules and **no** sample template
(confirmed empty `find . -iname "*.cmake"` under
`packages/loopy_engine/third_party/vst3sdk/`) — the CMakeLists, bundle
packaging (`Info.plist`, `.vst3` directory structure), and factory
registration are hand-rolled in this part, referencing Steinberg's public
documentation/GitHub samples for the exact shape rather than a vendored
template.

## Tasks

- [ ] New source tree `packages/loopy_engine/vst3/delay/` — `processor.h/.cpp`
  (subclasses `Steinberg::Vst::AudioEffect`), `controller.h/.cpp` (subclasses
  `Steinberg::Vst::EditController`), `ids.h` (class GUIDs), `factory.cpp`
  (`BEGIN_FACTORY_DEF`/`DEF_CLASS`, two entries: processor `kVstAudioEffectClass`
  subcategory `"Fx|Delay"`, controller `kVstComponentControllerClass`).
- [ ] Mint the processor + controller GUIDs **now** and record them as
  permanent constants in `ids.h` with a comment citing umbrella D-GUID
  ("never regenerate — see docs/plan/…-plan.md#decisions"). Add a native test
  asserting the constants match their expected hardcoded hex values (the
  drift regression test).
- [ ] `processor.cpp`: `initialize()` allocates one `le_fx_state` + prepares
  slot 0 via `le_fx_prepare(&fx, 0, LE_FX_DELAY, cap)`; `setActive(true)`
  calls `le_fx_entry_reset`; `process()` maps VST3's `ProcessData` stereo
  buffers into the `fx_apply_chain(&fx, sr, cap, l, r, 1, types, params)`
  call per block, reading queued normalized param changes from
  `ProcessData::inputParameterChanges` and converting via the same
  plain↔normalized mapping as `controller.cpp`.
- [ ] `controller.cpp`: registers three `Vst::RangeParameter`s (Time,
  Feedback, Mix) with plain ranges matching `TrackEffectType.delay`'s
  existing metadata
  ([track_effect.dart:80-84](../../packages/looper_repository/lib/src/models/track_effect.dart)),
  defaults from `le_fx_defaults(LE_FX_DELAY, ...)`.
- [ ] New CMake target in `packages/loopy_engine/vst3/CMakeLists.txt`:
  `target_link_libraries(loopy_vst3_delay PRIVATE loopy_dsp_core
  core_plugin_disabled_stub sdk sdk_common)` (the SDK's own compiled
  `public.sdk/source/vst/*` sources, plus a small target wrapping
  `core/plugin_disabled.c` to satisfy `le_plugin_slot_process` per D-LINK).
  Hand-rolled `.vst3` bundle packaging: `MACOSX_BUNDLE` target property,
  hand-authored `Info.plist` (bundle id `com.loopy.vst3.delay`,
  `CFBundlePackageType=BNDL`), post-build ad-hoc codesign
  (`codesign -f -s -` — real Developer ID signing is part 7).
- [ ] Dev-install: an `install()` rule (or a CMake custom command) copying the
  built bundle to `~/Library/Audio/Plug-Ins/VST3/Loopy Delay.vst3` on a local
  dev build, gated behind a CMake option (off by default in CI).
- [ ] Manual verification: insert "Loopy Delay" on an audio track in a local
  Ableton Live instance; confirm it appears under an Audio Effects category
  consistent with `"Fx|Delay"`; confirm Time/Feedback/Mix show with correct
  ranges/defaults; play audio through it and confirm no clicks; automate one
  parameter and confirm it responds.

## File References

- New: `packages/loopy_engine/vst3/delay/` (processor, controller, ids, factory)
- New: `packages/loopy_engine/vst3/CMakeLists.txt`
- [core/engine_fx.h](../../packages/loopy_engine/src/core/engine_fx.h) (consumed, unchanged)
- [track_effect.dart:80-84](../../packages/looper_repository/lib/src/models/track_effect.dart) (param metadata source of truth)
- Reference (not vendored, consulted for shape only): Steinberg `vst3_public_sdk` `samples/vst/adelay/`

## Acceptance Criteria

- [ ] `loopy_vst3_delay` builds a valid `.vst3` bundle on macOS via the new
  CMake target.
- [ ] GUID-drift regression test passes and is wired into
  `run_native_tests.sh`.
- [ ] Manual Ableton load check (above) passes and is recorded (screenshot or
  notes) in the PR.
- [ ] No change to `engine_fx.c`, `engine_fx.h`, or any file outside the new
  `vst3/` tree and `CMakeLists.txt` link wiring.
- [ ] Existing native test suite still passes unchanged.

## Out of Scope

Reverb (part 3); golden-parity automated diff (part 4); daw_export wiring
(part 5); code signing/notarization (part 7); Windows/Linux ports (parts 8-9).
</content>
