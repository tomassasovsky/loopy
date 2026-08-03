---
title: "feat(console): give the settings tray its own navigation rail"
type: feat
date: 2026-08-03
issue: 442
parent-plan: 2026-08-03-feat-console-ui-fx-v3-redesign-plan.md
---

> **Session setup:** Opus at medium effort · `autonomy:merge-gate` · check the status table in [the execution guide](2026-08-03-feat-console-ui-fx-v3-redesign-execution-guide.md) before starting, and update it before ending.

## Overview

Turn the tray from a tile grid with two in-tray faces into a **rail-driven
panel host**: a persistent vertical navigation rail down the left of the open
sheet, with the face it selects filling the rest. This is the shell parts 4
(FX), 5 (Routing) and 7 (Pedal) mount into — after this part, adding a config
surface to the console is "add a destination", not "push another full-screen
route".

Shell only. No new config surface ships here, and every destination reachable
today stays reachable and behaves identically.

## Scope correction to the index

Two things the index plan assumed that the code contradicts. Both narrow this
part; neither changes the epic.

1. **The tray is already near-fullscreen.** `trayHeight` is the full screen
   height (`settings_tray.dart:130`) and `_TrayPanel` already swaps faces
   through an `AnimatedSwitcher` keyed on `state.destination` (`:374-395`).
   There is no "grow the tray" work — the rail replaces the *centred face
   switch*, and the existing switcher is kept.
2. **No placeholder destinations.** The index said to land the full
   destination enum now so later parts need not touch it. Rejected: that ships
   three dead rail items — FX, Routing, Pedal — that do nothing when tapped.
   Each of parts 4, 5 and 7 adds its own enum value, rail item and panel in
   one commit instead. Touching a two-line enum is not a cost worth a stub in
   front of the user.

So the rail ships with the faces that exist today: **Home**, **Tuner**,
**WiFi**, **Bluetooth**.

## Dependencies

None. This part can start immediately.

## Context

Key files (all paths repo-relative):

- `lib/looper/view/settings_tray.dart` (833 lines) — the whole tray.
  `SettingsTray` (:43) owns the drag/scrim/handle `Stack`; `_TrayHandle`
  (:231) owns **all** drag recognition; `_TrayPanel` (:300) is the open sheet
  and holds the face `AnimatedSwitcher` (:348) keyed on `state.destination`;
  `_RadioDivision` (:411) is the fixed 520×680 footprint for the WiFi/BT
  faces; `_TrayHome` (:430) is the tile grid + brightness; `_TrayTile` (:628);
  `_BrightnessSliderTile` (:717).
- `lib/looper/cubit/settings_tray_cubit.dart` — `openWifi` (:103),
  `openBluetooth` (:111), `showHome` (:119), `closeTray` (:85, resets the
  destination to `home` on every close), `beginNavigating`/`endNavigating`
  (:124, :127).
- `lib/looper/cubit/settings_tray_state.dart:5` — `SettingsTrayDestination`
  (`home | wifi | bluetooth`), and `dragProgress` (:33), the **single** source
  of truth for open/closed.
- `lib/looper/view/coming_soon_stub.dart:8` — `showComingSoonStub`, the
  `AlertDialog` the Tuner tile opens today (`settings_tray.dart:549-560`).
- `lib/wifi/wifi_tray_panel.dart`, `lib/bluetooth/bluetooth_tray_panel.dart` —
  the two existing faces. Both take `onBack: cubit.showHome`.
- `lib/theme/surface_theme.dart` — `SurfaceTheme`, the only source of colour
  and dimming tokens [VGV]. No ad-hoc opacity constants, no pixel params in
  widget APIs.
- `routing_graph`'s `FocusableTapTarget` (imported at
  `settings_tray.dart:18`) — the established focusable/semantic tap target;
  rail items use it, they do not hand-roll focus.
- `lib/l10n/arb/app_en.arb` + `app_es.arb` — both ARBs change together,
  always. Existing strings to reuse: `trayWifiLabel`, `trayBluetoothLabel`,
  `trayTunerLabel`, `trayBrightnessLabel`, `a11yTrayHandle`, `dismiss`.
- `test/looper/view/settings_tray_test.dart`,
  `test/looper/cubit/settings_tray_cubit_test.dart` — existing coverage.
- `test/screenshots/goldens/control_center_tray.png` — author-only golden;
  this part **will** change it. Regenerate and eyeball.

## Decisions (pinned — from the index, do not revisit)

- **D6 — the Tuner is a rail destination, not a full-screen takeover, and this
  epic does not implement it.** The tile's `showComingSoonStub` *dialog*
  becomes an in-tray face carrying the same "coming soon" message. Placement
  now, pitch detection never (in this epic).
- **The rail hosts in-tray faces only.** Settings and Signal keep their tiles
  on the Home face and keep pushing full-screen routes
  (`settings_tray.dart:460`, `:476`), with the `isNavigating` guard intact. A
  rail item that pushes a route would lie about what the rail is. Part 5
  retires the Signal push; Settings keeps its own page (nesting the settings
  page's own rail inside the tray's rail is not on the table).
- **`dragProgress` stays the only open/closed bit.** A destination must never
  become a second, desyncable "is it open" signal. `closeTray` keeps resetting
  the destination to `home`.

## Tasks

1. **Widen the destination enum** (`settings_tray_state.dart:5`) with `tuner`.
   Add `openTuner()` to the cubit beside `openWifi`/`openBluetooth`, following
   the same `dragProgress: 1` + destination shape.
2. **Add the rail.** New widget file (e.g.
   `lib/looper/view/tray/tray_navigation_rail.dart`) — a vertical list of
   destination items built on `FocusableTapTarget`, selected state from
   `SurfaceTheme.accent`, driven by `SettingsTrayCubit`. Extracted widget
   classes, never `_build` methods [VGV].
3. **Restructure `_TrayPanel`** into `Row(rail, Expanded(faceSwitcher))`,
   keeping the existing `AnimatedSwitcher`, its curves and its
   `KeyedSubtree(key: ValueKey(state.destination))`. The full-bleed
   dismiss `GestureDetector` (:330-339) must stay *behind* both, and the rail
   must sit above it — verify a rail tap does not dismiss the tray.
4. **Make the Tuner an in-tray face**, replacing the dialog call at `:549-560`
   with `cubit.openTuner`. The face states plainly that it is not implemented
   yet; reuse `trayComingSoonMessage` rather than inventing a second string
   for the same idea. Delete `coming_soon_stub.dart` **only** if nothing else
   calls it — grep first.
5. **Split the file.** `settings_tray.dart` is 833 lines before this change.
   Extract at minimum `_TrayPanel`, `_TrayHome`, `_TrayTile` and
   `_BrightnessSliderTile` into their own files under `lib/looper/view/tray/`,
   preserving every doc comment verbatim — several encode hard-won gesture and
   semantics lessons (the drag-recognition isolation note at `:225-230`, the
   `Listener`-not-`GestureDetector` note at `:783-788`, the Slider semantics
   note at `:759-766`). Losing those is a regression even though nothing
   fails.
6. **l10n** — one new ARB string for the rail's accessibility label, in both
   `app_en.arb` and `app_es.arb`.

## Testing

- Rail item selection emits the right destination; the face switches.
- Tapping the rail does **not** close the tray (the dismiss detector sits
  behind it).
- `closeTray` still returns to `home`, so re-opening never lands on Tuner.
- The WiFi/BT long-press path still reaches the same faces the rail now also
  reaches — both entry points, one destination.
- Tuner opens a face, not a dialog. No `AlertDialog` in the tree.
- Semantics: the rail is excluded from the tree while the tray is closed
  (`ExcludeSemantics` at `:176`), focus order runs rail → face, and every rail
  item has a label.
- Brightness slider gestures still work — the drag-recognition isolation
  (`:225-230`) is the thing most likely to break silently when a new
  interactive region joins the open panel. Cover it.
- Regenerate `test/screenshots/goldens/control_center_tray.png` and look at
  it. It skips on CI and rots silently.

## Exit criteria

- Every destination reachable before this part is reachable after it, by the
  same gestures plus the rail — **with one deliberate exception**: the Tuner
  *tile* is removed from the home face, because the rail item sits permanently
  on screen and a tile that only opens it is pure duplication. The
  destination is not lost, the tile is. WiFi and Bluetooth keep their tiles
  because those are toggles, not just destinations. This also means the cubit
  needs no `openTuner()` — `showDestination` is the rail's one entry point,
  and a method with no production caller would be dead code with a passing
  test in front of it.
- `flutter test` green, `dart analyze` clean, native + firmware gates
  untouched (no code in their paths).
- The golden is regenerated and eyeballed, not just deleted.
- `settings_tray.dart` is meaningfully smaller and no doc comment was lost.

## Non-goals

- No FX, Routing or Pedal destination (parts 4, 5, 7).
- No tuner implementation (D6).
- No change to Settings or Signal navigation (part 5 retires the Signal push).
- No change to the drag/settle physics, the handle, or the scrim.
