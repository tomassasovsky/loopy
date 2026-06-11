---
title: "refactor: decompose lane graph view into file-per-widget (part 2)"
type: refactor
date: 2026-06-11
branch: refactor/routing-graph-kit
---

## ♻️ refactor: decompose `lane_graph_view` into file-per-widget — Part 2 of 3

## Dependencies

- **Part 1** (`…-part-1-plan.md`) must merge first — the lane view must already
  consume `package:routing_graph` and import `EffectParamsEditor` from
  `lib/common/` before it is split.
- Independent of Part 3 (different directory); A → B → C or A → C → B.

## Overview

`lib/looper/view/lane_graph_view.dart` (~700 lines) is a monolith: a `_LaneLayout`
god-object with terse constants (`chW`, `laneW`), `// ====` ASCII dividers, and
several private widget-returning methods. Decompose it into idiomatic
**one-widget-per-file** siblings under `lib/looper/view/lane_graph/`, matching
how the rest of the codebase is organised. **App-only, behaviour-preserving.**

## Problem Statement

The file mixes: the `StatefulWidget`/`State` assembly, the layout/geometry value
object, the lane node body, and the bottom panel — in one 700-line file with
ASCII section dividers and opaque constant names. Dart privacy means the
sub-widgets can't move to sibling files while staying `_private` (privacy is
library/file-scoped); they become **app-public** widgets (no leading underscore)
in their own files — the app does **not** enforce `public_member_api_docs`, so
there is no doc-churn cost.

## Proposed Solution

Folder `lib/looper/view/lane_graph/`:

| File | Contents |
|------|----------|
| `lane_graph_view.dart` | `LaneGraphView` `StatefulWidget` + `State` — **thin assembly** only (build → `GraphCanvas` children + `LanePanel`) |
| `lane_graph_layout.dart` | `LaneGraphLayout` (the computed geometry value object) with **descriptive** field names (`channelChipWidth`, `laneNodeWidth`, `laneRowHeight`, `fanGutter`, …) replacing `chW`/`laneW`/etc. |
| `lane_node.dart` | `LaneNode` (name + mute icon + read-only volume level) |
| `lane_panel.dart` | `LanePanel` (focused-lane vol/mute/remove + `EffectParamsEditor` slot + add-lane) |

- Remove every `// ====` / `// ----` divider — the files replace them.
- The shared card metrics + `positionedNode` + `buildEffectDropZones` come from
  `package:routing_graph` (Part 1); the lane-specific geometry stays in
  `lane_graph_layout.dart` with descriptive names.
- `LanePanel` imports `EffectParamsEditor` from `package:loopy/common/effect_params_editor.dart`.
- Keep all existing widget keys (`laneGraph_*`) so tests/goldens don't move.

## Implementation Phases

### Phase 1 — Extract the layout
Pull the layout value object into `lane_graph_layout.dart` as
`LaneGraphLayout`; rename terse constants to descriptive names (values
unchanged). View imports it. `flutter analyze` + lane tests green.

### Phase 2 — Extract the widgets
Move the lane node body → `LaneNode` (`lane_node.dart`) and the panel →
`LanePanel` (`lane_panel.dart`), each app-public. `lane_graph_view.dart` keeps
only the `StatefulWidget`/`State` assembly. Remove dividers. Update
`track_routing_dialog.dart`'s import to `lane_graph/lane_graph_view.dart`.

### Phase 3 — Validate
`flutter analyze` + `dart format` clean; lane + `track_routing_dialog` tests
green; `track_routing_dialog.png` golden **unchanged** (the pixel net).

## Acceptance Criteria

- [ ] `lane_graph_view.dart` is **thin** (StatefulWidget + State assembly only);
      `LaneGraphLayout`, `LaneNode`, `LanePanel` are separate sibling files under
      `lib/looper/view/lane_graph/`.
- [ ] No `// ====` / `// ----` dividers; no `chW`/`laneW`-style terse constants —
      descriptive names with values unchanged.
- [ ] `LanePanel` imports `EffectParamsEditor` from `lib/common/`.
- [ ] All `laneGraph_*` keys preserved; lane + `track_routing_dialog` widget
      tests pass unchanged; `track_routing_dialog.png` golden **unchanged**.
- [ ] `flutter analyze` + `dart format` clean.

## Risks & Mitigation

- **R1 — Behaviour regression in the split.** *Mit:* existing lane +
  `track_routing_dialog` tests; keys preserved; `track_routing_dialog.png` is the
  pixel check (confirm green pre/post).
- **R2 — Privacy → public surface.** *Mit:* sub-widgets become app-public (no
  doc enforcement in the app); they remain feature-internal (not exported).

## Files (touch list)

- **New:** `lib/looper/view/lane_graph/{lane_graph_view,lane_graph_layout,lane_node,lane_panel}.dart`.
- **Deleted:** `lib/looper/view/lane_graph_view.dart` (content moved into the folder).
- **Edited:** `lib/looper/view/track_routing_dialog.dart` (import); the lane test
  import path if it references the file directly.
