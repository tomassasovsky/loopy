---
title: "feat(vst3): Loopy Reverb VST3 plugin — macOS (part 3)"
type: feat
date: 2026-07-08
part: 3 of 12
umbrella: ./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md
---

> **Part 3 of the [Loopy FX as VST3 plugins](./2026-07-08-feat-loopy-fx-vst3-plugins-plan.md)
> pilot.** Shared design lives in the umbrella. Reuses part 2's proven
> scaffolding (CMake target shape, factory pattern, bundle packaging) for the
> **harder** of the two pilot kernels.

## Dependencies

Part 2 (proves the wrapper/CMake/packaging pattern once; this part repeats it
for a structurally more complex kernel rather than re-deriving it).

## Overview

A new CMake target, `loopy_vst3_reverb`, builds "Loopy Reverb" wrapping
`LE_FX_REVERB` — a Schroeder/Freeverb network (8 comb filters + 4 allpass
diffusers, run as `LE_REV_BANKS=2` parallel stereo banks,
[engine_private.h:110-119](../../packages/loopy_engine/src/core/engine_private.h))
through the same `engine_fx.h` seam as part 2. Structurally identical
plugin shape (`AudioEffect`+`EditController`, no custom GUI, hand-rolled
CMake/bundle packaging) — the added risk here is specifically the
**stereo-bus handling**: `fx_reverb` reads/writes both channels together
(`xl`, `xr`) and Ableton always feeds a stereo bus, so this needs no
mono-adaptation logic, but must be verified: a **mono source seeds `l == r`**
per the engine's own documented convention
([engine_private.h:143-144](../../packages/loopy_engine/src/core/engine_private.h)),
and the wrapper must preserve that exactly, not diverge from how
`fx_apply_chain` is invoked in the live engine.

## Tasks

- [ ] New source tree `packages/loopy_engine/vst3/reverb/` — mirrors part 2's
  `delay/` layout (`processor.h/.cpp`, `controller.h/.cpp`, `ids.h`,
  `factory.cpp`).
- [ ] Mint the Reverb processor + controller GUIDs now, permanent per D-GUID,
  with the same drift regression test pattern as part 2.
- [ ] `processor.cpp`: `le_fx_prepare(&fx, 0, LE_FX_REVERB, cap)` on activate
  (allocates the comb/allpass state via the vtable's `prepare` entry,
  `fx_reverb_prepare`); `fx_apply_chain` per block exactly as part 2, with
  `LE_FX_REVERB`'s 3 params (Size, Damping, Mix).
- [ ] `controller.cpp`: three `Vst::RangeParameter`s (Size, Damping, Mix)
  matching `TrackEffectType.reverb`'s metadata
  ([track_effect.dart:108-112](../../packages/looper_repository/lib/src/models/track_effect.dart)),
  defaults from `le_fx_defaults(LE_FX_REVERB, ...)`.
- [ ] `factory.cpp`: subcategory `"Fx|Reverb"`.
- [ ] `packages/loopy_engine/vst3/CMakeLists.txt`: add the `loopy_vst3_reverb`
  target alongside `loopy_vst3_delay`, sharing the same `loopy_dsp_core` +
  plugin-disabled-stub + SDK link set and dev-install pattern from part 2.
- [ ] Manual verification: same checklist as part 2 (Ableton load, param
  list/ranges, audio, automation), plus an explicit **mono-input check**
  (feed a mono clip, confirm the output is a coherent stereo reverb tail, not
  silence or a collapsed mono sum — proving `l == r` seeding is preserved).

## File References

- New: `packages/loopy_engine/vst3/reverb/` (processor, controller, ids, factory)
- [packages/loopy_engine/vst3/CMakeLists.txt](../../packages/loopy_engine/vst3/CMakeLists.txt) (extended, from part 2)
- [core/engine_fx.c:660-718](../../packages/loopy_engine/src/core/engine_fx.c) (`fx_reverb`, read-only reference for behavior, not reimplemented)
- [engine_private.h:110-119,143-144](../../packages/loopy_engine/src/core/engine_private.h) (comb/allpass layout + mono-seeding convention)
- [track_effect.dart:108-112](../../packages/looper_repository/lib/src/models/track_effect.dart) (param metadata source of truth)

## Acceptance Criteria

- [ ] `loopy_vst3_reverb` builds a valid `.vst3` bundle on macOS.
- [ ] GUID-drift regression test passes.
- [ ] Manual Ableton load check passes, including the mono-input stereo-tail
  check.
- [ ] No change to `engine_fx.c`/`engine_fx.h`; no change to part 2's Delay
  plugin.
- [ ] Existing native test suite still passes unchanged.

## Out of Scope

Golden-parity automated diff (part 4); daw_export wiring (part 5); code
signing/notarization (part 7); Windows/Linux ports (parts 8-9).
</content>
