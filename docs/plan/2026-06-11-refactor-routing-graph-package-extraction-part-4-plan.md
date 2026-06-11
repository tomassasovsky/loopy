---
title: "refactor: decompose tracks routing graph view + model (part 4)"
type: refactor
date: 2026-06-11
branch: refactor/routing-graph-part-4
---

## ♻️ refactor: decompose `tracks_routing_graph_view` into model + file-per-widget — Part 4 of 4

## Dependencies

- **Part 1** (`…-part-1-plan.md`) merged — the view already consumes
  `package:routing_graph` (`GraphEdge`/`GraphEdgePainter`).
- **Independent of Parts 2 & 3** (different files). Part 1 only *repointed* this
  view's imports; it was never split. This is the last routing-graph monolith.

## Overview

`lib/looper/view/tracks_routing_graph_view.dart` (~612 lines) is the
whole-system "big picture" routing diagram — a **different** graph from the
per-track lane and per-input monitor views (it keeps its own all-tracks node
model, responsive column layout, and arm/hover/target interaction). Unlike its
two siblings it bundles a full **domain model** (`RoutingNodeKind`,
`RoutingNode`, `RoutingEdge`, `RoutingGraph.fromTracks`, `RoutingEdit`) into the
same file as the `StatefulWidget`/`State`, the `_GraphNode` widget, and a
`Widget _positionedNode(...)` widget-returning method.

Decompose into idiomatic siblings under `lib/looper/view/tracks_routing_graph/`:
the pure model in its own files, a thin view, and an app-public node widget.
**App-only, behaviour-preserving.**

## Problem Statement

One 612-line file mixes four concerns: (1) the pure graph **model** + its
`fromTracks` builder (no Flutter); (2) the `RoutingEdit` value object + the
`editForTarget` routing logic (pure); (3) the `TracksRoutingGraphView`
assembly; (4) the `_GraphNode` body. It carries the same `Widget
_positionedNode(...)` builder-method smell the earlier parts removed, plus a
domain/presentation tangle the lane/monitor views didn't have. (Its few
view-layout constants — `nodeWidth`/`nodeHeight`/`_rowHeight`/`_topPad` — are
already descriptively named and stay on the view; there is no god-object
constant block to rename here.) The model is exported only via the `looper.dart`
barrel, so the public surface can be preserved while the files move.

## Proposed Solution

Folder `lib/looper/view/tracks_routing_graph/`:

| File | Contents |
|------|----------|
| `routing_graph.dart` | `RoutingNodeKind`, `RoutingNode`, `RoutingEdge`, `RoutingGraph` (+ `fromTracks`) — the pure graph model. Imports **only** `package:flutter/foundation.dart` (`@immutable`/`listEquals`) + `package:looper_repository/looper_repository.dart` (`Track`). **Not** the `routing_graph` package (whose barrel re-exports Material) — so the Flutter-free boundary actually holds. |
| `routing_edit.dart` | `RoutingEdit` + `RoutingEdit.forTarget(Track, RoutingNode)` — the static `editForTarget` logic **moved off the widget** (it is pure routing logic, not view code). Imports `foundation` + `looper_repository` + the local `routing_graph.dart` only. |
| `graph_node.dart` | `RoutingGraphNode` (was `_GraphNode`) — app-public; **renamed only**. Its existing precomputed-prop API (`node`/`armed`/`isTarget`/`connected`/`hovered`/`interactive`/`onTap`/`onHover`) is unchanged. |
| `tracks_routing_graph_view.dart` | `TracksRoutingGraphView` `StatefulWidget` + `State` — **thin assembly** only. Keeps the `routing_graph` package import (it needs `GraphEdge`/`GraphEdgePainter`). |

### Decisions (per the feature request)

- **Model lives beside the view** (`view/tracks_routing_graph/`), not a new
  `model/` layer: these are **view-models** (a drawable graph derived from
  `Track`s for one widget), matching how Parts 2/3 kept `*_layout.dart` next to
  their views. Keeping the family co-located is the established convention.
- **`editForTarget` → `RoutingEdit.forTarget`** (pure `Track`+`RoutingNode` →
  `RoutingEdit?`); its test group moves with it. **`nodeCenter` stays on the
  view** as a `@visibleForTesting static` — it is layout geometry (needs the
  rendered `Size`), not domain logic.
- **No widget-returning methods.** Inline `_positionedNode` per the Part 2/3
  rule (inline single-use assembly; keep *data*-returning helpers). `_wires`
  (→`List<GraphEdge>`) and `nodeCenter` (→`Offset`) stay as data helpers. The
  per-node visual state stays a **data** helper too (the monitor `outChips`
  pattern): add `_nodeState(RoutingNode node, Track? armedTrack)` returning
  `({bool isArmedTrack, bool isTarget, bool? connected})`, precompute a
  `Map<RoutingNode, …>` over all nodes once in `build`, then the `Stack`
  children inline `for (final node in [...inputs, ...tracks, ...outputs])
  Positioned(<nodeCenter geometry>, child: RoutingGraphNode(node: node, armed:
  states[node]!.isArmedTrack, isTarget: …, connected: …, hovered: _hovered ==
  node, interactive: _editable, onTap: …, onHover: …))`. `RoutingGraphNode` is
  unchanged (dumb) — no constructor redesign, lowest-risk for a behaviour-
  preserving move; the only removed thing is the `Widget _positionedNode` wrapper.
- Remove every `// ====` / `// ----` divider.

### Barrel + import stability

- `lib/looper/looper.dart` currently `export 'view/tracks_routing_graph_view.dart';`
  Replace with exports of the new model + view files —
  `view/tracks_routing_graph/{routing_graph,routing_edit,tracks_routing_graph_view}.dart` —
  so `RoutingNode`/`RoutingNodeKind`/`RoutingEdge`/`RoutingGraph`/`RoutingEdit`/
  `TracksRoutingGraphView` stay public through the barrel exactly as before.
  **Do not export `graph_node.dart`** — `_GraphNode` was private, so
  `RoutingGraphNode` stays feature-internal (not a new public type).
- **Why this part touches the barrel when Parts 2/3 didn't:** the lane/monitor
  widgets were always feature-internal (path-imported, never barrelled), so
  their split changed no public surface. This view *and its model* were already
  public via the `looper.dart` barrel, so re-exporting the moved files is what
  *preserves* the existing surface — the conservative choice, not a new one.
- Update the one direct importer, `lib/looper/view/big_picture_settings_page.dart`
  (it uses only `TracksRoutingGraphView`), to the new view path.

## Implementation Phases

Each phase leaves the tree green (no broken intermediate): every reference moves
in the **same** phase as its definition.

### Phase 1 — Extract the model
Move `RoutingNodeKind`/`RoutingNode`/`RoutingEdge`/`RoutingGraph` →
`routing_graph.dart`; move `RoutingEdit` + `editForTarget` (as
`RoutingEdit.forTarget`) → `routing_edit.dart`. **In the same phase**, repoint
the barrel exports, the view's `_onChannelTap` call site (→
`RoutingEdit.forTarget`), and the domain test call sites — so nothing dangles.
`flutter analyze` + the existing tests green.

### Phase 2 — Extract the node + thin the view
`_GraphNode` → `RoutingGraphNode` (`graph_node.dart`), **rename only** (API
unchanged). `tracks_routing_graph_view.dart` keeps the `StatefulWidget`/`State`
only; replace `_positionedNode` with the inline `for`-loop + `_nodeState`
data-helper map (above); remove dividers. Update `big_picture_settings_page.dart`'s
import. `flutter analyze` + tests green.

### Phase 3 — Split the tests + validate
Split `tracks_routing_graph_view_test.dart` along the seam into
`test/looper/view/tracks_routing_graph/`:
`routing_graph_test.dart` (the `RoutingGraph.fromTracks` group),
`routing_edit_test.dart` (the `editForTarget` group, now `RoutingEdit.forTarget`),
`tracks_routing_graph_view_test.dart` (the widget group). `nodeCenter` stays a
`@visibleForTesting` static on the view exercised indirectly — **no new unit
tests**. `flutter analyze` + `dart format` clean; all groups pass; keys preserved.

## Acceptance Criteria

- [ ] Pure model (`RoutingNodeKind`/`RoutingNode`/`RoutingEdge`/`RoutingGraph`)
      in `routing_graph.dart`; `RoutingEdit` + `forTarget` in `routing_edit.dart`;
      `RoutingGraphNode` in `graph_node.dart`; `TracksRoutingGraphView` thin in
      `tracks_routing_graph_view.dart` — all under
      `lib/looper/view/tracks_routing_graph/`.
- [ ] `routing_graph.dart` imports only `foundation` + `looper_repository` (no
      `routing_graph` package / no Material) — the model is genuinely Flutter-free.
- [ ] No `// ====` / `// ----` dividers; no `Widget _positionedNode`-style
      widget-returning methods (data helpers `_wires`/`nodeCenter`/`_nodeState`
      may stay).
- [ ] `looper.dart` barrel re-exports the model + view so the public surface is
      unchanged; `graph_node.dart` is **not** exported.
- [ ] All `routingGraph_*` / `routingNode_*` widget keys preserved; every
      existing tracks-routing test passes (the `editForTarget` group's call site
      updated to `RoutingEdit.forTarget` — the one intentional test change).
- [ ] `flutter analyze` + `dart format` clean.

## Risks & Mitigation

- **R1 — Behaviour regression in the 612-line split.** *Mit:* the existing
  domain + widget tests are the net; keys preserved; behaviour unchanged.
- **R2 — Public-API drift via the barrel.** Moving the model could silently drop
  a public type. *Mit:* barrel re-exports `routing_graph.dart` + `routing_edit.dart`
  + the view; confirm the test's `package:loopy/looper/looper.dart` import still
  resolves every type with no source change beyond `RoutingEdit.forTarget`.
- **R3 — Privacy → public surface.** `_GraphNode` → `RoutingGraphNode` becomes
  app-public. *Mit:* keep it **out of the barrel** (feature-internal, as it was).
- **R4 — `editForTarget` relocation churn.** *Mit:* it is a pure static; only the
  view's `_onChannelTap` and the moved test group reference it — both updated.

## Files (touch list)

- **New:** `lib/looper/view/tracks_routing_graph/{routing_graph,routing_edit,graph_node,tracks_routing_graph_view}.dart`.
- **Deleted:** `lib/looper/view/tracks_routing_graph_view.dart`.
- **Edited:** `lib/looper/looper.dart` (barrel exports); `lib/looper/view/big_picture_settings_page.dart` (import path).
- **Tests:** split `test/looper/view/tracks_routing_graph_view_test.dart` →
  `test/looper/view/tracks_routing_graph/{routing_graph_test,routing_edit_test,tracks_routing_graph_view_test}.dart`.
- **Out of scope (do not stage):** the 4 unrelated uncommitted theme WIP files
  (`big_picture_view.dart`, `looper_view.dart`, `looper_theme.dart`,
  `looper_theme_test.dart`) + `.portfolio-output/`.
