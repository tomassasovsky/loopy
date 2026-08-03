---
title: "feat(console): reach pedal assignment from the tray rail"
type: feat
date: 2026-08-03
issue: 442
parent-plan: 2026-08-03-feat-console-ui-fx-v3-redesign-plan.md
---

> **Session setup:** Sonnet at medium effort · `autonomy:auto` · check the status table in [the execution guide](2026-08-03-feat-console-ui-fx-v3-redesign-execution-guide.md) before starting, and update it before ending.

## Overview

Give the pedal-assignment surface a rail destination, so it is one gesture
from the stage instead of three levels deep in Settings. Closes **#440** — the
bug that triggered this whole epic.

Re-mount, not rewrite: part 6a already extracted the presentational
`PedalPlate`, and part 6b built the assignment UI on top of it. This part
lifts that UI out of its `Scaffold` so the same widget serves both the tray
face and the existing pushed route.

## Dependencies

Part 1 (the navigation rail) must be merged — this part adds a destination to
the shell it created.

## Context

- `lib/pedal/view/pedal_assignment_page.dart` — `showPedalAssignmentPage`
  (:18) pushes the route; `PedalAssignmentPage` (:41) is
  `Scaffold(appBar, body: ListView[intro, _PlatePicker, _Editor])`. The
  `ListView` body is the part worth sharing; the `Scaffold` and `AppBar` are
  route chrome the tray face replaces with `HostTrayChromeBar`.
- `_PlatePicker` (:110) wraps `PedalPlate` in an
  `AspectRatio(846 / 406.6)` — **2.08:1, very wide**. The radio faces' 520×680
  portrait frame is the wrong shape for it.
- `lib/pedal/view/pedal_settings_section.dart:88` — the Settings → Audio entry
  point that opens the pushed route today.
- `lib/looper/view/tray/tray_panel.dart` — `_TrayFaceFrame` (fixed 520×680)
  and the destination `switch` that a new enum value forces open.
- `lib/looper/view/tray/tray_navigation_rail.dart` — `_iconFor` / `_labelFor`
  are exhaustive switches, so the compiler names both places to update.
- **Providers:** `ControlCubit` (`app.dart:341`) and `LooperRepository` are
  provided above `LooperPage`, so they are already in scope where the tray
  mounts. The tray face needs no re-provision — unlike
  `showPedalAssignmentPage`, which re-provides precisely because a pushed
  route does not inherit them.
- `test/pedal/view/pedal_assignment_page_test.dart` and
  `test/looper/view/settings_tray_test.dart` — existing coverage.

## Tasks

1. **Extract the body.** Lift the `ListView` out of `PedalAssignmentPage` into
   a public `PedalAssignmentView` in the same file, holding the `_selected` /
   `_bank` state. `PedalAssignmentPage` becomes `Scaffold(appBar, body:
   PedalAssignmentView())`. No behaviour change, no new state.
2. **Add the `pedal` destination** to `SettingsTrayDestination`, placed
   directly after `home` — it is the most-used config surface on the console,
   and rail order is enum order.
3. **Add the face:** `PedalTrayPanel`, `HostTrayChromeBar` + a
   `PedalAssignmentView`, following `TunerTrayPanel`'s shape.
4. **Give the face its own frame.** `_TrayFaceFrame` gains an optional size so
   the pedal face can be landscape while the radios stay 520×680. Do not
   stretch the plate into a portrait box.
5. **Keep the Settings → Audio entry point.** Deliberate, not an oversight:
   the tray is the console path, Settings is the desktop path, and both now
   render the same `PedalAssignmentView`. Say so in a comment so the next
   reader does not "clean up" one of them.

## Testing

- The rail exposes a `pedal` item; selecting it shows the face and leaves the
  tray open.
- The face renders the plate and the editor, and selecting a footswitch on it
  edits that switch's binding — i.e. the extraction did not drop the state.
- The pushed route still works from Settings → Audio → Pedal.
- `closeTray` still returns to `home` from the pedal face.
- Regenerate and eyeball the screenshot goldens.

## Exit criteria

- #440 is closed: pedal assignment is reachable from the tray in one gesture.
- Behaviour of the existing pushed route is unchanged.
- `flutter test` green, `dart analyze` clean, goldens regenerated.

## Non-goals

- No Custom pedal mode (part 8), and no protocol work.
- No change to the binding model, the target picker, or `PedalPlate`.
