# feat: collapse the Signal surface FX into chip strips (FX redesign, part 3)

- Type: enhancement (UI, structural)
- Status: planned
- Branch: `feat/fx-screen-redesign`
- Date: 2026-07-03

## Dependencies

**Depends on part 2** — requires `showFxEditorPage`. Sequence after parts 1 + 2.

## Context (shared)

Part 3 of the FX-screen redesign. Full rationale and current-state map in the
overview:
[2026-07-03-feat-fx-screen-redesign-plan.md](2026-07-03-feat-fx-screen-redesign-plan.md).

Goal: the Signal surface becomes routing + a compact FX summary only. The bottom
docks' inline FX racks (walls of knobs) are replaced by tappable **chip strips**
that open the part-2 editor for the relevant scope. Mixing controls stay on the
routing surface (the editor is tone only).

Key current-state facts:
- A track has up to `kMaxLanes` lanes that play back together, each with its own
  `effects` (`lane.dart:11`, cap at `signal_list_view.dart:341`).
- `_MixControl` (volume/mute) lives in both docks (`signal_dock.dart:11`).
- Add/remove-lane controls live in `SignalLaneDock` (`signal_dock.dart:317-336`).
- Empty lane shows `signalLaneCleanHint` (`signal_dock.dart:341`).

## Tasks

- [ ] `lib/looper/view/signal_graph/signal_dock.dart` — remove `SignalFxRack` from
      `SignalInputDock`/`SignalLaneDock`; replace with a compact FX **chip strip**
      summary (named blocks, on/off) that calls `showFxEditorPage`.
  - [ ] **Multi-lane:** render **one chip strip per lane** (not one per track);
        each opens the editor for that lane's scope.
  - [ ] **Relocate add/remove-lane** controls (`signal_dock.dart:317-336`) onto
        the track's routing card so they survive the dock removal.
  - [ ] **Mix controls stay:** keep `_MixControl` (volume/mute) on the
        input/lane routing card.
- [ ] `lib/looper/view/signal_graph/signal_list_view.dart` — remove the dock's
      expanded rack; wire focus → chip strip → editor; preserve `signalLaneCleanHint`
      for empty lanes.
- [ ] **Delete `signal_fx_rack.dart` outright** (superseded by the editor, which
      reused its drag mechanics in part 2). Remove it and its exports — no
      conditional "slim if superseded".
- [ ] **l10n:** any new chip-strip copy via `context.l10n` (add en + es keys).

## Tests

- [ ] Update `signal_dock_test.dart` / `signal_list_view_test.dart` for the chip
      strip + navigation to the editor; per-lane strips on a multi-lane track;
      add/remove-lane in its new home.
- [ ] Regenerate `test/screenshots/goldens/signal_surface.png` (now dock-free).

## Acceptance criteria

- The Signal surface shows routing + a compact FX summary only; no inline knob
  walls.
- Tapping an input/lane FX summary opens the editor for that scope.
- Multi-lane tracks render one chip strip per lane; add/remove-lane survives the
  dock removal; volume/mute stay on the routing card.
- Grep: zero remaining `SignalFxRack` references (dead code fully removed).
- All new copy via `context.l10n` (en + es ARB keys added).
- `flutter analyze` clean; tests + goldens pass.
