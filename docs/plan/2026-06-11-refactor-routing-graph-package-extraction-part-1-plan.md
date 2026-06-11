---
title: "refactor: extract routing_graph package + wire app theme (part 1)"
type: refactor
date: 2026-06-11
branch: refactor/routing-graph-kit
---

## ♻️ refactor: extract a reusable `routing_graph` package + wire the app theme — Part 1 of 3

## Dependencies

- **None.** Builds on the 8 prior commits already on `refactor/routing-graph-kit`.
- Parts 2 (lane decomposition) and 3 (monitor decomposition) **depend on this PR**
  — the views must consume `package:routing_graph` before they are split.

## Overview

Move the generic routing-graph UI primitives out of the app
(`lib/common/routing_graph/`) into a real, reusable Flutter package
`packages/routing_graph`, following VGV `ui-package` / `layered-architecture` /
`material-theming` conventions. The two graph views keep their current
(monolithic) shape in this PR — they simply consume the package. Decomposition is
Parts 2 & 3.

Pure structural refactor; **behavioural parity** is the bar.

## Problem Statement

The "kit" lives inside the app, reads the app's private `SurfaceTheme`, bundles
five public items in one file (`effect_chain_card.dart`), and is consumed by
**three** views (`lane_graph_view.dart`, `monitor_graph_view.dart`,
`tracks_routing_graph_view.dart`). It is not reusable by anything but this app.

## Grounding — VGV conventions (from the plugin suite)

- UI package = its own path-dependency package; **no** repository/data deps.
- Package defines its **own** `ThemeExtension` (`copyWith` + `lerp`), read via
  `context`; the app registers it on `ThemeData`, mapping from its own tokens.
  Neutral structural colours live in the extension; **caller-specific semantic
  colours stay constructor params.**
- One public widget per file; barrel-only imports (never `src/`).
- `public_member_api_docs` **enforced** at package level (the app disables it) —
  every public class/ctor/named-param/fn/const needs a dartdoc.
- `test/` mirrors `lib/src/`; `pump_app` registers the package theme.

## Proposed Solution

### Package layout

```
packages/routing_graph/
├── analysis_options.yaml          # include: very_good_analysis (NO overrides)
├── pubspec.yaml                   # publish_to: none, version 0.1.0, flutter SDK only, very_good_analysis dev
├── lib/
│   ├── routing_graph.dart         # barrel: library doc + export 'package:flutter/material.dart' + public API
│   └── src/
│       ├── theme/routing_graph_theme.dart   # RoutingGraphTheme + RoutingGraphThemeX(context)
│       └── widgets/
│           ├── graph_card_ref.dart          # GraphCardRef  (split out of effect_chain_card.dart)
│           ├── channel_chip.dart             # ChannelChip
│           ├── graph_canvas.dart             # GraphCanvas
│           ├── graph_edge.dart               # GraphEdge
│           ├── graph_edge_painter.dart       # GraphEdgePainter
│           ├── effect_chain_card.dart        # EffectChainCard
│           ├── effect_drop_zone.dart         # EffectDropZone + buildEffectDropZones (split out)
│           ├── add_effect_button.dart        # AddEffectButton (split out)
│           └── graph_geometry.dart           # GraphSend + cardColumnXs/chainEdges/fanEdges/positionedNode + kRoutingCard* (cohesive geometry module)
└── test/{helpers/pump_app.dart, src/theme/…_test.dart, src/widgets/…_test.dart}
```

> No `dart_test.yaml` golden tag — the package has **no** goldens (goldens stay
> app-side, gated by `@Tags(['screenshots'])`). Package tests are plain widget
> tests.

### `RoutingGraphTheme` (package-local)

Neutral structural tokens only: `background, surface, card, cardHigh, line,
textPrimary, textSecondary, textTertiary`; with `copyWith` + `lerp` + an
`extension RoutingGraphThemeX on BuildContext { RoutingGraphTheme get
routingGraph => Theme.of(this).extension<RoutingGraphTheme>()!; }`. Package
widgets read **neutral** tokens via `context.routingGraph`. **Semantic colours
stay constructor params** (`ChannelChip.color`, `EffectChainCard.accentColor`,
`EffectDropZone.accentColor`, `AddEffectButton.accentColor`, `GraphSend.color`,
`GraphEdge.color`, `buildEffectDropZones(accentColor:)`).

### App wiring

- Root `pubspec.yaml`: add `routing_graph: { path: packages/routing_graph }`.
- `lib/theme/app_theme.dart`: register `RoutingGraphTheme(...)` in **both**
  `AppTheme.desktop` and `AppTheme.bigPicture` `extensions:` lists, mapping each
  token from `SurfaceTheme.dark`.
- Repoint the **three** consumers to `package:routing_graph/routing_graph.dart`:
  `lane_graph_view.dart`, `monitor_graph_view.dart`,
  `tracks_routing_graph_view.dart`.
- **Move** `effect_params_editor.dart` (domain-coupled to `TrackEffectType`) to
  `lib/common/effect_params_editor.dart` — **not** into the package, and **not**
  under one feature's `view/` (both `looper` and `audio_setup` use it). It keeps
  importing `looper_repository` + `context.surface`.
- Delete `lib/common/routing_graph/`.

## Implementation Phases

> Each phase its own commit. Continue on `refactor/routing-graph-kit`.
> **Before starting: confirm `track_routing_dialog.png` golden is green** (it has
> `failures/` artifacts on disk — the real lane-graph pixel net is this golden,
> rendered via `track_routing_dialog.dart`).

### Phase 1 — Scaffold
`very_good create flutter_package routing_graph --output-directory packages`
(or hand-author to the `packages/settings_repository` shape). Set pubspec,
`analysis_options.yaml` (very_good_analysis, no overrides), barrel with a library
doc. `flutter analyze` the empty package clean.

### Phase 2 — `RoutingGraphTheme`
Create the extension (`copyWith` + `lerp` + `RoutingGraphThemeX`), fully
documented. Unit-test `copyWith`/`lerp`.

### Phase 3 — Move + split + document the primitives
Move the 6 generic widgets + geometry into `lib/src/widgets/`, **one widget per
file** (split `effect_chain_card.dart`). Swap **neutral** `context.surface.*` →
`context.routingGraph.*`; keep `accentColor`/semantic params. **Document every
public member + named parameter** (incl. the top-level geometry functions —
`fanEdges` has 6 params). Barrel exports all. Move the kit tests
(`graph_geometry_test`, `graph_edge_test`) into `packages/routing_graph/test/`,
add per-widget tests with a package `pump_app` that registers `RoutingGraphTheme`.
`flutter test` in the package green.

### Phase 4 — Wire the app
Add the path dep; register `RoutingGraphTheme` in both `AppTheme` variants
(mapped from `SurfaceTheme.dark`). Repoint the three view imports to the barrel.
Move `EffectParamsEditor` → `lib/common/effect_params_editor.dart`. Delete
`lib/common/routing_graph/`. Update both bare-`ThemeData` sites in
`test/screenshots/settings_screenshots_test.dart` to add `RoutingGraphTheme`.
App `flutter analyze` + full suite + goldens green.

## Acceptance Criteria

### Package
- [ ] `packages/routing_graph` exists; root pubspec has the path dep; **all**
      app consumers import the **barrel**, never `src/`.
- [ ] **Zero** `looper_repository` / `loopy_engine` imports under the package
      (grep clean); `flutter pub deps` shows flutter SDK only.
- [ ] `analysis_options.yaml` = `very_good_analysis`, **no** overrides;
      `flutter analyze` clean with `public_member_api_docs` satisfied on every
      public class/ctor/param/fn/const.
- [ ] One public widget per file; `effect_chain_card.dart` split into
      `graph_card_ref` + `effect_chain_card` + `effect_drop_zone` +
      `add_effect_button`.
- [ ] `RoutingGraphTheme` implements `copyWith` + `lerp`; package widgets read
      neutral tokens via `context.routingGraph`; semantic colours
      (`accentColor`, wet/dry, lane) remain constructor params.
- [ ] Package `test/` mirrors `lib/src/`; package `pump_app` registers
      `RoutingGraphTheme`; package `flutter test` green.

### App
- [ ] `AppTheme.desktop` **and** `bigPicture` register `RoutingGraphTheme` mapped
      from `SurfaceTheme.dark`. **A test asserts** `RoutingGraphTheme`'s tokens
      equal the corresponding `SurfaceTheme.dark` values (anti-drift).
- [ ] `EffectParamsEditor` lives at `lib/common/effect_params_editor.dart` (still
      imports `looper_repository`); both `looper` and `audio_setup` views import
      it from there.
- [ ] `lib/common/routing_graph/` deleted; the three views consume the package.
- [ ] Both bare-`ThemeData` sites in `settings_screenshots_test.dart` register
      `RoutingGraphTheme`.
- [ ] **No test regressions** (moved geometry/edge tests pass in the package;
      app graph tests unchanged — selectors preserved); `track_routing_dialog.png`
      + settings goldens unchanged; `flutter analyze` + `dart format` clean across
      app + package.

## Risks & Mitigation

- **R1 — `public_member_api_docs` churn** (every package param documented).
  *Mit:* one-time doc pass in Phase 3; analyze gates it.
- **R2 — Theme not registered in a test → null-assert.** *Mit:* package
  `pump_app` registers it; app `pumpApp` already uses `AppTheme.bigPicture`; both
  screenshot `ThemeData` sites add it.
- **R3 — Cross-feature import of the moved editor.** *Mit:* `EffectParamsEditor`
  → `lib/common/`, imported by both features.
- **R4 — Domain leak into the package.** *Mit:* editor stays app-side; grep for
  `looper_repository` under the package in CI/criteria.
- **R5 — Pixel regression.** *Mit:* `track_routing_dialog.png` is the lane-graph
  golden; confirm it's green before starting and after.

## Files (touch list)

- **New package:** `packages/routing_graph/{pubspec,analysis_options}.yaml`,
  `lib/routing_graph.dart`, `lib/src/theme/routing_graph_theme.dart`,
  `lib/src/widgets/{graph_card_ref,channel_chip,graph_canvas,graph_edge,graph_edge_painter,effect_chain_card,effect_drop_zone,add_effect_button,graph_geometry}.dart`,
  `test/**`.
- **Moved:** `lib/common/effect_params_editor.dart` (from the kit).
- **Edited:** root `pubspec.yaml`; `lib/theme/app_theme.dart`;
  `lib/looper/view/lane_graph_view.dart`, `lib/audio_setup/view/monitor_graph_view.dart`,
  `lib/looper/view/tracks_routing_graph_view.dart` (imports);
  `test/screenshots/settings_screenshots_test.dart` (both `ThemeData` sites);
  new anti-drift theme test.
- **Deleted:** `lib/common/routing_graph/`.
