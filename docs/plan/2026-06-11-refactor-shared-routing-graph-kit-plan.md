---
title: "refactor: shared routing-graph kit + thin graph views + full-bleed settings"
type: refactor
date: 2026-06-11
---

## ♻️ refactor: shared routing-graph kit + thin lane/monitor views + un-window settings — Extensive

## Overview

Two routing-graph widgets — `lib/looper/view/lane_graph_view.dart` (track routing,
PR #16) and `lib/audio_setup/view/monitor_graph_view.dart` (input monitoring,
PR #17) — duplicate the bulk of their drawing and layout code. Extract a small
**shared routing-graph kit of primitives**, rewrite both views *thin* on top of
it, retire the last surviving legacy graph widget, and take the settings page
**out of `SetupSurfacePanel`** so it is full-bleed instead of a constrained
940×640 "little window".

This is a pure refactor: no new user features, no change to the multi-lane or
dry/wet semantics. The bar is **behavioural parity** for both views.

## Problem Statement

1. **Duplication.** `_Edge` / `_PathPainter`, `_maybeFit` (fit-to-view), the
   fixed-curvature constant + clamp, `_Tappable`, `_ChannelNode`, `_FxCard`, and
   the `_GraphLayout` geometry approach are copied across both views. They have
   **already drifted**: monitor's `_Edge` is a value type with `==`/`hashCode`
   and a `dashed` flag and the painter uses `listEquals`; lane's `_Edge` has
   neither (reference-equality repaint, no dashing).
2. **`monitor_graph_view.dart` still reads heavy** even after one decomposition
   pass — the geometry, canvas, nodes, painter, and panel all live in one file.
3. **The settings page is a "little window".** `BigPictureSettingsPage` wraps
   its whole content (rail + section) in `SetupSurfacePanel` (`maxWidth: 940`,
   `maxHeight: 640`) — `lib/looper/view/big_picture_settings_page.dart:60`.
4. **Three graph implementations.** A legacy `lib/looper/view/routing_graph_view.dart`
   (`RoutingGraphView`) is *still* wired into the settings "Routing" section,
   alongside the two new ones.

## Goals / Non-Goals

**Goals**

- One shared graph-primitive module; both views become thin assemblers.
- A single graph implementation — retire legacy `RoutingGraphView`.
- Full-bleed settings page (no `SetupSurfacePanel`).
- **Zero behavioural regressions** in either graph view or the settings page.

**Non-Goals**

- New user-facing functionality; changing dry/wet or multi-lane behaviour.
- Redesigning the bottom panels / effect editors.
- A single generic `RoutingGraph` widget (rejected below — leaky API).

## Sequencing — Critical Prerequisite

The shared kit needs both views in one working tree.

**Current state (verified 2026-06-11):**

- **PR #16 (`feat/multilane-ui`) is already MERGED** — `origin/master` already
  contains `lib/looper/view/lane_graph_view.dart` and the legacy
  `lib/looper/view/routing_graph_view.dart`.
- **PR #17 (`feat/monitor-dry-wet`) is still OPEN** — this branch carries
  `lib/audio_setup/view/monitor_graph_view.dart` and is **4 ahead / 7 behind**
  `master` (it branched before #16 landed, so it does not yet see
  `lane_graph_view.dart`).

> **Decision:** Only **PR #17 remains to merge**. Merge it to `master` (or merge
> `master` into it first to resolve conflicts), then start this refactor on a
> fresh branch `refactor/routing-graph-kit` off `master` — at which point master
> holds **all three** views (`lane_graph_view`, `monitor_graph_view`,
> `routing_graph_view`) in one tree. Do **not** attempt a cross-branch extraction
> or a speculative rebase — resolve any shared-file conflicts (e.g. the
> `monitor_fx_editor.dart` deletion, `setup_surface.dart` additions) at merge
> time. **This refactor cannot start until PR #17 is merged.**

## Proposed Solution — Primitives, Not a God-Widget

The two views diverge in load-bearing ways, so a single generic `RoutingGraph`
widget would need a leaky, over-parameterized model. Extract **primitives**;
keep the view-specific assembly and panels in each view.

### New module: `lib/common/routing_graph/`

| File | Exposes | Notes |
|------|---------|-------|
| `graph_edge.dart` | `GraphEdge` value type `{from, to, color, faded, dashed}` + `==`/`hashCode` | one wire |
| `graph_edge_painter.dart` | `GraphEdgePainter` | fixed-handle curvature clamp; dashing via `computeMetrics`; **faded drawn first** (z-order); `shouldRepaint` via `listEquals` |
| `graph_canvas.dart` | `GraphCanvas` | `InteractiveViewer` + clip + fit-to-view; **re-fit keyed on a caller-supplied structural identity value object** (a record/list, *not* a hash int); body is a positioned `Stack` |
| `channel_chip.dart` | `ChannelChip` | a port node; `color` is **caller-resolved**, plus `strong`/`wired`/`excluded`/`onTap` |
| `effect_chain_card.dart` | `EffectChainCard`, `AddEffectButton` | drag handle + tappable label + delete; DnD with a **typed payload `GraphCardRef(rowId, index)`** + same-row drop guard; add-button keeps the **opaque wire-mask backdrop** |
| `effect_params_editor.dart` | `EffectParamsEditor` | **only** the type dropdown + param sliders; `accentColor` passed in (lane neutral, monitor wet) |
| `graph_geometry.dart` | fan/edge builders + column/row layout helpers + geometry constants | **fan builder supports N sends per row**, each with its own `(originX, originY, mask, color, dashed)` |
| `graph_colors.dart` | curvature/geometry constants; lane positional palette **and** wet/dry role colours, kept **separate** | |

### Kept per-view (do NOT generalise into the kit)

The bottom panel; the wet/dry **legend** (monitor only); per-lane **vol/mute**
(lane only); **add/remove-lane** (lane only, a stack); **Stop** + **Effected/Dry
toggle** (monitor only); the **output-node colour resolver** (different rule per
view); **input-tap meaning** (lane: set single input `-1=none`; monitor: start
monitoring + focus); and **selection ownership** (lane is parent-owned via
props/callbacks — inversion of control; monitor owns `_selected` internally and
drives the cubit).

### Lanes vs monitors — the asymmetries the kit must accommodate

| Concern | Lane | Monitor | Kit requirement |
|---|---|---|---|
| Output routes per row | **1** (output mask) | **2** (wet mask + dry mask) | fan builder takes **N sends**, each own origin/colour/dashed |
| Dry wire origin | n/a | node **bottom + offset** (`dryDrop`), *not* the chain tail — so it clears the cards | per-send Y origin; assert distinct Y |
| Input tap | sets the lane's single input (`-1`=none) | **starts monitoring** + focuses | port `onTap` fully caller-controlled |
| Node body | label + **vol slider + mute** | label + "live · not recorded" | node allows arbitrary body; no vol/mute in kit |
| Lifecycle | add/remove **lane** (stack) | **Stop** (disable) | not in kit |
| Selection state | **parent-owned** (prop + callback) | **internal** (cubit) | kit treats selection as prop+callback, never owns it |
| Output colour | by single user's **lane colour**, neutral if shared | `focusDry ‖ (none-focused & dry-only) ? amber : blue` | colour is a caller resolver |
| Colours | 8-hue **positional** palette | **wet/dry roles** (blue/amber) | keep palette vs roles as separate concepts |
| Dashing / legend | none | dry edges dashed + a wet/dry legend | edge `dashed` is shared; **legend stays in monitor** |
| Reorder DnD | drop-zones **between** cards (gap index) + insertion caret | `DragTarget` **on** each card (target index) | **unify the convention** (see Decisions) |

## Decisions (open questions resolved)

1. **Reorder convention → unify on the gap/insertion-index model** (lane's),
   with drop-zones between cards and an insertion caret; the monitor's
   `cubit.moveEffect` adapts (target slot = gap index). Rationale: the caret is a
   real affordance worth keeping; gap-index is the more expressive of the two.
2. **Legacy `RoutingGraphView` → migrate the settings "Routing" section to the
   shared kit / `LaneGraphView` and delete `routing_graph_view.dart`** (+ its
   test, ported). One graph implementation, not three.
3. **Param-slider accent → per-view** (passed into `EffectParamsEditor`): lane
   neutral, monitor wet. Do not unify.
4. **Settings full-bleed must preserve** the route's provider scope (the page is
   pushed **above** `LooperBloc`, so the Routing section reads repositories
   directly), Esc-to-close (`Focus(autofocus: true)` must stay outside the new
   wrapper), a `Material`/`Scaffold` ancestor (rail tabs use `Material` ink), and
   per-section scroll reset (`ValueKey(_section)`).

## Implementation Phases

> Each phase is its own commit; the **existing widget tests are the safety net**.
> Refactor lane first, then monitor, so regressions surface one view at a time.

### Phase 0 — Prerequisite
PR #16 is already merged; **merge PR #17 to `master`** (the only remaining gate),
then branch `refactor/routing-graph-kit` off `master`. (Before refactoring, **add
a dry-edge geometry assertion** to the monitor test — see R1 — so the most
dangerous regression is caught.)

### Phase 1 — Extract the kit; rewrite `LaneGraphView` thin
Create `lib/common/routing_graph/*`. Move the painter/edge/canvas/chip/card/
geometry out of `lane_graph_view.dart`; the view keeps only its layout assembly,
vol/mute, add/remove-lane, output-colour resolver, and parent-owned selection.
`flutter test` (all existing lane tests pass unchanged) + add parity tests.
Regenerate the lane golden (`track_routing_dialog.png`).

### Phase 2 — Rewrite `MonitorGraphView` thin on the kit
Compose the kit primitives; supply the **two-send (wet+dry) geometry** with
dry-from-below, the output-colour resolver, internal selection, Stop, the
Effected/Dry toggle, and the legend. Parity tests + the dry-edge-origin
assertion. Regenerate the monitor golden.

### Phase 3 — Retire legacy `RoutingGraphView`
Point the settings "Routing" section at the shared kit / `LaneGraphView`; delete
`routing_graph_view.dart` and its test (port coverage). Verify the section still
sources `LooperRepository`/`SettingsRepository` from the route scope.

### Phase 4 — Un-window the settings page
Remove `SetupSurfacePanel` from `big_picture_settings_page.dart`; render
full-bleed (a full-screen `Scaffold` supplying `Material` + `backgroundColor:
bg`); keep `CallbackShortcuts` + `Focus(autofocus: true)` outside the new
wrapper; preserve per-section scroll reset and the rail. Delete `SetupSurfacePanel`
if it is then unused (**verify onboarding `audio_setup_view` does not use it**).
Regenerate settings goldens.

## Acceptance Criteria (parity-focused)

### Shared kit / graph parity
- [ ] Fan builder supports **N sends per row** with per-send `(origin, colour,
      dashed)`; the monitor **dry edge originates at node-bottom + offset**, at a
      **Y distinct from the wet edge** — asserted by a test (or golden).
- [ ] Port-node colour is a **caller resolver**; parity tests: lane shared-output
      → neutral accent; monitor output used by dry-only → amber; by both → blue.
- [ ] **Focus is caller-controlled** (port taps never auto-manage focus). Both
      stale-focus guards covered: remove the focused lane → focus clears; Stop the
      focused monitor → focus + selection clear; selected effect index beyond a
      shrunk chain → editor hides, no crash.
- [ ] **Selection is prop + callback**, never kit-owned (lane's IoC contract
      holds; monitor keeps its internal/cubit ownership).
- [ ] **Re-fit identity is a structural value object** (not a hash int):
      toggling a mask or focusing does **not** re-fit; adding a lane/effect or a
      channel-count change **does**.
- [ ] Reorder convention **unified**: dragging `[A,B,C]` so C lands before A
      yields the same final order in **both** views; the insertion caret is
      preserved for lane; the **same-row drop guard** holds (a drag from row 0 is
      rejected by row-1 targets).
- [ ] Add-effect button renders an **opaque wire-mask backdrop** in both views.
- [ ] `GraphEdge` is a value type; painter uses `listEquals`; **no per-frame
      repaint** when edges are unchanged.
- [ ] Colours: lane palette resolves by **lane index**; monitor by **send role**;
      neither conflated.

### Settings full-bleed
- [ ] **Esc closes** settings both with no prior interaction and after tapping a
      control.
- [ ] A `Material` ancestor is present (rail tab taps ripple; no "No Material
      widget found" assertion).
- [ ] Switching sections **resets scroll** to top.
- [ ] The rail does **not overflow** at small window heights.
- [ ] The Routing section's `LooperRepository`/`SettingsRepository` remain in
      scope; the section renders with the engine **running and stopped**.

### Hygiene
- [ ] All existing lane / monitor / settings widget tests pass; native engine
      tests unaffected; `flutter analyze` + `dart format` clean; goldens
      regenerated; `RoutingGraphView` deleted; `SetupSurfacePanel` deleted if
      unused.

## Success Metrics

- `monitor_graph_view.dart` and `lane_graph_view.dart` each shrink to mostly
  layout-assembly + their own panel (the painter/edge/canvas/chip/card code
  lives once in `lib/common/routing_graph/`).
- Exactly **one** graph implementation remains.
- The settings page fills the window; the monitor routing page already does.

## Risks & Mitigation

- **R1 — Dual-route geometry silently dropped.** There is **no test today** for
  the dry edge's origin/Y. *Mitigation:* add the dry-edge-origin assertion in
  Phase 0, before touching code; keep a monitor golden.
- **R2 — Over-general, leaky kit.** *Mitigation:* primitives only; the
  lanes-vs-monitors table is the guardrail; panels/selection/legend/vol-mute/Stop
  stay per-view.
- **R3 — Reorder index mismatch.** Lane uses gap-index, monitor target-index.
  *Mitigation:* pick gap-index, adapt both call sites, parity-test the result.
- **R4 — Settings full-bleed regressions** (Esc / Material / scroll / provider
  scope). *Mitigation:* the explicit criteria above + tests; keep the route mount
  point unchanged.
- **R5 — Cross-branch sequencing.** *Mitigation:* #16 already merged; merge #17
  before starting; no speculative rebase.
- **R6 — Large refactor of two complex custom-painted views.** *Mitigation:*
  existing widget tests as the net; lane then monitor incrementally; review the
  golden diffs.

## Files (touch list)

- **New:** `lib/common/routing_graph/{graph_edge,graph_edge_painter,graph_canvas,channel_chip,effect_chain_card,effect_params_editor,graph_geometry,graph_colors}.dart` + tests under `test/common/routing_graph/`.
- **Rewritten thin:** `lib/looper/view/lane_graph_view.dart`,
  `lib/audio_setup/view/monitor_graph_view.dart`.
- **Migrated + deleted:** the settings "Routing" section caller;
  `lib/looper/view/routing_graph_view.dart` (+ test).
- **Un-windowed:** `lib/looper/view/big_picture_settings_page.dart`;
  `lib/setup/setup_surface.dart` (delete `SetupSurfacePanel` if unused).
- **Goldens regenerated:** `track_routing_dialog.png`, the monitor render, the
  settings screenshots.

## Future Considerations

- A VST3-host effect type slots into the shared `EffectChainCard` unchanged.
- A third routing graph (if one appears) is served by the kit for free.
- The shared `GraphCanvas` could later gain mini-map / snap-to-grid without
  touching either view.
