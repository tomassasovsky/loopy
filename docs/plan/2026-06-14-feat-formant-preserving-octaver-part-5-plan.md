---
title: "feat: expose octaver added-latency + UI hint (octaver part 5)"
type: feat
date: 2026-06-14
---

## feat: expose octaver added-latency + UI hint — Standard (part 5 of 5)

> Part 5 of the formant-preserving octaver split
> ([umbrella](./2026-06-14-feat-formant-preserving-octaver-plan.md)). Surfaces the
> active octaver's added latency through the engine snapshot so the UI can warn a
> performer ("Phase Vocoder adds ~21 ms — use PSOLA for live monitoring"). Can be
> developed in **parallel with part 4** (it needs only `le_octaver_latency` from
> part 3). Record-offset auto-compensation remains **out of scope**.

## Overview

Add a per-engine **added-latency** field to the published snapshot, populate it
control-side from the active octaver's `le_octaver_latency()`, and render an
informational hint in the Flutter effect UI. This is the only user-visible part
of D3; the load-bearing latency *compensation* is deferred to a future
record-offset PR.

## Problem Statement / Motivation

The octaver runs on **monitor lanes** (live input monitoring), and the phase
vocoder adds ~21 ms. The existing latency harness measures only device loopback
and feeds the **record** offset
([loopy_engine_api.h:45,335,520](../../packages/loopy_engine/src/loopy_engine_api.h));
nothing models per-effect latency. A performer monitoring through a PV octaver has
no way to know why they feel lag, or that PSOLA is the low-latency choice.

## Proposed Solution

> **B4 — this is a real public-surface (ABI + ffigen) change, not a "reuse."** The
> snapshot struct (`le_engine_snapshot`, ~loopy_engine_api.h:320–346) carries only
> measurement-latency fields today; there is **no** per-effect latency field to
> reuse. Specify it to the same rigor as the param-width change.

### Native

- **`loopy_engine_api.h`**: add a concrete field to the published snapshot, e.g.
  `int32_t fx_added_latency_frames;` (units: **frames**, matching
  `record_offset_frames`; the Dart side converts to ms with the sample rate).
  Document semantics: the **maximum** added latency across active effects in any
  audible/monitored chain (an octaver is the only contributor today; max keeps it
  forward-compatible).
- **Backing atomic + writer**: back it with a published atomic on the engine,
  written on the **control thread** when an octaver's `mode`/type changes (latency
  depends on the active mode — `LE_PV_N` for PV, ~`period` for PSOLA), and folded
  into the snapshot in the existing snapshot-build path. Audio thread only reads.
- **ffigen**: regenerate `loopy_engine_bindings.dart` for the new field.

### Dart / UI

- Read `fxAddedLatencyFrames` from the snapshot; convert to ms.
- Render a hint in the effect UI when an octaver is present and `mode = PV`
  (e.g. "Phase Vocoder adds ~21 ms — use PSOLA for live monitoring"). Localized
  (template ARB first, then `es`).

## Dependencies

- **Part 3** (`le_octaver_latency` helper + the octaver state). Independent of
  part 4 — PSOLA's latency value is approximated until part 4 lands, which is fine
  for an informational hint.

## Implementation Order

1. `loopy_engine_api.h`: add `fx_added_latency_frames` to the snapshot; document
   units/semantics.
2. `engine.c`: backing atomic; write on octaver mode/type change; populate in the
   snapshot-build path.
3. ffigen regenerate `loopy_engine_bindings.dart`.
4. Flutter: read + convert + render the localized hint; l10n keys (template ARB
   first, N4).
5. Tests below. Gates: native `ALL PASSED`, `flutter analyze`, `flutter test`,
   `flutter build windows --debug`.

## Acceptance Criteria

- [ ] The snapshot reports `fx_added_latency_frames` ≈ `LE_PV_N` when a PV octaver
      is active, the **clamped** PSOLA latency (~one grain, capped at the ~80 Hz
      value per part 4) for PSOLA, and 0 when no octaver is in an audible chain.
- [ ] The UI shows the latency hint when a PV octaver is present, and not
      otherwise.
- [ ] The hint string is localized (present in the template ARB + `es`).
- [ ] ffigen output includes the new field; FFI round-trips it.
- [ ] Record-offset behavior is **unchanged** (compensation explicitly out of
      scope; documented).
- [ ] Gates green: native `ALL PASSED`, analyze clean, `flutter test` green,
      Windows debug build compiles.

## Testing

- **Native** (`test_engine_core.c`, registered in `main()`): with a PV octaver in
  a lane, the built snapshot's `fx_added_latency_frames == LE_PV_N`; with no
  octaver, `== 0`.
- **Dart/widget**: the latency hint renders when the snapshot reports PV-octaver
  latency and is absent otherwise; ms conversion uses the sample rate correctly.

## Dependencies & Risks

- **Public ABI change** (B4) — same care class as part 2's param width; the field
  semantics (frames, max-across-effects) are pinned in the AC.
- **Scope discipline** — this surfaces latency only; auto-aligning overdub timing
  for an in-chain octaver is a separate, larger change (out of scope, documented).

## References & Research

- Latency surface: `le_latency_state` / `measured_latency_ms` /
  `record_offset_frames`
  ([loopy_engine_api.h:45,335,520](../../packages/loopy_engine/src/loopy_engine_api.h)).
- `le_octaver_latency`: [part 3](./2026-06-14-feat-formant-preserving-octaver-part-3-plan.md).
- D3 (latency policy), H2 (monitor latency): [umbrella](./2026-06-14-feat-formant-preserving-octaver-plan.md).
