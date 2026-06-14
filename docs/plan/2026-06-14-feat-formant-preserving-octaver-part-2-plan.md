---
title: "feat: widen effect params 3->4 for octaver mode (octaver part 2)"
type: feat
date: 2026-06-14
---

## feat: widen effect params 3→4 for octaver mode — Standard (part 2 of 5)

> Part 2 of the formant-preserving octaver split
> ([umbrella](./2026-06-14-feat-formant-preserving-octaver-plan.md)). The
> **enabling, cross-stack** PR: it widens the effect param model so the octaver
> can later carry a `mode` selector. **No DSP changes** — the octaver still runs
> its current granular algorithm; the new `mode` param is stored but inert until
> parts 3–4. Isolating this lets the riskiest change (a global constant fanning
> through native, FFI, Dart, persistence, and l10n) land and stabilize alone.

## Overview

Bump the effect parameter width from **3 to 4** (`LE_FX_PARAMS` in C,
`kTrackEffectParams` in Dart) and add a discrete **Mode** control to the
octaver's UI param list only. Every other effect stays byte-for-byte unchanged
and gains no slider. Add the persistence migration so chains saved by the
3-param build still load.

## Problem Statement / Motivation

The octaver rewrite (parts 3–4) needs a 4th normalized param `p3 = mode`
(`< 0.5` → phase vocoder, `≥ 0.5` → PSOLA). The param array is a fixed global
width (`a_fx_param[LE_FX_MAX][LE_FX_PARAMS]`,
[loopy_engine_api.h:168](../../packages/loopy_engine/src/loopy_engine_api.h)),
so adding a param means widening that constant and every place that assumes the
old width — across two languages, the FFI boundary, persistence, and l10n.

## Proposed Solution

### Native (C)

- **`loopy_engine_api.h`**: `#define LE_FX_PARAMS 4`. The atomic arrays resize
  automatically.
- **`le_fx_default_params`** ([engine.c:2735](../../packages/loopy_engine/src/engine.c)):
  **every** `case` must write `out[3]` (B1). All non-octaver types set
  `out[3] = 0.0f` (inert). `LE_FX_OCTAVER` keeps `{0.25, 0.5, 0.5}` and adds
  `out[3] = 0.0f` (mode = PV). Audit each `case` body — none may leave `out[3]`
  unwritten or a later `for (p < LE_FX_PARAMS)` read returns garbage.
- **Confirm no effect reads `p[3]`** today (M3) — the granular octaver reads
  `p[0..2]`; the new `p[3]` is dormant until part 3.

### Dart model + UI

- **`kTrackEffectParams = 4`** ([track_effect.dart:13](../../packages/loopy_engine/lib/src/track_effect.dart)).
- **Per-type `params` lists** drive the editor (`fx.type.params.length` sliders,
  [effect_params_editor.dart:99](../../lib/common/effect_params_editor.dart)) —
  so **only the octaver's list grows**: append a **discrete `Mode`** entry
  (`divisions: 1` → 2 states) with a readout that maps `< 0.5` → "Phase Vocoder",
  `≥ 0.5` → "PSOLA". No other effect's list changes, so no other effect gains a
  slider.
- **`defaultParams` (B1)**: these are **separate** const lists from the slider
  metadata and are length-3 for **all eight** types
  ([track_effect.dart:108-117](../../packages/loopy_engine/lib/src/track_effect.dart)).
  Widen **all eight** to length 4 — append `0` to the seven non-octaver entries
  and append the mode default `0.0` to octaver. (Skipping the non-octaver entries
  leaves their `params.length` disagreeing with `kTrackEffectParams`.)
- **`fromJson` migration (B2 / D6)**: `TrackEffect.fromJson`
  ([track_effect.dart:174](../../packages/loopy_engine/lib/src/track_effect.dart))
  currently passes the decoded list through verbatim. Change it to **normalize to
  `kTrackEffectParams`**: truncate if longer; pad missing trailing slots with the
  **type's `defaultParams[i]`** (not a blanket `0.0`), so engine and editor agree
  even if a future default is non-zero. For octaver `p3` the per-type default is
  `0.0` (PV), giving the intended outcome.
- **l10n (N4)**: add the Mode label + "Phase Vocoder" / "PSOLA" readout keys to
  the **template ARB first** (`app_en.arb`), then `app_es.arb`, or
  `flutter gen-l10n` fails the build gate.
- **FFI**: regenerate `loopy_engine_bindings.dart` via ffigen (the width is a
  compile-time `#define`; this is doc/const sync).

## Dependencies

- None hard. Independent of part 1. Targets the full-stereo FX-chain branch so
  `le_fx_state` is already 2D. Parts 3–5 depend on this.

## Implementation Order

1. `loopy_engine_api.h`: `LE_FX_PARAMS 4`.
2. `engine.c` `le_fx_default_params`: write `out[3]` in **all** cases.
3. Native test: assert other effects unchanged after the widening (M3).
4. `track_effect.dart`: `kTrackEffectParams = 4`; octaver `params` += discrete
   Mode; widen **all** `defaultParams` to length 4; `fromJson` pad/truncate with
   per-type defaults.
5. l10n: template ARB first, then `es`; `flutter gen-l10n`.
6. ffigen regenerate `loopy_engine_bindings.dart`.
7. Dart tests (below). Register any native test in `main()`.
8. Gates: native `ALL PASSED`, `flutter analyze`, `flutter test`,
   `flutter build windows --debug`.

## Acceptance Criteria

- [ ] `LE_FX_PARAMS == 4` and `kTrackEffectParams == 4`.
- [ ] Every non-octaver effect's output is **byte-for-byte identical** to before
      the widening (native test) — none reads `p[3]`.
- [ ] The octaver editor shows a **discrete Mode** control (Phase Vocoder /
      PSOLA); every other effect shows its **original** slider count (no extra
      slider).
- [ ] A pre-rewrite **3-param** saved chain loads into a valid 4-param effect:
      octaver `mode` defaults to PV; UI does not crash.
- [ ] An over-long persisted `params` list is truncated to `kTrackEffectParams`.
- [ ] All eight `defaultParams` lists are length 4.
- [ ] `flutter gen-l10n` succeeds (keys present in template ARB).
- [ ] Gates green: native `ALL PASSED`, analyze clean, `flutter test` green,
      Windows debug build compiles.

## Testing

- **Native** (`test_engine_core.c`, registered in `main()`): widening leaves
  drive/filter/delay/tremolo/echo/reverb output unchanged on a mono input (can
  extend an existing FX test rather than add a new one).
- **Dart** (`packages/loopy_engine/test/.../track_effect_test.dart`):
  - `fromJson` with a **length-3 fixture** → length-4 `TrackEffect`, octaver
    `mode == 0.0` (PV) (B2/D6).
  - `fromJson` with a length-5 list → truncated to 4.
  - every `type.defaultParams.length == kTrackEffectParams`.
  - widget test: octaver editor renders the discrete Mode control; a sample
    non-octaver effect renders its original slider count (M3).

## Dependencies & Risks

- **Riskiest change in the whole feature** — a global constant across 2
  languages + FFI + persistence + l10n. Mitigated by isolating it here with the
  byte-for-byte and migration guards, before any DSP lands on top.
- **`defaultParams` vs slider metadata are two separate lists** (B1) — the most
  likely place to half-apply the widening; the AC pins both.
- **Persistence format bump** — the `fromJson` test with a real old-format
  fixture is the guard (B2).

## References & Research

- Param surface: `LE_FX_PARAMS`
  ([loopy_engine_api.h:168](../../packages/loopy_engine/src/loopy_engine_api.h)),
  `le_fx_default_params` ([engine.c:2735](../../packages/loopy_engine/src/engine.c)).
- Dart: `kTrackEffectParams`/`params`/`defaultParams`/`fromJson`
  ([track_effect.dart:13,64,108,174](../../packages/loopy_engine/lib/src/track_effect.dart));
  per-type slider loop
  ([effect_params_editor.dart:99](../../lib/common/effect_params_editor.dart)).
- Decisions D6 (persistence), M3 (other-effects inert) in the
  [umbrella](./2026-06-14-feat-formant-preserving-octaver-plan.md).
