---
title: "feat(vst3): Loopy Filter VST3 plugin — macOS (part 7)"
type: feat
date: 2026-07-08
part: 7 of 17
umbrella: ./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
---

> **Part 7 of the [Loopy FX as VST3 plugins](./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
> plan.** Shared design (D-SEAM, D-LINK, D-GUID, D-PARAM, D-NOGUI,
> D-ALL-EFFECTS) lives in the umbrella. Reuses part 6's generalized
> golden-parity harness unchanged — Filter is also a 2-param effect, no
> further harness work needed.

## Dependencies

Part 1 (`loopy_dsp_core` static lib). Part 6 (generalized `host_harness.h`
— consumed here, not modified further).

## Overview

`loopy_vst3_filter` wraps `LE_FX_FILTER` (`engine_fx.c`'s `fx_filter`, line
49) through the same seam and pattern as parts 2/3/5/6. No ring buffer, no
delay-family sizing concerns — structurally the same shape as Drive (part
6), just a different kernel and param pair.

## Tasks

- [ ] New source tree `packages/loopy_engine/vst3/filter/` —
  `processor.h/.cpp`, `controller.h/.cpp`, `ids.h`, `factory.cpp` (processor
  subcategory `"Fx|Filter"`).
- [ ] Mint the processor + controller GUIDs **now**, permanent (D-GUID).
  New `test_vst3_filter_ids.cpp`.
- [ ] `processor.cpp`: `le_fx_prepare(&fx, 0, LE_FX_FILTER, cap)` on
  activate, `le_fx_entry_reset` before first block, `fx_apply_chain(...,
  count=1, ...)` per block.
- [ ] `controller.cpp`: registers two `Vst::RangeParameter`s (Cutoff,
  Resonance) matching `TrackEffectType.filter`
  ([track_effect.dart:76-79](../../packages/loopy_engine/lib/src/track_effect.dart)),
  defaults from `le_fx_defaults(LE_FX_FILTER, ...)`.
- [ ] New CMake target block: `loopy_vst3_filter`, same link/bundle/codesign
  shape as prior parts.
- [ ] New `test_filter_parity.cpp` using the already-generalized harness
  (part 6) — 2-param sweep, edges + documented default.
- [ ] Manual verification: insert "Loopy Filter" on an audio track in
  Ableton; confirm Cutoff/Resonance ranges/defaults; play audio, confirm no
  clicks or unexpected resonance self-oscillation at extreme values;
  automate one parameter.

## File References

- New: `packages/loopy_engine/vst3/filter/` (processor, controller, ids,
  factory, `test_vst3_filter_ids.cpp`)
- New: `packages/loopy_engine/vst3/test/test_filter_parity.cpp`
- [core/engine_fx.c:49](../../packages/loopy_engine/src/core/engine_fx.c) (`fx_filter` kernel, reference only)
- [track_effect.dart:76-79,121-131](../../packages/loopy_engine/lib/src/track_effect.dart) (param metadata source of truth)
- `packages/loopy_engine/vst3/CMakeLists.txt` (new target block)
- `packages/loopy_engine/vst3/test/host_harness.h` (consumed, unchanged from part 6)

## Acceptance Criteria

- [ ] `loopy_vst3_filter` builds a valid `.vst3` bundle; GUID-drift test
  passes; `test_filter_parity.cpp` passes against the unmodified
  part-6-generalized harness.
- [ ] Manual Ableton load check passes and is recorded in the PR.
- [ ] No change to `engine_fx.c`, `engine_fx.h`, `host_harness.h`/`.cpp`, or
  any file outside the new `vst3/filter/` tree and
  `CMakeLists.txt`/`run_native_tests.sh` wiring.
- [ ] Existing native test suite still passes.

## Out of Scope

Tremolo (part 8); Octaver (part 9); daw_export wiring (part 10); code
signing (part 12); Windows/Linux ports (parts 13-14).
