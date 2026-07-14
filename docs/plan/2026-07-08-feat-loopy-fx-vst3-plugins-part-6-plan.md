---
title: "feat(vst3): Loopy Drive VST3 plugin — macOS (part 6)"
type: feat
date: 2026-07-08
part: 6 of 17
umbrella: ./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
---

> **Part 6 of the [Loopy FX as VST3 plugins](./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
> plan.** Shared design (D-SEAM, D-LINK, D-GUID, D-PARAM, D-NOGUI,
> D-ALL-EFFECTS, D-HARNESS-GENERIC) lives in the umbrella. Drive goes second
> (after Echo, part 5) and carries a one-time piece of shared infrastructure
> work: the golden-parity harness (part 4) is hardcoded to exactly 3 params
> per effect (`host_harness.h`'s own doc comment admits this: "a future
> plugin with a different param count would need this struct widened
> first"). Drive is the first 2-param effect, so this part generalizes the
> harness once; parts 7-8 (Filter, Tremolo, also 2 params) then reuse it
> unchanged, and part 9 (Octaver, 4 params) exercises its upper bound.

## Dependencies

Part 1 (`loopy_dsp_core` static lib). Part 4 (golden-parity harness — this
part modifies its shared infrastructure, not just adds a new per-effect
file, so treat `host_harness.h`/`.cpp` as shared, not append-only).

## Overview

Two pieces of work:

1. **`loopy_vst3_drive`**: the same `AudioEffect`/`EditController` wrapper
   pattern as parts 2/3/5, wrapping `LE_FX_DRIVE` (`engine_fx.c`'s
   `fx_drive`, line 41) — the simplest kernel of the remaining five (no ring
   buffer, no comb/allpass banks), chosen to go first among the harness-
   widening effects for exactly that reason.
2. **Harness generalization**: `vst3/test/host_harness.h`'s `ParamSpec
   params[3]`, `ParamCombo{ float values[3] }`, and `ParityConfig{ ...,
   params[3], combos[5] }` become variable-width (a `paramCount` field +
   arrays sized to the max across all seven effects, 4 — Octaver's width,
   part 9) rather than a hardcoded `3`. Existing Delay/Reverb/Echo parity
   tests (parts 2, 3, 5) must keep passing unchanged after this refactor —
   it is a structural widening, not a behavior change, and the existing
   parity suite is its own regression gate.

## Tasks

- [ ] Widen `packages/loopy_engine/vst3/test/host_harness.h`: replace the
  fixed `[3]` sizing on `ParamSpec`/`ParamCombo`/`ParityConfig` with a
  `paramCount` field (max 4, sized for Octaver) and update
  `host_harness.cpp`'s consumers accordingly. Update the header's own doc
  comment (previously admitting the fixed-3 limitation) to describe the new
  variable-width contract.
- [ ] Re-run `test_delay_parity.cpp`, `test_reverb_parity.cpp`,
  `test_echo_parity.cpp` (parts 2, 3, 5) unchanged against the widened
  harness — passing without modification to those three files is the proof
  the widening is behavior-preserving for existing effects.
- [ ] New source tree `packages/loopy_engine/vst3/drive/` —
  `processor.h/.cpp`, `controller.h/.cpp`, `ids.h`, `factory.cpp` (processor
  subcategory `"Fx|Distortion"`).
- [ ] Mint the processor + controller GUIDs **now**, permanent (D-GUID).
  New `test_vst3_drive_ids.cpp` (mirrors the existing per-plugin id-drift
  tests).
- [ ] `processor.cpp`: `le_fx_prepare(&fx, 0, LE_FX_DRIVE, cap)` on
  activate, `le_fx_entry_reset` before first block, `fx_apply_chain(...,
  count=1, ...)` per block. No ring buffer — the simplest processor.cpp of
  the seven.
- [ ] `controller.cpp`: registers two `Vst::RangeParameter`s (Drive, Level)
  matching `TrackEffectType.drive`
  ([track_effect.dart:72-75](../../packages/loopy_engine/lib/src/track_effect.dart)),
  defaults from `le_fx_defaults(LE_FX_DRIVE, ...)`.
- [ ] New CMake target block: `loopy_vst3_drive`, same link/bundle/codesign
  shape as parts 2/3/5.
- [ ] New `test_drive_parity.cpp` using the now-generalized harness (2-param
  sweep, edges + documented default).
- [ ] Manual verification: insert "Loopy Drive" on an audio track in Ableton;
  confirm Drive/Level ranges/defaults; play audio, confirm no clicks;
  automate one parameter.

## File References

- `packages/loopy_engine/vst3/test/host_harness.h`/`.cpp` (widened, shared)
- New: `packages/loopy_engine/vst3/drive/` (processor, controller, ids,
  factory, `test_vst3_drive_ids.cpp`)
- New: `packages/loopy_engine/vst3/test/test_drive_parity.cpp`
- [core/engine_fx.c:41](../../packages/loopy_engine/src/core/engine_fx.c) (`fx_drive` kernel, reference only)
- [track_effect.dart:72-75,121-131](../../packages/loopy_engine/lib/src/track_effect.dart) (param metadata source of truth)
- `packages/loopy_engine/vst3/CMakeLists.txt` (new target block)
- [test/run_native_tests.sh](../../packages/loopy_engine/src/test/run_native_tests.sh) (parity suite wiring)

## Acceptance Criteria

- [ ] `host_harness.h`/`.cpp` support a variable per-effect param count (up
  to 4) and the existing Delay/Reverb/Echo parity tests pass unmodified
  against the widened harness.
- [ ] `loopy_vst3_drive` builds a valid `.vst3` bundle; GUID-drift test
  passes; `test_drive_parity.cpp` passes.
- [ ] Manual Ableton load check passes and is recorded in the PR.
- [ ] No change to `engine_fx.c`, `engine_fx.h`, or any file outside the new
  `vst3/drive/` tree, the harness-widening files, and `CMakeLists.txt`/
  `run_native_tests.sh` wiring.
- [ ] Existing native test suite (all prior parts' tests) still passes.

## Out of Scope

Filter, Tremolo (parts 7-8, reuse the now-generalized harness unchanged);
Octaver (part 9, exercises the harness's 4-param upper bound); daw_export
wiring (part 10); code signing (part 12); Windows/Linux ports (parts 13-14).
