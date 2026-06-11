---
title: "refactor: extract routing_graph package + decompose graph views"
type: refactor
date: 2026-06-11
branch: refactor/routing-graph-kit
---

> **Note:** This plan has been split into parts. See the `-part-1` (package
> extraction + wiring), `-part-2` (lane view decomposition), and `-part-3`
> (monitor view decomposition) files in this directory. The corrections from the
> technical review (the three view consumers incl. `tracks_routing_graph_view`,
> the `track_routing_dialog.png` golden as the real pixel net, `EffectParamsEditor`
> moving to `lib/common/`, dropping the package `dart_test.yaml` golden tag, the
> anti-drift theme test, both screenshot `ThemeData` sites, and "no regressions"
> instead of a fixed test count) are folded into the part files; build from those.

## ♻️ refactor: extract a reusable `routing_graph` package + decompose the graph views — Extensive

## Overview

The routing-graph UI primitives currently live in `lib/common/routing_graph/`
(7 files) inside the app, read the app's `SurfaceTheme` extension, and are
consumed by two **monolithic** views (`lane_graph_view.dart` ~600 lines,
`monitor_graph_view.dart` ~800 lines) that bundle a layout "god object" with
terse constants (`chW`, `nodeW`), `// ====` ASCII section dividers, and many
private widget-returning methods. None of this matches how this codebase is
written: genuinely reusable code is a **path-dependency package under
`packages/`** (like `looper_repository`, `loopy_engine`), and `lib/<feature>/
view/` is **file-per-widget**.

This plan does what the VGV plugin suite prescribes:

1. **Extract** the generic, domain-agnostic, app-agnostic primitives into a new
   **`packages/routing_graph`** Flutter package (`very_good_analysis`,
   `public_member_api_docs` enforced), with its **own** `RoutingGraphTheme`
   ThemeExtension — no dependency on `looper_repository` or the app's
   `SurfaceTheme`.
2. **Decompose** both graph views into idiomatic **one-widget-per-file** units,
   killing the god-object/ASCII-divider style.

This is a pure structural refactor — **behavioural parity** is the bar; all 268
tests + goldens stay green.

## Grounding — VGV plugin-suite conventions (authoritative)

Synthesised from the `vgv-ai-flutter-plugin` **ui-package**,
**layered-architecture**, **material-theming**, and **testing** skills:

- **A UI package is its own path-dependency package**; it must **not** depend on
  any repository/data package. (layered-architecture)
- **Package defines its own `ThemeExtension`** (`copyWith` + `lerp` required),
  read via `Theme.of(context).extension<…>()`. The **app** registers it on
  `ThemeData`, mapping from its own tokens. Neutral structural colours live in
  the extension; **caller-specific semantic colours stay constructor params.**
  (material-theming / ui-package)
- **One public widget per file**, snake_case filename = widget name. (ui-package)
- **`public_member_api_docs` is enforced** at package level (the app disables
  it) — **every** public class, constructor, **named parameter**, method, and
  top-level constant needs a dartdoc comment. (very_good_analysis)
- Barrel `lib/<name>.dart` re-exports `material.dart` + public API; consumers
  import the barrel only, **never `src/`**. (ui-package / layered-architecture)
- `test/` mirrors `lib/src/`; `pump_app` helper registers the package theme;
  golden tests tagged. (testing)
- No raw `Function` (use `VoidCallback`/`ValueChanged<T>`); `const` constructors
  where possible; `super.key`. (ui-package)

## Problem Statement

1. **Not actually reusable.** The "kit" lives in `lib/common/` inside the app,
   reads the app's private `SurfaceTheme`, and one file
   (`effect_chain_card.dart`) bundles five public items
   (`GraphCardRef`, `EffectChainCard`, `EffectDropZone`, `AddEffectButton`,
   `buildEffectDropZones`). It cannot be consumed by anything but this app.
2. **Monolithic views.** `lane_graph_view.dart` / `monitor_graph_view.dart` each
   carry a `_GraphLayout`/`_LaneLayout` god object (terse `chW`/`nodeW`
   constants), `// ====` dividers, and many `_xxx()` widget-returning methods —
   non-idiomatic and hard to read.
3. **Domain leak.** `EffectParamsEditor` imports `looper_repository`
   (`TrackEffect`/`TrackEffectType`) — it cannot live in a reusable package.

## Goals / Non-Goals

**Goals**

- A real `packages/routing_graph` package: generic, domain-agnostic,
  app-agnostic, self-themed, fully documented, with its own tests.
- The app consumes it via a path dependency + barrel import; `AppTheme`
  registers `RoutingGraphTheme` mapped from `SurfaceTheme`.
- Both graph views decomposed into one-widget-per-file siblings; no god object,
  no ASCII dividers, descriptive names.
- **Zero behavioural regressions**; analyze + tests + goldens green.

**Non-Goals**

- Changing any graph behaviour, dry/wet semantics, or visuals.
- Generalising `EffectParamsEditor` into the package (it is domain UI — stays in
  the app).
- A `melos` workspace (the repo uses manual `path:` deps — keep that).

## Proposed Solution

### New package: `packages/routing_graph`

Scaffold with `very_good create flutter_package routing_graph --output-directory
packages`. Final structure:

```
packages/routing_graph/
├── analysis_options.yaml          # include: very_good_analysis (no overrides)
├── pubspec.yaml                   # publish_to: none, flutter SDK only, very_good_analysis
├── dart_test.yaml                 # golden tag declaration
├── lib/
│   ├── routing_graph.dart         # barrel: library doc + export material + public API
│   └── src/
│       ├── theme/
│       │   └── routing_graph_theme.dart   # RoutingGraphTheme + RoutingGraphThemeX(context)
│       └── widgets/
│           ├── graph_card_ref.dart        # GraphCardRef value type
│           ├── channel_chip.dart          # ChannelChip
│           ├── graph_canvas.dart          # GraphCanvas
│           ├── graph_edge.dart            # GraphEdge
│           ├── graph_edge_painter.dart    # GraphEdgePainter
│           ├── effect_chain_card.dart     # EffectChainCard
│           ├── effect_drop_zone.dart      # EffectDropZone + buildEffectDropZones
│           ├── add_effect_button.dart     # AddEffectButton
│           └── graph_geometry.dart        # GraphSend + cardColumnXs/chainEdges/fanEdges/positionedNode + kRoutingCard* (cohesive geometry module)
└── test/
    ├── helpers/{pump_app.dart,helpers.dart}
    └── src/{theme/…_test.dart, widgets/…_test.dart}
```

#### `RoutingGraphTheme` (package-local ThemeExtension)

Neutral structural tokens only (mirrors `SurfaceTheme`'s neutral subset):
`background, surface, card, cardHigh, line, textPrimary, textSecondary,
textTertiary`; with `copyWith` + `lerp` + `extension RoutingGraphThemeX on
BuildContext { RoutingGraphTheme get routingGraph => Theme.of(this)
.extension<RoutingGraphTheme>()!; }`.

**Caller-supplied semantic colours stay constructor params** (already are):
`ChannelChip.color`, `EffectChainCard.accentColor`, `EffectDropZone.accentColor`,
`AddEffectButton.accentColor`, `GraphSend.color`, `GraphEdge.color`,
`buildEffectDropZones(accentColor:)`. Package widgets read **neutral** tokens
from `context.routingGraph`, never the app's `context.surface`.

### Kept in the app (domain / presentation layer)

- **`EffectParamsEditor`** → moves to `lib/looper/view/effect_params_editor.dart`
  (app presentation). Keeps `looper_repository` import; reads `context.surface`.
  Used by both views.
- **The graph views' assembly + layout** (lane/monitor layout geometry, node
  bodies, panels, legend) — decomposed per view (below).

### App theme wiring

In `lib/theme/app_theme.dart`, both `AppTheme.desktop` and `AppTheme.bigPicture`
add `RoutingGraphTheme(...)` to their `extensions:` list, mapping each token from
`SurfaceTheme.dark`. (`SurfaceTheme` stays — it's the app's broader token set;
`RoutingGraphTheme` is the package's narrower view of it.)

### View decomposition (one-widget-per-file)

**Lane** (`lib/looper/view/lane_graph/`):
| File | Contents |
|------|----------|
| `lane_graph_view.dart` | `LaneGraphView` StatefulWidget + State (thin assembly only) |
| `lane_graph_layout.dart` | the layout value object, **descriptive** field names (`channelChipWidth`, `laneNodeWidth`, `laneRowHeight`, …), documented |
| `lane_node.dart` | `LaneNode` (name + mute + vol level) |
| `lane_panel.dart` | `LanePanel` (focused-lane controls + editor slot + add-lane) |

**Monitor** (`lib/audio_setup/view/monitor_graph/`):
| File | Contents |
|------|----------|
| `monitor_graph_view.dart` | `MonitorGraphView` + State + `showMonitorRoutingPage` |
| `monitor_graph_layout.dart` | layout value object, descriptive names |
| `monitor_node.dart` | `MonitorNode` |
| `route_panel.dart` | `RoutePanel` (toggle + stop + editor slot) |
| `route_legend.dart` | `RouteLegend` + its line painter |

> Folder-per-graph keeps siblings together while honouring file-per-widget.
> Remove every `// ====` / `// ----` divider; the files replace them. Replace
> terse constants with descriptive names + dartdoc.

## Implementation Phases

> Each phase is its own commit; existing widget tests + goldens are the safety
> net. Continue on the existing `refactor/routing-graph-kit` branch.

### Phase 1 — Scaffold the package
`very_good create flutter_package routing_graph --output-directory packages`.
Set `pubspec.yaml` (`publish_to: none`, `version: 0.1.0`, flutter SDK,
`very_good_analysis: ^10.2.0`), `analysis_options.yaml` (include
very_good_analysis, **no** overrides), `dart_test.yaml` (golden tag). Empty
barrel with a library doc comment. `flutter analyze` the empty package clean.

### Phase 2 — `RoutingGraphTheme`
Create `lib/src/theme/routing_graph_theme.dart` (extension + `copyWith` + `lerp`
+ `RoutingGraphThemeX`), fully documented. Unit test `lerp`/`copyWith`.

### Phase 3 — Move + split the generic primitives
Move the 6 generic widgets + geometry into `lib/src/widgets/`, **one widget per
file** (split `effect_chain_card.dart` → `graph_card_ref` + `effect_chain_card` +
`effect_drop_zone` + `add_effect_button`). Swap **neutral** `context.surface.*`
reads → `context.routingGraph.*`; keep `accentColor` params. **Document every
public member + named parameter** (public_member_api_docs). Barrel exports all.
Move the kit tests (`graph_geometry_test`, `graph_edge_test`) into
`packages/routing_graph/test/src/`, add per-widget tests with a package
`pump_app` that registers `RoutingGraphTheme`. `flutter test` in the package.

### Phase 4 — Wire the app to the package
Add `routing_graph: { path: packages/routing_graph }` to root `pubspec.yaml`.
Register `RoutingGraphTheme(...)` in both `AppTheme` variants (mapped from
`SurfaceTheme.dark`). Repoint app imports to
`package:routing_graph/routing_graph.dart`. Delete `lib/common/routing_graph/`
(except `effect_params_editor.dart`, which **moves** to
`lib/looper/view/effect_params_editor.dart`). App `flutter analyze` clean.

### Phase 5 — Decompose the lane view
Split into `lib/looper/view/lane_graph/` (view + layout + node + panel) with
descriptive names, no dividers. Update `track_routing_dialog.dart` import. Lane
+ dialog tests pass unchanged; lane golden unchanged.

### Phase 6 — Decompose the monitor view
Split into `lib/audio_setup/view/monitor_graph/` (view + layout + node + panel +
legend). Update any importer (`showMonitorRoutingPage` callers). Monitor tests
pass unchanged.

### Phase 7 — Final validation
`flutter analyze` (app + package) clean; `dart format` clean; full app suite +
package suite green; goldens unchanged (regenerate only if intentional). Verify
`packages/routing_graph` has **zero** repository deps (`flutter pub deps`).

## Acceptance Criteria

### Package
- [ ] `packages/routing_graph` exists; root pubspec has the path dep; consumers
      import the **barrel** only (no `src/` imports anywhere).
- [ ] **Zero** `looper_repository` / `loopy_engine` imports under the package
      (`grep` clean); `flutter pub deps` shows flutter SDK only.
- [ ] Package `analysis_options.yaml` includes `very_good_analysis` with **no**
      overrides; `flutter analyze` clean with `public_member_api_docs` satisfied
      (every public class/ctor/param/fn/const documented).
- [ ] One public widget per file; `effect_chain_card.dart` split into four files.
- [ ] `RoutingGraphTheme` implements `copyWith` + `lerp`; package widgets read
      neutral tokens via `context.routingGraph`; semantic colours
      (`accentColor`, wet/dry, lane) remain constructor params.
- [ ] Package has its own tests (`test/` mirrors `lib/src/`) with a `pump_app`
      that registers `RoutingGraphTheme`; package `flutter test` green.

### App
- [ ] `AppTheme.desktop` **and** `AppTheme.bigPicture` register
      `RoutingGraphTheme` mapped from `SurfaceTheme.dark`.
- [ ] `EffectParamsEditor` lives in the app presentation layer (still imports
      `looper_repository`); not in the package.
- [ ] `lane_graph_view.dart` and `monitor_graph_view.dart` are **thin assembly**;
      node/panel/layout/legend are separate files with **descriptive** names; no
      `// ====`/`// ----` dividers; no `chW`/`nodeW`-style terse constants.
- [ ] All 268 app tests + package tests pass; goldens unchanged (lane dialog +
      settings); `flutter analyze` + `dart format` clean across app + package.

### Parity (must not regress)
- [ ] Dry-edge geometry (distinct-Y, dashed) still asserted by the moved geometry
      test. Reorder gap-index convention unchanged. Re-fit structural identity,
      focus/selection lifecycle, Esc-close settings — all unchanged.

## Risks & Mitigation

- **R1 — public_member_api_docs churn.** Every package param needs a doc. *Mit:*
  Phase 3 budgets for it; analyze gates the phase.
- **R2 — Theme not registered in a test → null-assert.** Package widgets need
  `RoutingGraphTheme`; app pumps need it via `AppTheme`. *Mit:* package
  `pump_app` registers it; app `AppTheme` registers it (app `pumpApp` already
  uses `AppTheme.bigPicture`); the settings screenshot test's bare `ThemeData`
  adds it.
- **R3 — Behavioural regression in a 1400-line decomposition.** *Mit:* existing
  widget tests + goldens; split per view; keys preserved (`keyPrefix` scheme).
- **R4 — Domain leak slips into the package.** *Mit:* `EffectParamsEditor` stays
  app-side; CI-style grep for `looper_repository` under the package.
- **R5 — Geometry constant rename breaks layout.** *Mit:* rename is mechanical
  (values unchanged); lane golden is the pixel check.

## Files (touch list)

- **New package:** `packages/routing_graph/{pubspec,analysis_options,dart_test}.yaml`,
  `lib/routing_graph.dart`, `lib/src/theme/routing_graph_theme.dart`,
  `lib/src/widgets/{graph_card_ref,channel_chip,graph_canvas,graph_edge,graph_edge_painter,effect_chain_card,effect_drop_zone,add_effect_button,graph_geometry}.dart`,
  `test/**`.
- **Moved to app:** `lib/looper/view/effect_params_editor.dart` (from the kit).
- **New app view files:** `lib/looper/view/lane_graph/{lane_graph_view,lane_graph_layout,lane_node,lane_panel}.dart`;
  `lib/audio_setup/view/monitor_graph/{monitor_graph_view,monitor_graph_layout,monitor_node,route_panel,route_legend}.dart`.
- **Edited:** root `pubspec.yaml` (path dep), `lib/theme/app_theme.dart`
  (register `RoutingGraphTheme`), `lib/looper/view/track_routing_dialog.dart`
  (import), importers of `showMonitorRoutingPage`.
- **Deleted:** `lib/common/routing_graph/` (primitives now in the package;
  editor moved).
- **Tests moved/updated:** kit geometry/edge tests → package; app graph tests
  unchanged (selectors preserved); settings screenshot `ThemeData` gains
  `RoutingGraphTheme`.

## Future Considerations

- A third graph (or another app) can depend on `routing_graph` directly.
- `RoutingGraphTheme` could later gain typography tokens if package widgets grow
  text styles.
- If `very_good create` is unavailable, hand-author the package to the same
  shape (mirrors the existing `packages/*` layout).
