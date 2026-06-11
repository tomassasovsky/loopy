---
title: "refactor: decompose monitor graph view into file-per-widget (part 3)"
type: refactor
date: 2026-06-11
branch: refactor/routing-graph-kit
---

## ♻️ refactor: decompose `monitor_graph_view` into file-per-widget — Part 3 of 3

## Dependencies

- **Part 1** (`…-part-1-plan.md`) must merge first — the monitor view must
  already consume `package:routing_graph` and import `EffectParamsEditor` from
  `lib/common/` before it is split.
- **Independent of Part 2** (different directory, `lib/audio_setup/view/` vs
  `lib/looper/view/`); can be developed in parallel and merged in either order
  after Part 1.

## Overview

`lib/audio_setup/view/monitor_graph_view.dart` (~800 lines) is the larger
monolith: a `_GraphLayout` god-object with terse constants (`chW`, `nodeW`,
`rowH`), `// ====` ASCII dividers, private widget-returning methods, and the
wet/dry legend + its painter all in one file. Decompose into idiomatic
**one-widget-per-file** siblings under `lib/audio_setup/view/monitor_graph/`.
**App-only, behaviour-preserving.**

## Problem Statement

The file mixes the page entry (`showMonitorRoutingPage`), the
`StatefulWidget`/`State` assembly, the layout/geometry value object, the monitor
node body, the bottom route panel, the legend, and the legend painter. As in
Part 2, Dart file-scoped privacy means the sub-widgets become **app-public**
(no doc-churn — the app doesn't enforce `public_member_api_docs`).

## Proposed Solution

Folder `lib/audio_setup/view/monitor_graph/`:

| File | Contents |
|------|----------|
| `monitor_graph_view.dart` | `showMonitorRoutingPage` + `MonitorGraphView` `StatefulWidget` + `State` — thin assembly only |
| `monitor_graph_layout.dart` | `MonitorGraphLayout` (computed geometry, **dual-route** wet/dry sends) with **descriptive** field names replacing `chW`/`nodeW`/`rowH`/`fanGap` |
| `monitor_node.dart` | `MonitorNode` ("In N monitor · live · not recorded") |
| `route_panel.dart` | `RoutePanel` (Effected/Dry toggle + Stop + `EffectParamsEditor` slot) |
| `route_legend.dart` | `RouteLegend` + the wet/dry swatch painter |

- Remove every `// ====` / `// ----` divider.
- Shared card metrics + `positionedNode` + `buildEffectDropZones` come from
  `package:routing_graph`; the monitor-specific geometry (incl. `dryDrop`,
  two-send fan) stays in `monitor_graph_layout.dart` with descriptive names.
- `RoutePanel` imports `EffectParamsEditor` from `lib/common/`.
- Keep all `monitorGraph_*` keys.
- **R1 carry-over:** the R1 dry-edge geometry assertion (dry send originates at a
  distinct Y, dashed) is covered by the package geometry test (Part 1); the
  monitor view's two-send wiring stays unchanged.

## Implementation Phases

### Phase 1 — Extract the layout
Pull the geometry into `monitor_graph_layout.dart` as `MonitorGraphLayout`;
descriptive constant names (values unchanged). View imports it. `flutter
analyze` + monitor tests green.

### Phase 2 — Extract the widgets
Move `MonitorNode`, `RoutePanel`, and `RouteLegend` (+ its painter) into their
own files (app-public). `monitor_graph_view.dart` keeps `showMonitorRoutingPage`
+ the `StatefulWidget`/`State` assembly only. Remove dividers.

### Phase 3 — Validate
`flutter analyze` + `dart format` clean; monitor tests green (no goldens for the
monitor view — parity is the widget tests + the package geometry test).

## Acceptance Criteria

- [ ] `monitor_graph_view.dart` is **thin** (`showMonitorRoutingPage` + the
      StatefulWidget/State assembly); `MonitorGraphLayout`, `MonitorNode`,
      `RoutePanel`, `RouteLegend` are separate sibling files under
      `lib/audio_setup/view/monitor_graph/`.
- [ ] No `// ====` / `// ----` dividers; no `chW`/`nodeW`/`rowH`-style terse
      constants — descriptive names, values unchanged.
- [ ] `RoutePanel` imports `EffectParamsEditor` from `lib/common/`.
- [ ] All `monitorGraph_*` keys preserved; monitor widget tests pass unchanged
      (incl. the gap-index reorder + Stop + dry-toggle tests).
- [ ] `flutter analyze` + `dart format` clean.

## Risks & Mitigation

- **R1 — Behaviour regression in the 800-line split.** *Mit:* monitor widget
  tests as the net; keys preserved; the package geometry test guards the
  dry-edge geometry.
- **R2 — `showMonitorRoutingPage` context contract.** It re-provides
  `MonitorCubit` via `BlocProvider.value` into a pushed route; the caller's
  `context` must still be a `MonitorCubit` ancestor. *Mit:* keep the function's
  body identical; the existing page test covers it.
- **R3 — Privacy → public surface.** *Mit:* app-public sub-widgets, not exported.

## Files (touch list)

- **New:** `lib/audio_setup/view/monitor_graph/{monitor_graph_view,monitor_graph_layout,monitor_node,route_panel,route_legend}.dart`.
- **Deleted:** `lib/audio_setup/view/monitor_graph_view.dart` (content moved into
  the folder).
- **Edited:** importers of `showMonitorRoutingPage` (import path); the monitor
  test import path if it references the file directly.
