---
title: Unified Signal Surface
type: feat
date: 2026-06-22
---

## Unified Signal Surface

> Source brainstorm: [docs/brainstorm/2026-06-22-unified-signal-surface-brainstorm-doc.md](../brainstorm/2026-06-22-unified-signal-surface-brainstorm-doc.md)
> Design mockup: [docs/design/signal-surface-mockup.html](../design/signal-surface-mockup.html)
> Branch: `feat/unified-signal-surface` · Builds on the unified input FX & routing engine (PR #69).
>
> **Design-churn note:** the *visual* details (input-node layout, dock chrome,
> colours, exact affordances) are still being refined and will likely change.
> This plan is deliberately **modular**: the stable data/geometry/wiring work is
> isolated from the pure-visual node/dock rendering, so design edits stay
> contained to one phase and don't ripple through state or navigation.

## Overview

Collapse the loopstation's **three** node-and-wire surfaces into **one**
full-screen **Signal** canvas that matches the PR #69 engine model. Today FX is
configured twice, monitoring is buried in Audio Setup, and the same
inputs→tracks→outputs idea is split across the monitor graph, the routing tab,
and the per-track lane dialog. The Signal surface makes the **input** the single
home of a tone (gate + one FX chain + level + output), folds monitoring into that
node (an input that's *on* and routed *is* monitored), shows each take's FX as a
**snapshot** on the track lane, and keeps the structural **output gate** — all on
one canvas reached from the performance view.

This is a **presentation-only** rework: no engine, FFI, repository, bloc, or
persistence changes. It reuses the `routing_graph` kit and the existing
`MonitorCubit` / `LooperBloc` / `LooperState` from PR #69.

## Problem Statement

The PR #69 engine unified input FX & routing, but the UI was only mechanically
folded. Three surfaces remain, each a separate `GraphCanvas`:

1. **Monitor graph** — [lib/audio_setup/view/monitor_graph/](../../lib/audio_setup/view/monitor_graph/) — per-input live chain, reached from **Audio Setup**.
2. **Whole-system routing graph** — [lib/looper/view/tracks_routing_graph/](../../lib/looper/view/tracks_routing_graph/) — inputs→tracks→outputs + the output gate, reached from **Big Picture settings → Routing tab**.
3. **Per-track lane graph** — [lib/looper/view/lane_graph/](../../lib/looper/view/lane_graph/) — a track's lanes, reached from the **per-track routing dialog**.

User-confirmed pains: **FX configured twice** (input chain vs. track lane chain —
now the same thing at record time), **monitoring buried/separate** from the
performance flow, and **too many graph surfaces** for a now-simpler model. The
graph metaphor itself is wanted — only the fragmentation is the problem.

## Proposed Solution

One `SignalView` (full-screen route) with a single `GraphCanvas`:

```
   INPUTS (left)              TRACKS (middle)            OUTPUTS (right)
   rich node:                 track + lanes:             gated port:
   ⏻ gate (= monitor)         ◆ lane captures In N       ⏻ on/off gate
   FX chain (the tone)        ✦ "FX snapshot of In N"    greyed + struck when off
   level · output ●●          (post-record tweak)        edges still drawn when off
```

- **Input node = the FX home.** Gate toggle (this *is* "monitor this input"), the
  input's single FX chain (cards: drag-reorder + tap-edit), a level meter, and
  output dots. Editing the chain is what records (snapshot-on-record). Driven by
  `MonitorCubit` (existing single-chain API).
- **Track node = the captured take(s).** Tap a track to focus it, then tap inputs
  to capture them — each input→track wire is a **lane** with the input's FX
  **snapshot** badge. Absorbs the per-track lane dialog. Tapping a lane's snapshot
  badge opens the contextual dock in **"this take"** mode (the only post-record
  per-lane editor, D10). Driven by `LooperBloc` lane events.
- **Output node = a gated routing target.** Tap to toggle the structural gate
  (`LooperOutputEnabledToggled`); greyed + struck when off; edges still drawn; a
  non-blocking "no active outputs" notice when the last one is off.
- **One contextual dock** at the bottom that swaps by focus: focused **input** →
  its chain + selected-effect editor + mix/route; focused **lane** → the "this
  take" snapshot editor. View-local focus/selection state (as the existing graphs
  already do).
- **Live-monitor edges** (input routed straight to outputs) draw **only for the
  focused/hovered input**, keeping the canvas calm at high channel counts.
- **Scales 1→18**: the same zoom/pan canvas auto-fits compact for one input.

### Architecture

Strict VGV layering is untouched. The Signal surface is a **composition view** in
the presentation layer that watches and drives existing state — no new repository
or engine surface:

```
SignalView (new, full-screen route)
  ├── reads/drives  MonitorCubit          ── inputs: gate + single FX chain + out (PR #69)
  ├── reads/drives  LooperBloc + LooperState ── tracks/lanes (lane events) + output gate
  │                                            (LooperOutputEnabledToggled, LooperLane*Changed)
  ├── reads         AudioSetupCubit        ── octaver monitoring-lag hint (as monitor graph does)
  └── reuses        package:routing_graph  ── GraphCanvas, GraphEdge, ChannelChip,
                                              EffectChainCard, FocusableTapTarget, geometry
```

Reached as a route pushed from `BigPictureView`. `MonitorCubit`, `AudioSetupCubit`
and the repositories are all provided at the **app shell**, above
`LooperPage`/`BigPictureView`, so the pushed route re-provides all three of
`LooperBloc` + `MonitorCubit` + `AudioSetupCubit` with `BlocProvider.value` —
exactly the pattern `showMonitorRoutingPage` uses (it wraps the body in a
`BlocBuilder<AudioSetupCubit>` for the octaver-lag hint). Because the route sits
**inside** the
`LooperBloc` provider scope (unlike the settings page, which is pushed *above*
it), the output gate flows through the existing `LooperOutputEnabledToggled` bloc
event rather than a repo-direct call — this makes that (currently unused) event
live. (Gate **persistence** rides on the bloc's `_settings` being non-null, as the
event handler persists via `_settings?.saveOutputEnabled(...)`; the route must
provide the bloc with its `SettingsRepository`, as the shell already does.)

> **UI conventions (PROGRESS.md / `loopy-vgv-architecture-standards`):** new
> widgets use `LooperTheme` / `SurfaceTheme` `ThemeExtension` tokens — **no pixel
> dimensions in widget constructor APIs**, extract real widget classes (not
> `_buildX()` methods), `lib/common` can't import features. Reuse the
> `routing_graph` kit's geometry constants; keep semantic colours as params.

### Key decisions

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | **No new cubit** — `SignalView` composes `MonitorCubit` (inputs) + `LooperBloc` (tracks/lanes/output gate). Focus/selection is view-local. | Mirrors the existing graph views; nothing new to test at the state layer; the engine/repo already expose every needed setter. |
| D2 | **Compose existing geometry, don't re-derive it.** `SignalGraphLayout` reuses `RoutingGraph.fromTracks` (the inputs→tracks→outputs *structural* graph, incl. `outputEnabledMask`/`excludedInputMask`) for node/edge structure and the kit helpers (`cardColumnXs`/`chainEdges`/`fanEdges`/`positionedNode` + `MonitorGraphLayout`/`LaneGraphLayout`'s row math) for the FX-card columns — overlaying card positions + the focused-input monitor edges on top. It does **not** re-implement the column arithmetic. | The three surfaces already compute 80% of this; re-deriving it is duplicated code + duplicated tests (review CRITICAL-1/IMPORTANT-3). |
| D2b | **Capture-on-tap is NEW view logic, not reuse.** "Focus a track → tap In N → a lane appears" is a two-event composite: `LooperLaneCountChanged` (allocate the next lane, capped at `kMaxLanes`) then `LooperLaneInputChanged` (set that lane's input). Re-tapping a captured input **un-captures** it (drop the last lane recording that input via `LooperLaneCountChanged`); only the last lane is removable (stack semantics, as the lane graph today). At `kMaxLanes` the tap is a no-op. | The existing lane surface focuses an *existing* lane + a separate "Add lane" button; the Signal gesture inverts this and needs its own spec + test (review CRITICAL vgv-1). |
| D2c | **Consolidate the three near-identical channel chips** (`MonitorChannelChip`, `LaneChannelChip`, the routing graph's port chip) into one `ChannelChip` in `package:routing_graph` during Phase 1, before the old files are deleted. | Three 75-line copies of the same widget; deleting two surfaces shouldn't spawn a third copy (review IMPORTANT-4). |
| D3 | **Push from the performance view, inside the `LooperBloc` scope**, re-providing **all three** of `LooperBloc`, `MonitorCubit`, and `AudioSetupCubit` via `BlocProvider.value` (the last drives the octaver monitoring-lag hint, as `showMonitorRoutingPage` does). | Output gate uses the real bloc event; monitoring lives with performance, not Audio Setup. |
| D4 | **Delete the three old surfaces** (monitor graph, tracks routing graph, lane graph) once Signal covers them; migrate their tests onto `SignalView`. | "Fewer surfaces" is the whole point; leaving them is dead UI + double maintenance. |
| D5 | **Isolate visual churn to one phase.** Phase 1 ships a working Signal assembled from existing widgets; Phase 2 is the rich node + dock (the part likely to change); Phase 3 is the IA cleanup/deletion. | The design is still being refined — keep state + navigation stable while the look iterates. |
| D6 | **Audio Setup keeps only device setup** (device pickers, SR/buffer, exclusive mode, latency, loopback note). The `_monitorRouting` section + its button are removed. | Monitoring is no longer a "setup" concept; it's live performance on the Signal surface. |
| D7 | **Live-monitor edges render only for the focused/hovered input** (user choice). | Calm canvas at 18 channels; the routing is still discoverable on focus. |
| D8 | **One contextual dock** swapping input ↔ lane (user choice), not two-up. | Less crowding; the dock follows what you focus. |

### Implementation Phases (3 stacked PRs)

Each PR is independently mergeable and green.

---

#### Phase 1 (PR 1/3): `SignalGraphLayout` + `SignalView` scaffold (assembled from existing widgets)

**Goal:** a working unified Signal canvas reachable behind a temporary entry,
built by merging the three existing layouts — the old surfaces still exist.

- New `SignalGraphLayout` ([lib/looper/view/signal_graph/signal_graph_layout.dart](../../lib/looper/view/signal_graph/signal_graph_layout.dart)):
  geometry that **composes** the structural graph from `RoutingGraph.fromTracks`
  (inputs/tracks/outputs + masks + the output gate) and overlays the FX-card
  columns + focused-input live-monitor edges using the kit helpers
  (`cardColumnXs`/`chainEdges`/`fanEdges`/`positionedNode`) and the existing row
  math — **not** re-deriving the column arithmetic (D2).
- Consolidate the channel chips into one `ChannelChip` in `package:routing_graph`
  (D2c) so the merged canvas and the soon-to-delete surfaces share one widget.
- New `SignalView` ([lib/looper/view/signal_graph/signal_view.dart](../../lib/looper/view/signal_graph/signal_view.dart))
  + `showSignalPage(context)`: a `GraphCanvas` wired to the layout, **reusing the
  existing node widgets as-is** for this phase (`MonitorInputNode`, `LaneNode`,
  the shared `ChannelChip`) with view-local focus/selection. Drives `MonitorCubit`
  (input edits) + `LooperBloc` (lane wiring, output gate). Implements the
  **capture-on-tap** gesture per D2b (allocate-lane-then-set-input; re-tap
  un-captures; cap/stack semantics).
- **Wire the real entry now**, not a throwaway: add the `BigPictureView` keyboard
  shortcut + a visible chrome entry alongside the `S`→settings handler (two lines).
  This avoids an orphaned temporary button (review CRITICAL-2); Phase 3 then does
  deletions only.
- Tests: `signal_graph_layout_test.dart` (geometry from a seeded `MonitorState` +
  `LooperState`: capture/playback/focused-monitor/gated-output edges; 1-input
  compact vs 4×4 fit; derive-counts-when-stopped). `signal_view_test.dart`
  (renders; tap-input-enables-monitor; **capture-on-tap**: tap-track-then-input
  allocates a lane + sets its input, re-tap un-captures, no-op at `kMaxLanes`;
  tap-output-toggles the gate → `LooperOutputEnabledToggled`; **focus/selection
  dropped without exception** when a focused input is disabled / a focused track
  cleared mid-build; a11y labels).
- **Success:** Signal renders, edits inputs/lanes/outputs, and is reachable from
  performance; old surfaces still present; `flutter analyze` clean; tests green.
- **Effort:** M.

---

#### Phase 2 (PR 2/3): Rich input node + one contextual dock (the visual surface)

**Goal:** the design from the mockup — the part most likely to keep changing,
deliberately isolated here.

- `SignalInputNode` ([lib/looper/view/signal_graph/signal_input_node.dart](../../lib/looper/view/signal_graph/signal_input_node.dart)):
  the rich input node — gate toggle (labelled as monitor/live), the single FX
  chain (cards, drag-reorder via the kit's `EffectChainCard` + `EffectDropZone`,
  tap-to-edit), a level meter, output dots — replacing the plain `MonitorInputNode`
  in the canvas. "tone → records onto the take" affordance.
- `SignalDock` ([lib/looper/view/signal_graph/signal_dock.dart](../../lib/looper/view/signal_graph/signal_dock.dart)):
  one docked bottom panel that **swaps by focus** via **two subtree widget
  classes** (not one conditional body) — `SignalInputDock` (chain +
  `EffectParamsEditor` + mix/route, ~1:1 with `MonitorInputPanel`) and
  `SignalLaneDock` (the **"this take"** snapshot editor, scoped to that lane,
  clearly labelled). `SignalDock` just picks which to render by the focused kind.
- Output node treatment: reuse the routing graph's `excluded` render for gated-off
  outputs (greyed, line-through, non-targetable, edges still drawn) + the
  non-blocking "no active outputs" notice (E1/F-12 from PR #69, already in the
  routing graph — port it here).
- Focus/hover: focus ring on the focused input; **live-monitor edges only for the
  focused/hovered input** (D7).
- Theme tokens only (`SurfaceTheme`/`LooperTheme`); no pixel params in node APIs.
- Tests: `signal_input_node_test.dart`, `signal_dock_test.dart` — gate toggle,
  add/edit/reorder FX (→ `MonitorCubit`), level/output edits, dock swaps
  input↔lane, "this take" edits only that lane (→ `LooperBloc` lane events),
  snapshot badge, **accessibility** (`find.bySemanticsLabel` / `meetsGuideline`)
  for the gate, the disabled output, and the dock context. **Migrate the
  load-bearing widget-level assertions** from the three old surfaces' tests onto
  these new node/dock tests **here** (not in Phase 3), so Phase 3 is pure
  deletion. Keep NF-2 honest: node sizing comes from the kit geometry constants +
  `SurfaceTheme`/`LooperTheme` tokens — a Phase-2 review checkpoint that the rich
  `SignalInputNode` API exposes **no pixel doubles**.
- **Success:** the Signal surface matches the (current) design; coverage migrated;
  widget tests green; `flutter analyze` clean.
- **Effort:** L (the visual surface; expect iteration).

---

#### Phase 3 (PR 3/3): Make Signal the only surface — IA cleanup + deletions

**Goal:** Signal becomes the single signal surface; the three old surfaces and
their entries are removed. The Signal entry was already wired in Phase 1, so this
PR is **deletions + reference cleanup + test mapping only** — no new behaviour.

- Remove the monitor entry from Audio Setup: drop `_monitorRouting` + the
  `showMonitorRoutingPage` button + the monitoring group label from
  [lib/audio_setup/view/audio_settings_section.dart](../../lib/audio_setup/view/audio_settings_section.dart).
  Audio Setup keeps device/SR/buffer/exclusive/latency/loopback only.
- Remove the Routing tab from Big Picture settings
  ([lib/looper/view/big_picture_settings_page.dart](../../lib/looper/view/big_picture_settings_page.dart)):
  drop `_Section.routing` + `_routingSection` (the whole-system graph now lives on
  Signal).
- Remove the per-track lane dialog
  ([lib/looper/view/track_routing_dialog.dart](../../lib/looper/view/track_routing_dialog.dart))
  and its entry (per-track wiring is on Signal).
- **Delete** the three view dirs once nothing references them:
  `lib/audio_setup/view/monitor_graph/`, `lib/looper/view/tracks_routing_graph/`,
  `lib/looper/view/lane_graph/`.
- Ship an explicit **old-test → new-home mapping table** in the PR description so
  reviewers can verify coverage was preserved, not silently dropped. Each deleted
  test file (`test/audio_setup/view/monitor_graph/*`,
  `test/looper/view/tracks_routing_graph/*` incl. `routing_edit_test` /
  `graph_node_test` / `routing_graph_test`, `test/looper/view/lane_graph/*`,
  `test/looper/view/track_routing_dialog_test.dart` — ~1.3k lines) maps to one of:
  (a) already covered by the Phase-1/2 `signal_*` tests, (b) **kept** because it
  tests a `package:routing_graph` primitive that still exists (move it under the
  kit's own tests), or (c) intentionally dropped (state why). Since node/dock
  coverage was migrated in Phase 2 (R2 mitigation), this PR mostly `git rm`s.
- Update `big_picture_settings_page_test` (no Routing tab) and
  `audio_settings_section_test` (no monitor section).
- Screenshot/goldens: this PR only **re-points filenames/structure** at the new
  surface; the actual pixel regeneration is the author-only `screenshots`-tagged
  task (PROGRESS.md), not a CI blocker — consistent with Out of Scope below.
- **Success:** one signal surface; no dangling references; `flutter analyze`
  clean; `MonitorCubit.load()` restore path still drives the inputs on Signal;
  macOS app builds end-to-end.
- **Effort:** M–L (mostly deletions + test migration).

## User flows & edge cases

- **Set a tone & hear it:** open Signal → tap In 1 (gate on, live to its outputs)
  → add/edit FX on In 1 → audible. That *is* monitoring. (F1)
- **Record what you hear:** arm/record a track (existing transport) → a lane wired
  from In 1 appears with a snapshot badge; playback re-applies the In 1 tone.
  Editing In 1 afterwards leaves the take unchanged. (F2 — guaranteed by the PR #69
  engine.)
- **Tweak a take:** tap the lane snapshot badge → dock → "this take" editor →
  edits affect only that lane. (F3)
- **Capture a 2nd input into a track:** focus the track → tap In 2 → 2nd lane +
  its own snapshot. (F4)
- **Gate an output:** tap Out 4 → greyed/struck; routes kept; tap again restores;
  last-output-off shows the notice. (F5)
- **Edge cases to cover in tests:** engine **stopped** (0 in/0 out — derive node
  counts from masks, like `RoutingGraph.fromTracks`); an input that is **off** but
  still feeds a recorded lane (the lane snapshot persists — PR#69-D8:
  recording independent of the monitor gate); a track routed **only** to a
  gated-off output (edge still drawn — discoverable, F-11); a **loopback-excluded**
  input (dim, never monitorable/capturable); **empty** state (no tracks recorded
  yet — inputs + outputs still wire-able); **focus/selection dropped** when its
  node disappears (input disabled, track cleared) — render cleared this frame
  without mutating state during build (as the existing graphs do).

## Acceptance Criteria

### Functional

- [ ] **F-1** One `SignalView` renders inputs→tracks→outputs on a single canvas
      with bezier edges; reachable as a full-screen route from the performance view.
- [ ] **F-2** An input node is the **only** FX home: its single chain edits drive
      `MonitorCubit`; there is no second input-FX surface.
- [ ] **F-3** An input that is enabled (gate on) and routed to outputs is audible
      live (monitoring) — no separate monitor screen/concept remains.
- [ ] **F-4** Tap a track to focus, tap inputs to capture → each is a lane with an
      FX-snapshot badge; tapping a lane opens the dock's "this take" editor scoped
      to that lane only.
- [ ] **F-5** Tap an output to toggle its structural gate via
      `LooperOutputEnabledToggled`; greyed/struck + non-targetable when off; edges
      to it still drawn; "no active outputs" notice when the last is off.
- [ ] **F-6** Live-monitor edges render only for the focused/hovered input (D7).
- [ ] **F-7** The dock is a single panel that swaps between focused-input controls
      and the focused-lane "this take" editor (D8).
- [ ] **F-8** The same canvas auto-fits compact for a 1-input rig and zoom/pans for
      a multichannel (≥4×4) rig.
- [ ] **F-9** The monitor graph, the settings Routing tab, and the per-track lane
      dialog are removed; their three view dirs are deleted; Audio Setup keeps only
      device setup.

### Non-Functional

- [ ] **NF-1** No engine/FFI/repository/bloc/persistence changes — presentation
      only on the PR #69 engine.
- [ ] **NF-2** New widgets use `SurfaceTheme`/`LooperTheme` tokens; no pixel
      dimensions in widget constructor APIs; real widget classes (not `_buildX`).
- [ ] **NF-3** Accessibility: the gate toggle, the disabled output, the snapshot
      badge, and the dock context have semantic labels — **asserted in widget
      tests** (`find.bySemanticsLabel` / `meetsGuideline`).
- [ ] **NF-4** `MonitorCubit.load()` restore still drives the Signal inputs on a
      cold start (no second restorer).

### Quality Gates

- [ ] Every new widget + the layout has a test; geometry (`SignalGraphLayout`)
      proven for capture/playback/monitor/gated edges + compact vs multichannel.
- [ ] Coverage migrated from the three deleted surfaces (wiring, gating, a11y) is
      preserved on `SignalView`.
- [ ] `flutter analyze` clean; tests via the absolute flutter path (PROGRESS.md
      gotcha); macOS app builds end-to-end.
- [ ] PROGRESS.md updated as each PR lands; code-review approval per PR.

## Files (create / modify / delete)

**Create** (`lib/looper/view/signal_graph/`): `signal_graph_layout.dart`,
`signal_view.dart` (+ `showSignalPage`), `signal_input_node.dart`,
`signal_dock.dart` (+ a `signal_graph.dart` barrel). Tests:
`test/looper/view/signal_graph/{signal_graph_layout,signal_view,signal_input_node,signal_dock}_test.dart`.

**Modify:** `lib/looper/view/big_picture_view.dart` (Signal key + entry),
`lib/audio_setup/view/audio_settings_section.dart` (remove monitor section),
`lib/looper/view/big_picture_settings_page.dart` (remove Routing tab), l10n arb
(Signal title, hints, action labels), PROGRESS.md.

**Delete:** `lib/audio_setup/view/monitor_graph/` (5 files),
`lib/looper/view/tracks_routing_graph/` (4 files),
`lib/looper/view/lane_graph/` (5 files), `lib/looper/view/track_routing_dialog.dart`,
and their now-dead tests (migrating retained coverage onto `SignalView`).

## Alternative Approaches Considered

1. **Mixer channel-strips lead, graph demoted to a read-only overview.** Simpler
   for 1–2 inputs but demotes the graph the user values and is less spatial for
   many-to-many output routing. **Rejected.**
2. **FX home on the track, not the input.** Re-creates the "configure per take"
   feel the PR #69 feature set out to kill. **Rejected.**
3. **Keep per-track lane wiring in a separate focused view** (don't fully fold).
   Less crowded canvas but reintroduces a surface — against the "fewer surfaces"
   goal. **Folded in instead** (track focus + input taps).
4. **A new `SignalCubit` owning focus/wiring.** Unneeded — focus is view-local and
   every edit already has a `MonitorCubit`/`LooperBloc` setter. **Rejected (YAGNI).**

## Risks & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| **R1** Design keeps changing, churning the implementation | High | Med | Phase split (D5): Phase 1 (geometry/wiring) + Phase 3 (IA) are stable; visual churn is confined to Phase 2's node + dock. |
| **R2** Deleting three surfaces loses test coverage | Med | High | Node/dock coverage is migrated onto the `signal_*` tests in **Phase 2** (not the deletion PR), so Phase 3 is `git rm` + cleanup; Phase 3 ships an explicit old-test→new-home mapping table so dropped vs. moved coverage is auditable, not assumed. |
| **R3** One canvas too dense at 18 channels | Med | Med | Focused-only monitor edges (D7); zoom/pan + auto-fit; compact 1-input layout proven by a test. |
| **R4** `MonitorCubit`/`LooperBloc` not both in scope on the Signal route | Low | Med | Push from `BigPictureView` (inside both providers) and re-provide via `.value`, mirroring `showMonitorRoutingPage`. |
| **R5** Removing the settings Routing tab breaks the whole-system overview some users relied on | Low | Low | The Signal canvas *is* the whole-system overview now (inputs→tracks→outputs), so nothing is lost. |

## Out of Scope / Future

- No engine/data changes (PR #69 is the foundation; commit/freeze stays deferred).
- Multi-input-per-track is supported via track-focus + input taps; no new
  multi-lane *engine* behaviour.
- Drag-to-rewire In→Lane (currently tap-while-focused) — a later polish.
- Per-lane waveform thumbnails inside the track node — later.
- Golden/screenshot regeneration for the new surface (the existing screenshot
  goldens already need regen after any UI change).

## References

- Brainstorm: [docs/brainstorm/2026-06-22-unified-signal-surface-brainstorm-doc.md](../brainstorm/2026-06-22-unified-signal-surface-brainstorm-doc.md)
- Design mockup: [docs/design/signal-surface-mockup.html](../design/signal-surface-mockup.html)
- Engine foundation: PR #69 (unified input FX & routing) + [docs/plan/2026-06-22-feat-unified-input-fx-routing-plan.md](2026-06-22-feat-unified-input-fx-routing-plan.md)
- Shared kit: `package:routing_graph` ([packages/routing_graph/lib/routing_graph.dart](../../packages/routing_graph/lib/routing_graph.dart))
- Surfaces to merge: [monitor_graph/](../../lib/audio_setup/view/monitor_graph/), [tracks_routing_graph/](../../lib/looper/view/tracks_routing_graph/), [lane_graph/](../../lib/looper/view/lane_graph/)
- State reused: `MonitorCubit` ([lib/audio_setup/cubit/monitor_cubit.dart](../../lib/audio_setup/cubit/monitor_cubit.dart)), `LooperBloc` ([lib/looper/bloc/looper_bloc.dart](../../lib/looper/bloc/looper_bloc.dart)), `LooperState.outputEnabledMask`
- Nav pattern: `BigPictureView` key handling ([lib/looper/view/big_picture_view.dart:230](../../lib/looper/view/big_picture_view.dart))
- Build/test gotchas: [docs/PROGRESS.md](../PROGRESS.md)
