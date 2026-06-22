---
title: "refactor: domain models for the effects type cluster (D2a)"
type: refactor
date: 2026-06-19
---

## PR 2a (D2 — effects cluster) — Repository-owned effect domain models

> Part 2 of 4. Parent plan:
> [2026-06-19-refactor-enforce-repository-layer-boundaries-plan.md](2026-06-19-refactor-enforce-repository-layer-boundaries-plan.md).
> Source finding: [docs/code-review/architecture-review.md](../code-review/architecture-review.md) (D2).

## Overview

The `looper_repository` barrel re-exports raw `loopy_engine` effect/track types, leaking
engine shapes into the effect-editing, routing-graph, and monitor UI. This PR introduces
repository-owned domain equivalents for the **effects cluster**, transforms at the repository
boundary, updates the consuming files, and stops re-exporting those raw types.
Behavior-preserving.

## Problem Statement

`packages/looper_repository/lib/looper_repository.dart:5-24` re-exports `TrackEffect`,
`TrackEffectType`, `TrackEffectParam`, `ParamReadout` (plus others handled in Part 3). These
flow into ~10 `lib/` files. A change to `loopy_engine`'s effect shapes ripples into the UI.

## Technical Approach

Define domain effect models in `packages/looper_repository/lib/src/models/`, map at the
repository boundary, and switch consumers to the domain types.

**Keepers (do NOT domain-wrap — documented barrel exceptions):**

- `encodeTrackEffects` / `decodeTrackEffects` — pure engine wire-format serializers. Wrapping
  hides coupling without removing it; keep re-exported.
- `kTrackEffectMax`, `kTrackEffectParams` — stable native constants referenced in `lib/`
  (`track_routing_dialog`, monitor panels). Keep re-exported.
- `TrackState` — already surfaced through the existing `Track` / `LooperState` domain models.
  Keep it as a `show` re-export (or expose as a field on `Track`); **no new enum, no mapping
  pass.**

## Tasks

- [ ] Define domain `TrackEffect`, `TrackEffectType`, `TrackEffectParam`, `ParamReadout` in
      `packages/looper_repository/lib/src/models/` (immutable `Equatable`).
- [ ] Map engine↔domain effect types at the repository boundary (where `LooperRepository`
      already projects snapshots and where effect chains are read/written).
- [ ] Update consumers to the domain types: `lib/common/effect_params_editor.dart`,
      `lib/looper/view/track_routing_dialog.dart`, `lib/looper/view/lane_graph/lane_graph_view.dart`,
      `lib/audio_setup/cubit/monitor_cubit.dart`,
      `lib/audio_setup/view/monitor_graph/monitor_graph_view.dart`,
      `lib/audio_setup/view/monitor_graph/monitor_lane_panel.dart`,
      `lib/looper/bloc/looper_event.dart`, `lib/looper/bloc/looper_bloc.dart`,
      `lib/l10n/localized.dart` (effects portion), `lib/theme/looper_theme.dart`.
- [ ] Confirm `TrackState` consumers (`big_picture_view`, `pedal_cubit`, `looper_theme`,
      `localized`) resolve it via the domain `Track`/re-export — no behavior change.
- [ ] Remove `TrackEffect`, `TrackEffectType`, `TrackEffectParam`, `ParamReadout` from the
      `looper_repository` barrel `export ... show` list; keep the documented keepers.
- [ ] **Tests:** update existing effect/routing/monitor tests to domain types. Add round-trip
      mapping tests asserting effect-param **ordering** and enum-value parity (not just field
      equality) at the boundary.

## Acceptance Criteria

- [ ] No `lib/` file names `TrackEffect` / `TrackEffectType` / `TrackEffectParam` /
      `ParamReadout` from `loopy_engine`; they come from `looper_repository` domain models.
- [ ] Effect editing, routing graphs, monitor lanes, and track-state colors behave exactly
      as before.
- [ ] `flutter analyze` + `bloc_lint` clean; full suite green.

## Dependencies

- **Requires Part 1 (V1) merged** — keeps the `app.dart` / `run_loopy.dart` wiring stable and
  avoids mid-flight merge conflicts.
- Blocks Part 3 (both edit the barrel + shared `localized.dart` / `app.dart`).

## References

- Barrel: [packages/looper_repository/lib/looper_repository.dart:5-24](../../packages/looper_repository/lib/looper_repository.dart)
- Heaviest consumer: [lib/looper/view/track_routing_dialog.dart](../../lib/looper/view/track_routing_dialog.dart)
- Effect editor: [lib/common/effect_params_editor.dart](../../lib/common/effect_params_editor.dart)
