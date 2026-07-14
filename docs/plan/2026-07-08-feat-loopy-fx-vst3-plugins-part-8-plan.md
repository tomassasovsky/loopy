---
title: "feat(vst3): Loopy Tremolo VST3 plugin — macOS (part 8)"
type: feat
date: 2026-07-08
part: 8 of 17
umbrella: ./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
---

> **Part 8 of the [Loopy FX as VST3 plugins](./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
> plan.** Shared design (D-SEAM, D-LINK, D-GUID, D-PARAM, D-NOGUI,
> D-ALL-EFFECTS) lives in the umbrella. Reuses part 6's generalized
> golden-parity harness unchanged — Tremolo is also a 2-param effect.

## Dependencies

Part 1 (`loopy_dsp_core` static lib). Part 6 (generalized `host_harness.h`
— consumed here, not modified further).

## Overview

`loopy_vst3_tremolo` wraps `LE_FX_TREMOLO` (`engine_fx.c`'s `fx_tremolo`,
line 91) through the same seam and pattern as the prior plugin parts. The
one behavior worth confirming explicitly during manual verification: Rate is
a rate parameter (Hz-ish, not a 0-1 mix-style knob) — its plain-range mapping
must match `TrackEffectType.tremolo`'s real range, not be assumed linear-0-1
like a generic mix knob.

## Tasks

- [ ] New source tree `packages/loopy_engine/vst3/tremolo/` —
  `processor.h/.cpp`, `controller.h/.cpp`, `ids.h`, `factory.cpp` (processor
  subcategory `"Fx|Modulation"`).
- [ ] Mint the processor + controller GUIDs **now**, permanent (D-GUID).
  New `test_vst3_tremolo_ids.cpp`.
- [ ] `processor.cpp`: `le_fx_prepare(&fx, 0, LE_FX_TREMOLO, cap)` on
  activate, `le_fx_entry_reset` before first block, `fx_apply_chain(...,
  count=1, ...)` per block.
- [ ] `controller.cpp`: registers two `Vst::RangeParameter`s (Rate, Depth)
  matching `TrackEffectType.tremolo`
  ([track_effect.dart:85-88](../../packages/loopy_engine/lib/src/track_effect.dart)),
  defaults from `le_fx_defaults(LE_FX_TREMOLO, ...)`. Double-check Rate's
  real plain range against the Dart source rather than assuming 0-1 —
  tremolo rate is typically Hz-scaled.
- [ ] New CMake target block: `loopy_vst3_tremolo`, same link/bundle/codesign
  shape as prior parts.
- [ ] New `test_tremolo_parity.cpp` using the already-generalized harness
  (part 6) — 2-param sweep, edges + documented default, plus a slow-vs-fast
  Rate case to confirm the LFO phase isn't a source of drift at block
  boundaries (the one place a per-block wrapper could plausibly diverge from
  the live engine's continuous LFO phase — a real risk this parity test
  exists to catch, not a hypothetical).
- [ ] Manual verification: insert "Loopy Tremolo" on an audio track in
  Ableton; confirm Rate/Depth ranges/defaults; play audio, confirm the
  audible tremolo rate matches the displayed Rate value; automate one
  parameter.

## File References

- New: `packages/loopy_engine/vst3/tremolo/` (processor, controller, ids,
  factory, `test_vst3_tremolo_ids.cpp`)
- New: `packages/loopy_engine/vst3/test/test_tremolo_parity.cpp`
- [core/engine_fx.c:91](../../packages/loopy_engine/src/core/engine_fx.c) (`fx_tremolo` kernel, reference only)
- [track_effect.dart:85-88,121-131](../../packages/loopy_engine/lib/src/track_effect.dart) (param metadata source of truth)
- `packages/loopy_engine/vst3/CMakeLists.txt` (new target block)
- `packages/loopy_engine/vst3/test/host_harness.h` (consumed, unchanged from part 6)

## Acceptance Criteria

- [ ] `loopy_vst3_tremolo` builds a valid `.vst3` bundle; GUID-drift test
  passes; `test_tremolo_parity.cpp` passes, including the LFO
  block-boundary-phase check.
- [ ] Manual Ableton load check passes and is recorded in the PR.
- [ ] No change to `engine_fx.c`, `engine_fx.h`, `host_harness.h`/`.cpp`, or
  any file outside the new `vst3/tremolo/` tree and
  `CMakeLists.txt`/`run_native_tests.sh` wiring.
- [ ] Existing native test suite still passes.

## Out of Scope

Octaver (part 9); daw_export wiring (part 10); code signing (part 12);
Windows/Linux ports (parts 13-14).
